# Build Estimator

AI-powered construction estimating for residential builders. Upload an
architectural plan PDF, add a short brief, and get a fully costed estimate —
broken into the same ~40 sections as your historical job costing reports, with
a low/high range on every line item — downloadable as CSV.

Built with Rails 8, SQLite, Solid Queue, Hotwire, and the Anthropic API
(Claude reads the plan PDFs directly).

## How it works

1. **Sign up → activate** — activation email (opens in the browser in
   development via letter_opener; SMTP from ENV in production).
2. **New estimate** — upload the plan PDF (≤ 50 MB), add any extra context
   (finish level, site issues, inclusions/exclusions), pick a layout template.
3. **Generation pipeline** (background job):
   - *Plan analysis* — Claude reads the full PDF and produces a structured
     scope of works (areas, rooms, counts, structure, site notes).
   - *Line item generation* — template sections are costed in batches,
     grounded in a **price book** of 1,300+ real unit rates extracted from
     historical job costings (Hilda, Constitution, Benecia, Carberry).
   - Every line item carries a confidence level (high/medium/low → ±10/20/35%)
     which rolls up into the estimate's low/high range.
4. **Review + download** — sections, line items, assumptions, totals, and the
   range in the UI; one click to download the CSV.

## Setup

```sh
# Ruby 3.4.4 (see .ruby-version)
bundle install
cp .env.example .env       # then paste your ANTHROPIC_API_KEY
bin/rails db:setup         # creates DB, runs seeds (template + price book)
bin/dev                    # http://localhost:3000
```

Signup activation emails open automatically in your browser in development.

## Tests

```sh
bin/rails test         # models, controllers, pipeline (AI stubbed), mailers
bin/rails test:system  # full browser flow: signup → activate → estimate → CSV link
bin/rails test:all
```

No API key or network needed — the AI client is faked in tests and WebMock
blocks stray requests.

## Evaluating accuracy against real jobs

`eval/projects.yml` maps four historical projects (plan PDF + a baseline CSV of
the human estimate and actual job cost). Run the real pipeline against them:

```sh
bin/rails "estimator:evaluate[hilda]"   # one project (~3-10 min, real API usage)
bin/rails estimator:evaluate            # all projects
```

Reports the AI estimate vs the human estimate vs actual cost, percentage
error, whether the actual falls inside the AI's low/high range, and the
largest sections. Baselines were extracted from the job costing spreadsheets
(`eval/baselines/*.csv`).

## Price book & templates

- **Price Book** (in-app): searchable, editable unit rates. The estimator is
  grounded in these — keep them current as costs move.
- **Estimate template**: `EstimateTemplate` records hold the ordered section
  list (seeded as "Built Homes Standard", 40 sections mirroring your job
  costing reports). Add more templates via the console or seeds.

## Deployment (Kamal)

The app ships with the standard Rails 8 Dockerfile and Kamal config
(SQLite + Solid Queue running inside Puma — one container, no external
services).

1. Edit `config/deploy.yml`: server IP, registry, and `proxy.host`.
2. Make sure `ANTHROPIC_API_KEY` is exported in your shell (Kamal reads it via
   `.kamal/secrets`), along with your registry password.
3. Set `APP_HOST` and the `SMTP_*` variables (see `.env.example`) so
   activation emails send in production.
4. `kamal setup` (first time) / `kamal deploy`.

Seeds run automatically on `db:prepare` are **not** included — run once after
first deploy: `kamal app exec "bin/rails db:seed"`.

## Key code

| Piece | Where |
|---|---|
| AI client (Anthropic SDK wrapper) | `app/services/ai/client.rb` |
| Plan analysis | `app/services/plan_analyzer.rb` |
| Line item generation | `app/services/line_item_generator.rb` |
| Pipeline orchestration | `app/services/estimate_generator.rb` |
| CSV export | `app/services/estimate_csv.rb` |
| Background job | `app/jobs/generate_estimate_job.rb` |
| Accuracy evaluation | `lib/tasks/evaluate.rake`, `eval/` |
| Price book seed data | `db/seed_data/price_book.csv`, `db/seeds.rb` |
