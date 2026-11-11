require_relative "config"
require_relative "api"
require_relative "throttle"
require_relative "bot_guard"
require "roda"
require "mail"

# Dev: print emails (verification and reset links) to the terminal. Test: keep them in memory.
class ConsoleMail
  attr_reader :settings # Mail reads this after delivering
  def initialize(settings) = @settings = settings
  def deliver!(mail) = puts("\n--- Email to #{mail.to.join(', ')}: #{mail.subject}\n#{mail.body.decoded}\n---\n")
end

Mail.defaults do
  case ENV["RACK_ENV"]
  when "test" then delivery_method :test
  when "production"
    delivery_method :smtp, address: ENV.fetch("SMTP_HOST"), port: Integer(ENV.fetch("SMTP_PORT", "587")),
                           user_name: ENV.fetch("SMTP_USER"), password: ENV.fetch("SMTP_PASSWORD"), enable_starttls: true
  else delivery_method ConsoleMail
  end
end

class App < Roda
  use Throttle
  PRODUCTION = ENV["RACK_ENV"] == "production"

  plugin :default_headers, {
    "Content-Type" => "text/html; charset=UTF-8",
    "X-Content-Type-Options" => "nosniff",
    "Referrer-Policy" => "same-origin",
    "Strict-Transport-Security" => ("max-age=63072000; includeSubDomains" if PRODUCTION)
  }.compact
  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.script_src :self            # app.js and the copied d3 files; nothing inline, no CDNs
    csp.connect_src :self           # the page's own /api calls
    csp.style_src :self, :unsafe_inline
    csp.font_src :self              # Instrument Sans, served from public/fonts
    csp.img_src :self
    csp.form_action :self
    csp.base_uri :none
    csp.frame_ancestors :none
    if Turnstile.enabled? # Cloudflare's bot check loads a script and an iframe on the sign-up page
      csp.script_src :self, "https://challenges.cloudflare.com"
      csp.frame_src "https://challenges.cloudflare.com"
    end
  end

  plugin :sessions, secret: ENV.fetch("SESSION_SECRET"), key: "jt.session",
                    cookie_options: { httponly: true, same_site: :lax, secure: PRODUCTION }
  plugin :flash
  plugin :route_csrf, csrf_failure: :empty_403 # a form without a valid token gets a plain 403
  plugin :render, escape: true, layout: "layout"
  plugin :public # public/: the page's html, css, js and d3 (no user data in them)

  plugin :rodauth do
    db DB
    enable :create_account, :verify_account, :login, :logout, :reset_password,
           :change_password, :lockout, :close_account
    hmac_secret ENV.fetch("HMAC_SECRET")
    # Email links must use the real site address, never the request's Host header.
    app_url = PRODUCTION ? ENV.fetch("APP_URL") : ENV.fetch("APP_URL", "http://localhost:4570")
    base_url app_url
    domain URI(app_url).host
    already_logged_in { redirect "/" } # e.g. visiting /login while logged in
    email_from ENV.fetch("MAIL_FROM", "Job Tracker <no-reply@localhost>")

    verify_account_set_password? false # pick the password at sign-up
    require_login_confirmation? false
    password_minimum_length 10
    password_maximum_bytes 72          # bcrypt ignores anything past 72 bytes
    max_invalid_logins 10              # then the account locks until the emailed unlock link is used
    # Closing an account deletes the account row; applications, timeline steps and referrals cascade.
    delete_account_on_close? true

    # Bot protection on sign-up: a hidden field people never fill, Turnstile when configured, and the email cap.
    create_account_additional_form_tags do
      honeypot = %(<div class="hp" aria-hidden="true"><label>Leave this empty <input type="text" name="website" tabindex="-1" autocomplete="off"></label></div>)
      check = Turnstile.enabled? ? %(<div class="cf-turnstile" data-sitekey="#{Turnstile.site_key}"></div><script src="#{Turnstile::SCRIPT}" async defer></script>) : ""
      honeypot + check
    end
    before_create_account_route do
      next unless request.post?
      unless param("website").empty? # a bot filled the invisible field: act as if it worked, create nothing
        set_notice_flash verify_account_email_sent_notice_flash
        redirect login_path
      end
      if Turnstile.enabled? && !Turnstile.passed?(param("cf-turnstile-response"), request.ip)
        set_redirect_error_flash "Please complete the security check and try again."
        redirect create_account_path
      end
      if EmailCap.reached?
        set_redirect_error_flash EmailCap::Reached.new.message
        redirect create_account_path
      end
    end
    send_email do |email|
      EmailCap.take! # raises past the cap, which rolls back whatever triggered the email
      super(email)
    end
    login_redirect "/"
    login_return_to_requested_location? true # e.g. back to the bookmarklet popup after logging in
    logout_redirect "/login"
  end

  include Api
  plugin :all_verbs # r.patch, r.delete
  plugin :json
  plugin :json_parser, error_handler: ->(r) { r.halt([400, { "content-type" => "application/json" }, ['{"error":"Bad JSON"}']]) }

  route do |r|
    r.on "api" do
      account = rodauth.logged_in? && rodauth.account_from_session or
        r.halt([401, { "content-type" => "application/json" }, ['{"error":"Log in first"}']])
      # The page sends one token in a header (from GET /api/session); forms keep per-form tokens.
      check_csrf!(check_header: true, require_request_specific_tokens: false)
      api_routes(r, account[:id])
    rescue Api::Invalid => e
      response.status = 422
      { error: e.message }
    end

    r.public
    check_csrf!
    begin
      r.rodauth
    rescue EmailCap::Reached => e
      flash["error"] = e.message
      r.redirect "/login"
    end
    rodauth.require_account # everything below needs a logged-in, verified account

    r.root { File.read(File.join(__dir__, "public/index.html")) }
    r.get("account") { view "home" }

    # Bookmarklet popup: opening it only shows a pre-filled form; Save is a POST with a CSRF token,
    # so another site can open this page but can't log anything into the account.
    r.is "add" do
      account_id = rodauth.session_value
      apps = Application.where(account_id: account_id)
      r.get do
        url = r.params["url"].to_s.strip
        @job = { "url" => url }
        begin
          link!(url)
          if !url.empty? && (dup = apps.with_encrypted_value(:url, url).first)
            @duplicate = dup.to_api
          else
            info = url.empty? ? {} : Fetcher.fetch(url)
            tab_title = r.params["title"].to_s.sub(/\s*[|\-–].*\z/, "") # "Role at Acme | Greenhouse" -> "Role at Acme"
            @job.merge!("company" => info[:company].to_s, "title" => auto_title(info, tab_title).to_s,
                        "location" => Locations.normalize(info[:location]), "pay" => info[:pay].to_s)
          end
        rescue Api::Invalid => e
          @error = e.message
        end
        view "add"
      end
      r.post do
        job = add_job(apps, account_id, r.params)
        job[:duplicate] ? (@duplicate = job) : (@saved = job)
        view "add"
      rescue Api::Invalid => e
        @error = e.message
        @job = r.params
        view "add"
      end
    end
  end
end
