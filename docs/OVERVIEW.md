# All-in-One Job App: overview

_Last updated 2026-11-11._

## Where this came from

The job tracker started as a single-user app that runs only on one Mac, at `~/Desktop/Zanes/job-tracker/` (http://localhost:4567). It's plain Rack and Puma, and it saves data to `jobs.json` and `referrals.json`. It already has:

- **Auto-fill from a job link.** Greenhouse, Ashby, Lever, LinkedIn, Y Combinator and Work at a Startup fill in fully. Workday fills in from the URL only, because Workday blocks automated lookups.
- **A bookmarklet** that logs the job posting you're looking at.
- **Applications** with a timeline of stages, goals, stats, a pipeline (Sankey) chart, salary analysis and a searchable table.
- **Referrals**, imported from the "Zane's-Outreach" Google Sheet: statuses, notes that save as you type, and search and sorting by date.
- **Three tabs:** Applications, Referrals, and Together (what both share).

That app keeps running until this one replaces it.

## Where it's going

This repo is the multi-user, hosted version:

1. **Accounts:** anyone can sign up, and each person sees only their own data.
2. **Use it anywhere:** hosted online, so it works from any computer or phone.
3. **Gmail scanning:** finds rejection and "moving on" emails, matches them to applications, and suggests stage updates for you to approve.

## Decisions so far

| Decision | Choice | Why |
|---|---|---|
| Language | Ruby | Same as the current app, so its code can be reused |
| Web framework | **Roda** | Closest to the current Rack server. Small and fast, with security in mind from the start |
| Database | **PostgreSQL** with **Sequel** | A real database, needed once there's more than one user. Sequel is a Ruby library for working with it |
| Accounts | **Rodauth** | The most careful account library in Ruby, built to keep password hashes away from the app |
| Hosting | Fly.io, with Postgres from Fly or Neon | About $0–5 a month. Planned, not set up yet |
| Email | Gmail over IMAP, using each user's app password, stored encrypted | Works without Google's paid review. "Sign in with Google" can come later, if people want it |
| Rails? | No | Less familiar to Zane. Roda keeps the existing code and its style |

## How it works

```
Browser ──HTTPS──▶ Puma ──▶ Roda app (app.rb)
                              │ every request has to pass:
                              │   CSRF check (forms) ─▶ Rodauth routes (/login, /create-account, …)
                              │   ─▶ require a logged-in, verified account ─▶ app routes
                              ▼
                          PostgreSQL
                  ┌─────────────────────────────┬──────────────────────────────┐
                  │ app user: job_tracker       │ job_tracker_password         │
                  │ accounts, applications,     │ account_password_hashes      │
                  │ referrals, email inbox …    │ (the app can't read these)   │
                  └─────────────────────────────┴──────────────────────────────┘
       Hourly job (planned) ──IMAP──▶ Gmail ──▶ suggestions in the email inbox
```

### Accounts (done)
- **Signing up:** pick an email and a password of at least 10 characters. You verify the email before you can log in.
- **Login protection:** 10 wrong passwords lock the account until you use the emailed unlock link.
- **Self-service:** reset, change, and delete-account all work by email or from the account page.
- **How passwords are checked:** password hashes live in a table owned by a second database user. The app can only call two database functions, one to get the salt and one to ask "does this hash match?". So even a SQL injection bug can't read the hashes.
- **Other protections:**
  - Every form carries a CSRF token, a per-form secret that stops other sites from submitting forms as you.
  - Cookies can't be read by scripts, and they're only sent from this site.
  - A strict Content-Security-Policy (rules for what the page may load).
  - HSTS (always use HTTPS) in production.

### Applications and referrals (next)
- **Tables:**
  - `applications`
  - `application_events`: the timeline steps
  - `referrals`
- **Ownership:** every row has an `account_id`, and every query starts from the logged-in account. That way, user A's data can't be reached from user B's session.
- **Moving the code over:**
  - The current page (`index.html`) moves over almost unchanged.
  - The `/api/...` routes move from the current `app.rb` to Roda.
  - `fetcher.rb` and `locations.rb` copy over as they are.
- **Importing your data:** a one-time script loads `jobs.json` and `referrals.json` into your account, then checks the totals match.
- **Bookmarklet:** each user gets a personal key they can switch off, because the bookmarklet can't send a form's CSRF token.
- **Auto-fill safety:** when hosted, auto-fill refuses links to private or internal network addresses. Otherwise someone could make the server fetch addresses on its own internal network.

### Hosting (after that)
- **Platform:** Fly.io runs the app, with Postgres from Fly or Neon.
- **Settings:** secrets are set as environment variables (`.env.example` lists them). `APP_URL` tells the app its real address, so links in emails can't be faked.
- **Email:** sending sign-up and reset emails needs an SMTP provider, to be chosen then.

### Gmail scanning (last)
1. **Connect:** each user adds a Gmail app password, which is stored encrypted.
2. **First scan:** one wide search of their mail, going back to their earliest application date. Each email is matched by **company name, then role title**. If they've applied to the same company more than once, the role title decides which application it belongs to.
3. **Hourly checks:** the app remembers the last email it read, so new mail is only processed once.
4. **Sorting:**
   - **Rejected:** "other candidates", "not moving forward".
   - **Moving on:** "schedule", "next steps", "interview".
   - **Confirmation:** these are ignored.
5. **Review:** suggestions wait in an inbox for approval. Approving one adds a timeline step, dated with the email's date. Nothing changes without approval.
6. **Filtering:** the inbox can be filtered by company, role, location or category.

## Progress

| Step | Status |
|---|---|
| 1. Roda + Sequel + Rodauth app with accounts, and tests | **Done** |
| 2. Applications and referrals tables, plus importing Zane's data | Next |
| 3. Move the page and API over, plus the bookmarklet key | |
| 4. Security pass: auto-fill safety, a test proving users can't see each other's data, a security scan | |
| 5. Host on Fly.io | |
| 6. Gmail scanning | |

## Left for later

- **Sorting emails with Claude:** only if the keyword rules sort too many emails wrong.
- **"Sign in with Google" for Gmail:** needs Google's approval once more than 100 users connect.
- **Login rate limits by IP address:** the account lockout covers guessing for now.
