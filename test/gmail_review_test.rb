# Reviewing Gmail suggestions: approve adds a dated step to your own application, dismiss hides it,
# approve-all handles every matched one, and nothing touches another account.
require_relative "helper"
require "rack/test"
require "bcrypt"

class GmailReviewTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.app

  def setup
    reset_db!
    @me = account("me@example.com")
    @other = account("other@example.com")
    @acme = job(@me, "Acme", ["Applied"])
    @beta = job(@me, "Beta", ["Applied", "Recruiter Screen"])
    @gone = job(@me, "Gone", ["Applied", "Rejected"])
    @theirs = job(@other, "Theirs", ["Applied"])
    GmailToken.create(account_id: @me, digest: GmailToken.digest("t"), mailbox: "zanedev28@gmail.com")
    @rej = suggestion(@acme, "rejected", "We went with other candidates.")
    @mov = suggestion(@beta, "moving_on", "We'd like to move you forward to the next round.")
    @loose = suggestion(nil, "rejected", "The role has been filled.", candidates: "#{@acme.id},#{@gone.id}")
  end

  def account(email)
    id = DB[:accounts].insert(email: email, status_id: 2)
    DB[:account_password_hashes].insert(id: id, password_hash: BCrypt::Password.create("correct horse battery", cost: 4))
    id
  end

  def job(account_id, company, stages)
    Application.create(account_id: account_id, company: company, applied_on: Date.new(2026, 3, 1))
      .tap { |a| stages.each_with_index { |s, i| a.add_event(stage: s, on: Date.new(2026, 3, 1 + i), note: "") } }
  end

  def suggestion(job, category, sentence, candidates: "")
    EmailMatch.create(account_id: job&.account_id || @me, application_id: job&.id, category: category, sentence: sentence,
                      msg_key: "m#{rand(1e9)}", sender: "Recruiting · jobs@example.com", subject: "Update", email_on: Date.new(2026, 3, 20),
                      candidates: candidates)
  end

  def log_in(email)
    clear_cookies
    get "/login"
    post "/login", "login" => email, "password" => "correct horse battery", "_csrf" => last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    get "/api/session"
    @csrf = JSON.parse(last_response.body)["csrf"]
  end

  def api(verb, path, body = nil)
    custom_request(verb, path, body&.to_json || "", "CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => @csrf)
    [last_response.status, (JSON.parse(last_response.body) rescue nil)]
  end

  def test_list_approve_and_dismiss
    log_in("me@example.com")
    _, list = api("GET", "/api/gmail/matches")
    assert_equal 3, list.size
    assert_equal "https://mail.google.com/mail/u/zanedev28@gmail.com/#all/#{@rej.msg_key}", list.find { _1["id"] == @rej.id.to_s }["gmail_url"]

    _, res = api("POST", "/api/gmail/matches/#{@rej.id}/approve")
    step = res["job"]["history"].last
    assert_equal ["Rejected", "2026-03-20", "From Gmail: We went with other candidates."], step.values_at("stage", "on", "note")
    _, res = api("POST", "/api/gmail/matches/#{@mov.id}/approve")
    assert_equal "Hiring Manager", res["job"]["history"].last["stage"], "the stage after the current one"

    assert_equal 422, api("POST", "/api/gmail/matches/#{@loose.id}/approve").first, "unmatched needs a pick"
    _, res = api("POST", "/api/gmail/matches/#{@loose.id}/approve", { application_id: @gone.id, stage: "Rejected" })
    assert_equal 1, res["job"]["history"].count { _1["stage"] == "Rejected" }, "already rejected: no second step"
    assert_empty api("GET", "/api/gmail/matches")[1]
    assert_equal %w[approved approved approved], EmailMatch.order(:id).select_map(:status)
  end

  def test_dismiss_and_approve_all
    log_in("me@example.com")
    api("POST", "/api/gmail/matches/#{@mov.id}/dismiss")
    _, res = api("POST", "/api/gmail/matches/approve-all", { category: "rejected" })
    assert_equal 1, res["approved"], "only matched ones"
    assert_equal "Rejected", @acme.refresh.history.last.stage
    assert_equal "Recruiter Screen", @beta.refresh.history.last.stage, "dismissed: unchanged"
    assert_equal [@loose.id.to_s], api("GET", "/api/gmail/matches")[1].map { _1["id"] }
    assert_equal 422, api("POST", "/api/gmail/matches/approve-all", { category: "spam" }).first
  end

  def test_moving_on_after_a_rejection_suggests_the_next_real_stage
    log_in("me@example.com")
    m = suggestion(@gone, "moving_on", "Next round!")
    _, res = api("POST", "/api/gmail/matches/#{m.id}/approve")
    assert_equal "Recruiter Screen", res["job"]["history"].last["stage"]
  end

  def test_a_named_step_wins_when_it_is_further_along
    log_in("me@example.com")
    m = suggestion(@acme, "moving_on", "We'd like to schedule a technical interview.")
    _, res = api("POST", "/api/gmail/matches/#{m.id}/approve")
    assert_equal "Technical Interview", res["job"]["history"].last["stage"]
    m = suggestion(@beta, "moving_on", "Next, a quick phone screen.") # Beta is already past the screen
    _, res = api("POST", "/api/gmail/matches/#{m.id}/approve")
    assert_equal "Hiring Manager", res["job"]["history"].last["stage"]
  end

  def test_other_accounts_cannot_review_or_target_your_data
    log_in("other@example.com")
    assert_empty api("GET", "/api/gmail/matches")[1]
    assert_equal 404, api("POST", "/api/gmail/matches/#{@rej.id}/approve").first
    assert_equal 404, api("POST", "/api/gmail/matches/#{@rej.id}/dismiss").first
    log_in("me@example.com")
    assert_equal 422, api("POST", "/api/gmail/matches/#{@loose.id}/approve", { application_id: @theirs.id }).first, "can't point at their application"
    assert_equal ["Applied"], @theirs.refresh.history.map(&:stage)
  end
end
