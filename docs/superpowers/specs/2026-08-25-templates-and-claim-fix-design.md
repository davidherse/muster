# Templates page and estimate-claim fix — design

Date: 2026-08-25. Approved in chat by David.

Two pieces of work on one branch (`templates-and-claim-fix`):

- **A.** Fix the bug where every freshly created estimate fails with
  "This estimate is already being generated."
- **B.** A Templates page so a user can view and adjust their estimate
  template after onboarding.

## A. Estimate claim fix

### Problem

`EstimatesController#create` (and `#regenerate` without resume) marks the
estimate `processing` so the show page starts polling, then enqueues
`GenerateEstimateJob`. `EstimateGenerator#call` opens with an advisory claim
(added in e7eccdd) that refuses when `status == "processing"`. The controller's
UI state and the generator's ownership signal are the same column, so the
claim always refuses the real entry path. The generator's rescue marks the
estimate failed with the refusal text; the AI is never called. Only the
resume paths (questions wizard, "Try again") work, because they bypass the
claim.

### Change

- Migration: `add_column :estimates, :claimed_at, :datetime`.
- `EstimateGenerator#call`:
  - Fresh run: inside the existing `with_lock`, refuse if `claimed_at` is
    present; otherwise set `claimed_at: Time.current, status: "processing"`.
    The refusal message is unchanged.
  - Resume run: inside a lock, set `claimed_at` without refusing (so a fresh
    call cannot race a resume). Behaviour otherwise unchanged.
  - `ensure` at the end of `call` clears `claimed_at` — success, failure and
    refusal all release the claim.
- Controller unchanged: it keeps `processing!("Queued for analysis…")` for
  the UI; its `processing?` guards on regenerate/answer_questions stay.
- Crash semantics are unchanged from today: a killed process leaves the
  claim set; when Solid Queue re-runs the job it is refused, the estimate is
  marked failed, and "Try again" resumes.

### Tests (written first)

- `EstimateGeneratorTest`:
  - an estimate the controller just marked `processing!` is not refused;
  - a second fresh call while `claimed_at` is set raises
    `Ai::Client::Error` with the existing message and marks the estimate
    failed;
  - a resume run with `claimed_at` set succeeds;
  - `claimed_at` is nil after a completed run and after a failed run.
- `EstimatesControllerTest`: `post /estimates` then `perform_enqueued_jobs`
  with the fake AI client → estimate ends `completed`, not `failed`.

## B. Templates page

### Scope

- Users can see their personal template and the shared default, edit the
  one they are allowed to edit, and re-derive a proposal from training
  documents with a review step.
- One personal template per user (unchanged: `activate!` supersedes any
  other personal template).
- Edits affect future generations and Regenerate only; existing estimates
  keep their snapshotted sections.

### Routes and navigation

```ruby
resources :templates, only: %i[ index edit update ] do
  collection do
    post :customise   # copy the default into a new personal template
    post :rederive    # enqueue SynthesizeTemplateJob for Current.user
    post :accept      # activate the pending proposal
    delete :discard   # destroy the pending proposal
    get  :status      # JSON for polling while synthesis runs
  end
end
```

Sidebar gains "Templates" between Estimates and Training.

### Authorisation

- Personal template (`user_id` present): owner only.
- Global default (`user_id` nil): admins only. Non-admins see it read-only.
- Any other case: redirect to `templates_path` with an alert, matching the
  Price Book pattern.

### Index

Cards, in order:

1. **Your template** — the user's active personal template, if any: name,
   section count, Edit link. If none: explanation and a **Customise the
   default** button (only when no personal template exists).
2. **Built Homes Standard** (the global default): name, section count; Edit
   for admins, read-only otherwise.
3. **Proposed template** — shown only when `EstimateTemplate.proposed` exists
   for the user: the same section list as onboarding renders, with
   **Accept** (calls `activate!`, sets nothing else) and **Discard**.
4. **Re-derive from training documents** — button, enabled only when the
   user has at least one completed training document. Enqueues
   `SynthesizeTemplateJob`; the page shows a polling card (reusing the
   `poll` Stimulus controller against `templates/status`) until a proposal
   appears, then reloads.

`status` JSON: `{ status: "ready" | "processing", progress:, note: }` with
the same shape as `onboarding#status`.

### Edit form

`form_with model: @template, url: template_path(@template)`.

- `template[name]` text field.
- One row per section, rendered from `@template.sections`, fields:
  `template[sections][][name]`, `template[sections][][hint]`,
  `template[sections][][typical_items]` (textarea, one item per line).
- Row controls via a new Stimulus `sections_controller`: add row (clones a
  `<template>` element), remove row, move up, move down. Without JS the
  form still submits existing rows.
- Save redirects to `templates_path` with a notice; errors re-render with
  the standard alert block.

### Model

`EstimateTemplate`:

- Instance setter `sections_form=(rows)`: drops rows with a blank name,
  strips strings, splits `typical_items` on newlines and drops blanks,
  preserves order, and assigns the result to `sections`. Produces the same
  `{ "name", "hint", "typical_items" }` hashes the synthesizer writes.
- Validation: every section has a non-blank name (`sections` presence
  already exists).
- `self.available_to(user)`: the user's active personal template (if any)
  plus the global active default — used by the new-estimate dropdown, which
  today lists every template in the database, including other users' and
  unagreed proposals.
- `customise_for(user)` on the default: creates an active personal template
  for `user` with a copy of the default's sections, named
  "<user name> — <default name>". Refuses (returns nil) if the user already
  has a personal template.

### Controller

`TemplatesController` with `index`, `edit`, `update`, `customise`,
`rederive`, `accept`, `discard`, `status`. `set_template` +
`authorise_edit!` before `edit`/`update`. Strong params:
`params.expect(template: [ :name, sections: [ [ :name, :hint, :typical_items ] ] ])`
— then normalised via the model.

### Tests

- `TemplatesControllerTest`: requires auth; index shows personal + default;
  index shows proposal with accept/discard; edit own personal OK; edit
  another user's personal → redirected; edit global as admin OK; edit global
  as non-admin → redirected; update normalises rows (blank row dropped,
  typical items split); update with all-blank names re-renders 422;
  customise creates a personal copy and refuses when one exists; accept
  activates the proposal; discard destroys it; rederive enqueues
  `SynthesizeTemplateJob` and refuses without completed training docs.
- `EstimateTemplateTest`: `available_to` scoping; `customise_for`;
  section normalisation and validation.
- `EstimatesControllerTest`: new-estimate dropdown lists only templates
  available to the user.

### Out of scope

- Multiple personal templates, template versioning, drag-and-drop ordering,
  editing typical items with prices, changes to the onboarding wizard's own
  screens beyond what the shared model helpers touch.

## Delivery

TDD throughout; full suite green before each commit. Commits, in order:

1. Root redirect (`PagesController#home`: logged-out → sign-in, logged-in →
   estimates) — currently an uncommitted edit on the server's deploy clone.
2. Claim fix (migration + generator + tests).
3. Templates page (model, routes, controller, views, Stimulus, tests).

Push the branch, open a PR against `main`, then deploy the branch to
`~/muster` on faber (checkout, `db:migrate`, `assets:precompile`, restart
`muster-web` and `muster-jobs`) so it is live before merge.
