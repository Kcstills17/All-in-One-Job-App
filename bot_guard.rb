require "net/http"
require "json"
require_relative "config"

# Daily cap on emails the app sends. It stays under the email provider's free limit (Resend: 100/day),
# so a flood of fake sign-ups can't get the account suspended or block real users' emails.
module EmailCap
  class Reached < StandardError
    def message = "We've hit today's limit for sign-up and password emails. Please try again tomorrow."
  end

  def self.limit = Integer(ENV.fetch("EMAIL_DAILY_CAP", "90"))

  # Counts one email and raises Reached once today's count is over the cap.
  def self.take!
    sent = DB[:daily_email_counts].returning(:sent)
      .insert_conflict(target: :day, update: { sent: Sequel[:daily_email_counts][:sent] + 1 })
      .insert(day: Date.today, sent: 1).first[:sent]
    raise Reached if sent > limit
  end

  def self.reached? = DB[:daily_email_counts].where(day: Date.today).get(:sent).to_i >= limit
end

# Cloudflare Turnstile on the sign-up form. On only when both keys are set (production); off locally.
module Turnstile
  SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js"

  def self.enabled? = !ENV["TURNSTILE_SITE_KEY"].to_s.empty? && !ENV["TURNSTILE_SECRET_KEY"].to_s.empty?
  def self.site_key = ENV.fetch("TURNSTILE_SITE_KEY")

  # Asks Cloudflare whether the browser passed the check. Any failure counts as not passed.
  def self.passed?(token, ip)
    return false if token.to_s.empty?
    res = Net::HTTP.post_form(URI("https://challenges.cloudflare.com/turnstile/v0/siteverify"),
                              "secret" => ENV.fetch("TURNSTILE_SECRET_KEY"), "response" => token, "remoteip" => ip.to_s)
    JSON.parse(res.body)["success"] == true
  rescue StandardError
    false
  end
end
