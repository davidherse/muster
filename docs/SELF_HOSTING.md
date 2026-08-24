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

## Notes / gotchas

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
