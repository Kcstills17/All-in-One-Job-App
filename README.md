# All-in-One-Job-App
A job application meant to streamline the process of applying for roles. I found the whole setup frustrating after a while in term of how I was approaching it. I wanted to just be able to place a link and have all my needed info filled out with a lot of metrics and data to see where I am successful and not. 

## Stack

Ruby, [Roda](https://roda.jeremyevans.net) (web routing), [Sequel](https://sequel.jeremyevans.net) (database), [Rodauth](https://rodauth.jeremyevans.net) (accounts) and PostgreSQL.

## Running it locally

Needs Ruby 3.4 and PostgreSQL running locally.

```sh
bundle install
bundle exec rake setup    # one time: database users, dev + test databases, .env files with random secrets
bundle exec puma -b tcp://127.0.0.1:4570 config.ru
```

Open http://localhost:4570 and create an account. In development, emails such as the verification link print to the terminal running the server.

Run the tests with `bundle exec rake`.

## Security

- **Passwords:** hashed with bcrypt and stored in a table owned by a separate database user. The app can check a password but can't read the hashes, so a SQL injection bug can't leak them.
- **Accounts:** you must verify your email before logging in. After 10 wrong passwords the account locks until the emailed unlock link is used. Password reset works by email, and users can delete their own account.
- **Every form** carries a CSRF token, a per-form secret that stops other sites from submitting forms as you. Session cookies are HTTP-only, SameSite=Lax, and secure in production.
- **Headers:** a strict Content-Security-Policy, nosniff, and HSTS in production.
- **Secrets** live in environment variables only. `.env*` files and job data (`*.json`) are git-ignored.
