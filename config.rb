# Loads settings and connects to Postgres. Locally, settings come from .env.development / .env.test
# (made by `rake setup`); in production they're real environment variables.
ENV["RACK_ENV"] ||= "development"
# A local .env.production (from `rake setup_production`) lets rake tasks reach the hosted database.
# The host has no such file and sets real variables instead.
env_file = File.join(__dir__, ".env.#{ENV['RACK_ENV']}")
if File.exist?(env_file)
  require "dotenv"
  Dotenv.load(env_file)
end

require "sequel"
# Connects as the app's database user, which can check passwords but never read the hashes.
DB = Sequel.connect(ENV.fetch("DATABASE_URL"))
