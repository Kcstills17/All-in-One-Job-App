# The only allowed values for a job's location: Remote, the 100 largest US cities, a few extra
# tech hubs already in the data, and Other. Keeps formatting consistent ("City, ST").
module Locations
  TOP_100 = [
    "New York, NY", "Los Angeles, CA", "Chicago, IL", "Houston, TX", "Phoenix, AZ", "Philadelphia, PA", "San Antonio, TX",
    "San Diego, CA", "Dallas, TX", "San Jose, CA", "Austin, TX", "Jacksonville, FL", "Fort Worth, TX", "Columbus, OH",
    "Indianapolis, IN", "Charlotte, NC", "San Francisco, CA", "Seattle, WA", "Denver, CO", "Washington, DC", "Nashville, TN",
    "Oklahoma City, OK", "El Paso, TX", "Boston, MA", "Portland, OR", "Las Vegas, NV", "Detroit, MI", "Memphis, TN",
    "Louisville, KY", "Baltimore, MD", "Milwaukee, WI", "Albuquerque, NM", "Tucson, AZ", "Fresno, CA", "Sacramento, CA",
    "Kansas City, MO", "Mesa, AZ", "Atlanta, GA", "Omaha, NE", "Colorado Springs, CO", "Raleigh, NC", "Long Beach, CA",
    "Virginia Beach, VA", "Miami, FL", "Oakland, CA", "Minneapolis, MN", "Tulsa, OK", "Bakersfield, CA", "Wichita, KS",
    "Arlington, TX", "Aurora, CO", "Tampa, FL", "New Orleans, LA", "Cleveland, OH", "Honolulu, HI", "Anaheim, CA",
    "Lexington, KY", "Stockton, CA", "Corpus Christi, TX", "Henderson, NV", "Riverside, CA", "Newark, NJ", "Saint Paul, MN",
    "Santa Ana, CA", "Cincinnati, OH", "Irvine, CA", "Orlando, FL", "Pittsburgh, PA", "St. Louis, MO", "Greensboro, NC",
    "Jersey City, NJ", "Anchorage, AK", "Lincoln, NE", "Plano, TX", "Durham, NC", "Buffalo, NY", "Chandler, AZ",
    "Chula Vista, CA", "Toledo, OH", "Madison, WI", "Gilbert, AZ", "Reno, NV", "Fort Wayne, IN", "North Las Vegas, NV",
    "St. Petersburg, FL", "Lubbock, TX", "Irving, TX", "Laredo, TX", "Winston-Salem, NC", "Chesapeake, VA", "Glendale, AZ",
    "Garland, TX", "Scottsdale, AZ", "Norfolk, VA", "Boise, ID", "Fremont, CA", "Spokane, WA", "Santa Clarita, CA",
    "Baton Rouge, LA", "Richmond, VA"
  ].freeze
  EXTRAS = ["Charleston, SC", "Palo Alto, CA", "Menlo Park, CA", "Salt Lake City, UT"].freeze
  ALL = (["Remote"] + TOP_100 + EXTRAS + ["Other"]).freeze
  BY_KEY = ALL.to_h { [_1.downcase, _1] }.freeze

  ALIASES = {
    /\bsf\b|san francisco|south san francisco/ => "San Francisco, CA", /\bnyc\b|new york|manhattan|brooklyn/ => "New York, NY",
    /washington,? d\.?c\.?|\bd\.?c\.?\b/ => "Washington, DC", /\bst\.? louis|saint louis/ => "St. Louis, MO",
    /\bst\.? paul|saint paul/ => "Saint Paul, MN", /\bst\.? pete(rsburg)?\b/ => "St. Petersburg, FL",
    /charleston|mount pleasant|mt\.? pleasant|summerville|goose creek|ladson|daniel island/ => "Charleston, SC",
    /auburn hills/ => "Detroit, MI", /\bslc\b/ => "Salt Lake City, UT",
  }.freeze

  module_function

  # Exact (case-insensitive) list value, or nil.
  def canonical(text) = BY_KEY[text.to_s.strip.downcase]

  # Best list match for free text from a posting or old data; "" if nothing fits.
  # A named city beats "remote" ("SF (remote at first)" is an SF job).
  def normalize(text)
    s = text.to_s.strip.downcase
    return "" if s.empty? || s.match?(/\A\?+\z/)
    return BY_KEY[s] if BY_KEY[s]
    ALIASES.each { |re, loc| return loc if s.match?(re) }
    hits = (TOP_100 + EXTRAS).select { |loc| s.match?(/\b#{Regexp.escape(loc.split(',').first.downcase)}\b/) }
    hits = hits.select { |loc| s.include?(", #{loc.split(', ').last.downcase}") } if hits.size > 1 && hits.any? { |loc| s.include?(", #{loc.split(', ').last.downcase}") }
    return hits.first if hits.any?
    return "Remote" if s.match?(/remote|anywhere|work from home|\bwfh\b/)
    ""
  end
end

if $PROGRAM_NAME == __FILE__ # ruby locations.rb → quick self-check
  t = { "Remote - US" => "Remote", "San Francisco" => "San Francisco, CA", "SF (remote arrangement discussed)" => "San Francisco, CA",
        "Austin" => "Austin, TX", "New York" => "New York, NY", "Charleston area" => "Charleston, SC", "Palo Alto" => "Palo Alto, CA",
        "Menlo Park, CA (3+ days in office)" => "Menlo Park, CA", "Menlo Park, CA (relocation paid, remote at first)" => "Menlo Park, CA", "Atlanta, GA (relocate within 50 mi)" => "Atlanta, GA",
        "Arlington, TX" => "Arlington, TX", "Portland, OR" => "Portland, OR", "Virginia" => "", "?" => "", "Auburn Hills, MI" => "Detroit, MI",
        "Eastern Time zone" => "", "Remote, United States" => "Remote", "Washington, DC" => "Washington, DC" }
  bad = t.reject { |i, want| Locations.normalize(i) == want }
  abort("FAIL #{bad.map { |i, w| "#{i.inspect} → #{Locations.normalize(i).inspect} (want #{w.inspect})" }.join('; ')}") unless bad.empty?
  abort("expected 106 locations, got #{Locations::ALL.size}") unless Locations::ALL.size == 106
  puts "locations ok (#{Locations::ALL.size} options)"
end
