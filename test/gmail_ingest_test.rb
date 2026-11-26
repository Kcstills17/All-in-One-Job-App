# The Gmail script's endpoint: token-only access, emails sorted into suggestions, nothing else kept.
require_relative "helper"
require "rack/test"
require "bcrypt"

class GmailIngestTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app

  def setup
    reset_db!
    @me = account("me@example.com")
    @other = account("other@example.com")
    @acme = Application.create(account_id: @me, company: "Acme", title: "Support Engineer", applied_on: Date.new(2026, 3, 1))
    @acme.add_event(stage: "Applied", on: Date.new(2026, 3, 1), note: "")
    2.times { |i| Application.create(account_id: @me, company: "Cribl", title: ["Streaming Engineer", "Metrics Engineer"][i], applied_on: Date.new(2026, 2, 1)).add_event(stage: "Applied", note: "") }
    Application.create(account_id: @me, company: "Trashed Co", deleted_at: Time.now).add_event(stage: "Applied", note: "")
    @token = "tok_#{SecureRandom.hex(8)}"
    GmailToken.create(account_id: @me, digest: GmailToken.digest(@token))
  end

  def account(email)
    id = DB[:accounts].insert(email: email, status_id: 2)
    DB[:account_password_hashes].insert(id: id, password_hash: BCrypt::Password.create("correct horse battery", cost: 4))
    id
  end

  def ingest(emails, token: @token, mailbox: nil)
    header "Authorization", token && "Bearer #{token}"
    post "/gmail/ingest", { emails: emails, mailbox: mailbox }.compact.to_json, "CONTENT_TYPE" => "application/json"
    [last_response.status, (JSON.parse(last_response.body) rescue nil)]
  end

  def mail(id, from:, subject:, body:, date: "2026-03-10T15:00:00Z") = { id:, from:, subject:, body:, date: }

  REJECT = "Thank you for applying. Unfortunately, we have decided to move forward with other candidates. Best of luck."

  def test_unknown_or_missing_token_gets_nothing
    assert_equal 401, ingest([], token: "nope").first
    assert_equal 401, ingest([], token: nil).first
    assert_equal 422, (header("Authorization", "Bearer #{@token}"); post("/gmail/ingest", "{}", "CONTENT_TYPE" => "application/json"); last_response.status)
    assert_equal 0, EmailMatch.count
  end

  def test_emails_become_suggestions_and_only_the_sentence_is_kept
    st, counts = ingest([
      mail("m1", from: "Acme Recruiting <no-reply@greenhouse.io>", subject: "Your application to Acme", body: REJECT),
      mail("m2", from: "\"Cribl Talent\" <talent@cribl.io>", subject: "Next steps", body: "We'd love to schedule a call."),
      mail("m3", from: "Jobs <jobs@board.example>", subject: "Thanks for applying!", body: "We've received your application."),
      mail("m4", from: "News <news@example.com>", subject: "Weekly digest", body: "Ten tips."),
      mail("m5", from: "Trashed Co Hiring <hr@trashed.example>", subject: "Your application", body: REJECT)
    ])
    assert_equal 200, st
    assert_equal({ "matched" => 1, "needs_a_match" => 2, "confirmation" => 1, "not_job" => 1 }, counts)
    acme = EmailMatch.first(application_id: @acme.id)
    assert_equal ["rejected", "pending", "2026-03-10", "Acme Recruiting · no-reply@greenhouse.io", "Unfortunately, we have decided to move forward with other candidates."],
                 [acme.category, acme.status, acme.email_on.to_s, acme.sender, acme.sentence]
    assert_equal "https://mail.google.com/mail/u/0/#all/m1", acme.gmail_url
    assert_equal "https://mail.google.com/mail/u/kcstills17@gmail.com/#all/m1", acme.gmail_url("kcstills17@gmail.com")
    assert_equal "https://mail.google.com/mail/u/0/#all/m1", acme.gmail_url("not/an address"), "only a plain address goes in the link"
    cribl = EmailMatch.all.find { _1.sender.start_with?("Cribl") }
    assert_equal ["moving_on", nil, 2], [cribl.category, cribl.application_id, cribl.candidates.split(",").size], "two Cribl applications: you pick"
    trashed = EmailMatch.all.find { _1.sender.start_with?("Trashed") }
    assert_equal [nil, ""], [trashed.application_id, trashed.candidates], "trashed applications aren't matched"
    stored = DB[:email_matches].all.map(&:values).flatten.join
    refute_includes stored, "Unfortunately", "encrypted"
    refute_includes stored, "Best of luck", "the body isn't stored"
    refute_nil GmailToken[@me].last_used_at
  end

  def test_the_script_says_which_mailbox_it_reads
    ingest([], mailbox: "kcstills17@gmail.com")
    assert_equal "kcstills17@gmail.com", GmailToken[@me].mailbox
    refute_includes DB[:gmail_tokens].first.values.join, "kcstills17", "stored encrypted"
    ingest([])
    assert_equal "kcstills17@gmail.com", GmailToken[@me].mailbox, "kept when a request doesn't say"
  end

  def test_repeats_are_ignored_and_accounts_are_separate
    ingest([mail("m1", from: "Acme <jobs@acme.com>", subject: "Update", body: REJECT)])
    _, counts = ingest([mail("m1", from: "Acme <jobs@acme.com>", subject: "Update", body: REJECT)])
    assert_equal({ "skipped" => 1 }, counts)
    other_token = "tok_other"
    GmailToken.create(account_id: @other, digest: GmailToken.digest(other_token))
    _, counts = ingest([mail("m1", from: "Acme <jobs@acme.com>", subject: "Update", body: REJECT)], token: other_token)
    assert_equal({ "needs_a_match" => 1 }, counts, "the other account has no Acme application, and its own copy of m1")
    assert_equal [1, 1], [EmailMatch.where(account_id: @me).count, EmailMatch.where(account_id: @other).count]
    assert_equal 422, ingest(Array.new(101) { |i| mail("x#{i}", from: "a@b.c", subject: "", body: "") }).first
  end

  def test_account_page_connects_and_disconnects
    GmailToken.where(account_id: @me).delete
    get "/login"
    post "/login", "login" => "me@example.com", "password" => "correct horse battery", "_csrf" => last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    get "/account"
    assert_includes last_response.body, "Connect Gmail"
    post "/account/gmail-token", "_csrf" => last_response.body[%r{action="/account/gmail-token">\s*<input type="hidden" name="_csrf" value="([^"]+)"}, 1]
    token = last_response.body[/readonly value="([^"]+)"/, 1]
    refute_nil token
    assert_equal GmailToken.digest(token), GmailToken[@me].digest, "only the digest is stored"
    assert_equal 200, ingest([], token: token).first
    get "/account"
    refute_includes last_response.body, token, "shown only once"
    post "/account/gmail-revoke", "_csrf" => last_response.body[%r{action="/account/gmail-revoke">\s*<input type="hidden" name="_csrf" value="([^"]+)"}, 1]
    assert_equal 401, ingest([], token: token).first
  end
end
