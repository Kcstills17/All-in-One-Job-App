# Interview prep that outlives one application:
# - companies: notes shared by every application to the same company (matched by name, ignoring case)
# - applications.prep: role notes and prep for one application
# - prep_notes: a reusable prep library (kind "note") and the day-of checklist (kind "checklist", one per account)
# - application_events.checked: which checklist items are ticked for that interview step
# Text columns hold ciphertext (see 003), so they're text with no defaults.
Sequel.migration do
  change do
    create_table(:companies) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade, index: true
      String :key, text: true, null: false # lowercased name, encrypted and searchable
      String :name, text: true, null: false
      String :notes, text: true, null: false
    end

    create_table(:prep_notes) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade, index: true
      String :kind, null: false, default: "note"
      String :title, text: true, null: false
      String :body, text: true, null: false
      constraint(:valid_kind, kind: %w[note checklist])
    end

    add_column :applications, :prep, String, text: true
    add_column :application_events, :checked, String, text: true
  end
end
