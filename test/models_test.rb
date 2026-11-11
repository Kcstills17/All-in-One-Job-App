# What users type is stored encrypted, reads back as typed, and links stay findable for duplicates.
require_relative "helper"

class ModelsTest < Minitest::Test
  def setup
    reset_db!
    @account = DB[:accounts].insert(email: "me@example.com", status_id: 2)
  end

  def test_application_fields_are_encrypted_at_rest
    app = Application.create(account_id: @account, company: "Stripe", title: "Support Engineer",
                             url: "https://stripe.com/jobs/1", notes: "met Kana")
    app.add_event(stage: "Applied", note: "via referral")
    raw = DB[:applications].first(id: app.id)
    %i[company title url notes].each { refute_includes raw[_1], app.public_send(_1).split.first, "#{_1} stored in plain text" }
    refute_equal "via referral", DB[:application_events].first[:note]
    assert_equal ["Stripe", "", "via referral"], [app.refresh.company, app.pay, app.history.first.note]
  end

  def test_links_can_be_matched_without_decrypting
    Application.create(account_id: @account, url: "https://stripe.com/jobs/1")
    assert_equal 1, Application.with_encrypted_value(:url, "https://stripe.com/jobs/1").count
    assert_equal 0, Application.with_encrypted_value(:url, "https://stripe.com/jobs/2").count
  end

  def test_referral_round_trip
    ref = Referral.create(account_id: @account, name: "Kana", notes: "coffee chat")
    refute_equal "Kana", DB[:referrals].first[:name]
    assert_equal({ name: "Kana", notes: "coffee chat", contact: "", status: "To Contact" },
                 ref.refresh.to_api.slice(:name, :notes, :contact, :status))
  end
end
