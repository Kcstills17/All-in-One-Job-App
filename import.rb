require "json"
require "date"
require_relative "models"

# Copies the old app's jobs.json and referrals.json into one verified account. It only reads those
# files. Re-running it syncs again: rows match on the old id, so edits update in place and new
# entries are added.
# ponytail: one-way and additive. Deleting something in the old app doesn't delete it here, so
# delete it in the new app instead.
module Import
  VERIFIED = 2

  def self.run(email, dir)
    account_id = DB[:accounts].where(email: email, status_id: VERIFIED).get(:id) or
      raise "No verified account for #{email}. Sign up and click the verification link first."
    jobs = JSON.parse(File.read(File.join(dir, "jobs.json")))
    refs = JSON.parse(File.read(File.join(dir, "referrals.json")))

    DB.transaction do
      # The old files list newest first, so insert oldest first and the newest rows get the highest ids.
      jobs.reverse_each { |job| import_job(account_id, job) }
      refs.reverse_each { |ref| import_referral(account_id, ref) }
      verify!(account_id, jobs, refs)
    end
  end

  # Goes through the models so every text field is encrypted. Matching on legacy_id updates in place.
  def self.import_job(account_id, job)
    app = (Application.first(account_id: account_id, legacy_id: job["id"]) || Application.new(account_id: account_id, legacy_id: job["id"]))
    app.set(applied_on: date(job["applied_on"]), **%w[company title location pay url notes].to_h { [_1.to_sym, job[_1].to_s] })
    app.save
    app.events_dataset.delete
    job["history"].each { app.add_event(stage: _1["stage"], on: date(_1["on"]), note: _1["note"].to_s) }
  end

  def self.import_referral(account_id, ref)
    (Referral.first(account_id: account_id, legacy_id: ref["id"]) || Referral.new(account_id: account_id, legacy_id: ref["id"]))
      .set(status: ref["status"], **%w[name contact company role url notes].to_h { [_1.to_sym, ref[_1].to_s] },
           **%w[first_contact second_contact meeting_on added_on].to_h { [_1.to_sym, date(ref[_1])] })
      .save
  end

  # Fails the whole import (nothing saved) unless every old row and timeline step landed.
  def self.verify!(account_id, jobs, refs)
    legacy = ->(table, list) { DB[table].where(account_id: account_id, legacy_id: list.map { _1["id"] }).count }
    counts = {
      applications: [legacy[:applications, jobs], jobs.size],
      timeline_steps: [DB[:application_events].where(application_id: DB[:applications]
        .where(account_id: account_id, legacy_id: jobs.map { _1["id"] }).select(:id)).count,
        jobs.sum { _1["history"].size }],
      referrals: [legacy[:referrals, refs], refs.size]
    }
    bad = counts.reject { |_, (got, want)| got == want }
    raise "Import counts don't match, nothing was saved: #{bad}" unless bad.empty?
    counts.transform_values(&:first)
  end

  def self.date(value) = value.to_s.empty? ? nil : Date.iso8601(value)
end
