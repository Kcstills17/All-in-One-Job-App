require "date"
require "uri"
require_relative "models"
require_relative "fetcher"
require_relative "locations"

# The JSON API the page calls, ported from the local app with the same paths and payloads.
# Every lookup starts from the logged-in account's rows, so another user's ids simply aren't found.
module Api
  class Invalid < StandardError; end

  def api_routes(r, account_id)
    apps = Application.where(account_id: account_id)
    refs = Referral.where(account_id: account_id)

    r.get("session") { { email: rodauth.account[:email], csrf: csrf_token } }
    r.get("stages") { STAGES }
    r.get("locations") { Locations::ALL }

    r.on "jobs" do
      r.is do
        r.get { apps.order(Sequel.desc(:id)).eager(:events).all.map(&:to_api) }
        r.post { add_job(apps, account_id, r.POST) }
      end
      r.on Integer do |id|
        job = apps.first(id: id) or not_found(r)
        r.is do
          r.patch { update_job(job, r.POST) }
          r.delete { job.destroy; { ok: true } }
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
        r.delete { ref.destroy; { ok: true } }
      end
    end
  end

  private

  def not_found(r) = r.halt([404, { "content-type" => "application/json" }, ['{"error":"Not found"}']])

  def add_job(apps, account_id, params)
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
      applied_on: date!(params["applied_on"]) || Date.today
    )
    DB.transaction { job.save; job.add_event(stage: "Applied", on: job.applied_on, note: "") }
    job.to_api
  end

  def update_job(job, params)
    fields = params.slice(*%w[company title location pay notes url applied_on]).transform_values(&:to_s)
    fields["location"] = location!(fields["location"]) if fields.key?("location")
    fields["url"] = link!(fields["url"]) if fields.key?("url")
    fields["applied_on"] = date!(fields["applied_on"]) if fields.key?("applied_on")
    DB.transaction do
      job.set_fields(fields, fields.keys).save
      job.add_event(event_attrs(params)) if params["stage"] && params["stage"] != job.history.last&.stage
    end
    job.refresh.to_api
  end

  def event_attrs(params)
    raise Invalid, "unknown stage #{params['stage']}" unless STAGES.include?(params["stage"])
    { stage: params["stage"], on: date!(params["on"]) || Date.today, note: params["note"].to_s }
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
