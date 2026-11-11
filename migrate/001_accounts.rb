# Rodauth's account tables, for the features enabled in app.rb. Runs as the app's database user.
Sequel.migration do
  up do
    extension :date_arithmetic
    deadline = ->(days) { { null: false, default: Sequel.date_add(Sequel::CURRENT_TIMESTAMP, days: days) } }

    create_table(:account_statuses) do
      Integer :id, primary_key: true
      String :name, null: false, unique: true
    end
    from(:account_statuses).import([:id, :name], [[1, "Unverified"], [2, "Verified"], [3, "Closed"]])

    create_table(:accounts) do
      primary_key :id, type: :Bignum
      foreign_key :status_id, :account_statuses, null: false, default: 1
      citext :email, null: false
      constraint :valid_email, email: /^[^,;@ \r\n]+@[^,@; \r\n]+\.[^,@; \r\n]+$/
      # Closed accounts free up their email for a new sign-up.
      index :email, unique: true, where: { status_id: [1, 2] }
    end

    create_table(:account_verification_keys) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :requested_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :email_last_sent, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    create_table(:account_password_reset_keys) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :deadline, deadline[1]
      DateTime :email_last_sent, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    create_table(:account_login_failures) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      Integer :number, null: false, default: 1
    end

    create_table(:account_lockouts) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :deadline, deadline[1]
      DateTime :email_last_sent
    end

    # The password user's hash table points at accounts.
    run "GRANT REFERENCES ON accounts TO #{get(Sequel.lit('current_user'))}_password"
  end

  down do
    drop_table :account_lockouts, :account_login_failures, :account_password_reset_keys,
               :account_verification_keys, :accounts, :account_statuses
  end
end
