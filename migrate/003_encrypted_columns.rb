# Encrypted values are long base64 strings, so the text columns lose their 255-character limit,
# and lose their '' defaults so plain text can never slip in next to encrypted values.
Sequel.migration do
  encrypted = {
    applications: %i[company title location pay url notes],
    application_events: %i[note],
    referrals: %i[name contact company role url notes]
  }

  up do
    alter_table(:referrals) { drop_constraint :name_present } # checked in the app; ciphertext is never blank
    encrypted.each do |table, columns|
      alter_table(table) do
        columns.each do |column|
          set_column_type column, :text
          set_column_default column, nil
        end
      end
    end
  end

  down do
    encrypted.each do |table, columns|
      alter_table(table) { columns.each { set_column_default _1, "" } }
    end
  end
end
