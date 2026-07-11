# Deploying Muster to Heroku

No Redis needed: background jobs run on Solid Queue, which lives in the same
Postgres database. Estimates are long jobs (20-60 min of streaming AI calls),
so they run on a dedicated worker dyno.

## One-time setup

    heroku create muster-app
    heroku addons:create heroku-postgresql:essential-1
    heroku buildpacks:set heroku/ruby

    # Secrets
    heroku config:set RAILS_MASTER_KEY=$(cat config/master.key)
    heroku config:set ANTHROPIC_API_KEY=sk-ant-...
    heroku config:set MUSTER_INVITE_CODE=CHOOSE-A-CODE

    # File storage (plans/PDFs cannot live on Heroku's ephemeral disk).
    # Cloudflare R2 (default): create a bucket + an R2 API token in the
    # Cloudflare dashboard (R2 -> Manage API Tokens -> Object Read & Write):
    heroku config:set R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... R2_BUCKET=muster-production
    # (S3 alternative: set STORAGE_SERVICE=amazon + AWS_* vars instead.)

## Deploy

    git push heroku main
    heroku ps:scale web=1 worker=1
    heroku run bin/rails db:seed        # base price book + template (first deploy only)
    heroku run bin/rails estimator:ingest_market   # published market bands

## Domain: muster.build

    heroku domains:add muster.build
    heroku domains:add www.muster.build
    # Add the DNS targets Heroku prints:
    #   muster.build      -> ALIAS/ANAME record to the DNS target
    #   www.muster.build  -> CNAME record to the DNS target
    heroku certs:auto:enable

## Notes

- Release phase runs db:prepare (schema + solid_queue/cache/cable schemas on
  the same Postgres).
- Daily dyno restarts can interrupt an estimate mid-generation; the app's
  resume support picks up from the last costed section via the estimate page.
- Mail (SendGrid via the generic SMTP env vars):
      heroku config:set SMTP_ADDRESS=smtp.sendgrid.net SMTP_PORT=587 SMTP_USERNAME=apikey SMTP_PASSWORD=SG.your-key SMTP_DOMAIN=muster.build
  In SendGrid: authenticate the muster.build domain (Settings -> Sender
  Authentication) so activation emails don't land in spam.
