# The clarification questionnaire shown when creating an estimate. Every
# question here is evidence-backed: it captures information that measurably
# moved estimates against historical actuals (see docs/ACCURACY.md) and that
# plans alone cannot supply.
module EstimateQuestionnaire
  QUESTIONS = [
    {
      key: "finish_level",
      label: "Finish level",
      type: :select,
      options: [ "Standard", "High-end", "Luxury" ],
      hint: "Drives joinery, fixtures, tiling and glazing rates.",
      prompt_label: "Finish level"
    },
    {
      key: "repaint_extent",
      label: "Repaint extent",
      type: :select,
      options: [
        "New work only",
        "New work plus touch-ups (retained areas untouched)",
        "Full internal repaint",
        "Full repaint inside and out, incl. retained linings (VJ, trim, fretwork)"
      ],
      hint: "The single biggest painting cost driver — historical jobs ranged $159–493 per m² of floor area by extent.",
      prompt_label: "Repaint extent"
    },
    {
      key: "duration_months",
      label: "Expected build duration (months)",
      type: :number,
      hint: "Leave blank to let the estimator judge. Drives preliminaries, supervision and hire.",
      prompt_label: "Expected build duration (months)"
    },
    {
      key: "building_era",
      label: "Building era",
      type: :select,
      options: [ "Pre-1946 character home", "1946–1990", "Post-1990", "New build" ],
      hint: "Older structures carry latent-conditions risk and asbestos likelihood.",
      prompt_label: "Building era"
    },
    {
      key: "asbestos",
      label: "Asbestos",
      type: :select,
      options: [ "None present", "Present — removal required", "Unknown — allow for testing" ],
      prompt_label: "Asbestos"
    },
    {
      key: "structural_work",
      label: "Structural work",
      type: :multi,
      options: [ "House raise / restumping", "Build-in-under", "New slab or extension footprint",
                 "Retaining walls", "New pool", "Existing pool retained" ],
      prompt_label: "Structural work"
    },
    {
      key: "site_conditions",
      label: "Site conditions",
      type: :multi,
      options: [ "Sloped block", "Difficult access", "Reactive / P-class soil", "Flat, straightforward site" ],
      prompt_label: "Site conditions"
    },
    {
      key: "services_scope",
      label: "Electrical & plumbing scope",
      type: :select,
      options: [ "Full rewire and replumb", "Partial upgrade plus new work", "New work only" ],
      prompt_label: "Electrical & plumbing scope"
    },
    {
      key: "inclusions",
      label: "Inclusions not on the drawings",
      type: :text,
      hint: "e.g. solar + battery, plantation shutters, ducted A/C, landscaping, appliances.",
      prompt_label: "Include (not drawn)"
    },
    {
      key: "exclusions",
      label: "Exclusions (by others / out of scope)",
      type: :text,
      hint: "e.g. pool by others, landscaping excluded, owner-supplied appliances.",
      prompt_label: "Excluded"
    }
  ].freeze

  # Renders answered questions as a block for the AI's brief. Unanswered
  # questions are omitted — the estimator uses its own judgement for those.
  def self.to_prompt(answers)
    return nil if answers.blank?

    lines = QUESTIONS.filter_map do |q|
      value = answers[q[:key]]
      value = Array(value).reject(&:blank?).join(", ") if q[:type] == :multi
      next if value.blank?
      "- #{q[:prompt_label]}: #{value}"
    end
    return nil if lines.empty?

    "BUILDER'S CLARIFICATIONS (answers to the estimating questionnaire):\n#{lines.join("\n")}"
  end
end
