require "date"
require "set"
require "cgi"
require_relative "models"
require_relative "gmail_scan"

# Takes the job emails a user's Gmail script posts (see apps_script/), sorts and matches them, and
# saves a suggestion for each rejection or next-steps email. Bodies are only read here, in memory.
module GmailIngest
  MAX_EMAILS = 100      # per request; the script sends batches
  MAX_TEXT = 20_000     # characters of body read per email

  # emails: [{ "id", "from", "subject", "date", "body" }]. Returns counts for the script's log.
  def self.run(account_id, emails, mailbox: nil)
    raise ArgumentError, "send at most #{MAX_EMAILS} emails at a time" if emails.size > MAX_EMAILS
    apps = Application.where(account_id: account_id, deleted_at: nil).eager(:events).all
                      .reject { _1.history.last&.stage == "Saved" }
                      .map { { id: _1.id, company: _1.company, title: _1.title, applied_on: _1.applied_on } }
    mine = EmailMatch.where(account_id: account_id)
    counts = Hash.new(0)
    emails.each do |raw|
      id = raw["id"].to_s
      next counts[:skipped] += 1 if id.empty? || mine.with_encrypted_value(:msg_key, id).any?
      email = parse(raw)
      result = GmailScan.classify(email)
      next counts[:not_job] += 1 unless result
      next counts[:confirmation] += 1 if result[:category] == :confirmation
      match = GmailScan.match(email, apps)
      EmailMatch.create(account_id: account_id, msg_key: id, category: result[:category].to_s, email_on: email[:date],
                        sender: [email[:from_name], email[:from_address]].reject(&:empty?).join(" · "), subject: email[:subject],
                        sentence: result[:sentence], application_id: match[:app]&.dig(:id),
                        candidates: Array(match[:candidates]).map { _1[:id] }.join(","))
      counts[match[:app] ? :matched : :needs_a_match] += 1
    end
    token = GmailToken[account_id]
    token.set(last_used_at: Time.now)
    token.set(mailbox: mailbox.to_s[0, 320]) if mailbox.to_s.include?("@")
    token.save
    counts
  end

  # Some senders put HTML in the "plain text" part; drop the tags so the saved sentence is readable.
  def self.plain(text)
    return text unless text.match?(/<(!doctype|html|body|div|table|p|br)\b/i)
    CGI.unescapeHTML(text.gsub(%r{<(style|script|head)[^>]*>.*?</\1>}mi, " ").gsub(/<[^>]+>/, " ")).gsub(/\s+/, " ").strip
  end

  # "Acme Recruiting <jobs@acme.com>" -> name and address
  def self.parse(raw)
    from = raw["from"].to_s
    address = from[/<([^>]+)>/, 1] || from[/\S+@\S+/].to_s
    { from_name: from.sub(/<[^>]*>/, "").delete('"').strip.then { _1 == address ? "" : _1 },
      from_address: address.strip, subject: raw["subject"].to_s[0, 500], text: plain(raw["body"].to_s[0, MAX_TEXT]),
      date: (Date.parse(raw["date"].to_s) rescue nil) }
  end
end
