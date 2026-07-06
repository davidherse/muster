# Keeping the Price Book Current — Source Options

Researched July 2026. The price book has three layers, freshest wins:

1. **User price book** (`source_kind: "user"`, per-user) — built from the
   builder's own uploaded estimates via Training (see below). Their real
   rates, with questionnaire context recording what "high-end" etc. meant on
   each source job. Preferred whenever a comparable exists.
2. **Base price book** (`source_kind: "base"`) — the shared historical book,
   kept current by index escalation (automated, free) or a subscription feed.
3. **Model market knowledge** — fallback when neither book has a comparable.

## Itemised data feeds (subscription)

| Source | What | Fit |
|---|---|---|
| [Cotality (CoreLogic) Cordell Construction Cost API](https://www.corelogic.com.au/software-solutions/construction-api) | Itemised install/material/plant/sub rates, AU+NZ, delivered via API | The purpose-built option. Implement a `PriceSources::Cordell` adapter if subscribed; map items into `source_kind: "base"` entries with provenance. |
| [Rawlinsons](https://www.rawlhouse.com.au/) | 22,000+ items, regional pricing, annual guide + quarterly updates | Platform/publication licence; no public API — dataset import per licence terms. |

## Index escalation (free, automated — implemented)

Without an itemised feed, base-book rates stay current by escalating with the
[ABS Producer Price Indexes](https://www.abs.gov.au/statistics/economy/price-indexes-and-inflation/producer-price-indexes-australia/latest-release)
(inputs to house construction, quarterly; free API key via the
[ABS Indicator/Data API](https://www.abs.gov.au/about/data-services/application-programming-interfaces-apis/indicator-api),
or CSV from [data.gov.au](https://data.gov.au/data/dataset/producer-price-indexes-by-industry)).
The Cordell [CCCI quarterly index](https://www.cotality.com/au/resources/downloads/cordell-construction-cost-index-ccci)
is a free cross-check.

`bin/rails estimator:escalate_prices[percent]` applies a quarterly escalation
to base-book entries and records it in each item's source note. Run it when
the ABS quarterly PPI lands (or wire the ABS API key into a scheduled job).

Deliberately avoided: scraping retailer sites (Bunnings/Reece etc.) — against
their terms and brittle.

## Training uploads (user layer)

Builders upload past estimates (PDF or spreadsheet) and answer the same
clarification questionnaire used for new estimates. Ingestion extracts
sections and unit rates into their user price book with the questionnaire
context attached — so the estimator knows what that builder's "high-end,
sloped block, full repaint" actually costs, benchmarked from their own work.

## Market tier (implemented July 2026)

`PriceBookItem.source_kind = "market"` — published, citable references below
user and base books in preference order. Currently sourced from the
**Archicentre Australia Cost Guide** (free, published annually by the
architects' body): wet-area/renovation composites plus ~25 trade rates,
converted to ex-GST, each entry carrying `band_low`/`band_high` and a
consumer-price caveat in context. Refresh on each edition:

    bin/rails estimator:ingest_market

Used three ways: scoped advisory reference in costing batches (only where
neither book answers), a listed reference block in review passes, and
computed per-room band violations on partial jobs (above the published
standard-finishes top requires documented premium spec; under half the
floor is implausibly thin). The Cordell/Cotality Construction API
(REST + OAuth2, contact-sales) is the item-level upgrade path — it would
populate this same tier programmatically on a cron.
