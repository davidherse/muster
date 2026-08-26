# Edit brief & answers without re-analysing — design

Date: 2026-08-27. Approved in chat by David. Branch: `edit-brief-and-answers`.

## Problem

After an estimate is generated, the only ways to change anything are the
one-shot questions wizard (answers can't be revisited) or **Regenerate**,
which re-runs the plan analysis — the single most expensive AI step (a
two-pass read of every uploaded PDF). David wants to go back and adjust his
answers and the original brief/questionnaire, and pay only for re-costing
the sections that change.

## Behaviour

An **Edit brief & answers** page on a generated estimate (`GET /estimates/:id/edit`,
`PATCH /estimates/:id`), reachable from a button beside "Regenerate estimate".
Available only when the estimate has a stored plan analysis (`plan_summary`)
and is not currently generating (a stalled run counts as not generating).

The page has three blocks:

1. **Original details** — name, free-text brief (`prompt`), and the
   questionnaire (the same `shared/questionnaire_fields` partial as New
   Estimate, pre-filled).
2. **Your answers** — every clarification (question + editable answer) and
   every skipped question (question + empty answer box, so it can be answered
   after all).
3. **What gets re-costed** — a checklist of the template's sections. A small
   Stimulus controller ticks sections as the user edits: an answer field ticks
   the sections its question belongs to; any change to name/brief/questionnaire
   ticks all sections. "Tick all" / "Tick none" links. Nothing is ticked on
   load.

**Saving:**

- Name, brief, questionnaire, and answers are stored.
- Changed answers keep their question's `sections`. Answering a skipped
  question moves it from `open_questions` to `clarifications` (with its
  sections).
- Re-cost set = the submitted checklist when the form sent one (a hidden
  `recost_submitted=1` marks that the checklist was present, so an empty
  selection means "save only"); otherwise the server's computed default —
  all sections if the brief/questionnaire changed, else the union of the
  changed answers' sections (answers without stored sections count as "all").
- If the questionnaire changed, the questionnaire overrides (project type,
  works area) are re-applied to the **stored** analysis in place — no AI
  call.
- If the re-cost set is non-empty: those sections' rows are deleted, their
  names removed from `costed_sections`, status → `processing` with note
  "Re-costing N sections…", and `GenerateEstimateJob` is enqueued with
  `resume: true`. The generator's existing resume path costs only the
  uncosted sections against the stored analysis, then re-runs the review and
  totals. The questions gate is **not** re-opened (harvest runs only when
  there are no clarifications and no open questions, as today).
- If the re-cost set is empty: redirect with "Saved. Nothing re-costed."

## Model changes

- `clarifications` entries gain `"sections" => [...]`; `answer_questions`
  stores `q.slice("question", "sections")`. Existing entries without
  `sections` are treated as affecting all sections.
- `Estimate#apply_questionnaire_overrides(analysis)` — moved from
  `EstimateGenerator` (which delegates to it). It strips any existing
  "BUILDER-CONFIRMED PROJECT TYPE: …" prefix before prepending, so
  re-applying is idempotent.
- `Estimate#reapply_questionnaire_overrides!` — deep-dups `plan_summary`,
  applies overrides, saves `plan_summary` and `floor_area`. No-op without a
  stored analysis.
- `Estimate#recost!(section_names)` — filters to the template's section
  names, destroys those `sections`, removes them from `costed_sections`, sets
  status/progress note. Returns the names actually scheduled. Used by
  `update` (and `answer_questions` keeps its current behaviour).

## Controller

`EstimatesController#edit` / `#update` (routes already exist from
`resources :estimates`). `set_estimate` scopes to `Current.account`. Both
refuse with a redirect + alert when `plan_summary` is blank or the estimate
is generating (`processing? && !generation_stalled?`).

Strong params: `params.require(:estimate).permit(:name, :prompt, questionnaire: {})`;
`params.fetch(:clarifications, {}).permit!` (index ⇒ answer);
`params.fetch(:skipped_answers, {}).permit!` (question id ⇒ answer);
`params[:recost_sections]` (array of names) with `params[:recost_submitted]`.

## View

`app/views/estimates/edit.html.erb` with the three blocks; a new Stimulus
`recost_controller` (targets: `section` checkboxes with `data-section`;
actions: `touch` on inputs carrying `data-recost-sections="A|B"` or `"*"`,
`all`, `none`). Show page: "Edit brief & answers" link beside Regenerate when
`plan_summary` is present.

## Tests

- Model: overrides idempotent (prefix not duplicated); `reapply…!` updates
  `plan_summary["project_class"]`/`floor_area` and is a no-op without
  analysis; `recost!` removes rows/markers and ignores unknown names.
- Controller: edit renders pre-filled (name, prompt, a questionnaire value,
  an answer, a skipped question, the checklist); update name only → saved,
  no job; changed answer → its sections deleted and removed from
  `costed_sections`, job enqueued `resume: true`, other sections untouched;
  questionnaire change → all sections re-cost and `plan_summary` override
  re-applied with no analysis call; answering a skipped question moves it;
  submitted checklist wins (including empty = save only); refused while
  generating; other account → 404; answers keep `sections` from the wizard.

## Out of scope

Changing the template on an existing estimate, edit history/undo, re-running
the plan analysis alone, re-opening the questions gate.
