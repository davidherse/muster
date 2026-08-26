# Running Muster on your own machine (Tailscale)

The simplest self-host runs the app in the development environment: SQLite on
disk, uploads stored locally, background jobs in-process — no Postgres, no
Redis, no S3/R2, no mail server. Access is protected by your tailnet.

## 1. Prerequisites on the server

- Ruby **3.4.4** (`.ruby-version`) — via rbenv/mise/asdf, plus build tools
  (`build-essential`, `libyaml-dev`, `libsqlite3-dev` on Debian/Ubuntu)
- git, and Tailscale already joined to your tailnet

## 2. Clone and set up

```sh
git clone https://github.com/davidherse/muster.git
cd muster
git checkout quantities-first
bundle install
export ANTHROPIC_API_KEY=sk-ant-...   # put in your shell profile or a systemd unit
bin/rails db:prepare                  # creates SQLite DBs, seeds base book + template
bin/rails tailwindcss:build           # one-off CSS build (no watcher needed)
```

## 3. Bring your data (optional but recommended)

A fresh clone has the seeded base book but none of your accounts, training
uploads, or estimates. To mirror the Mac's state, copy the whole `storage/`
directory (it holds the SQLite databases AND the uploaded files):

```sh
rsync -av yourmac:~/Code/build_estimator/storage/ ./storage/
```

Do this while the Mac's server is stopped. Skipping this is fine too — you'll
just sign up fresh through the wizard (invite code not enforced in dev) and
re-upload training documents.

## 4. Run it

```sh
bin/rails server            # binds to localhost:3000
```

Keep it alive however you prefer — `tmux`, or a systemd unit like:

```ini
[Unit]
Description=Muster
After=network.target

[Service]
User=you
WorkingDirectory=/home/you/muster
Environment=ANTHROPIC_API_KEY=sk-ant-...
ExecStart=/home/you/.rbenv/shims/bundle exec rails server
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## 5. Serve it over Tailscale

```sh
tailscale serve --bg 3000
```

That proxies `https://<machine-name>.<tailnet>.ts.net` → localhost:3000 with
TLS handled by Tailscale, visible only inside your tailnet. The app already
allows `*.ts.net` hostnames in development; for a custom name set
`DEV_HOST=myname.example`.

## Production mode (recommended once it's working)

Development mode is the quickest start; production mode adds eager loading,
real caching, digested assets, and a proper background worker. With no
`DATABASE_URL` set it automatically uses SQLite (four databases under
`storage/`) — no Postgres needed.

```sh
# .env in the app directory (dotenv loads it automatically):
#   RAILS_ENV=production
#   ANTHROPIC_API_KEY=sk-ant-...
#   STORAGE_SERVICE=local
#   APP_HOST=<machine>.<tailnet>.ts.net      # used in generated links/emails
#   MUSTER_INVITE_CODE=pick-something        # sign-up gate

# copy config/master.key from your dev machine (NOT in git) — it decrypts
# credentials including secret_key_base; production won't boot without it.

bin/rails assets:precompile
bin/rails db:prepare        # creates + seeds all four SQLite databases
bin/rails server            # web
bin/jobs                    # background worker, as a second process/unit
```

Both processes need the same env. `tailscale serve --bg 3000` works exactly as
in dev — production trusts the proxy's TLS (`assume_ssl`) and allows `*.ts.net`
hosts (extend with `EXTRA_HOSTS=name1,name2`).

### Environment variables reference

| Variable | Needed? | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | required | estimate generation |
| `RAILS_MASTER_KEY` (or `config/master.key` file) | required in production | decrypts credentials / secret_key_base |
| `STORAGE_SERVICE=local` | required in production self-host | else it defaults to Cloudflare R2 and wants `R2_*` keys |
| `APP_HOST` | recommended | hostname used in generated links (defaults muster.build) |
| `MUSTER_INVITE_CODE` | recommended | sign-up invite gate (defaults MUSTER-BETA) |
| `EXTRA_HOSTS` | optional | extra allowed hostnames, comma-separated |
| `SMTP_ADDRESS/PORT/USERNAME/PASSWORD/DOMAIN` | optional | outgoing email; unset = emails skipped (activate users via console) |
| `ESTIMATOR_MODEL`, `ESTIMATOR_BATCH_SIZE`, `ESTIMATOR_REVIEW_MODE` | optional | estimator tuning overrides |

## Notes / gotchas

- **Seats:** the workspace owner adds people from the Team page (sidebar → Team); because there is no email, it shows a set-password link (valid for 2 days) to forward by hand. Everyone in the workspace shares the same estimates, template, training documents and price book.
- **Email isn't configured in dev** — account activation links are printed to
  the server log instead of sent. Watch `log/development.log` for the link, or
  activate from the console:
  `bin/rails runner 'User.find_by(email_address: "x@y.z").activate!'`
- **Jobs run in-process** (async adapter) — estimate generation dies if you
  restart the server mid-run; the estimate page's "Try again" resumes it.
- **Costs**: every estimate generation calls the Anthropic API (~$3–8/estimate)
  using the key on the server.
- **Real production deploys** (Heroku/Postgres/R2/SendGrid) are covered in
  `DEPLOY.md`; this document is the lightweight personal-server path.
