# Resume versions: CRUD, encrypted, scoped to the account; an application can pin one of yours only.
require_relative "helper"
require "rack/test"
require "bcrypt"

class ResumesTest < Minitest::Test
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

  def test_versions_and_pinning
    log_in("me@example.com")
    _, v2 = api("POST", "/api/resumes", { name: "FDE v2", url: "https://docs.example.com/v2", started_on: "2026-09-01", notes: "Led with Retriever" })
    _, v1 = api("POST", "/api/resumes", { name: "Support v1", started_on: "2026-01-15" })
    assert_equal %w[Support\ v1 FDE\ v2], api("GET", "/api/resumes")[1].map { _1["name"] }, "oldest first"
    refute_includes DB[:resumes].all.map(&:values).flatten.join, "Retriever"
    assert_equal 422, api("POST", "/api/resumes", { name: " " }).first
    assert_equal 422, api("POST", "/api/resumes", { name: "x", url: "javascript:alert(1)" }).first

    _, job = api("POST", "/api/jobs", { company: "Acme" })
    assert_nil job["resume_id"], "new applications go by date"
    _, job = api("PATCH", "/api/jobs/#{job['id']}", { resume_id: v1["id"] })
    assert_equal v1["id"], job["resume_id"]
    _, job = api("PATCH", "/api/jobs/#{job['id']}", { resume_id: "" })
    assert_nil job["resume_id"]

    api("PATCH", "/api/jobs/#{job['id']}", { resume_id: v2["id"] })
    api("DELETE", "/api/resumes/#{v2['id']}")
    assert_nil api("GET", "/api/jobs")[1].first["resume_id"], "deleting a version puts its applications back to by-date"
  end

  def test_accounts_cannot_use_each_others_versions
    log_in("me@example.com")
    _, mine = api("POST", "/api/resumes", { name: "Mine" })
    log_in("other@example.com")
    assert_empty api("GET", "/api/resumes")[1]
    assert_equal 404, api("PATCH", "/api/resumes/#{mine['id']}", { name: "Stolen" }).first
    assert_equal 404, api("DELETE", "/api/resumes/#{mine['id']}").first
    _, job = api("POST", "/api/jobs", { company: "Theirs" })
    assert_equal 422, api("PATCH", "/api/jobs/#{job['id']}", { resume_id: mine["id"] }).first
  end
end
