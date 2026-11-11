require "securerandom"
require "rake/testtask"

ROLE = "job_tracker"

desc "One-time local setup: database users, dev + test databases, .env files, migrations"
task :setup do
  require "sequel"
  admin = Sequel.connect("postgres:///postgres") # your own (superuser) login
  [ROLE, "#{ROLE}_password"].each do |r|
    admin.run "CREATE ROLE #{r} LOGIN" if admin[:pg_roles].where(rolname: r).empty?
  end

  %w[development test].each do |env|
    name = "job_tracker_#{env}"
    unless File.exist?(".env.#{env}")
      File.write(".env.#{env}", <<~ENV)
        DATABASE_URL=postgres:///#{name}?user=#{ROLE}
        PASSWORD_DATABASE_URL=postgres:///#{name}?user=#{ROLE}_password
        SESSION_SECRET=#{SecureRandom.hex(64)}
        HMAC_SECRET=#{SecureRandom.hex(32)}
      ENV
    end
    admin.run "CREATE DATABASE #{name} OWNER #{ROLE}" if admin[:pg_database].where(datname: name).empty?

    Sequel.connect("postgres:///#{name}") do |db|
      db.run "CREATE EXTENSION IF NOT EXISTS citext"
      # Match Postgres 15+ (what hosts run): only the owner creates tables in public.
      db.run "ALTER SCHEMA public OWNER TO #{ROLE}"
      db.run "REVOKE CREATE ON SCHEMA public FROM PUBLIC"
      db.run "GRANT CREATE ON SCHEMA public TO #{ROLE}_password" # only while migrating
      sh({ "RACK_ENV" => env }, "bundle exec rake migrate")
      db.run "REVOKE CREATE ON SCHEMA public FROM #{ROLE}_password"
    end
  end
  admin.disconnect
end

desc "Run database migrations (app user, then password user)"
task :migrate do
  require_relative "config"
  Sequel.extension :migration
  Sequel::Migrator.run(DB, "migrate")
  Sequel.connect(ENV.fetch("PASSWORD_DATABASE_URL")) do |db|
    Sequel::Migrator.run(db, "migrate_password", table: :schema_info_password)
  end
end

Rake::TestTask.new { |t| t.pattern = "test/*_test.rb"; t.warning = false }
task default: :test
