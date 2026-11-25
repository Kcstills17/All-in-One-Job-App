# Quick live check that each job board still parses. Run: ruby fetcher_check.rb
require_relative "fetcher"

{
  "https://job-boards.greenhouse.io/bugcrowd/jobs/8334498" => "Bugcrowd",
  "https://jobs.ashbyhq.com/checkly/0d236bb0-f860-4317-bc1c-84fed94d0f5a" => "Checkly",
  "https://jobs.ashbyhq.com/talkiatry/4343b2d6-b89f-4534-b208-515963523015" => "Talkiatry",
  "https://jobs.lever.co/palantir/6ed76ce8-4156-4b60-b120-403538bd66cd" => "Palantir",
  "https://www.linkedin.com/jobs/view/4479064983" => "EasyPost",
  "https://www.ycombinator.com/companies/tasklet-2/jobs/UcpBWuw-customer-success-engineer" => "Tasklet",
  "https://www.workatastartup.com/jobs/85660" => "Drillbit",
  "https://apply.workable.com/bask-health-1/j/7E3C450C5D/" => "Bask Health",
  "https://ats.rippling.com/empowerly/jobs/bf9b3e41-e94a-409e-8dc6-620f2cc0171b" => "Empowerly",
  "https://jobs.smartrecruiters.com/AECOM2/744000146474898-structural-engineer" => "AECOM",
  "https://jobs.recruitee.com/o/campaign-manager-france" => "Tellent",
  "https://career.teamtailor.com/jobs/8706432-enterprise-account-executive-chicago" => "Teamtailor",
  "https://jobs.jobvite.com/enphase-energy/job/oKEOAfww" => "Enphase Energy",
  "https://peregrineteam.applytojob.com/apply/ppXpgq8Ykg/Software-Engineer" => "Peregrine Team",
  "https://jobright.ai/jobs/info/6908e6a0bcccf20de59d48ca" => "Scale"
}.each do |url, company|
  info = Fetcher.fetch(url)
  ok = info[:company].to_s.include?(company) && !info[:title].to_s.empty?
  puts "#{ok ? 'ok  ' : 'FAIL'} #{company}: #{info.inspect}"
end

# Offline: LinkedIn <title> parsing.
m = "Support Engineer at Acme — Remote | LinkedIn".match(/\A(.+?) at (.+?)(?: [—|-] (.+?))? \| LinkedIn/)
raise "title parse broke" unless m && m[1] == "Support Engineer" && m[2] == "Acme" && m[3] == "Remote"
raise "pay parse broke" unless Fetcher.pay("Pay: $59,520 - $74,400.") == "$59,520 - $74,400"
# Offline: Workday URLs (no network involved).
{
  "https://redhat.wd5.myworkdayjobs.com/en-US/jobs/job/Associate-Software-Engineer_R-058395" => ["Redhat", "Associate Software Engineer", nil],
  "https://motorolasolutions.wd5.myworkdayjobs.com/Careers/job/Chicago-IL/Web-Developer--Digital-Marketing_R61082" => ["Motorolasolutions", "Web Developer, Digital Marketing", "Chicago IL"],
  "https://wd5.myworkdaysite.com/en-US/recruiting/guidewire/external/job/Software-Engineer-II_JR_14273" => ["Guidewire", "Software Engineer II", nil],
  "https://cgg.wd103.myworkdayjobs.com/en-US/viridiengraduate/job/Junior-Platform-Engineer---Developer-Platform---DevOps-Tooling_JR101375" => ["Cgg", "Junior Platform Engineer - Developer Platform - DevOps Tooling", nil],
  "https://toyota.wd503.myworkdayjobs.com/en-US/tmna/job/Software-Engineer--Early-Career-Professional-_10329087" => ["Toyota", "Software Engineer, Early Career Professional", nil],
  "https://redhat.wd5.myworkdayjobs.com/en-US/jobs/job/Associate-Software-Engineer_R-058395/apply?source=x" => ["Redhat", "Associate Software Engineer", nil]
}.each do |url, want|
  got = Fetcher.fetch(url).values_at(:company, :title, :location)
  raise "workday parse broke: #{url} gave #{got.inspect}" unless got == want
end
puts "ok   parsers"
