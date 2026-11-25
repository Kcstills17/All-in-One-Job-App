# Resume versions. Each has the date you started sending it, so an application without a chosen
# version uses whichever one was current on its applied date. resume_id is set only to override that.
Sequel.migration do
  change do
    create_table(:resumes) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade, index: true
      String :name, text: true, null: false  # encrypted
      String :url, text: true, null: false   # encrypted
      String :notes, text: true, null: false # encrypted
      Date :started_on, null: false
    end
    alter_table(:applications) do
      add_foreign_key :resume_id, :resumes, type: :Bignum, on_delete: :set_null
    end
  end
end
