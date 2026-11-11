# All-in-One Job App

A multi-user, hosted job tracker. It replaces the single-user app at `~/Desktop/Zanes/job-tracker/`, which is the reference when porting the page (`index.html`), the API routes (`app.rb`), and `fetcher.rb` / `locations.rb`. The plan, the decisions behind it, and progress are in `docs/OVERVIEW.md`. Read it before starting a step, and update its Progress table when a step finishes.

Stack: Ruby, Roda, Sequel, Rodauth and PostgreSQL. Setup and run commands are in `README.md`. Tests: `bundle exec rake`.

## Commits

- **Small and frequent:** commit after each working change, one concern per commit. The tests pass before every commit.
- **Format:** Conventional Commits, `<type>(<scope>): <description>`, with types feat, fix, docs, style, refactor, test or chore. Use an imperative description under 72 characters, and an optional body of `- ` bullets.
- **Author:** messages and PR bodies credit only the human author. End them after the body, with no AI co-author or "generated with" lines.

## Data and security

- **Account scoping:** every user-owned table has an `account_id`. Every query starts from the logged-in account (`rodauth.session_value`), never from an ID taken from the request alone. Each new resource gets a test proving one user can't read or change another user's rows.
- **Two database users:** the app connects as `job_tracker`. Only migrations in `migrate_password/` run as `job_tracker_password`, which owns `account_password_hashes`. App code checks passwords through Rodauth and never selects hash columns. Schema changes go in a new numbered file in `migrate/`.
- **Secrets and personal data:** these live in env vars and git-ignored files (`.env.*`, `jobs*.json`, `referrals*.json`). When importing or testing with Zane's real data, work on a copy and leave the originals untouched.
- **Forms and JSON writes:** these carry a CSRF token. The bookmarklet uses a per-user key instead.

## Gotchas

- `pg` is built from source (`force_ruby_platform` in the Gemfile) because the prebuilt binary won't load on this machine's Ruby 3.4 dev build.
- Local Postgres is 14, but `rake setup` copies the Postgres 15+ rule that only the owner creates tables in `public`. Keep it that way so it behaves the same in production.
- The dev server runs on port 4570, so it doesn't clash with the old app on 4567.
