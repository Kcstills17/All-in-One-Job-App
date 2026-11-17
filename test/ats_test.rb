# Auto-fill for the other common ATS boards, from canned responses (no network).
require_relative "helper"

class AtsTest < Minitest::Test
  LD = ->(posting) { %(<html><head><title>Careers</title><script type="application/ld+json">#{posting.to_json}</script></head></html>) }
  PAGES = {
    "https://api.smartrecruiters.com/v1/companies/AECOM2/postings/744000146474898" =>
      { name: "Structural Engineer", company: { name: "AECOM" }, location: { city: "Indianapolis", region: "IN", country: "us", remote: false },
        compensation: { min: 103979, max: 129000, currency: "USD", period: "YEARLY" } }.to_json,
    "https://tellent.recruitee.com/api/offers/campaign-manager-france" =>
      { offer: { title: "Campaign Manager - France", company_name: "Tellent", location: "Paris, France", remote: false,
                 salary: { min: "53000", max: "65000", period: "year", currency: "EUR" } } }.to_json,
    "https://acme.breezy.hr/json" =>
      [{ id: "98323abf2296", friendly_id: "98323abf2296-engineer", name: "Engineer", company: { name: "Acme" },
         location: { name: "Remote, US", is_remote: true }, salary: "$90K - $110K / year" }].to_json,
    "https://career.example.com/jobs/1" =>
      LD[{ "@context" => "https://schema.org", "@type" => "JobPosting", title: "Account Executive", hiringOrganization: { name: "Example Co" },
           jobLocation: [{ address: { addressLocality: "Chicago", addressRegion: "IL", addressCountry: { name: "US" } } }],
           baseSalary: { currency: "USD", value: { minValue: 80000, maxValue: 100000, unitText: "YEAR" } } }],
    "https://jobs.example.com/job/2" =>
      LD[{ "@type" => "JobPosting", title: "DVT Manager", hiringOrganization: "Enphase Energy", jobLocationType: "TELECOMMUTE",
           jobLocation: [{ address: { addressCountry: "New Zealand" } }],
           baseSalary: { currency: "", value: { minValue: "", maxValue: "", unitText: "" } }, description: "<p>Pay $40/hr</p>" }],
    "https://peregrine.applytojob.com/apply/ppXpgq8Ykg/Software-Engineer" =>
      "<title>Software Engineer - Peregrine Team - Career Page</title>"
  }

  def setup
    @get = Fetcher.method(:get)
    Fetcher.define_singleton_method(:get) { |url, *| PAGES.fetch(url) }
  end

  def teardown = Fetcher.define_singleton_method(:get, @get)

  def assert_fills(expected, url) = assert_equal(expected, Fetcher.fetch(url))

  def test_smartrecruiters
    assert_fills({ company: "AECOM", title: "Structural Engineer", location: "Indianapolis, IN, US", pay: "$103,979 - $129,000 per year" },
                 "https://jobs.smartrecruiters.com/AECOM2/744000146474898-structural-engineer")
  end

  def test_recruitee
    assert_fills({ company: "Tellent", title: "Campaign Manager - France", location: "Paris, France", pay: "EUR 53,000 - EUR 65,000 per year" },
                 "https://tellent.recruitee.com/o/campaign-manager-france")
  end

  def test_breezy
    assert_fills({ company: "Acme", title: "Engineer", location: "Remote (Remote, US)", pay: "$90K - $110K / year" },
                 "https://acme.breezy.hr/p/98323abf2296-engineer")
  end

  def test_json_ld_job_posting
    assert_fills({ company: "Example Co", title: "Account Executive", location: "Chicago, IL, US", pay: "$80,000 - $100,000 per year" },
                 "https://career.example.com/jobs/1")
  end

  def test_json_ld_with_string_org_and_blank_salary
    assert_fills({ company: "Enphase Energy", title: "DVT Manager", location: "Remote (New Zealand)", pay: "$40/hr" },
                 "https://jobs.example.com/job/2")
  end

  def test_jazzhr_page_title
    assert_fills({ title: "Software Engineer", company: "Peregrine Team" },
                 "https://peregrine.applytojob.com/apply/ppXpgq8Ykg/Software-Engineer")
  end
end
