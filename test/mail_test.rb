# The development mailer prints emails instead of sending them. A crash here rolls back sign-ups.
require_relative "helper"

class MailTest < Minitest::Test
  def test_console_mail_prints_the_link_without_raising
    mail = Mail.new(to: "a@example.com", from: "app@example.com", subject: "Verify Account",
                    body: "go to http://localhost:4570/verify-account?key=1_abc")
    mail.delivery_method ConsoleMail
    out, = capture_io { mail.deliver! }
    assert_includes out, "Email to a@example.com: Verify Account"
    assert_includes out, "verify-account?key=1_abc"
  end
end
