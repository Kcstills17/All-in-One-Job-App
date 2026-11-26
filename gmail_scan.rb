# Sorting and matching job emails. No network: GmailIngest hands it plain emails from the Gmail
# script, so the rules can be tested and tuned on their own.
#
# An email is { from_name:, from_address:, subject:, text:, date: }.
module GmailScan
  # Checked in this order; the first group with a matching phrase wins:
  # 1. rejected: rejections often also say "thank you for applying", so they go first
  # 2. moving_on: clear invitations (schedule, interview, assessment)
  # 3. confirmation: "thanks for applying, we'll be in touch about next steps" is only a receipt (skipped)
  # 4. maybe_moving_on: vague "next steps" wording, counted as moving on only in an email about a job
  RULES = {
    rejected: [
      "not moving forward", "not be moving forward", "won't be moving forward", "will not be moving forward",
      "not to move forward", "move forward with other candidates", "moving forward with other candidates",
      "pursue other candidates", "other candidates whose", "other candidates who", "decided not to proceed",
      "not been selected", "were not selected", "was not selected", "unable to offer you", "position has been filled",
      "role has been filled", "has been filled", "filled or closed", "decided to go in a different direction",
      "regret to inform", "not a match for", "no longer under consideration", "will not be proceeding",
      "won't be proceeding", "decided to move on", "decided we won't", "it is unfortunate that"
    ],
    moving_on: [
      "schedule a call", "schedule a time", "schedule an interview", "schedule your interview", "set up a time",
      "set up a call", "like to invite you", "invite you to interview", "invite you to a", "phone interview",
      "phone screen", "video interview", "technical interview", "take-home", "take home assignment", "coding challenge",
      "coding assessment", "online assessment", "complete an assessment", "love for you to complete", "calendly.com",
      "your availability", "times that work", "move you forward", "moving you forward", "advance you to", "next round"
    ],
    confirmation: [
      "received your application", "thank you for applying", "thanks for applying", "application has been received",
      "application was received", "thank you for your application", "thanks for your interest", "we've received your",
      "your application was sent to", "submitting your application", "if your experience aligns",
      "if your profile is a good fit", "if your background is a match", "we will contact you", "we'll be in touch",
      "we will be in touch", "once we review your application"
    ],
    maybe_moving_on: ["next steps", "next step in", "advance to the next"]
  }.freeze
  JOB_WORDS = /\b(application|applied|applying|interview|candidate|position|role|resume|hiring|recruit)/i

  # Mail from these hosts is sent on a company's behalf, so their domain says nothing about the company.
  ATS_DOMAINS = %w[greenhouse.io greenhouse-mail.io lever.co hire.lever.co ashbyhq.com myworkday.com workday.com
                   workablemail.com workable.com smartrecruiters.com icims.com jobvite.com bamboohr.com rippling.com
                   breezy.hr recruitee.com teamtailor.com jazzhr.com applytojob.com gem.com dover.com paradox.ai
                   linkedin.com indeed.com ycombinator.com workatastartup.com gmail.com outlook.com].freeze

  # The category and the sentence that decided it, or nil for emails that aren't about an application.
  def self.classify(email)
    text = "#{email[:subject]}. #{email[:text]}".gsub(/\s+/, " ")
    down = text.downcase
    RULES.each do |group, phrases|
      phrase = phrases.find { down.include?(_1) } or next
      next if group == :maybe_moving_on && !text.match?(JOB_WORDS)
      body = email[:text].to_s.gsub(/\s+/, " ")
      return { category: group == :maybe_moving_on ? :moving_on : group, phrase: phrase,
               sentence: sentence_with(body.downcase.include?(phrase) ? body : text, phrase) }
    end
    nil
  end

  def self.sentence_with(text, phrase)
    i = text.downcase.index(phrase)
    from = (text.rindex(/[.!?]\s/, i) || -2) + 2
    to = text.index(/[.!?](\s|\z)/, i + phrase.size) || text.size - 1
    text[from..to].strip[0, 240]
  end

  # "Acme, Inc." -> "acme"; "Insight Global / CACI" -> "insight global caci"
  def self.key(name) = name.to_s.downcase.gsub(/\b(inc|llc|ltd|corp|co|corporation|company|technologies|labs|ai|hq)\b\.?/, " ")
                                         .gsub(/[^a-z0-9]+/, " ").strip

  # Which application an email is about. Returns { app:, confidence: :company | :role } or
  # { app: nil, candidates: [...] } when it's ambiguous or unknown. `apps` are hashes with
  # :id, :company, :title, :applied_on (Date or nil); only those applied on or before the email count.
  def self.match(email, apps)
    address = email[:from_address].to_s.downcase
    domain = address[/@([^>]+)\z/, 1].to_s
    # Job sites send for many companies: their domain says nothing, but the part before the @ often
    # does (poolcorp@myworkday.com, realpagepms+autoreply@icims.com).
    ats = ATS_DOMAINS.any? { domain == _1 || domain.end_with?(".#{_1}") }
    local = ats ? address[/\A([a-z0-9]+)/, 1].to_s : ""
    domain_word = ats ? "" : domain.split(".")[-2].to_s # careers.acme.com -> acme
    # Only the sender's name, the subject and the address count. Bodies are left out: they're full of
    # other companies' names (LinkedIn's "people also viewed", signatures, newsletters).
    strong = " #{key("#{email[:from_name]} #{email[:subject]}")} "
    eligible = apps.select { |a| !a[:applied_on] || !email[:date] || a[:applied_on] <= email[:date] }
    by_company = eligible.group_by { key(_1[:company]) }.reject { |k, _| k.empty? }
    hits = by_company.select do |k, _|
      squashed = k.delete(" ")
      strong.include?(" #{k} ") || (domain_word.size > 2 && squashed == domain_word) ||
        (squashed.size >= 5 && local.start_with?(squashed))
    end
    # The longest company name wins when one contains another ("Scale" vs "Scale AI").
    company, list = hits.max_by { |k, _| k.size }
    return { app: nil, candidates: [] } unless company
    return { app: list.first, confidence: :company } if list.size == 1

    words = ->(s) { key(s).split.reject { _1.size < 3 }.to_set }
    scored = list.map { |a| [a, (words[a[:title]] & words["#{email[:subject]} #{email[:text].to_s[0, 3000]}"]).size] }.sort_by { -_2 }
    if scored[0][1] > 0 && scored[0][1] > scored[1][1]
      { app: scored[0][0], confidence: :role }
    else
      { app: nil, candidates: list }
    end
  end
end
