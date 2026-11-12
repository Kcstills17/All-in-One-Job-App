# Workable auto-fill, from canned responses (no network).
require_relative "helper"

class WorkableTest < Minitest::Test
  PAGE = "<html><head><title>Junior Forward Deployed Engineer - Bask Health</title></head></html>"
  JOB = { title: "Junior Forward Deployed Engineer", remote: true,
          location: { city: "", region: nil, country: "United States" },
          description: "<p>Build things.</p>", requirements: "<p>Ruby</p>", benefits: "<p>Pay: $90,000 - $110,000 per year</p>" }.to_json

  def setup
    @get = Fetcher.method(:get)
    Fetcher.define_singleton_method(:get) do |url, *|
      { "https://apply.workable.com/j/7E3C450C5D" => PAGE,
        "https://apply.workable.com/api/v2/accounts/bask-health-1/jobs/7E3C450C5D" => JOB }.fetch(url)
    end
  end

  def teardown = Fetcher.define_singleton_method(:get, @get)

  def test_full_link
    assert_equal({ company: "Bask Health", title: "Junior Forward Deployed Engineer",
                   location: "Remote (United States)", pay: "$90,000 - $110,000 per year" },
                 Fetcher.fetch("https://apply.workable.com/bask-health-1/j/7E3C450C5D/"))
  end

  def test_short_link_uses_the_page_title
    assert_equal({ company: "Bask Health", title: "Junior Forward Deployed Engineer" },
                 Fetcher.fetch("https://apply.workable.com/j/7E3C450C5D"))
  end
end
