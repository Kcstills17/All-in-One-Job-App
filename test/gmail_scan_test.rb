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


# Cases taken from a first real scan, where the earlier rules went wrong.
class GmailRealWorldTest < Minitest::Test
  def email(subject: "", text: "", from_name: "", from_address: "jobs@example.com", date: Date.new(2026, 10, 1))
    { subject:, text:, from_name:, from_address:, date: }
  end

  def cat(**kw) = GmailScan.classify(email(**kw))&.fetch(:category)

  def test_receipts_that_mention_next_steps_are_confirmations
    assert_equal :confirmation, cat(subject: "Thank you for applying to Steno!", text: "If your profile is a good fit for the role, we'll be in touch shortly about next steps.")
    assert_equal :confirmation, cat(subject: "Your first step with Auctus", text: "We will send an email with next steps once we review your application.")
    assert_equal :confirmation, cat(subject: "Zane, your application was sent to Celestron, LLC.", text: "Your application was sent to Celestron. Next steps: people also viewed Snowflake.")
  end

  def test_clear_invitations_are_moving_on_even_after_a_thank_you
    assert_equal :moving_on, cat(subject: "Thanks for applying", text: "We'd like to schedule a call with you this week.")
    assert_equal :moving_on, cat(subject: "Re: Helpt opportunity", text: "As a next step in our hiring process, we'd love for you to complete a short exercise.")
    assert_equal :moving_on, cat(subject: "Checking your availability for a phone interview", text: "")
  end

  def test_next_steps_outside_a_job_email_is_ignored
    assert_nil cat(subject: "Swappa Listing (LALP58577)", text: "*Next steps:* 1. Ship your phone.")
    assert_nil cat(subject: "Earn rewards and affiliate credit", text: "Useful next steps: short paths, clear wins.")
  end

  def test_more_rejection_wording
    assert_equal :rejected, cat(subject: "Counter Sales Associate has been filled.", text: "We regret to inform you that we have filled or closed this position.")
    assert_equal :rejected, cat(text: "Unfortunately we've reviewed your application and have decided we won't move forward.")
  end

  APPS = [{ id: 1, company: "Snowflake", title: "Solutions Engineer", applied_on: Date.new(2026, 2, 2) },
          { id: 2, company: "PoolCorp", title: "Counter Sales Associate", applied_on: Date.new(2026, 9, 1) },
          { id: 3, company: "RealPage", title: "Help Desk Coordinator", applied_on: Date.new(2026, 9, 1) }].freeze

  def test_company_names_in_the_body_dont_match
    m = GmailScan.match(email(from_name: "LinkedIn", from_address: "jobs-noreply@linkedin.com", subject: "Your application was sent to Celestron",
                              text: "People also viewed: Snowflake Solutions Engineer"), APPS)
    assert_nil m[:app]
  end

  def test_job_site_senders_match_by_the_name_before_the_at
    assert_equal 2, GmailScan.match(email(from_address: "poolcorp@myworkday.com", subject: "Position update"), APPS)[:app][:id]
    assert_equal 3, GmailScan.match(email(from_name: "Do Not Reply", from_address: "realpagepms+email+4e2q@icims.com", subject: "Thank You"), APPS)[:app][:id]
    assert_nil GmailScan.match(email(from_address: "no-reply@myworkday.com", subject: "Update"), APPS)[:app]
  end
end

class GmailSentenceTest < Minitest::Test
  def test_the_sentence_comes_from_the_body_when_it_has_the_phrase
    r = GmailScan.classify({ subject: "Next steps", text: "Hi Zane. Here are the next steps for your interview. Thanks!" })
    assert_equal "Here are the next steps for your interview.", r[:sentence]
  end
end
