# Estimator Accuracy — Method and Results

Last updated: July 2026, after five system iterations evaluated against four
historical Built Homes projects.

## Method

- Ground truth: the four job costing spreadsheets (Hilda, Constitution,
  Benecia, Carberry). Per-category actuals live in `eval/baselines/*.csv`.
- The estimator prices in current (2026) dollars; each job's actual is in its
  own cost-base dollars. For scoring, AI totals are deflated by the same
  escalation factors used to index the price book (`eval/projects.yml`).
- Prompts are the builder's real briefs, verbatim.
- Integrity rule for all tuning: no per-project logic, no percentage targets
  derived from the known answers. Every change had to be justifiable as
  generic estimating discipline before its effect on the numbers was known.
- Run-to-run variance on identical config is material: ±5–6 points on a
  single project. Single-run comparisons under ~10 points are noise.

## Production configuration (result of the iterations)

1. **Plan analysis** extracts QS takeoff quantities, not just narrative:
   paint areas scoped to work actually being done, window/door schedule
   notes, construction duration reasoned stage by stage, deck areas, finish
   level, retained-scope notes, and explicit special features.
2. **Line item generation** must derive quantities from that geometry:
   painting priced as painter-hours (how the price book carries the trade),
   windows taken off per opening, preliminaries itemised with supervision
   hours x duration (no percentage targets), hire scaled by duration.
3. **Review pass** (`EstimateReviewer`) re-checks the finished estimate
   against the scope analysis in both directions (thin and padded), fed with
   computed intensity metrics ($/m² floor, paint $/m², $/opening, supervision
   hours/week). Corrections are annotated into line item assumptions.

Rejected on evidence: percentage-of-total anchors for preliminaries
(iteration 1: fixed the big job, +21 points on the control) and published
market-rate ranges in the review pass (iterations 4–5: caused range-seeking
top-ups on in-range sections).

## Results (production config, deflated to job-year dollars)

| Project | AI estimate | Reality | Error | Actual in range? |
|---|---|---|---|---|
| Hilda | $736,141 | $704,860 actual | +4.4% | yes |
| Benecia | $1,021,723 | $1,041,897 actual | −1.9% | yes |
| Carberry | $964,951 | $1,043,659 human est. (no actuals) | −7.5% | yes |
| Constitution | $1,189,881 | $1,500,955 actual | −20.7% | no |

Mean absolute error: **8.6%** (baseline config before iterations: ~10%, with
Constitution at −30% and outside its range).

### The Constitution caveat

Constitution resists plan-based estimation: its actuals overran even the
builder's own quote (−5.9%, vs −0.9% and −0.2% on Hilda/Benecia), and the
persistent AI shortfall concentrates in character-work intensity (painting
priced ~$50/m² where the job ran ~$118/m² effective) plus supervision hours.
Versus the builder's own plan-based estimate the AI is −15.7%. Treat
heavy-character, high-glazing jobs as the estimator's weak class and review
painting and preliminaries manually there.

## Prompt experiments (same Hilda plans, three brief levels)

| Brief | Error vs actual |
|---|---|
| No prompt (plans only) | +10.8% |
| One-liner (type, area, finish level) | +12.3% |
| Full brief (real one) | +4.4% (repeat runs +10.6/+15.8 on variant configs) |

Within run variance, the **total** barely moves with prompt detail — the
plans dominate quantity extraction. What the brief demonstrably changes is
**scope correctness**, not arithmetic: exclusions ("pool excluded, by
others"), inclusions not drawn (solar + battery, shutters), site conditions
(asbestos, P-class soil), and finish level all flowed into the right line
items in every run that supplied them. Brief-writing guidance:

- Always state: exclusions, non-drawn inclusions, site/soil conditions,
  asbestos, finish level, and anything retained that drawings might imply is
  new (or vice versa).
- Don't bother restating what the plans already show (areas, room lists,
  storeys) — the analysis reads schedules reliably.

### Enriched-brief experiment (character renovations)

Adding three walkthrough-knowledge sentences to the briefs — no prices, no
totals — moved both character jobs into range:

| Project | Standard brief | + repaint extent, duration, latent conditions |
|---|---|---|
| Constitution | −20.7%, actual OUT of range | **−13.0%, actual IN range** |
| Carberry | −7.5% | **−2.8%** |

The sentences that matter for a character reno brief:
1. Repaint extent: "full prep-heavy heritage repaint inside and out including
   all retained VJ/fretwork/trim — not just the new work" (drawings show the
   linings but not the repaint intent).
2. Duration: "expect a 13–15 month build with continuous site supervision"
   (the model guesses short otherwise; drives prelims and hire).
3. Latent conditions: "pre-1947 structure — allow for latent conditions"
   (standard practice; plans never show it).

Composition caveat: on Constitution the enriched brief overcooked prelims
(~$199k vs ~$124k indexed actual) while painting stayed light (~$107k vs
~$197k) — the total is right partly by offset, so still sanity-check those
two sections manually on heavy-character jobs.

## Validation v2 — painting composites + enriched standard briefs

After adding historical whole-house painting composites to the price book
($159–493 per m² floor by repaint extent, derived from the four jobs) and
making the enriched briefs standard (`eval/projects.yml`), all four projects
land IN RANGE for the first time:

| Project | Error | In range? | Note |
|---|---|---|---|
| Carberry | +1.1% | yes | from −7.5% |
| Hilda | +5.7% | yes | selective-repaint line kept composites honest |
| Constitution | −13.5% | yes | painting improved ($114k) but still under its $197k |
| Benecia | +14.6% | yes | overshoot from prudent duration/latent allowances a clean job never consumed |

Mean absolute error 8.7%; the distribution now skews slightly conservative —
the enriched briefs include allowances (latent conditions, full durations)
that consumed actuals only sometimes reflect. That is quote-basis behaviour,
not error, but it means: **strip visible allowance lines when comparing to
lean actuals.** Line item generation now requires risk allowances to be
explicit, labelled line items so they can be seen and stripped.

The questionnaire (new-estimate form) captures these movers per job:
finish level, repaint extent, duration, era/latent risk, asbestos,
structural and site conditions, services scope, inclusions/exclusions.

## Reproducing

```sh
bin/rails "estimator:evaluate[hilda]"    # one project
bin/rails estimator:evaluate             # all four (real API spend)
```

For quoting-critical estimates, consider running twice and comparing —
run-to-run variance is real, and two runs bracket the answer cheaply.
