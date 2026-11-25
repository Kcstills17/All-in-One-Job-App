# Sorting and matching job emails, with made-up emails (no network).
require "minitest/autorun"
require "date"
require "set"
require_relative "../gmail_scan"

class GmailScanTest < Minitest::Test
  def email(subject: "", text: "", from_name: "", from_address: "jobs@example.com", date: Date.new(2026, 3, 10))
    { subject:, text:, from_name:, from_address:, date: }
  end

  def test_rejections_win_over_thank_you
    r = GmailScan.classify(email(subject: "Your application to Acme",
      text: "Thank you for applying. Unfortunately, we have decided to move forward with other candidates whose experience fits more closely. Best of luck!"))
    assert_equal :rejected, r[:category]
    assert_equal "Unfortunately, we have decided to move forward with other candidates whose experience fits more closely.", r[:sentence]
  end

  def test_moving_on_and_confirmation_and_unrelated
    assert_equal :moving_on, GmailScan.classify(email(text: "We'd love to schedule a call. Here's my calendly.com/sam link."))[:category]
    assert_equal :confirmation, GmailScan.classify(email(subject: "Thanks for applying to Acme!", text: "We've received your application."))[:category]
    assert_nil GmailScan.classify(email(subject: "Weekly newsletter", text: "Ten tips for your garden."))
  end

  APPS = [
    { id: 1, company: "Acme, Inc.", title: "Support Engineer", applied_on: Date.new(2026, 3, 1) },
    { id: 2, company: "Cribl", title: "Software Engineer, Streaming Integrations", applied_on: Date.new(2026, 2, 1) },
    { id: 3, company: "Cribl", title: "Senior Software Engineer (metrics and alerts)", applied_on: Date.new(2026, 2, 5) },
    { id: 4, company: "Scale", title: "Forward Deployed Engineer", applied_on: Date.new(2026, 2, 1) },
    { id: 5, company: "Later Co", title: "Engineer", applied_on: Date.new(2026, 4, 1) },
  ].freeze

  def test_match_by_sender_name_subject_or_domain
    assert_equal 1, GmailScan.match(email(from_name: "Acme Recruiting", from_address: "no-reply@greenhouse.io"), APPS)[:app][:id]
    assert_equal 1, GmailScan.match(email(from_address: "talent@acme.com"), APPS)[:app][:id]
    assert_equal 1, GmailScan.match(email(from_address: "talent@careers.acme.com"), APPS)[:app][:id]
    assert_equal 1, GmailScan.match(email(subject: "Update on your Acme application"), APPS)[:app][:id]
  end

  def test_ats_domains_and_short_words_in_the_body_dont_match
    assert_nil GmailScan.match(email(from_address: "no-reply@lever.co", text: "We build at scale."), APPS)[:app]
    assert_equal 4, GmailScan.match(email(from_name: "Scale AI Recruiting"), APPS)[:app][:id], "\"Scale AI\" is Scale"
  end

  def test_role_title_picks_between_applications_to_one_company
    m = GmailScan.match(email(from_name: "Cribl", subject: "Software Engineer, Streaming Integrations: an update"), APPS)
    assert_equal [2, :role], [m[:app][:id], m[:confidence]]
    unclear = GmailScan.match(email(from_name: "Cribl", subject: "An update on your application"), APPS)
    assert_nil unclear[:app]
    assert_equal [2, 3], unclear[:candidates].map { _1[:id] }
  end

  def test_only_applications_sent_before_the_email
    assert_nil GmailScan.match(email(from_name: "Later Co", date: Date.new(2026, 3, 10)), APPS)[:app]
    assert_equal 5, GmailScan.match(email(from_name: "Later Co", date: Date.new(2026, 4, 2)), APPS)[:app][:id]
  end
end


class GmailSentenceTest < Minitest::Test
  def test_the_sentence_comes_from_the_body_when_it_has_the_phrase
    r = GmailScan.classify({ subject: "Next steps", text: "Hi Zane. Here are the next steps for your interview. Thanks!" })
    assert_equal "Here are the next steps for your interview.", r[:sentence]
  end
end
