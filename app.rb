require_relative "config"
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
  PRODUCTION = ENV["RACK_ENV"] == "production"

  plugin :default_headers, {
    "Content-Type" => "text/html; charset=UTF-8",
    "X-Content-Type-Options" => "nosniff",
    "Referrer-Policy" => "same-origin",
    "Strict-Transport-Security" => ("max-age=63072000; includeSubDomains" if PRODUCTION)
  }.compact
  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.style_src :self, :unsafe_inline
    csp.img_src :self
    csp.form_action :self
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  plugin :sessions, secret: ENV.fetch("SESSION_SECRET"), key: "jt.session",
                    cookie_options: { httponly: true, same_site: :lax, secure: PRODUCTION }
  plugin :flash
  plugin :route_csrf, csrf_failure: :empty_403 # a form without a valid token gets a plain 403
  plugin :render, escape: true, layout: "layout"

  plugin :rodauth do
    db DB
    enable :create_account, :verify_account, :login, :logout, :reset_password,
           :change_password, :lockout, :close_account
    hmac_secret ENV.fetch("HMAC_SECRET")
    # Email links must use the real site address, never the request's Host header.
    base_url ENV.fetch("APP_URL") if PRODUCTION
    email_from ENV.fetch("MAIL_FROM", "Job Tracker <no-reply@localhost>")

    verify_account_set_password? false # pick the password at sign-up
    require_login_confirmation? false
    password_minimum_length 10
    password_maximum_bytes 72          # bcrypt ignores anything past 72 bytes
    max_invalid_logins 10              # then the account locks until the emailed unlock link is used
    login_redirect "/"
    logout_redirect "/login"
  end

  route do |r|
    check_csrf!
    r.rodauth
    rodauth.require_account # everything below needs a logged-in, verified account

    r.root { view "home" }
  end
end
