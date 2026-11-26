# The Gmail address the script reads (encrypted), so "Open in Gmail" opens that mailbox even when the
# browser is signed in to several Google accounts.
Sequel.migration do
  change do
    add_column :gmail_tokens, :mailbox, String, text: true
  end
end
