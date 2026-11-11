# Loads settings and connects to Postgres. Locally, settings come from .env.development / .env.test
# (made by `rake setup`); in production they're real environment variables.
ENV["RACK_ENV"] ||= "development"
unless ENV["RACK_ENV"] == "production"
  require "dotenv"
  Dotenv.load(File.join(__dir__, ".env.#{ENV['RACK_ENV']}"))
end

require "sequel"
# Connects as the app's database user, which can check passwords but never read the hashes.
DB = Sequel.connect(ENV.fetch("DATABASE_URL"))
