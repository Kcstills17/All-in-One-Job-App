# Account flows end to end, against the test database. Run: bundle exec rake
require_relative "helper"
require "rack/test"

class AuthTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app
  EMAIL = "zane@example.com"
  PASSWORD = "correct horse battery"

  def setup
    Mail::TestMailer.deliveries.clear
    reset_db!
  end

  # GET the page holding the form, then POST to it with that form's CSRF token.
  def submit(path, params)
    get path
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1] or flunk "no form on #{path}: #{last_response.body[0, 300]}"
    post path, params.merge("_csrf" => token)
    follow_redirect! while last_response.redirect?
  end

  def emailed_link = Mail::TestMailer.deliveries.last.body.decoded[%r{https?://\S+}]

  def sign_up(email = EMAIL)
    submit "/create-account", "login" => email, "password" => PASSWORD, "password-confirm" => PASSWORD
    get URI(emailed_link).request_uri
    follow_redirect! while last_response.redirect?
    submit "/verify-account", {}
  end

  def log_in(password = PASSWORD) = submit("/login", "login" => EMAIL, "password" => password)

  def test_pages_need_login
    get "/"
    assert last_response.redirect?
    assert_equal "/login", URI(last_response.location).path
  end

  def test_sign_up_verify_and_log_out
    submit "/create-account", "login" => EMAIL, "password" => PASSWORD, "password-confirm" => PASSWORD
    log_in
    assert_includes last_response.body, "awaiting verification", "unverified accounts can't log in"

    get URI(emailed_link).request_uri
    follow_redirect! while last_response.redirect?
    submit "/verify-account", {}
    get "/"
    assert_includes last_response.body, "Logged in as <b>#{EMAIL}</b>"

    submit "/logout", {}
    get "/"
    assert last_response.redirect?
  end

  def test_short_password_rejected
    submit "/create-account", "login" => EMAIL, "password" => "short", "password-confirm" => "short"
    assert_empty DB[:accounts].all
  end

  def test_form_without_csrf_token_is_refused
    post "/login", "login" => EMAIL, "password" => PASSWORD
    assert_equal 403, last_response.status
  end

  def test_lockout_after_ten_bad_passwords
    sign_up
    submit "/logout", {}
    10.times { log_in("wrong password!") }
    log_in
    get "/"
    assert last_response.redirect?, "the right password doesn't work while locked"
  end

  def test_reset_password
    sign_up
    submit "/logout", {}
    submit "/reset-password-request", "login" => EMAIL
    get URI(emailed_link).request_uri
    follow_redirect! while last_response.redirect?
    submit "/reset-password", "password" => "a brand new password", "password-confirm" => "a brand new password"
    submit "/logout", {}
    log_in("a brand new password")
    get "/"
    assert_includes last_response.body, "Logged in as"
  end

  def test_closing_an_account_erases_its_data
    other = DB[:accounts].insert(email: "other@example.com", status_id: 2)
    Referral.create(account_id: other, name: "Kept")
    sign_up
    me = DB[:accounts].where(email: EMAIL).get(:id)
    app_id = Application.create(account_id: me, company: "Acme").tap { _1.add_event(stage: "Applied") }.id
    Referral.create(account_id: me, name: "Kana", notes: "private")

    submit "/close-account", "password" => PASSWORD
    assert_empty DB[:accounts].where(id: me).all, "account row deleted, not just marked closed"
    assert_empty DB[:applications].where(account_id: me).all
    assert_empty DB[:application_events].where(application_id: app_id).all
    assert_empty DB[:referrals].where(account_id: me).all
    assert_empty DB[:account_password_hashes].where(id: me).select(:id).all
    assert_equal ["Kept"], Referral.where(account_id: other).map(&:name), "other accounts untouched"
  end

  def test_app_cannot_read_password_hashes
    sign_up
    assert_raises(Sequel::DatabaseError) { DB[:account_password_hashes].select(:password_hash).all }
  end

  def test_security_headers
    get "/login"
    assert_match "frame-ancestors 'none'", last_response.headers["content-security-policy"]
    assert_equal "nosniff", last_response.headers["x-content-type-options"]
  end
end
