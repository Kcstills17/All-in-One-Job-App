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

Run the tests with `bundle exec rake`, and check the gems for known security problems with `bundle exec rake audit`.

### Importing data from the old local app

New accounts start empty. To copy the old app's `jobs.json` and `referrals.json` into one account, sign up and verify first, then run:

```sh
bundle exec rake import EMAIL=you@example.com FROM=~/Desktop/Zanes/job-tracker
```

The import only reads the old files. Running it again syncs the account: edited entries update and new ones get added. Anything deleted in the old app has to be deleted here too. If any count doesn't match, nothing is saved.

## Privacy and security

- **Your data is encrypted.** Everything you type is encrypted before it's stored, so it can't be read straight out of the database. That covers companies, roles, links, notes and referral contacts.
- **Only you see your data.** Every account is separate, and the tests check that no account can read or change another's.
- **Deleting your account deletes your data.** All of it, right away.
- **Found a security problem?** Please report it privately, as [SECURITY.md](SECURITY.md) explains, not in a public issue.
