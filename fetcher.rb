require "json"
require "net/http"
require "cgi"
require "openssl"
require "ipaddr"
require "socket"

# Pulls company/title/location/pay from a job URL using the public job-board APIs.
# Anything it can't recognize falls back to the page's <title>.
module Fetcher
  UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36"
  PAY = /\$\s?\d[\d,.]*\s?[kK]?(?:\s*(?:-|–|to)\s*\$?\s?\d[\d,.]*\s?[kK]?)?(?:\s*(?:\/\s?(?:hr|hour|yr|year)|per (?:hour|year)))?/

  module_function

  def fetch(url)
    info = fetch_raw(url)
    info.transform_values { _1.is_a?(String) ? _1.strip : _1 }
  end

  def fetch_raw(url)
    case url
    when %r{greenhouse\.io/(?:embed/job_app\?for=)?([\w-]+)/jobs/(\d+)}, %r{greenhouse\.io/([\w-]+)/jobs/(\d+)}
      greenhouse($1, $2)
    when %r{jobs\.ashbyhq\.com/([^/?]+)/([0-9a-f-]{36})}
      ashby($1, $2)
    when %r{jobs\.lever\.co/([^/?]+)/([0-9a-f-]{36})}
      lever($1, $2)
    when %r{linkedin\.com/jobs/view/(?:[^/?]*-)?(\d+)}, %r{linkedin\.com/.*currentJobId=(\d+)}
      linkedin($1)
    when %r{(?:ycombinator|workatastartup)\.com/(?:companies/[^/]+/)?jobs/[^/?]+}
      yc(url)
    when %r{myworkdayjobs\.com/.*/job/}, %r{myworkdaysite\.com/.*/job/}
      workday(url)
    when %r{apply\.workable\.com/(?:([\w-]+)/)?j/([0-9A-F]+)}i
      workable($1, $2)
    when %r{ats\.rippling\.com/(?:[a-z]{2}-[A-Z]{2}/)?([\w-]+)/jobs/([0-9a-f-]{36})}
      rippling($1, $2)
    when %r{jobs\.smartrecruiters\.com/([^/?]+)/(\d+)}
      smartrecruiters($1, $2)
    when %r{([\w-]+)\.recruitee\.com/o/([^/?#]+)}
      recruitee($1, $2)
    when %r{([\w-]+)\.breezy\.hr/p/([^/?#]+)}
      breezy($1, $2)
    when %r{jobright\.ai/jobs/info/(\w+)}
      jobright($1)
    else
      page_title(url)
    end
  rescue StandardError
    page_title(url) rescue {}
  end

  def greenhouse(org, id)
    j = get_json("https://boards-api.greenhouse.io/v1/boards/#{org}/jobs/#{id}")
    { company: titleize(org), title: j["title"], location: j.dig("location", "name"), pay: pay(CGI.unescapeHTML(j["content"].to_s)) }
  end

  # The job page (~35KB) embeds a JobPosting; the board API lists every job with full descriptions
  # and passes MAX_BYTES on big boards (Talkiatry's 190 jobs), so it's only the fallback.
  def ashby(org, id)
    info = json_ld(get("https://jobs.ashbyhq.com/#{org}/#{id}")) rescue nil
    return info.reject { |_, v| v.to_s.empty? } if info && !info[:title].empty?
    jobs = get_json("https://api.ashbyhq.com/posting-api/job-board/#{org}?includeCompensation=true")["jobs"]
    j = jobs.find { _1["id"] == id } or return { company: titleize(org) }
    # Ashby flags remote roles separately ("Eastern Time zone" + isRemote) — fold that into the text.
    { company: titleize(org), title: j["title"], location: j["isRemote"] ? "Remote (#{j['location']})" : j["location"],
      pay: j.dig("compensation", "compensationTierSummary") || pay(j["descriptionHtml"]) }
  end

  def lever(org, id)
    j = get_json("https://api.lever.co/v0/postings/#{org}/#{id}")
    r = j["salaryRange"]
    { company: titleize(org), title: j["text"], location: j.dig("categories", "location"),
      pay: r ? "$#{r['min']}–$#{r['max']}" : pay(j["descriptionPlain"]) }
  end

  def linkedin(id)
    h = get("https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/#{id}")
    grab = ->(re) { h[re, 1]&.strip&.then { CGI.unescapeHTML(_1) } }
    title = grab[/topcard__title[^>]*>\s*(.*?)\s*</m]
    return page_title("https://www.linkedin.com/jobs/view/#{id}") unless title # guest API is rate-limited at times
    { company: grab[/topcard__org-name-link[^>]*>\s*(.*?)\s*</m], title: title,
      location: grab[/topcard__flavor--bullet[^>]*>\s*(.*?)\s*</m], pay: pay(h.gsub(/<[^>]+>/, " ")) }
  end

  # YC company pages and Work at a Startup embed the job as JSON in a data-page attribute.
  def yc(url)
    props = JSON.parse(CGI.unescapeHTML(get(url)[/data-page="([^"]*)"/, 1]))["props"]
    j = props["job"]
    { company: j["companyName"] || props.dig("company", "name"), title: j["title"], location: j["location"], pay: j["salaryRange"] }
  end

  # ponytail: parsed from the URL because Workday's job API answers 403. Company is the tenant slug
  # ("wexinc" -> "Wexinc") and pay is unavailable; fix by hand in the detail panel.
  def workday(url)
    uri = URI(url)
    org = uri.host[/\A([\w-]+)\.wd\d+\.myworkdayjobs\.com/, 1] || uri.path[%r{/recruiting/([^/]+)/}, 1]
    parts = uri.path.split("/job/", 2).last.split("/")
    i = parts.index { _1.include?("_") } || parts.size - 1 # the title segment ends in "_<req id>"
    { company: org && titleize(org), title: slug_text(parts[i].split("_").first), location: (slug_text(parts[i - 1]) if i > 0) }
  end

  # Workable: the page title ("Role - Company") names the company for both link forms
  # (/<account>/j/<code> and the short /j/<code>). With the account, the job API adds the clean
  # title, location and remote flag; it has no salary field, so pay comes from the description text.
  def workable(account, code)
    page = CGI.unescapeHTML(get("https://apply.workable.com/j/#{code}")[%r{<title[^>]*>(.*?)</title>}mi, 1].to_s.strip)
    title, _, company = page.rpartition(" - ")
    info = title.empty? ? { title: page } : { company: company, title: title }
    return info unless account

    j = get_json("https://apply.workable.com/api/v2/accounts/#{account}/jobs/#{code}")
    where = %w[city region country].map { j.dig("location", _1) }.reject { _1.to_s.empty? }.join(", ")
    info.merge(title: j["title"] || info[:title],
               location: j["remote"] ? ["Remote", ("(#{where})" unless where.empty?)].compact.join(" ") : where,
               pay: pay([j["description"], j["requirements"], j["benefits"]].join(" ").gsub(/<[^>]+>/, " ")))
  end

  # Rippling's public board API returns the company name and structured pay ranges.
  def rippling(board, id)
    j = get_json("https://api.rippling.com/platform/api/ats/v1/board/#{board}/jobs/#{id}")
    r = j["payRangeDetails"]&.first
    { company: j["companyName"] || titleize(board), title: j["name"], location: Array(j["workLocations"]).join("; "),
      pay: r ? range(r["rangeStart"], r["rangeEnd"], r["currency"], r["frequency"]) :
                pay(text(Array(j["description"]&.values).join(" "))) }
  end

  def smartrecruiters(company, id)
    j = get_json("https://api.smartrecruiters.com/v1/companies/#{company}/postings/#{id}")
    l = j["location"] || {}
    where = [l["city"], l["region"], l["country"]&.upcase].reject { _1.to_s.empty? }.join(", ")
    c = j["compensation"]
    { company: j.dig("company", "name") || titleize(company), title: j["name"],
      location: l["remote"] ? "Remote (#{where})" : where,
      pay: c ? range(c["min"], c["max"], c["currency"], c["period"]) : pay(text(j.dig("jobAd", "sections").to_s)) }
  end

  def recruitee(company, slug)
    o = get_json("https://#{company}.recruitee.com/api/offers/#{slug}")["offer"]
    s = o["salary"] || {}
    { company: o["company_name"] || titleize(company), title: o["title"],
      location: o["remote"] ? "Remote (#{o['location']})" : o["location"],
      pay: !s["min"].to_s.empty? ? range(s["min"], s["max"], s["currency"], s["period"]) : pay(text(o["description"])) }
  end

  # Breezy has no per-job API; the board's /json list carries every posting.
  def breezy(company, friendly_id)
    j = get_json("https://#{company}.breezy.hr/json").find { _1["friendly_id"] == friendly_id || friendly_id.start_with?("#{_1['id']}-") } or return page_title("https://#{company}.breezy.hr/p/#{friendly_id}")
    loc = j.dig("location", "name")
    { company: j.dig("company", "name") || titleize(company), title: j["name"],
      location: j.dig("location", "is_remote") ? "Remote (#{loc})" : loc, pay: j["salary"] }
  end

  # Jobright's job page is a Next.js app with the job in __NEXT_DATA__. Search links
  # (/jobs/search?...position=N) carry no job id and sit behind a bot check, so only /jobs/info/<id> works.
  def jobright(id)
    ds = JSON.parse(get("https://jobright.ai/jobs/info/#{id}")[%r{<script id="__NEXT_DATA__"[^>]*>(.*?)</script>}m, 1]).dig("props", "pageProps", "dataSource")
    j = ds["jobResult"]
    { company: ds.dig("companyResult", "companyName"), title: j["jobTitle"],
      location: j["isRemote"] ? "Remote (#{j['jobLocation']})" : j["jobLocation"], pay: j["salaryDesc"] }
  end

  # schema.org JobPosting embedded in the page: Teamtailor, Jobvite, iCIMS and many company sites.
  def json_ld(html)
    html.scan(%r{<script[^>]*application/ld\+json[^>]*>(.*?)</script>}mi).flatten.each do |raw|
      data = JSON.parse(raw) rescue next
      data = data["@graph"] if data.is_a?(Hash) && data["@graph"]
      j = (data.is_a?(Array) ? data : [data]).find { _1.is_a?(Hash) && _1["@type"] == "JobPosting" } or next
      places = Array(j["jobLocation"]).map do |p|
        a = p.is_a?(Hash) ? p["address"] : nil
        a.is_a?(Hash) ? [a["addressLocality"], a["addressRegion"], a["addressCountry"].then { _1.is_a?(Hash) ? _1["name"] : _1 }].reject { _1.to_s.empty? }.uniq.join(", ") : a.to_s
      end.reject(&:empty?)
      where = places.join("; ")
      where = where.empty? ? "Remote" : "Remote (#{where})" if j["jobLocationType"].to_s.upcase == "TELECOMMUTE"
      s = j["baseSalary"].is_a?(Hash) ? j["baseSalary"] : {}
      v = s["value"].is_a?(Hash) ? s["value"] : {}
      org = j["hiringOrganization"]
      return { company: org.is_a?(Hash) ? org["name"] : org, title: CGI.unescapeHTML(j["title"].to_s), location: where,
               pay: !v["minValue"].to_s.empty? ? range(v["minValue"], v["maxValue"] || v["minValue"], s["currency"], v["unitText"]) : pay(text(CGI.unescapeHTML(j["description"].to_s))) }
    end
    nil
  end

  # "$125,000 - $145,000 per year" from structured pay fields.
  def range(min, max, currency, period)
    money = ->(n) { "#{currency.to_s.upcase.then { _1.empty? || _1 == 'USD' ? '$' : "#{_1} " }}#{n.to_f.round.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}" }
    per = period.to_s.downcase.sub(/ly\z/, "").sub("dai", "day")
    [money[min], (" - #{money[max]}" if max && max.to_f != min.to_f), (" per #{per}" unless per.empty?)].join
  end

  def text(html) = html.to_s.gsub(/<[^>]+>/, " ")

  # Workday slugs: "---" was " - ", "--" was punctuation like ", ", "-" was a space.
  def slug_text(slug) = slug.gsub(/---|--|-/, "---" => " - ", "--" => ", ", "-" => " ").sub(/[,\s]+\z/, "").strip

  def page_title(url)
    html = get(url)
    if (info = json_ld(html)) && !info[:title].empty?
      return info.reject { |_, v| v.to_s.empty? }
    end
    t = CGI.unescapeHTML(html[%r{<title[^>]*>(.*?)</title>}mi, 1].to_s.strip)
    # LinkedIn: "Support Engineer at Acme — Remote | LinkedIn"
    if (m = t.match(/\A(.+?) at (.+?)(?: [—|-] (.+?))? \| LinkedIn/))
      return { title: m[1], company: m[2], location: m[3] }
    end
    # JazzHR (applytojob.com): "Software Engineer - Peregrine Team - Career Page"
    if (m = t.match(/\A(.+) - (.+?) - Career Page\z/))
      return { title: m[1], company: m[2] }
    end
    { title: t, company: URI(url).host.sub(/\Awww\./, ""), fallback: true }
  end

  def pay(text) = text.to_s[PAY]&.sub(/[.,]\z/, "")
  def titleize(slug) = slug.tr("-_", "  ").split.map(&:capitalize).join(" ")

  # Fresh cert store: this Ruby's default one demands CRLs and fails every HTTPS call. Verification stays on.
  STORE = OpenSSL::X509::Store.new.tap(&:set_default_paths)

  class Blocked < StandardError; end

  MAX_BYTES = 2_000_000
  # Addresses a user's link must never make the server fetch: its own machine, private networks
  # (including the hosting provider's internal one), cloud metadata services and reserved ranges.
  BLOCKED = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
               192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
               ::/128 ::1/128 64:ff9b::/96 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8].map { IPAddr.new(_1) }

  # Every request goes through here, redirects included, so each hop is checked.
  def get(url, limit = 3)
    uri = URI(url)
    ip = safe_address!(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = ip # connect to the address that was checked, so DNS can't swap in another
    http.use_ssl = uri.scheme == "https"
    http.cert_store = STORE
    http.open_timeout = 5
    http.read_timeout = 10
    # Work at a Startup answers 406 unless HTML is explicitly accepted.
    req = Net::HTTP::Get.new(uri, "User-Agent" => UA, "Accept" => "text/html,application/json;q=0.9,*/*;q=0.8")
    body = +""
    res = http.request(req) do |r|
      r.read_body { |chunk| body << chunk; raise Blocked, "response too large" if body.bytesize > MAX_BYTES } unless r.is_a?(Net::HTTPRedirection)
    end
    return get(URI.join(url, res["location"]).to_s, limit - 1) if res.is_a?(Net::HTTPRedirection) && limit > 0
    body.force_encoding("UTF-8").scrub
  end

  # Returns the IP to connect to, or raises Blocked for anything but a public http(s) address on 80/443.
  def safe_address!(uri)
    raise Blocked, "only http and https links" unless %w[http https].include?(uri.scheme) && uri.host
    raise Blocked, "only standard web ports" unless [80, 443].include?(uri.port)
    addrs = Addrinfo.getaddrinfo(uri.host.delete_prefix("[").delete_suffix("]"), nil, nil, :STREAM).map(&:ip_address).uniq
    raise Blocked, "unknown host" if addrs.empty?
    addrs.each do |a|
      ip = IPAddr.new(a)
      ip = ip.native # ::ffff:127.0.0.1 is 127.0.0.1
      raise Blocked, "private or reserved address" if BLOCKED.any? { _1.family == ip.family && _1.include?(ip) }
    end
    addrs.first
  rescue SocketError, IPAddr::InvalidAddressError
    raise Blocked, "unknown host"
  end

  def get_json(url) = JSON.parse(get(url))
end
