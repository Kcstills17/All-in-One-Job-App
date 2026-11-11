# The bookmarklet popup: opening it never saves; only its form's POST (with a CSRF token) does.
require_relative "helper"
require "rack/test"
require "bcrypt"

class BookmarkletTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app
  URL = "https://boards.greenhouse.io/acme/jobs/123"

  def setup
    reset_db!
    @me = DB[:accounts].insert(email: "me@example.com", status_id: 2)
    DB[:account_password_hashes].insert(id: @me, password_hash: BCrypt::Password.create("correct horse battery", cost: 4))
    @fetch = Fetcher.method(:fetch)
    Fetcher.define_singleton_method(:fetch) { |_| { company: "Acme", title: "Support Engineer", location: "Remote", pay: "$100K" } }
  end

  def teardown = Fetcher.define_singleton_method(:fetch, @fetch)

  def log_in
    get "/login"
    post "/login", "login" => "me@example.com", "password" => "correct horse battery",
                   "_csrf" => last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    follow_redirect! while last_response.redirect?
  end

  def open_popup = get("/add", "url" => URL, "title" => "Support Engineer at Acme | Greenhouse")
  def form_token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]

  def test_logged_out_goes_to_login_and_back
    open_popup
    assert_equal "/login", URI(last_response.location).path
    log_in
    assert_equal "/add", last_request.path, "returns to the popup after login"
    assert_includes last_response.body, "Log this job"
  end

  def test_opening_shows_a_prefilled_form_and_saves_nothing
    log_in
    open_popup
    assert_includes last_response.body, %(value="Acme")
    assert_includes last_response.body, %(value="Support Engineer")
    assert_equal 0, Application.count
  end

  def test_save_needs_the_form_token
    log_in
    open_popup
    post "/add", "url" => URL, "company" => "Acme"
    assert_equal 403, last_response.status
    assert_equal 0, Application.count
  end

  def test_save_logs_the_job_once
    log_in
    open_popup
    post "/add", "url" => URL, "company" => "Acme Corp", "title" => "Support Engineer", "location" => "Remote", "_csrf" => form_token
    assert_includes last_response.body, "Logged"
    assert_equal ["Acme Corp"], Application.where(account_id: @me).map(&:company)
    open_popup
    assert_includes last_response.body, "Already logged"
  end

  def test_bad_links_and_locations_show_an_error
    log_in
    get "/add", "url" => "javascript:alert(1)"
    assert_includes last_response.body, "Links must start with http"
    open_popup
    post "/add", "url" => URL, "location" => "Atlantis", "_csrf" => form_token
    assert_includes last_response.body, "Pick a location from the list"
    assert_equal 0, Application.count
  end
end
