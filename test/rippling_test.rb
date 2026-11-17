# Rippling auto-fill, from a canned response (no network).
require_relative "helper"

class RipplingTest < Minitest::Test
  JOB = { name: "Full Stack Software Engineer", companyName: "Empowerly", workLocations: ["Remote, US"],
          payRangeDetails: [{ currency: "USD", frequency: "YEAR", rangeStart: 125000.0, rangeEnd: 145000.0 }] }.to_json

  def setup
    @get = Fetcher.method(:get)
    Fetcher.define_singleton_method(:get) do |url, *|
      { "https://api.rippling.com/platform/api/ats/v1/board/empowerly/jobs/bf9b3e41-e94a-409e-8dc6-620f2cc0171b" => JOB }.fetch(url)
    end
  end

  def teardown = Fetcher.define_singleton_method(:get, @get)

  def test_job_link_with_tracking_params
    assert_equal({ company: "Empowerly", title: "Full Stack Software Engineer", location: "Remote, US",
                   pay: "$125,000 - $145,000 per year" },
                 Fetcher.fetch("https://ats.rippling.com/empowerly/jobs/bf9b3e41-e94a-409e-8dc6-620f2cc0171b?utm_source=Simplify&ref=Simplify"))
  end
end
