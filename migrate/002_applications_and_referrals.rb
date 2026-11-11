# Each user's applications, their timeline steps, and referral contacts. Rows belong to an account
# and disappear with it. legacy_id is the id from the old JSON app, so re-importing updates rows
# instead of duplicating them.
Sequel.migration do
  stages = ["Applied", "Followed Up", "Recruiter Screen", "Hiring Manager", "Technical Interview", "Take-home",
            "Final Round", "Work Trial", "Offer", "Accepted", "Rejected", "Ghosted", "Withdrawn"]
  statuses = ["To Contact", "Messaged", "Followed Up", "Replied", "Met", "Referral Offered", "Referred",
              "Declined", "No Response"]

  up do
    create_table(:applications) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String :legacy_id
      String :company, null: false, default: ""
      String :title, null: false, default: ""
      String :location, null: false, default: ""
      String :pay, null: false, default: ""
      String :url, null: false, default: ""
      String :notes, text: true, null: false, default: ""
      Date :applied_on
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      index :account_id
      index [:account_id, :legacy_id], unique: true
    end

    create_table(:application_events) do
      primary_key :id, type: :Bignum
      foreign_key :application_id, :applications, type: :Bignum, null: false, on_delete: :cascade, index: true
      String :stage, null: false
      Date :on
      String :note, text: true, null: false, default: ""
      constraint(:valid_stage, stage: stages)
    end

    create_table(:referrals) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String :legacy_id
      String :name, null: false
      String :contact, null: false, default: ""
      String :company, null: false, default: ""
      String :role, null: false, default: ""
      String :url, null: false, default: ""
      String :notes, text: true, null: false, default: ""
      String :status, null: false, default: statuses.first
      Date :first_contact
      Date :second_contact
      Date :meeting_on
      Date :added_on
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      constraint(:valid_status, status: statuses)
      constraint(:name_present) { char_length(trim(name)) > 0 }
      index :account_id
      index [:account_id, :legacy_id], unique: true
    end
  end

  down do
    drop_table :application_events, :applications, :referrals
  end
end
