# The JSON API: login and CSRF required, each account sees only its own rows, input is validated.
require_relative "helper"
require "rack/test"
require "bcrypt"

module Fetcher
  def self.fetch(_url) = { company: "Fetched Co", title: "Fetched Role", location: "Remote", pay: "$100K" } # no network in tests
end

class ApiTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app
  PASSWORD = "correct horse battery"

  def setup
    reset_db!
    @me = make_account("me@example.com")
    @other = make_account("other@example.com")
  end

  def make_account(email)
    id = DB[:accounts].insert(email: email, status_id: 2)
    DB[:account_password_hashes].insert(id: id, password_hash: BCrypt::Password.create(PASSWORD, cost: 4))
    id
  end

  def log_in(email)
    clear_cookies
    get "/login"
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    post "/login", "login" => email, "password" => PASSWORD, "_csrf" => token
    get "/api/session"
    @csrf = JSON.parse(last_response.body)["csrf"]
  end

  def api(verb, path, body = nil, csrf: true)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["HTTP_X_CSRF_TOKEN"] = @csrf if csrf
    custom_request(verb, path, body&.to_json || "", headers)
    [last_response.status, (JSON.parse(last_response.body) rescue nil)]
  end

  def test_requires_login
    assert_equal 401, api("GET", "/api/jobs").first
  end

  def test_writes_need_the_csrf_header
    log_in("me@example.com")
    assert_equal 403, api("POST", "/api/jobs", { company: "Acme" }, csrf: false).first
    assert_equal 200, api("POST", "/api/jobs", { company: "Acme" }).first
  end

  def test_job_lifecycle
    log_in("me@example.com")
    st, job = api("POST", "/api/jobs", { url: "https://boards.example.com/j/1", location: "" })
    assert_equal 200, st
    assert_equal ["Fetched Co", "Fetched Role", "Remote", "$100K", ["Applied"]],
                 [job["company"], job["title"], job["location"], job["pay"], job["history"].map { _1["stage"] }]
    assert_equal true, api("POST", "/api/jobs", { url: "https://boards.example.com/j/1" })[1]["duplicate"]

    _, job = api("PATCH", "/api/jobs/#{job['id']}", { stage: "Recruiter Screen", notes: "call Tue" })
    assert_equal [["Applied", "Recruiter Screen"], "call Tue"], [job["history"].map { _1["stage"] }, job["notes"]]
    _, job = api("PATCH", "/api/jobs/#{job['id']}/events/1", { on: "2026-11-01", note: "with Sam" })
    assert_equal "with Sam", job["history"].find { _1["stage"] == "Recruiter Screen" }["note"]
    _, job = api("POST", "/api/jobs/#{job['id']}/events", { stage: "Rejected", on: Date.today.to_s })
    assert_equal "Rejected", job["history"].last["stage"]
    _, job = api("DELETE", "/api/jobs/#{job['id']}/events/2")
    assert_equal 2, job["history"].size

    assert_equal 1, api("GET", "/api/jobs")[1].size
    api("DELETE", "/api/jobs/#{job['id']}")
    assert_empty api("GET", "/api/jobs")[1]
  end

  def test_validation
    log_in("me@example.com")
    assert_equal 422, api("POST", "/api/jobs", { url: "javascript:alert(1)" }).first
    assert_equal 422, api("POST", "/api/jobs", { company: "A", location: "Atlantis" }).first
    _, job = api("POST", "/api/jobs", { company: "A" })
    assert_equal 422, api("PATCH", "/api/jobs/#{job['id']}", { stage: "Hired!!" }).first
    assert_equal 422, api("PATCH", "/api/jobs/#{job['id']}", { applied_on: "soon" }).first
    assert_equal 422, api("DELETE", "/api/jobs/#{job['id']}/events/0").first, "last stage can't be removed"
    assert_equal 422, api("POST", "/api/referrals", { company: "No name" }).first
    assert_equal 422, api("POST", "/api/referrals", { name: "A", status: "Best friend" }).first
  end

  def test_referral_lifecycle
    log_in("me@example.com")
    st, ref = api("POST", "/api/referrals", { name: " Kana ", url: "https://boards.example.com/j/2", junk: "x" })
    assert_equal 200, st
    assert_equal ["Kana", "Fetched Co", "Fetched Role", "To Contact", Date.today.to_s],
                 ref.values_at("name", "company", "role", "status", "added_on")
    refute ref.key?("junk")
    _, ref = api("PATCH", "/api/referrals/#{ref['id']}", { status: "Referred", first_contact: "2026-02-16", notes: "coffee" })
    assert_equal ["Referred", "2026-02-16", "coffee"], ref.values_at("status", "first_contact", "notes")
    assert_equal REF_STATUSES, api("GET", "/api/referrals")[1]["statuses"]
    api("DELETE", "/api/referrals/#{ref['id']}")
    assert_empty api("GET", "/api/referrals")[1]["referrals"]
  end

  def test_accounts_cannot_see_or_touch_each_others_rows
    log_in("me@example.com")
    _, job = api("POST", "/api/jobs", { company: "Mine" })
    _, ref = api("POST", "/api/referrals", { name: "My contact" })

    log_in("other@example.com")
    assert_empty api("GET", "/api/jobs")[1]
    assert_empty api("GET", "/api/referrals")[1]["referrals"]
    assert_equal 404, api("PATCH", "/api/jobs/#{job['id']}", { company: "Stolen" }).first
    assert_equal 404, api("DELETE", "/api/jobs/#{job['id']}").first
    assert_equal 404, api("POST", "/api/jobs/#{job['id']}/events", { stage: "Rejected" }).first
    assert_equal 404, api("PATCH", "/api/referrals/#{ref['id']}", { name: "Stolen" }).first
    assert_equal 404, api("DELETE", "/api/referrals/#{ref['id']}").first
    # Same link in another account is not a duplicate.
    refute api("POST", "/api/jobs", { url: "https://boards.example.com/j/9" })[1]["duplicate"]

    log_in("me@example.com")
    assert_equal ["Mine"], api("GET", "/api/jobs")[1].map { _1["company"] }
    assert_equal ["My contact"], api("GET", "/api/referrals")[1]["referrals"].map { _1["name"] }
  end
end
