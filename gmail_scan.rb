# Sorting and matching job emails. No network: Gmail (gmail.rb) hands it plain emails, so the
# rules can be tested and tuned on their own.
#
# An email is { from_name:, from_address:, subject:, text:, date: }.
module GmailScan
  # Checked in this order; the first category with a matching phrase wins. Rejections often also say
  # "thank you for applying", so they go first; plain confirmations are recognized only to be skipped.
  RULES = {
    rejected: [
      "not moving forward", "not be moving forward", "won't be moving forward", "will not be moving forward",
      "move forward with other candidates", "moving forward with other candidates", "pursue other candidates",
      "other candidates whose", "other candidates who", "decided not to proceed", "not to move forward",
      "not been selected", "were not selected", "was not selected", "unable to offer you", "position has been filled",
      "role has been filled", "decided to go in a different direction", "regret to inform", "not a match for",
      "no longer under consideration", "will not be proceeding", "won't be proceeding", "decided to move on"
    ],
    moving_on: [
      "next steps", "next step in", "schedule a call", "schedule a time", "schedule an interview", "set up a time",
      "set up a call", "invite you to", "like to invite you", "move you forward", "moving you forward",
      "advance you to", "advance to the next", "phone screen", "technical interview", "take-home", "take home assignment",
      "coding challenge", "coding assessment", "online assessment", "calendly.com", "your availability", "times that work"
    ],
    confirmation: [
      "received your application", "thank you for applying", "thanks for applying", "application has been received",
      "application was received", "thank you for your application", "thanks for your interest", "we've received your"
    ]
  }.freeze

  # Mail from these hosts is sent on a company's behalf, so their domain says nothing about the company.
  ATS_DOMAINS = %w[greenhouse.io greenhouse-mail.io lever.co hire.lever.co ashbyhq.com myworkday.com workday.com
                   workablemail.com workable.com smartrecruiters.com icims.com jobvite.com bamboohr.com rippling.com
                   breezy.hr recruitee.com teamtailor.com jazzhr.com applytojob.com gem.com dover.com paradox.ai
                   linkedin.com indeed.com ycombinator.com workatastartup.com gmail.com outlook.com].freeze

  # The category and the sentence that decided it, or nil for emails that aren't about an application.
  def self.classify(email)
    text = "#{email[:subject]}. #{email[:text]}".gsub(/\s+/, " ")
    down = text.downcase
    RULES.each do |category, phrases|
      phrase = phrases.find { down.include?(_1) } or next
      body = email[:text].to_s.gsub(/\s+/, " ")
      return { category: category, phrase: phrase, sentence: sentence_with(body.downcase.include?(phrase) ? body : text, phrase) }
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
    domain = email[:from_address].to_s.downcase[/@([^>]+)\z/, 1].to_s
    domain = "" if ATS_DOMAINS.any? { domain == _1 || domain.end_with?(".#{_1}") }
    domain_word = domain.split(".")[-2].to_s # careers.acme.com -> acme
    # The sender's name, the subject and the domain are trusted; the body only for distinctive names,
    # since short ones ("Scale", "Ramp") turn up in ordinary sentences.
    strong = " #{key("#{email[:from_name]} #{email[:subject]}")} "
    body = " #{key(email[:text].to_s[0, 3000])} "
    distinctive = ->(k) { k.include?(" ") || k.size >= 7 }
    eligible = apps.select { |a| !a[:applied_on] || !email[:date] || a[:applied_on] <= email[:date] }
    by_company = eligible.group_by { key(_1[:company]) }.reject { |k, _| k.empty? }
    hits = by_company.select do |k, _|
      squashed = k.delete(" ")
      strong.include?(" #{k} ") || (distinctive[k] && body.include?(" #{k} ")) ||
        (domain_word.size > 2 && (squashed == domain_word || squashed == domain.split(".").first))
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
