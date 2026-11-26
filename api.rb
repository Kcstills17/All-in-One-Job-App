require "date"
require "uri"
require_relative "models"
require_relative "fetcher"
require_relative "locations"
require_relative "export"

# The JSON API the page calls, ported from the local app with the same paths and payloads.
# Every lookup starts from the logged-in account's rows, so another user's ids simply aren't found.
module Api
  class Invalid < StandardError; end

  def api_routes(r, account_id)
    # Live rows only; trashed ones are reachable through /api/trash.
    apps = Application.where(account_id: account_id, deleted_at: nil)
    refs = Referral.where(account_id: account_id, deleted_at: nil)

    r.get("session") { { email: rodauth.account[:email], csrf: csrf_token } }
    r.get("stages") { STAGES }
    r.get("locations") { Locations::ALL }

    # Download your data. Plain GETs are fine: a page on another site can start the download, but the
    # browser saves it for you and that site never gets to read it.
    r.on "export" do
      stamp = Date.today.iso8601
      download = ->(name, type) do
        response["content-type"] = type
        response["content-disposition"] = %(attachment; filename="job-tracker-#{name}-#{stamp}.#{type[/json|csv/]}")
      end
      r.get("all.json") { download.("all", "application/json"); JSON.pretty_generate(Export.data(account_id)) }
      r.get("applications.csv") { download.("applications", "text/csv; charset=utf-8"); Export.applications_csv(account_id) }
      r.get("referrals.csv") { download.("referrals", "text/csv; charset=utf-8"); Export.referrals_csv(account_id) }
    end

    r.on "jobs" do
      r.is do
        r.get do
          purge_trash(account_id)
          apps.order(Sequel.desc(:id)).eager(:events).all.map(&:to_api)
        end
        r.post { add_job(apps, account_id, r.POST) }
      end
      r.on Integer do |id|
        job = apps.first(id: id) or not_found(r)
        r.is do
          r.patch { update_job(job, r.POST) }
          r.delete { job.update(deleted_at: Time.now); { ok: true } } # to Trash
        end
        r.on "events" do
          r.is { r.post { job.add_event(event_attrs(r.POST)); job.refresh.to_api } }
          r.is Integer do |idx|
            event = job.history[idx] or not_found(r)
            r.patch { event.update(event_attrs(event.to_api.transform_keys(&:to_s).merge(r.POST))); job.refresh.to_api }
            r.delete do
              raise Invalid, "a job needs at least one stage" if job.history.size == 1
              event.destroy
              job.refresh.to_api
            end
          end
        end
      end
    end

    # Gmail suggestions waiting for review. Approving one adds a timeline step to one of this
    # account's live applications, dated from the email; nothing changes without approval.
    r.on "gmail" do
      matches = EmailMatch.where(account_id: account_id, status: "pending")
      mailbox = GmailToken[account_id]&.mailbox
      r.get("matches") { matches.order(Sequel.desc(:email_on), Sequel.desc(:id)).all.map { _1.to_api(mailbox) } }
      r.post "matches/approve-all" do
        category = r.POST["category"].to_s
        raise Invalid, "unknown category" unless %w[rejected moving_on].include?(category)
        approved = 0
        DB.transaction do
          matches.where(category: category).exclude(application_id: nil).all.each do |m|
            job = apps.first(id: m.application_id) or next
            approve_match(m, job, nil)
            approved += 1
          end
        end
        { approved: approved }
      end
      r.on "matches", Integer do |id|
        match = matches.first(id: id) or not_found(r)
        r.post "dismiss" do
          match.update(status: "dismissed")
          { ok: true }
        end
        r.post "approve" do
          job_id = r.POST["application_id"].to_s.empty? ? match.application_id : r.POST["application_id"].to_i
          job = (job_id && apps.first(id: job_id)) or raise Invalid, "Pick the application this email is about"
          DB.transaction { approve_match(match, job, r.POST["stage"]) }
          { job: job.refresh.to_api }
        end
      end
    end

    r.on "resumes" do
      resumes = Resume.where(account_id: account_id)
      r.is do
        r.get { resumes.order(:started_on, :id).all.map(&:to_api) }
        r.post { Resume.create(account_id: account_id, **resume_fields(r.POST, required: true)).to_api }
      end
      r.is Integer do |id|
        resume = resumes.first(id: id) or not_found(r)
        r.patch { resume.update(resume_fields(r.POST)).to_api }
        r.delete { resume.destroy; { ok: true } } # its applications go back to "by date"
      end
    end

    # Company notes, found by name. PUT creates or updates the notes for that name.
    r.is "companies" do
      companies = Company.where(account_id: account_id)
      r.get { companies.all.map(&:to_api) }
      r.put do
        name = r.POST["name"].to_s.strip
        raise Invalid, "Company name is required" if name.empty?
        company = companies.with_encrypted_value(:key, Company.key_for(name)).first ||
                  Company.new(account_id: account_id, key: Company.key_for(name))
        company.set(name: name, notes: r.POST["notes"].to_s).save.to_api
      end
    end

    # The prep library and the day-of checklist.
    r.on "prep" do
      notes = PrepNote.where(account_id: account_id)
      r.is do
        r.get do
          checklist = notes.first(kind: "checklist")
          { notes: notes.where(kind: "note").order(:id).all.map(&:to_api),
            checklist: checklist ? lines(checklist.body) : PrepNote::DEFAULT_CHECKLIST }
        end
        r.post { PrepNote.create(account_id: account_id, kind: "note", **prep_fields(r.POST, required: true)).to_api }
      end
      r.is "checklist" do
        r.put do
          items = lines(r.POST["items"])
          (notes.first(kind: "checklist") || PrepNote.new(account_id: account_id, kind: "checklist", title: "Day-of checklist"))
            .set(body: items.join("\n")).save
          { checklist: items }
        end
      end
      r.is Integer do |id|
        note = notes.first(id: id, kind: "note") or not_found(r)
        r.patch { note.update(prep_fields(r.POST)).to_api }
        r.delete { note.destroy; { ok: true } }
      end
    end

    # Trash: deleted applications (saved jobs included) and referrals, restorable for TRASH_DAYS.
    r.on "trash" do
      trashed = { "jobs" => Application.where(account_id: account_id).exclude(deleted_at: nil),
                  "referrals" => Referral.where(account_id: account_id).exclude(deleted_at: nil) }
      r.is do
        r.get do
          purge_trash(account_id)
          { days: TRASH_DAYS,
            jobs: trashed["jobs"].order(Sequel.desc(:deleted_at)).eager(:events).all.map { _1.to_api.merge(deleted_at: _1.deleted_at.iso8601) },
            referrals: trashed["referrals"].order(Sequel.desc(:deleted_at)).all.map { _1.to_api.merge(deleted_at: _1.deleted_at.iso8601) } }
        end
        r.delete { trashed.each_value(&:delete); { ok: true } } # empty it; timeline steps cascade
      end
      r.on %w[jobs referrals], Integer do |kind, id|
        row = trashed[kind].first(id: id) or not_found(r)
        r.is("restore") { r.post { row.update(deleted_at: nil).to_api } }
        r.is { r.delete { row.destroy; { ok: true } } }
      end
    end

    r.on "referrals" do
      r.is do
        r.get { { statuses: REF_STATUSES, referrals: refs.order(Sequel.desc(:id)).all.map(&:to_api) } }
        r.post { add_referral(account_id, r.POST) }
      end
      r.is Integer do |id|
        ref = refs.first(id: id) or not_found(r)
        r.patch do
          fields = referral_fields(r.POST)
          raise Invalid, "Referrer name is required" if fields.key?(:name) && fields[:name].empty?
          ref.update(fields).to_api
        end
        r.delete { ref.update(deleted_at: Time.now); { ok: true } } # to Trash
      end
    end
  end

  private

  TRASH_DAYS = 30
  def purge_trash(account_id)
    cutoff = Time.now - TRASH_DAYS * 86_400
    [Application, Referral].each { _1.where(account_id: account_id) { deleted_at < cutoff }.delete }
  end

  def not_found(r) = r.halt([404, { "content-type" => "application/json" }, ['{"error":"Not found"}']])

  # saved=1 keeps it as a lead ("Saved" stage, no applied date) until you apply.
  def add_job(apps, account_id, params)
    saved = params["saved"].to_s == "1" || params["saved"] == true
    url = link!(params["url"])
    dup = apps.with_encrypted_value(:url, url).first unless url.empty?
    return dup.to_api.merge(duplicate: true) if dup

    info = url.empty? ? {} : Fetcher.fetch(url)
    no_location = blank?(params["location"])
    job = Application.new(
      account_id: account_id, url: url,
      company: text(params["company"]) || info[:company].to_s,
      title: text(params["title"]) || auto_title(info, params["page_title"]).to_s,
      location: no_location ? Locations.normalize(info[:location]) : location!(params["location"]),
      pay: text(params["pay"]) || info[:pay].to_s,
      # Keep a posting's location text if it didn't map to the list (e.g. "Eastern Time zone").
      notes: [params["notes"].to_s, (posting_loc_note(info[:location]) if no_location)].compact.reject(&:empty?).join("\n"),
      applied_on: saved ? nil : date!(params["applied_on"]) || Date.today
    )
    DB.transaction do
      job.save
      job.add_event(stage: saved ? "Saved" : "Applied", on: saved ? date!(params["on"]) || Date.today : job.applied_on, note: "")
    end
    job.to_api
  end

  def update_job(job, params)
    fields = params.slice(*%w[company title location pay notes prep url applied_on]).transform_values(&:to_s)
    fields["location"] = location!(fields["location"]) if fields.key?("location")
    fields["url"] = link!(fields["url"]) if fields.key?("url")
    fields["applied_on"] = date!(fields["applied_on"]) if fields.key?("applied_on")
    # "" means "by date"; otherwise it must be one of this account's resumes.
    if params.key?("resume_id")
      rid = params["resume_id"].to_s
      fields["resume_id"] = rid.empty? ? nil :
        (Resume.where(account_id: job.account_id, id: rid.to_i).get(:id) || raise(Invalid, "Unknown resume version"))
    end
    DB.transaction do
      job.set_fields(fields, fields.keys).save
      job.add_event(event_attrs(params)) if params["stage"] && params["stage"] != job.history.last&.stage
    end
    job.refresh.to_api
  end

  def event_attrs(params)
    raise Invalid, "unknown stage #{params['stage']}" unless STAGES.include?(params["stage"])
    { stage: params["stage"], on: date!(params["on"]) || Date.today, at: time!(params["at"]), note: params["note"].to_s,
      checked: lines(params["checked"]).join("\n") }
  end

  # A list of short text items (a JSON array, or one per line), blank ones dropped.
  def lines(value) = (value.is_a?(Array) ? value : value.to_s.split("\n")).map { _1.to_s.strip }.reject(&:empty?)

  # "HH:MM" (24-hour, what <input type="time"> sends) or blank.
  def time!(value)
    value = value.to_s.strip
    return nil if value.empty?
    raise Invalid, "times look like 14:30" unless value.match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
    value
  end

  # Parsed job data beats the browser tab's title ("Role at Company | Site"); the tab beats a scraped <title>.
  def auto_title(info, page_title)
    (info[:fallback] ? [page_title, info[:title]] : [info[:title], page_title]).find { !blank?(_1) }
  end

  # A link fills in a blank company or role.
  def add_referral(account_id, params)
    fields = referral_fields(params)
    raise Invalid, "Referrer name is required" if fields[:name].to_s.empty?
    blank = %i[company role].select { fields[_1].to_s.empty? }
    unless fields[:url].to_s.empty? || blank.empty?
      company, role = referral_guess(fields[:url], Fetcher.fetch(fields[:url]))
      fields[:company] = company.to_s if blank.include?(:company)
      fields[:role] = role.to_s if blank.include?(:role)
    end
    Referral.create(account_id: account_id, status: REF_STATUSES.first, added_on: Date.today, **fields).to_api
  end

  # ponytail: for sites without auto-fill, guess from the domain and page title. Only a plain domain names
  # the company (cribl.io, not apply.workable.com), and titles that read like a careers page are skipped.
  def referral_guess(url, info)
    return [info[:company], info[:title]] unless info[:fallback]
    labels = URI(url).host.sub(/\Awww\./, "").split(".")
    [(labels.first.capitalize if labels.size == 2), (info[:title] unless info[:title].to_s.match?(/career|opening|open role|\bjobs?\b/i))]
  end

  # Only known fields are saved, so a request can't set account_id or anything else.
  def referral_fields(params)
    out = Referral::TEXT.filter_map { |k| [k, params[k.to_s].to_s.strip] if params.key?(k.to_s) }.to_h
    out[:url] = link!(out[:url]) if out.key?(:url)
    Referral::DATES.each { |k| out[k] = date!(params[k.to_s]) if params.key?(k.to_s) }
    if params.key?("status")
      raise Invalid, "unknown status #{params['status']}" unless REF_STATUSES.include?(params["status"])
      out[:status] = params["status"]
    end
    out
  end

  # Rejected for rejections; for next steps, the stage after where the application is now.
  # When the email names the step ("schedule a technical interview"), use it if it's further along.
  NAMED_STAGES = { /final round|onsite|on-site/i => "Final Round", /work trial|paid trial/i => "Work Trial",
                   /take[- ]home|coding (challenge|assessment)|online assessment/i => "Take-home",
                   /technical interview|technical screen|pairing|live coding/i => "Technical Interview",
                   /hiring manager/i => "Hiring Manager", /phone screen|recruiter (call|screen)|intro call/i => "Recruiter Screen" }.freeze

  def suggested_stage(match, job)
    return "Rejected" if match.category == "rejected"
    named = NAMED_STAGES.find { |re, _| "#{match.subject} #{match.sentence}".match?(re) }&.last
    # Furthest real progress: endings (Rejected, Ghosted, Withdrawn) don't count.
    last = job.history.map(&:stage).reject { %w[Rejected Ghosted Withdrawn].include?(_1) }.max_by { STAGES.index(_1) }
    after = [nil, "Saved", "Applied", "Followed Up"].include?(last) ? "Recruiter Screen" : STAGES[[STAGES.index(last) + 1, STAGES.index("Accepted")].min]
    named && STAGES.index(named) > STAGES.index(after) ? named : after
  end

  # Adds the step (unless the application is already at that stage) and closes the suggestion.
  def approve_match(match, job, stage)
    stage = stage.to_s.empty? ? suggested_stage(match, job) : stage
    raise Invalid, "unknown stage #{stage}" unless STAGES.include?(stage)
    unless job.history.last&.stage == stage
      job.add_event(stage: stage, on: match.email_on || Date.today, note: "From Gmail: #{match.sentence}")
    end
    match.update(status: "approved", application_id: job.id)
  end

  def resume_fields(params, required: false)
    out = %w[name url notes].filter_map { |k| [k.to_sym, params[k].to_s.strip] if params.key?(k) }.to_h
    out[:url] = link!(out[:url]) if out.key?(:url)
    out[:started_on] = date!(params["started_on"]) || Date.today if required || params.key?("started_on")
    raise Invalid, "A resume version needs a name" if (required || out.key?(:name)) && out[:name].to_s.empty?
    out
  end

  def prep_fields(params, required: false)
    out = %w[title body].filter_map { |k| [k.to_sym, params[k].to_s] if params.key?(k) }.to_h
    out[:title] = out[:title].strip if out[:title]
    raise Invalid, "A prep note needs a title" if (required || out.key?(:title)) && out[:title].to_s.empty?
    out
  end

  # Links must be http(s): a javascript: link would run code when clicked.
  def link!(value)
    url = value.to_s.strip
    raise Invalid, "Links must start with http:// or https://" unless url.empty? || url.match?(%r{\Ahttps?://\S+\z}i)
    url
  end

  # Locations must come from Locations::ALL (blank allowed). Fixes casing, rejects anything else.
  def location!(value)
    return "" if blank?(value)
    Locations.canonical(value) || raise(Invalid, "Pick a location from the list (got #{value.to_s.strip.inspect})")
  end

  def posting_loc_note(raw)
    raw = raw.to_s.strip
    "Posting location: #{raw}" if !raw.empty? && Locations.normalize(raw).empty?
  end

  def date!(value)
    blank?(value) ? nil : Date.iso8601(value.to_s)
  rescue Date::Error
    raise Invalid, "Dates must look like 2026-11-11 (got #{value.to_s.inspect})"
  end

  def text(value) = (s = value.to_s.strip).empty? ? nil : s
  def blank?(value) = value.to_s.strip.empty?
end
