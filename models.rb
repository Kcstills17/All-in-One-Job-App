require_relative "config"

# Everything a user types is encrypted (AES-256-GCM) before it reaches the database, so someone
# reading the tables sees ids, dates, stages and statuses only. Losing COLUMN_KEY loses the data:
# keep a copy of the production key somewhere other than the server.
Sequel::Model.plugin :column_encryption do |enc|
  enc.key 0, [ENV.fetch("COLUMN_KEY")].pack("H*")
end

module Encrypted
  # Decrypted values come back as binary; everything stored is text, so tag it UTF-8 (the stored
  # bytes are unchanged). Passed as `format:` on every encrypted column.
  TEXT = [->(v) { v }, ->(v) { String.new(v, encoding: Encoding::UTF_8) }].freeze

  # Encrypted columns have no database default, so a missing value is saved as an encrypted "".
  # (Use the col / col= methods: self[col] holds ciphertext, filled in only as validation runs.)
  def before_validation
    self.class.encrypted.each { |c| public_send(:"#{c}=", "") if public_send(c).nil? }
    super
  end
end

STAGES = ["Saved", "Applied", "Followed Up", "Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home",
          "Final Round", "Work Trial", "Offer", "Accepted", "Rejected", "Ghosted", "Withdrawn"].freeze
REF_STATUSES = ["To Contact", "Messaged", "Followed Up", "Replied", "Met", "Referral Offered", "Referred",
                "Declined", "No Response"].freeze

class Application < Sequel::Model
  def self.encrypted = %i[company title location pay url notes prep]
  plugin :column_encryption do |enc|
    (encrypted - [:url]).each { enc.column _1, format: Encrypted::TEXT }
    enc.column :url, searchable: true, format: Encrypted::TEXT # exact-match lookups find duplicate links
  end
  include Encrypted
  one_to_many :events, class: :ApplicationEvent

  # Timeline order the page expects: by date (blank first), then stage order, then entry order.
  def history = events.sort_by { [_1.on.to_s, STAGES.index(_1.stage), _1.id] }

  def to_api
    { id: id.to_s, company:, title:, location:, pay:, url:, notes:, prep: prep.to_s, resume_id: resume_id&.to_s, applied_on: applied_on.to_s,
      history: history.map(&:to_api) }
  end
end

class ApplicationEvent < Sequel::Model
  def self.encrypted = %i[note checked]
  plugin :column_encryption do |enc|
    encrypted.each { enc.column _1, format: Encrypted::TEXT }
  end
  include Encrypted
  many_to_one :application

  # checked: the day-of checklist items ticked for this step, one per line.
  def to_api = { stage:, on: on.to_s, at: at.to_s, note:, checked: checked.to_s.split("\n") }
end

class Referral < Sequel::Model
  TEXT = %i[name contact company role url notes].freeze
  DATES = %i[first_contact second_contact meeting_on].freeze
  def self.encrypted = TEXT
  plugin :column_encryption do |enc|
    TEXT.each { enc.column _1, format: Encrypted::TEXT }
  end
  include Encrypted

  def to_api
    { id: id.to_s, status:, added_on: added_on.to_s, **TEXT.to_h { [_1, public_send(_1)] },
      **DATES.to_h { [_1, self[_1].to_s] } }
  end
end

# Notes about a company, shared by every application to it. `key` is the lowercased name, searchable
# without decrypting, so "Acme" and "acme " find the same notes.
class Company < Sequel::Model
  def self.encrypted = %i[key name notes]
  plugin :column_encryption do |enc|
    enc.column :key, searchable: true, format: Encrypted::TEXT
    %i[name notes].each { enc.column _1, format: Encrypted::TEXT }
  end
  include Encrypted

  def self.key_for(name) = name.to_s.strip.downcase
  def to_api = { id: id.to_s, name:, notes: }
end

# The prep library (kind "note") and the day-of checklist (kind "checklist": one item per line in body).
class PrepNote < Sequel::Model
  def self.encrypted = %i[title body]
  plugin :column_encryption do |enc|
    encrypted.each { enc.column _1, format: Encrypted::TEXT }
  end
  include Encrypted

  DEFAULT_CHECKLIST = ["Tested the video link, camera and mic", "Picked the resume version I sent",
                       "Reread the posting and my role notes", "Questions ready for them", "Water and a quiet room"].freeze

  def to_api = { id: id.to_s, title:, body: }
end

# A resume version: name, link to the file, notes, and the date you started sending it.
class Resume < Sequel::Model
  def self.encrypted = %i[name url notes]
  plugin :column_encryption do |enc|
    encrypted.each { enc.column _1, format: Encrypted::TEXT }
  end
  include Encrypted

  def to_api = { id: id.to_s, name:, url:, notes:, started_on: started_on.to_s }
end

# Gmail scan. Only the token's digest is kept; the token itself is shown once.
class GmailToken < Sequel::Model
  unrestrict_primary_key
  def self.digest(token) = OpenSSL::Digest::SHA256.hexdigest(token.to_s)
end

# One suggestion from one email, waiting for review. The email body is never stored.
class EmailMatch < Sequel::Model
  def self.encrypted = %i[msg_key sender subject sentence]
  plugin :column_encryption do |enc|
    enc.column :msg_key, searchable: true, format: Encrypted::TEXT
    %i[sender subject sentence].each { enc.column _1, format: Encrypted::TEXT }
  end
  include Encrypted
  many_to_one :application

  def gmail_url = "https://mail.google.com/mail/u/0/#all/#{msg_key}"
  def to_api
    { id: id.to_s, category:, status:, email_on: email_on.to_s, sender:, subject:, sentence:, gmail_url:,
      application_id: application_id&.to_s, candidates: candidates.to_s.split(",") }
  end
end
