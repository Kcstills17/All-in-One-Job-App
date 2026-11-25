require "net/imap"
require "mail"
require "date"
require "cgi"

# Reads job emails from Gmail over IMAP with an app password. Only Gmail's own search picks which
# emails are fetched, and only the first part of each is read, in memory; nothing here is stored.
module Gmail
  HOST = "imap.gmail.com"
  BATCH = 50
  BYTES = 40_000 # enough for the text of a recruiting email; skips attachments
  # Gmail search syntax (X-GM-RAW): likely job email since a date, minus promotions, social and what you sent.
  def self.query(since)
    %(after:#{since.strftime("%Y/%m/%d")} -category:promotions -category:social -in:sent ) +
      %{(subject:(application OR applying OR applied OR interview OR candidacy OR opportunity OR position OR role) } +
      %{OR "other candidates" OR "moving forward" OR "move forward" OR "next steps" OR "your application" OR "regret to inform")}
  end

  # Yields { uid:, msgid:, from_name:, from_address:, subject:, text:, date: } for each matching email, oldest first.
  def self.each_email(address, app_password, since:, after_uid: nil)
    imap = Net::IMAP.new(HOST, port: 993, ssl: true)
    imap.login(address, app_password)
    imap.examine("[Gmail]/All Mail") # read-only: nothing is marked read or moved
    uids = imap.uid_search(["X-GM-RAW", query(since)])
    uids = uids.select { _1 > after_uid } if after_uid
    uids.sort.each_slice(BATCH) do |batch|
      imap.uid_fetch(batch, ["ENVELOPE", "X-GM-MSGID", "BODY.PEEK[]<0.#{BYTES}>"]).each do |f|
        yield parse(f)
      end
    end
  ensure
    imap&.logout rescue nil
    imap&.disconnect rescue nil
  end

  def self.parse(fetched)
    env = fetched.attr["ENVELOPE"]
    from = env.from&.first
    raw = fetched.attr.find { |k, _| k.start_with?("BODY[]") }&.last.to_s
    { uid: fetched.attr["UID"], msgid: fetched.attr["X-GM-MSGID"],
      from_name: decode(from&.name), from_address: from ? "#{from.mailbox}@#{from.host}" : "",
      subject: decode(env.subject), date: (Date.parse(env.date) rescue nil), text: text_of(raw) }
  end

  def self.decode(value) = value ? Mail::Encodings.value_decode(value).to_s.encode("UTF-8", invalid: :replace, undef: :replace) : ""

  # Plain text if the email has it, else the HTML with tags removed.
  def self.text_of(raw)
    mail = Mail.new(raw)
    part = mail.multipart? ? (mail.text_part || mail.html_part) : mail
    text = part&.decoded.to_s
    text = text.gsub(%r{<(style|script)[^>]*>.*?</\1>}mi, " ").gsub(/<[^>]+>/, " ") if part&.mime_type.to_s.include?("html") || text.include?("</")
    CGI.unescapeHTML(text.encode("UTF-8", invalid: :replace, undef: :replace)).gsub(/\s+/, " ").strip
  rescue StandardError
    ""
  end
end
