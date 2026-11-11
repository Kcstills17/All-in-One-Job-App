# The dashboard page: behind login, loads only its own files, and nothing in it runs inline.
require_relative "helper"
require "rack/test"

class PageTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app
  PUBLIC = File.expand_path("../public", __dir__)

  def test_dashboard_needs_login
    get "/"
    assert_equal "/login", URI(last_response.location).path
  end

  def test_assets_are_served_with_a_strict_policy
    %w[/app.js /app.css /vendor/d3.min.js /vendor/d3-sankey.min.js].each do |path|
      get path
      assert_equal 200, last_response.status, path
    end
    get "/login" # rendered pages (the dashboard included) carry the policy; browsers apply it to what they load
    policy = last_response.headers["content-security-policy"]
    assert_match "script-src 'self'", policy
    refute_match(/script-src[^;]*(unsafe-inline|http)/, policy)
  end

  # The policy blocks inline scripts and handlers, so one slipping in would silently break the page.
  def test_page_has_no_inline_scripts_or_handlers
    html = File.read(File.join(PUBLIC, "index.html"))
    assert_empty html.scan(/<script(?![^>]*\bsrc=)[^>]*>/), "inline <script>"
    files = [html, File.read(File.join(PUBLIC, "app.js"))]
    assert_empty files.flat_map { _1.scan(/<[a-z][^>]*\son[a-z]+=/i) }, "inline on*= handler"
    assert_empty html.scan(%r{src="https?://}), "script from another site"
  end
end
