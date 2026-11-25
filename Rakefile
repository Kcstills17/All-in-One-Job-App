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
        COLUMN_KEY=#{SecureRandom.hex(32)}
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

desc "One-time hosted database setup: rake setup_production ADMIN_DATABASE_URL='<owner url from Neon>'"
task :setup_production do
  require "sequel"
  require "uri"
  file = ".env.production"
  abort "#{file} already exists. Delete it first to start over (that makes new passwords and keys)." if File.exist?(file)
  admin_url = ENV.fetch("ADMIN_DATABASE_URL")
  urls = {}
  Sequel.connect(admin_url) do |db|
    [ROLE, "#{ROLE}_password"].each do |r|
      password = SecureRandom.hex(24)
      verb = db[:pg_roles].where(rolname: r).empty? ? "CREATE" : "ALTER"
      db.run "#{verb} ROLE #{r} LOGIN PASSWORD '#{password}'"
      urls[r] = URI(admin_url).tap { _1.user = r; _1.password = password }.to_s
    end
    db.run "CREATE EXTENSION IF NOT EXISTS citext"
    # Hosted Postgres 15+ already limits CREATE in public to its owner; grant it to the app's users.
    db.run "GRANT USAGE, CREATE ON SCHEMA public TO #{ROLE}, #{ROLE}_password"
    # Secrets go to a git-ignored file, never the terminal. Copy each line into the host's settings.
    File.write(file, <<~ENV, perm: 0o600)
      RACK_ENV=production
      DATABASE_URL=#{urls[ROLE]}
      PASSWORD_DATABASE_URL=#{urls["#{ROLE}_password"]}
      SESSION_SECRET=#{SecureRandom.hex(64)}
      HMAC_SECRET=#{SecureRandom.hex(32)}
      COLUMN_KEY=#{SecureRandom.hex(32)}
    ENV
    sh({ "RACK_ENV" => "production" }, "bundle exec rake migrate")
    db.run "REVOKE CREATE ON SCHEMA public FROM #{ROLE}_password" # only while migrating
  end
  puts "Done. Settings for the host are in #{file}. Back up COLUMN_KEY somewhere safe: losing it loses the data."
end

# The host runs this before every start (render.yaml), so the schema is always current before the app
# reads it. It needs only the app's database user; password-table changes still go through `rake migrate`.
desc "Run the app user's migrations (migrate/)"
task "migrate:app" do
  require_relative "config"
  Sequel.extension :migration
  Sequel::Migrator.run(DB, "migrate")
end

desc "Run database migrations (app user, then password user)"
task migrate: "migrate:app" do
  Sequel.connect(ENV.fetch("PASSWORD_DATABASE_URL")) do |db|
    # The migrator always tries to create its version table, and the password user may only create
    # tables during setup. So skip it unless a migrate_password/ file hasn't run yet.
    current = db.table_exists?(:schema_info_password) &&
              db[:schema_info_password].get(:version) >= Dir["migrate_password/*.rb"].size
    Sequel::Migrator.run(db, "migrate_password", table: :schema_info_password) unless current
  end
end

desc "Import the old app's data into one account: rake import EMAIL=you@example.com [FROM=dir]"
task :import do
  require_relative "import"
  dir = File.expand_path(ENV.fetch("FROM", "~/Desktop/Zanes/job-tracker"))
  puts "Imported into #{ENV.fetch('EMAIL')}: #{Import.run(ENV.fetch('EMAIL'), dir)}"
end

desc "Write one account's data as jobs.json + referrals.json: rake export EMAIL=you@example.com TO=dir"
task :export do
  require_relative "export"
  dir = File.expand_path(ENV.fetch("TO"))
  puts "Exported #{ENV.fetch('EMAIL')} to #{dir}: #{Export.run(ENV.fetch('EMAIL'), dir)}"
end

desc "Create a verified account without email (for closed sign-ups): rake create_account EMAIL=you@example.com"
task :create_account do
  require_relative "config"
  require "bcrypt"
  require "io/console"
  email = ENV.fetch("EMAIL")
  abort "#{email} already has an account." if DB[:accounts].where(email: email, status_id: [1, 2]).any?
  password = IO.console.getpass("Password (10+ characters): ")
  abort "Too short." if password.length < 10
  abort "Passwords don't match." unless IO.console.getpass("Again: ") == password
  DB.transaction do
    id = DB[:accounts].insert(email: email, status_id: 2) # 2 = verified
    DB[:account_password_hashes].insert(id: id, password_hash: BCrypt::Password.create(password))
  end
  puts "Created #{email}. Log in with that password."
end

Rake::TestTask.new { |t| t.pattern = "test/*_test.rb"; t.warning = false }
desc "Run the page's JavaScript tests (test/*.test.js) with node"
task :test_js do
  if system("node --version", out: File::NULL, err: File::NULL)
    sh "node --test test/"
  else
    puts "Skipping JavaScript tests: node isn't installed."
  end
end
task default: %i[test test_js]

desc "Check gems against the Ruby security advisory database"
task :audit do
  sh "bundle exec bundle-audit check --update"
end
