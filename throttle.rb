# Per-IP rate limits on the requests bots abuse: sign-up, login, emails, and anything that fetches a link.
# ponytail: counts live in this process's memory with fixed windows, which is enough for one server.
# Move the counts to Postgres or Redis if the app ever runs on more than one machine.
class Throttle
  RULES = {
    ["POST", "/create-account"] => [5, 3600],
    ["POST", "/login"] => [20, 600],
    ["POST", "/reset-password-request"] => [5, 3600],
    ["POST", "/verify-account-resend"] => [5, 3600],
    ["POST", "/unlock-account-request"] => [5, 3600],
    ["POST", "/api/jobs"] => [120, 3600], # auto-fill fetches the link
    ["POST", "/api/referrals"] => [120, 3600],
    ["GET", "/add"] => [120, 3600],
    ["POST", "/add"] => [120, 3600],
    ["POST", "/gmail/ingest"] => [200, 3600] # the Gmail script sends batches of 100
  }.freeze

  @counts = {}
  @lock = Mutex.new
  class << self
    def reset! = @lock.synchronize { @counts.clear }

    # true while this ip is within the rule's limit for the current window
    def allow?(rule, ip, now = Time.now.to_i)
      limit, period = RULES.fetch(rule)
      window = now / period
      @lock.synchronize do
        @counts.delete_if { |(r, _, w), _| w < now / RULES[r][1] } if @counts.size > 10_000
        (@counts[[rule, ip, window]] = @counts.fetch([rule, ip, window], 0) + 1) <= limit
      end
    end
  end

  def initialize(app) = @app = app

  def call(env)
    rule = [env["REQUEST_METHOD"], env["PATH_INFO"]]
    return @app.call(env) unless RULES.key?(rule)
    # Behind a host's proxy the socket address is the proxy's, so CLIENT_IP_HEADER names the header the
    # host sets to the real client (Render: True-Client-IP; Fly.io: Fly-Client-IP). Locally it's unset.
    header = ENV["CLIENT_IP_HEADER"]
    ip = (header && env["HTTP_#{header.upcase.tr('-', '_')}"]) || env["REMOTE_ADDR"]
    return @app.call(env) if self.class.allow?(rule, ip)
    [429, { "content-type" => "text/plain", "retry-after" => RULES[rule][1].to_s }, ["Too many requests. Try again later.\n"]]
  end
end
