# Sign-up protections: the honeypot, Turnstile and the daily email cap.
require_relative "helper"
require "rack/test"

class BotProtectionTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app

  def setup
    reset_db!
    Mail::TestMailer.deliveries.clear
  end

  def sign_up(email, extra = {})
    get "/create-account"
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    post "/create-account", { "login" => email, "password" => "correct horse battery",
                              "password-confirm" => "correct horse battery", "_csrf" => token }.merge(extra)
  end

  def test_honeypot_creates_nothing_and_looks_normal
    sign_up("bot@example.com", "website" => "http://spam.example")
    assert last_response.redirect?
    assert_equal 0, DB[:accounts].count
    assert_empty Mail::TestMailer.deliveries
    get "/create-account"
    assert_includes last_response.body, %(name="website"), "the field is on the form"
  end

  def test_email_cap_stops_sign_ups_without_creating_accounts
    ENV["EMAIL_DAILY_CAP"] = "1"
    sign_up("first@example.com")
    assert_equal 1, Mail::TestMailer.deliveries.size
    sign_up("second@example.com")
    follow_redirect!
    assert_includes last_response.body, "today&#39;s limit"
    assert_equal ["first@example.com"], DB[:accounts].select_map(:email)
  ensure
    ENV.delete("EMAIL_DAILY_CAP")
  end

  # Two sign-ups racing past the pre-check: the one whose email goes over the cap is rolled back.
  def test_email_over_the_cap_rolls_back_the_sign_up
    ENV["EMAIL_DAILY_CAP"] = "0"
    original = EmailCap.method(:reached?)
    EmailCap.define_singleton_method(:reached?) { false }
    sign_up("rolled-back@example.com")
    assert_equal 0, DB[:accounts].count, "no account without its verification email"
    assert_empty Mail::TestMailer.deliveries
  ensure
    ENV.delete("EMAIL_DAILY_CAP")
    EmailCap.define_singleton_method(:reached?, original)
  end

  def test_turnstile_when_configured
    ENV["TURNSTILE_SITE_KEY"] = "site-key"
    ENV["TURNSTILE_SECRET_KEY"] = "secret"
    original = Turnstile.method(:passed?)
    Turnstile.define_singleton_method(:passed?) { |token, _ip| token == "good-token" }
    get "/create-account"
    assert_includes last_response.body, %(class="cf-turnstile" data-sitekey="site-key")
    sign_up("no-check@example.com")
    assert_equal 0, DB[:accounts].count
    sign_up("checked@example.com", "cf-turnstile-response" => "good-token")
    assert_equal 1, DB[:accounts].count
  ensure
    ENV.delete("TURNSTILE_SITE_KEY")
    ENV.delete("TURNSTILE_SECRET_KEY")
    Turnstile.define_singleton_method(:passed?, original)
  end

end
