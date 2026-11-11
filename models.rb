require_relative "config"

# Everything a user types is encrypted (AES-256-GCM) before it reaches the database, so someone
# reading the tables sees ids, dates, stages and statuses only. Losing COLUMN_KEY loses the data:
# keep a copy of the production key somewhere other than the server.
Sequel::Model.plugin :column_encryption do |enc|
  enc.key 0, [ENV.fetch("COLUMN_KEY")].pack("H*")
end

module Encrypted
  # Encrypted columns have no database default, so a missing value is saved as an encrypted "".
  # (Use the col / col= methods: self[col] holds ciphertext, filled in only as validation runs.)
  def before_validation
    self.class.encrypted.each { |c| public_send(:"#{c}=", "") if public_send(c).nil? }
    super
  end
end

STAGES = ["Applied", "Followed Up", "Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home",
          "Final Round", "Work Trial", "Offer", "Accepted", "Rejected", "Ghosted", "Withdrawn"].freeze
REF_STATUSES = ["To Contact", "Messaged", "Followed Up", "Replied", "Met", "Referral Offered", "Referred",
                "Declined", "No Response"].freeze

class Application < Sequel::Model
  def self.encrypted = %i[company title location pay url notes]
  plugin :column_encryption do |enc|
    (encrypted - [:url]).each { enc.column _1 }
    enc.column :url, searchable: true # exact-match lookups find duplicate links
  end
  include Encrypted
  one_to_many :events, class: :ApplicationEvent

  # Timeline order the page expects: by date (blank first), then stage order, then entry order.
  def history = events.sort_by { [_1.on.to_s, STAGES.index(_1.stage), _1.id] }

  def to_api
    { id: id.to_s, company:, title:, location:, pay:, url:, notes:, applied_on: applied_on.to_s,
      history: history.map(&:to_api) }
  end
end

class ApplicationEvent < Sequel::Model
  def self.encrypted = %i[note]
  plugin :column_encryption do |enc|
    enc.column :note
  end
  include Encrypted
  many_to_one :application

  def to_api = { stage:, on: on.to_s, note: }
end

class Referral < Sequel::Model
  TEXT = %i[name contact company role url notes].freeze
  DATES = %i[first_contact second_contact meeting_on].freeze
  def self.encrypted = TEXT
  plugin :column_encryption do |enc|
    TEXT.each { enc.column _1 }
  end
  include Encrypted

  def to_api
    { id: id.to_s, status:, added_on: added_on.to_s, **TEXT.to_h { [_1, public_send(_1)] },
      **DATES.to_h { [_1, self[_1].to_s] } }
  end
end
