# Auto-fill must never fetch the server's own machine, private networks or cloud metadata. Runs offline.
require_relative "helper"

class FetcherGuardTest < Minitest::Test
  BLOCKED = %w[
    http://127.0.0.1/ http://localhost:4570/api/jobs http://localhost/ http://0.0.0.0/
    http://10.1.2.3/ http://172.20.0.1/ http://192.168.1.1/ http://100.64.0.1/
    http://169.254.169.254/latest/meta-data/ http://[::1]/ http://[fd00::1]/ http://[fe80::1]/
    http://[::ffff:127.0.0.1]/ http://[::ffff:169.254.169.254]/ http://2130706433/
    http://example.com:22/ http://example.com:6379/ ftp://example.com/ file:///etc/passwd gopher://127.0.0.1/
  ].freeze

  def test_blocks_internal_and_odd_targets
    BLOCKED.each do |url|
      assert_raises(Fetcher::Blocked, url) { Fetcher.get(url) }
    end
  end

  def test_allows_a_public_address
    assert_equal "93.184.215.14", Fetcher.safe_address!(URI("https://93.184.215.14/jobs/1"))
    assert_equal "1.1.1.1", Fetcher.safe_address!(URI("http://1.1.1.1/"))
  end

  def test_blocked_links_just_skip_auto_fill
    assert_equal({}, Fetcher.method(:fetch_raw).call("http://169.254.169.254/latest/meta-data/"))
  end
end
