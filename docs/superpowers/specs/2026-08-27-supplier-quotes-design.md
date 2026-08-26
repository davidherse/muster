# Supplier quotes as inputs + round-2 calibration — design

Date: 2026-08-27. Approved in chat by David ("go"). Branch: `supplier-quotes` (from main after PR "edit brief & answers" merges).

## Problem

Builders hold supplier quotes for the big trades (cabinetry, tiling, painting,
air-conditioning) before they estimate. Muster prices those trades from rates
and allowances, so on Drayton v2 the three largest residual gaps (cabinetry
−$107k, tiling −$95k, painting −$73k) were all quoted trades. Uploading a
quote PDF today does nothing useful: the plan analyser extracts scope only,
and the generator never sees documents.

## Behaviour

- **Upload:** quote PDFs go in with the plans (same `plans` attachment; the
  New Estimate and Edit pages say "Plans, specifications and any supplier
  quotes (PDF)"). No new attachment type.
- **Analyser:** `PlanAnalyzer::SCHEMA` gains `supplier_quotes` — an array of
  `{ trade, supplier, amount_ex_gst, gst_status, includes, excludes, sections }`
  where `sections` are exact template section names the quote covers and
  `gst_status` is `ex_gst | inc_gst | unclear`. The user prompt tells the
  analyser to recognise a quote only when a named supplier prices a trade
  (a specification or drawing set is never a quote), to convert inc-GST totals
  to ex GST (÷1.1) and say so, and to list what the quote excludes. The
  verification pass checks `supplier_quotes` completeness.
- **Generator:** a new binding rule in `LineItemGenerator#instructions`:
  "QUOTED TRADES ARE BINDING: where the analysis lists a supplier quote
  covering a section, cost that section as ONE Sub line described
  `Quoted by <supplier> — <trade>` at the quoted ex-GST amount (quantity 1,
  uom Quoted, confidence high), plus only the builder-side items the quote
  EXCLUDES (e.g. tile supply when the tiler quotes labour only, delivery,
  attendance). Never re-price a quoted trade from rates, never add labour
  the quote already covers, and never mark a quoted section inapplicable."
  Emitted only when `@analysis["supplier_quotes"]` is non-empty, listing the
  quotes for the batch's sections.
- **Estimate page:** a line whose description starts with `Quoted by` gets a
  "quote" badge (`ui_badge(variant: :outline)`) after the description.
- **Brief-stated quotes still work** (the inclusions/PC path is unchanged).

## Round-2 calibration (same branch, from Drayton v2)

1. **Labourer weekly rate (data):** a console step on faber adds to the
   account book `Site Labourer per week (1 man)` — $773/week, category
   "Carpentry & General Labour", source `manual:drayton-calibration`,
   `source_kind: "user"`, context `{ project_class: "extension_and_renovation" }`.
   The crew rule text names it: "…plus a site labourer at the builder's own
   per-week labourer rate ('Site Labourer per week')".
2. **Supervision by duration (prompt):** when `duration_months` is stated and
   the book has a monthly supervision allowance, the Site Supervision section
   is costed as months × that monthly rate (not hours). Rule text added
   beside SUPERVISION ONCE.
3. **Premium repaint composite (data + code):** a base-book entry
   `Whole-house repaint composite - full repaint, premium finish (high-end /
   luxury spec) - per m² floor` at $300/m² (seeded in `db/seeds.rb` and
   inserted on faber via a console step); `repaint_class` returns
   "full repaint, premium finish" when the analysis `finish_level` is
   `high_end` or `luxury` (or the questionnaire finish level says High-end /
   Luxury) and the class would otherwise be the standard one. Heritage and
   raise classes are unchanged.
4. **Single-system air-conditioning (prompt):** "A stated single ducted
   system means ONE outdoor unit and its ducting/zoning — no additional
   ducted units or wall splits unless the brief or plans list them."

## Tests

- `PlanAnalyzerTest`: schema accepts `supplier_quotes`; `FakeAiClient`'s
  default analysis gains an empty `supplier_quotes` array and a helper to
  return one quote; the verification prompt mentions supplier_quotes.
- `LineItemGeneratorTest`: rule present only with quotes; rule text names the
  supplier, amount and sections for a quote covering a batch section; absent
  otherwise. Premium repaint class cases (high_end → premium; standard →
  standard; heritage unchanged). Supervision-by-duration and single-system
  rule strings present.
- `EstimateGeneratorTest`: with `FakeAiClient` returning a quote, an
  end-to-end run produces a `Quoted by` Sub line in the covered section
  (extend `sections_response` to honour a quote when the section is listed).
- Controller/view: a `Quoted by …` line renders the badge.
- Seeds: `db/seeds.rb` premium composite present; `rails db:seed` idempotent.

## Deploy

Merge → faber pull → seed the premium composite → add the labourer book
entry → restart → re-run Drayton as v3 with the same PDFs plus the quote
PDFs David has (cabinetry, tiling, painting, air-con, if available), and
compare v3 to the human sheet.

## Out of scope

Line-by-line quote parsing, quote validity/expiry, a separate attachments
type for quotes, per-section quote overrides in the UI.
