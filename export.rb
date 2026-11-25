require "json"
require_relative "models"

# One account's data, for the "Download your data" links and for moving an account between databases
# (`rake export` here, `rake import` there). Trashed rows are left out. The output is plain text:
# keep it on your own machine and delete it once it's served its purpose.
module Export
  APP_FIELDS = %w[company title location pay url notes prep].freeze

  # Everything, in the shape `rake import` reads: jobs and referrals as the old app had them,
  # plus the newer data under "extras".
  def self.data(account_id)
    # Rows without an old id get a stable one from this database.
    id = ->(row) { row.legacy_id || "web-#{row.id}" }
    resumes = Resume.where(account_id: account_id).order(:started_on, :id).all
    jobs = Application.where(account_id: account_id, deleted_at: nil).order(Sequel.desc(:id)).eager(:events).all.map do |a|
      { "id" => id[a], "applied_on" => a.applied_on.to_s, **APP_FIELDS.to_h { [_1, a.public_send(_1).to_s] },
        "resume" => resumes.find { _1.id == a.resume_id }&.name, # pinned version only; otherwise by date
        "history" => a.history.map { { "stage" => _1.stage, "on" => _1.on.to_s, "at" => _1.at.to_s, "note" => _1.note.to_s,
                                    "checked" => _1.checked.to_s.split("\n") } } }
    end
    refs = Referral.where(account_id: account_id, deleted_at: nil).order(Sequel.desc(:id)).all.map do |r|
      { "id" => id[r], "status" => r.status, **Referral::TEXT.to_h { [_1.to_s, r.public_send(_1).to_s] },
        **(Referral::DATES + [:added_on]).to_h { [_1.to_s, r[_1].to_s] } }
    end
    prep = PrepNote.where(account_id: account_id).order(:id).all
    { "jobs" => jobs, "referrals" => refs, "extras" => {
      "resumes" => resumes.map { { "name" => _1.name, "url" => _1.url, "notes" => _1.notes, "started_on" => _1.started_on.to_s } },
      "companies" => Company.where(account_id: account_id).order(:id).all.map { { "name" => _1.name, "notes" => _1.notes } },
      "prep_notes" => prep.select { _1.kind == "note" }.map { { "title" => _1.title, "body" => _1.body } },
      "checklist" => prep.find { _1.kind == "checklist" }&.body.to_s.split("\n")
    } }
  end

  # Writes jobs.json, referrals.json and extras.json into dir, readable only by you.
  def self.run(email, dir)
    account_id = DB[:accounts].where(email: email).get(:id) or raise "No account for #{email}."
    all = data(account_id)
    { "jobs.json" => all["jobs"], "referrals.json" => all["referrals"], "extras.json" => all["extras"] }.each do |name, value|
      File.write(File.join(dir, name), JSON.pretty_generate(value), perm: 0o600)
    end
    { applications: all["jobs"].size, timeline_steps: all["jobs"].sum { _1["history"].size }, referrals: all["referrals"].size,
      **all["extras"].to_h { |k, v| [k.to_sym, Array(v).size] } }
  end

  # Spreadsheet-ready CSVs. Cells starting with = + - @ get a leading ' so a spreadsheet shows them as
  # text instead of running them as formulas.
  def self.csv(rows)
    cell = ->(v) { s = v.to_s; s = "'#{s}" if s.match?(/\A[=+\-@\t\r]/); s.match?(/[",\r\n]/) ? %("#{s.gsub('"', '""')}") : s }
    rows.map { |r| r.map(&cell).join(",") }.join("\r\n") + "\r\n"
  end

  def self.applications_csv(account_id)
    jobs = data(account_id)["jobs"]
    head = %w[applied_on company title stage location pay url resume notes timeline]
    csv([head, *jobs.map { |j| [j["applied_on"], j["company"], j["title"], j["history"].last&.fetch("stage"), j["location"], j["pay"],
                                j["url"], j["resume"], j["notes"], j["history"].map { "#{_1['stage']} #{_1['on']}".strip }.join("; ")] }])
  end

  def self.referrals_csv(account_id)
    head = %w[name company role status contact url first_contact second_contact meeting_on added_on notes]
    csv([head, *data(account_id)["referrals"].map { |r| head.map { r[_1] } }])
  end
end
