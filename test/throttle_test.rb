# Per-IP rate limits on sign-up, login, emails and link fetching.
require_relative "helper"
require "rack/test"

class ThrottleTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app
  def setup = reset_db!

  def sign_up(email)
    get "/create-account"
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    post "/create-account", "login" => email, "password" => "correct horse battery",
                            "password-confirm" => "correct horse battery", "_csrf" => token
  end

  def test_sign_ups_are_rate_limited_per_address
    5.times { |i| sign_up("person#{i}@example.com") }
    assert_equal 5, DB[:accounts].count
    sign_up("sixth@example.com")
    assert_equal 429, last_response.status
    assert_equal 5, DB[:accounts].count
    env "REMOTE_ADDR", "203.0.113.9"
    sign_up("other-ip@example.com")
    assert_equal 6, DB[:accounts].count, "a different address isn't affected"
  end

  def test_windows_reset
    rule = ["POST", "/create-account"]
    5.times { assert Throttle.allow?(rule, "198.51.100.1", 0) }
    refute Throttle.allow?(rule, "198.51.100.1", 0)
    assert Throttle.allow?(rule, "198.51.100.1", 3600), "next hour starts fresh"
  end
end
