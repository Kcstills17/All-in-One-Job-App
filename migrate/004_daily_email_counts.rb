# One row per day counting emails the app sent, so a bot can't use sign-up to burn the email budget.
Sequel.migration do
  change do
    create_table(:daily_email_counts) do
      Date :day, primary_key: true
      Integer :sent, null: false, default: 0
    end
  end
end
