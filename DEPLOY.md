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

    # File storage (plans/PDFs cannot live on Heroku's ephemeral disk)
    # Create an S3 bucket (ap-southeast-2) and an IAM user with access to it:
    heroku config:set AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_BUCKET=muster-production AWS_REGION=ap-southeast-2

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
- Mail: activation emails need an SMTP add-on (e.g. Resend/Postmark) before
  open signup; configure action_mailer SMTP settings when chosen.
