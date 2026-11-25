# Export writes what import reads: an account survives the round trip into another account unchanged.
require_relative "helper"
require "tmpdir"
require_relative "../export"
require_relative "../import"

class ExportTest < Minitest::Test
  def setup
    reset_db!
    @from = DB[:accounts].insert(email: "from@example.com", status_id: 2)
    @to = DB[:accounts].insert(email: "to@example.com", status_id: 2)
    DB[:accounts].insert(email: "bystander@example.com", status_id: 2)
    a = Application.create(account_id: @from, company: "Acme", title: "FDE", notes: "hi", url: "https://acme.dev/j", applied_on: Date.new(2026, 3, 2))
    a.add_event(stage: "Applied", on: Date.new(2026, 3, 2), note: "")
    a.add_event(stage: "Rejected", on: Date.new(2026, 3, 9), note: "form email")
    Application.create(account_id: @from, company: "Legacy Co", legacy_id: "old-1").add_event(stage: "Applied", note: "")
    Referral.create(account_id: @from, name: "Kana", company: "Cribl", status: "Messaged", first_contact: Date.new(2026, 2, 16), added_on: Date.new(2026, 2, 1))
    @dir = Dir.mktmpdir
  end

  def teardown = FileUtils.rm_rf(@dir)

  def snapshot(account_id)
    [Application.where(account_id: account_id).all.map { _1.to_api.except(:id) }.sort_by { _1[:company] },
     Referral.where(account_id: account_id).all.map { _1.to_api.except(:id) }]
  end

  def test_round_trip
    assert_equal({ applications: 2, timeline_steps: 3, referrals: 1 }, Export.run("from@example.com", @dir))
    assert_equal 0o600, File.stat(File.join(@dir, "jobs.json")).mode & 0o777, "only you can read the files"
    Import.run("to@example.com", @dir)
    assert_equal snapshot(@from), snapshot(@to)
  end

  def test_unknown_account
    assert_raises(RuntimeError) { Export.run("nobody@example.com", @dir) }
  end
end
