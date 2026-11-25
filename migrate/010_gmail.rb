# Gmail scan. A script in the user's own Google account searches their mail and posts likely job
# emails here with a token; the app sorts and matches them and keeps only a suggestion to review.
# - gmail_tokens: the token's SHA-256 digest (the token itself is shown once and never stored)
# - email_matches: one suggestion per email. Sender, subject, the deciding sentence and the Gmail
#   message id are encrypted; msg_key (message id, encrypted and searchable) stops duplicates.
#   The email body is never stored.
Sequel.migration do
  change do
    create_table(:gmail_tokens) do
      foreign_key :account_id, :accounts, type: :Bignum, primary_key: true, on_delete: :cascade
      String :digest, null: false, unique: true
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :last_used_at
    end

    create_table(:email_matches) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade, index: true
      foreign_key :application_id, :applications, type: :Bignum, on_delete: :set_null
      String :msg_key, text: true, null: false   # encrypted, searchable
      String :sender, text: true, null: false    # encrypted
      String :subject, text: true, null: false   # encrypted
      String :sentence, text: true, null: false  # encrypted
      String :candidates, null: false, default: "" # application ids to pick from, comma-separated
      String :category, null: false
      Date :email_on
      String :status, null: false, default: "pending"
      constraint(:valid_category, category: %w[rejected moving_on])
      constraint(:valid_status, status: %w[pending approved dismissed])
    end
  end
end
