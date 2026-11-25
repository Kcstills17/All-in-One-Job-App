require "json"
require_relative "models"

# Writes one account's data as jobs.json and referrals.json, the same shape `rake import` reads, so an
# account can move between databases (e.g. local to hosted): export here, import there. The files
# are plain text: keep them on your own machine and delete them once imported.
module Export
  def self.run(email, dir)
    account_id = DB[:accounts].where(email: email).get(:id) or raise "No account for #{email}."
    # Newest first, like the old app's files. Rows without an old id get a stable one from this database.
    id = ->(row) { row.legacy_id || "web-#{row.id}" }
    jobs = Application.where(account_id: account_id).order(Sequel.desc(:id)).all.map do |a|
      { "id" => id[a], "applied_on" => a.applied_on.to_s, **%w[company title location pay url notes prep].to_h { [_1, a.public_send(_1)] },
        "history" => a.history.map { { "stage" => _1.stage, "on" => _1.on.to_s, "at" => _1.at.to_s, "note" => _1.note } } }
    end
    refs = Referral.where(account_id: account_id).order(Sequel.desc(:id)).all.map do |r|
      { "id" => id[r], "status" => r.status, **Referral::TEXT.to_h { [_1.to_s, r.public_send(_1)] },
        **(Referral::DATES + [:added_on]).to_h { [_1.to_s, r[_1].to_s] } }
    end
    File.write(File.join(dir, "jobs.json"), JSON.pretty_generate(jobs), perm: 0o600)
    File.write(File.join(dir, "referrals.json"), JSON.pretty_generate(refs), perm: 0o600)
    { applications: jobs.size, timeline_steps: jobs.sum { _1["history"].size }, referrals: refs.size }
  end
end
