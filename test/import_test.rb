# The old-app import: lands in one account only, re-runs without duplicates, and refuses bad targets.
require_relative "helper"
require "tmpdir"

class ImportTest < Minitest::Test
  JOBS = [
    { "id" => "b2", "company" => "Socket", "title" => "SE", "location" => "Remote", "pay" => "", "url" => "",
      "notes" => "", "applied_on" => "2026-03-02",
      "history" => [{ "stage" => "Applied", "on" => "2026-03-02" }, { "stage" => "Rejected", "on" => "2026-03-09", "note" => "form email" }] },
    { "id" => "a1", "company" => "Acme", "title" => "FDE", "location" => "", "pay" => "120k", "url" => "https://acme.dev/j",
      "notes" => "hi", "applied_on" => "", "history" => [{ "stage" => "Applied", "on" => "" }] }
  ]
  REFS = [{ "id" => "r1", "name" => "Kana", "contact" => "", "company" => "Cribl", "role" => "SE", "url" => "",
            "notes" => "met at meetup", "status" => "Messaged", "first_contact" => "2026-02-16", "second_contact" => "",
            "meeting_on" => "" }]

  def setup
    reset_db!
    @me = DB[:accounts].insert(email: "me@example.com", status_id: 2)
    @other = DB[:accounts].insert(email: "other@example.com", status_id: 2)
    DB[:accounts].insert(email: "new@example.com", status_id: 1)
    @dir = Dir.mktmpdir
    write(JOBS, REFS)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def write(jobs, refs)
    File.write(File.join(@dir, "jobs.json"), jobs.to_json)
    File.write(File.join(@dir, "referrals.json"), refs.to_json)
  end

  def test_imports_everything_into_one_account
    assert_equal({ applications: 2, timeline_steps: 3, referrals: 1 }, Import.run("ME@example.com", @dir))
    assert_equal 0, DB[:applications].where(account_id: @other).count, "other accounts stay blank"
    assert_equal 0, DB[:referrals].where(account_id: @other).count

    socket = DB[:applications].first(legacy_id: "b2")
    assert_equal ["Applied", "Rejected"], DB[:application_events].where(application_id: socket[:id]).order(:id).select_map(:stage)
    assert_nil DB[:applications].first(legacy_id: "a1")[:applied_on], "blank dates stay blank"
    assert_operator socket[:id], :>, DB[:applications].first(legacy_id: "a1")[:id], "newest (listed first) gets the highest id"
    assert_equal Date.new(2026, 2, 16), DB[:referrals].first[:first_contact]
    refute_equal "Socket", socket[:company], "imported text is encrypted"
    assert_equal ["Socket", "form email"], [Application[socket[:id]].company, Application[socket[:id]].history.last.note]
    assert_equal "met at meetup", Referral.first.notes
  end

  def test_rerun_updates_without_duplicates
    Import.run("me@example.com", @dir)
    jobs = JOBS.map(&:dup)
    jobs[0] = jobs[0].merge("notes" => "edited", "history" => jobs[0]["history"] + [{ "stage" => "Ghosted", "on" => "2026-04-01" }])
    write([{ **JOBS[1], "id" => "c3" }] + jobs, REFS)
    assert_equal({ applications: 3, timeline_steps: 5, referrals: 1 }, Import.run("me@example.com", @dir))
    assert_equal "edited", Application.first(legacy_id: "b2").notes
  end

  def test_refuses_unverified_or_unknown_accounts
    assert_raises(RuntimeError) { Import.run("new@example.com", @dir) }
    assert_raises(RuntimeError) { Import.run("nobody@example.com", @dir) }
    assert_equal 0, DB[:applications].count
  end

  def test_bad_row_saves_nothing
    write(JOBS + [{ **JOBS[1], "id" => "z9", "history" => [{ "stage" => "Bogus" }] }], REFS)
    assert_raises(Sequel::CheckConstraintViolation) { Import.run("me@example.com", @dir) }
    assert_equal 0, DB[:applications].count
  end
end
