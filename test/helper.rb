ENV["RACK_ENV"] = "test"
require_relative "../app"
require_relative "../import"
require "minitest/autorun"

# Empties every table, children first. Rodauth's key tables don't cascade, so they go before accounts;
# applications, timeline steps and referrals cascade from accounts.
def reset_db!
  %i[account_password_hashes account_verification_keys account_password_reset_keys
     account_login_failures account_lockouts accounts].each { DB[_1].delete }
end
