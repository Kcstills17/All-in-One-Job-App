# Interview prep: company notes shared across applications, role notes per job, the prep library,
# the day-of checklist and its ticks. All of it scoped to the account and stored encrypted.
require_relative "helper"
require "rack/test"
require "bcrypt"

class InterviewNotesTest < Minitest::Test
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

  def test_company_notes_are_shared_by_name_and_encrypted
    log_in("me@example.com")
    _, c = api("PUT", "/api/companies", { name: "Acme", notes: "Builds rockets. Met Sam." })
    _, again = api("PUT", "/api/companies", { name: " acme ", notes: "Builds rockets. Met Sam and Kim." })
    assert_equal [c["id"], "acme", "Builds rockets. Met Sam and Kim."], again.values_at("id", "name", "notes")
    assert_equal 1, api("GET", "/api/companies")[1].size
    refute_includes DB[:companies].first.values.join, "rockets"
    assert_equal 422, api("PUT", "/api/companies", { name: " ", notes: "x" }).first
  end

  def test_role_prep_and_checklist_ticks
    log_in("me@example.com")
    _, job = api("POST", "/api/jobs", { company: "Acme" })
    _, job = api("PATCH", "/api/jobs/#{job['id']}", { prep: "Pitch: support + Ruby" })
    assert_equal "Pitch: support + Ruby", job["prep"]
    _, job = api("POST", "/api/jobs/#{job['id']}/events", { stage: "Technical Interview", on: "2026-12-02", checked: ["Tested the link", " "] })
    assert_equal ["Tested the link"], job["history"].last["checked"]
    _, job = api("PATCH", "/api/jobs/#{job['id']}/events/1", { note: "went well" })
    assert_equal ["Tested the link"], job["history"].last["checked"], "editing the note keeps the ticks"
  end

  def test_prep_library_and_checklist
    log_in("me@example.com")
    _, prep = api("GET", "/api/prep")
    assert_equal [], prep["notes"]
    assert_equal PrepNote::DEFAULT_CHECKLIST, prep["checklist"]
    _, note = api("POST", "/api/prep", { title: "STAR: outage at FedEx", body: "Situation…" })
    _, note = api("PATCH", "/api/prep/#{note['id']}", { body: "Situation, task, action, result" })
    assert_equal ["STAR: outage at FedEx", "Situation, task, action, result"], note.values_at("title", "body")
    assert_equal 422, api("POST", "/api/prep", { title: "" }).first
    assert_equal({ "checklist" => ["Link works", "Water"] }, api("PUT", "/api/prep/checklist", { items: "Link works\n\nWater" })[1])
    assert_equal ["Link works", "Water"], api("GET", "/api/prep")[1]["checklist"]
    assert_equal 1, api("GET", "/api/prep")[1]["notes"].size, "the checklist isn't listed as a note"
  end

  def test_accounts_cannot_see_each_others_prep
    log_in("me@example.com")
    api("PUT", "/api/companies", { name: "Acme", notes: "mine" })
    _, note = api("POST", "/api/prep", { title: "Mine", body: "secret" })
    api("PUT", "/api/prep/checklist", { items: ["My item"] })

    log_in("other@example.com")
    assert_empty api("GET", "/api/companies")[1]
    assert_equal [[], PrepNote::DEFAULT_CHECKLIST], api("GET", "/api/prep")[1].values_at("notes", "checklist")
    assert_equal 404, api("PATCH", "/api/prep/#{note['id']}", { body: "stolen" }).first
    assert_equal 404, api("DELETE", "/api/prep/#{note['id']}").first
    _, theirs = api("PUT", "/api/companies", { name: "Acme", notes: "theirs" })
    log_in("me@example.com")
    assert_equal ["mine"], api("GET", "/api/companies")[1].map { _1["notes"] }, "same name, separate notes"
    refute_equal theirs["id"], api("GET", "/api/companies")[1].first["id"]
  end
end
