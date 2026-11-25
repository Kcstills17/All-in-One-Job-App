# Export writes what import reads, so an account survives the round trip into another account
# unchanged; the download links serve the same data as JSON and CSV.
require_relative "helper"
require "tmpdir"
require "rack/test"
require "bcrypt"
require_relative "../export"
require_relative "../import"

class ExportTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app

  def setup
    reset_db!
    @from = DB[:accounts].insert(email: "from@example.com", status_id: 2)
    DB[:account_password_hashes].insert(id: @from, password_hash: BCrypt::Password.create("correct horse battery", cost: 4))
    @to = DB[:accounts].insert(email: "to@example.com", status_id: 2)
    DB[:accounts].insert(email: "bystander@example.com", status_id: 2)
    v1 = Resume.create(account_id: @from, name: "Support v1", url: "https://docs.example.com/v1", notes: "first", started_on: Date.new(2026, 1, 1))
    a = Application.create(account_id: @from, company: "Acme, Inc.", title: "FDE", notes: "said \"great\"\nthen ghosted", url: "https://acme.dev/j",
                           prep: "pitch", applied_on: Date.new(2026, 3, 2), resume_id: v1.id)
    a.add_event(stage: "Applied", on: Date.new(2026, 3, 2), note: "")
    a.add_event(stage: "Technical Interview", on: Date.new(2026, 3, 5), at: "14:30", note: "", checked: "Link works")
    a.add_event(stage: "Rejected", on: Date.new(2026, 3, 9), note: "form email")
    Application.create(account_id: @from, company: "=HYPERLINK(\"x\")", legacy_id: "old-1").add_event(stage: "Applied", note: "")
    Application.create(account_id: @from, company: "Trashed Co", deleted_at: Time.now).add_event(stage: "Applied", note: "")
    Referral.create(account_id: @from, name: "Kana", company: "Cribl", status: "Messaged", first_contact: Date.new(2026, 2, 16), added_on: Date.new(2026, 2, 1))
    Company.create(account_id: @from, key: "acme, inc.", name: "Acme, Inc.", notes: "rockets")
    PrepNote.create(account_id: @from, kind: "note", title: "STAR: outage", body: "S, T, A, R")
    PrepNote.create(account_id: @from, kind: "checklist", title: "Day-of checklist", body: "Link works\nWater")
    @dir = Dir.mktmpdir
  end

  def teardown = FileUtils.rm_rf(@dir)

  def snapshot(account_id)
    resume_names = Resume.where(account_id: account_id).to_h { [_1.id.to_s, _1.name] }
    [Application.where(account_id: account_id, deleted_at: nil).all.map { _1.to_api.except(:id).merge(resume_id: resume_names[_1.to_api[:resume_id]]) }.sort_by { _1[:company] },
     Referral.where(account_id: account_id).all.map { _1.to_api.except(:id) },
     Resume.where(account_id: account_id).all.map { _1.to_api.except(:id) },
     Company.where(account_id: account_id).all.map { _1.to_api.except(:id) },
     PrepNote.where(account_id: account_id).order(:kind).all.map { [_1.kind, _1.title, _1.body] }]
  end

  def test_round_trip_carries_everything
    counts = Export.run("from@example.com", @dir)
    assert_equal({ applications: 2, timeline_steps: 4, referrals: 1, resumes: 1, companies: 1, prep_notes: 1, checklist: 2 }, counts, "trash left out")
    assert_equal 0o600, File.stat(File.join(@dir, "extras.json")).mode & 0o777, "only you can read the files"
    Import.run("to@example.com", @dir)
    Import.run("to@example.com", @dir) # re-running updates instead of duplicating
    assert_equal snapshot(@from), snapshot(@to)
  end

  def test_download_links
    get "/api/export/all.json"
    assert_equal 401, last_response.status, "needs a login"
    get "/login"
    post "/login", "login" => "from@example.com", "password" => "correct horse battery", "_csrf" => last_response.body[/name="_csrf" value="([^"]+)"/, 1]

    get "/api/export/all.json"
    assert_match(/attachment; filename="job-tracker-all-\d{4}-\d\d-\d\d\.json"/, last_response.headers["content-disposition"])
    all = JSON.parse(last_response.body)
    assert_equal [2, "Support v1", ["Link works", "Water"]], [all["jobs"].size, all["jobs"].find { _1["company"] == "Acme, Inc." }["resume"], all["extras"]["checklist"]]

    get "/api/export/applications.csv"
    assert_equal "text/csv; charset=utf-8", last_response.content_type
    lines = last_response.body.split("\r\n")
    assert_equal "applied_on,company,title,stage,location,pay,url,resume,notes,timeline", lines.first
    assert_includes last_response.body, %(2026-03-02,"Acme, Inc.",FDE,Rejected,,,https://acme.dev/j,Support v1,"said ""great""\nthen ghosted",Applied 2026-03-02; Technical Interview 2026-03-05; Rejected 2026-03-09)
    assert_includes last_response.body, %(,"'=HYPERLINK(""x"")",), "formulas are shown as text"
    refute_includes last_response.body, "Trashed Co"

    get "/api/export/referrals.csv"
    assert_includes last_response.body, "Kana,Cribl,,Messaged,,,2026-02-16,,,2026-02-01,"
    get "/account"
    assert_includes last_response.body, %(href="/api/export/all.json")
  end
end
