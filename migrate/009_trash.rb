# Trash: deleting an application or referral sets deleted_at instead of removing the row. It can be
# restored for 30 days, then it's removed for good. Every list and lookup skips trashed rows.
Sequel.migration do
  change do
    %i[applications referrals].each do |table|
      alter_table(table) do
        add_column :deleted_at, DateTime
        add_index %i[account_id deleted_at]
      end
    end
  end
end
