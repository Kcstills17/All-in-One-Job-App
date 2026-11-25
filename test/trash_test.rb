# Trash: deleting moves applications and referrals to Trash, where they can be restored for 30 days.
require_relative "helper"
require "rack/test"
require "bcrypt"

class TrashTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app
  PASSWORD = "correct horse battery"

  def setup
    reset_db!
    %w[me@example.com other@example.com].each do |email|
      id = DB[:accounts].insert(email: email, status_id: 2)
      DB[:account_password_hashes].insert(id: id, password_hash: BCrypt::Password.create(PASSWORD, cost: 4))
    end
  end

  def log_in(email)
    clear_cookies
    get "/login"
    post "/login", "login" => email, "password" => PASSWORD, "_csrf" => last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    get "/api/session"
    @csrf = JSON.parse(last_response.body)["csrf"]
  end

  def api(verb, path, body = nil)
    custom_request(verb, path, body&.to_json || "", "CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => @csrf)
    [last_response.status, (JSON.parse(last_response.body) rescue nil)]
  end

  def test_delete_restore_and_delete_forever
    log_in("me@example.com")
    _, job = api("POST", "/api/jobs", { company: "Acme", url: "https://acme.dev/j/1" })
    api("POST", "/api/jobs/#{job['id']}/events", { stage: "Recruiter Screen", note: "with Sam" })
    _, ref = api("POST", "/api/referrals", { name: "Kana" })
    api("DELETE", "/api/jobs/#{job['id']}")
    api("DELETE", "/api/referrals/#{ref['id']}")

    assert_empty api("GET", "/api/jobs")[1]
    assert_empty api("GET", "/api/referrals")[1]["referrals"]
    assert_equal 404, api("PATCH", "/api/jobs/#{job['id']}", { notes: "x" }).first, "trashed jobs can't be edited"
    _, trash = api("GET", "/api/trash")
    assert_equal [30, ["Acme"], ["Kana"]], [trash["days"], trash["jobs"].map { _1["company"] }, trash["referrals"].map { _1["name"] }]
    refute_equal true, api("POST", "/api/jobs", { url: "https://acme.dev/j/1" })[1]["duplicate"], "a trashed link isn't a duplicate"

    _, back = api("POST", "/api/trash/jobs/#{job['id']}/restore")
    assert_equal ["Applied", "Recruiter Screen"], back["history"].map { _1["stage"] }, "restored with its timeline"
    assert_includes api("GET", "/api/jobs")[1].map { _1["id"] }, job["id"]

    assert_equal 200, api("DELETE", "/api/trash/referrals/#{ref['id']}").first
    assert_empty api("GET", "/api/trash")[1]["referrals"]
    assert_equal 0, Referral.count
  end

  def test_empty_trash_and_thirty_day_purge
    log_in("me@example.com")
    ids = 3.times.map { api("POST", "/api/jobs", { company: "Co #{_1}" })[1]["id"] }
    ids.each { api("DELETE", "/api/jobs/#{_1}") }
    Application.where(id: ids[0].to_i).update(deleted_at: Time.now - 31 * 86_400)
    assert_equal 2, api("GET", "/api/trash")[1]["jobs"].size, "older than 30 days is gone"
    assert_equal 0, ApplicationEvent.where(application_id: ids[0].to_i).count, "with its timeline"
    api("DELETE", "/api/trash")
    assert_empty api("GET", "/api/trash")[1]["jobs"]
    assert_equal 0, Application.count
  end

  def test_trash_is_per_account
    log_in("me@example.com")
    _, job = api("POST", "/api/jobs", { company: "Mine" })
    api("DELETE", "/api/jobs/#{job['id']}")
    log_in("other@example.com")
    assert_empty api("GET", "/api/trash")[1]["jobs"]
    assert_equal 404, api("POST", "/api/trash/jobs/#{job['id']}/restore").first
    assert_equal 404, api("DELETE", "/api/trash/jobs/#{job['id']}").first
    api("DELETE", "/api/trash")
    log_in("me@example.com")
    assert_equal ["Mine"], api("GET", "/api/trash")[1]["jobs"].map { _1["company"] }, "emptying yours leaves mine"
  end
end
