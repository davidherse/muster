class EstimatesController < ApplicationController
  before_action :set_estimate, only: %i[ show edit update csv status regenerate answer_questions destroy ]
  before_action :require_editable!, only: %i[ edit update ]

  PER_PAGE = 15

  def index
    scope = Current.account.estimates.recent_first.includes(:user)
    scope = scope.where("name LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%") if params[:q].present?
    @total_count = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @total_pages = [ (@total_count / PER_PAGE.to_f).ceil, 1 ].max
    @page = @total_pages if @page > @total_pages
    @estimates = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def new
    @estimate = Current.account.estimates.new(user: Current.user, estimate_template: EstimateTemplate.for_account(Current.account))
  end

  def create
    @estimate = Current.account.estimates.new(estimate_params.merge(user: Current.user))
    # estimate_template_id arrives from a form the user controls: only their
    # account's agreed template and the shared default are theirs to build on.
    @estimate.estimate_template = nil unless EstimateTemplate.available_to(Current.account).include?(@estimate.estimate_template)
    @estimate.estimate_template ||= EstimateTemplate.for_account(Current.account)
    if @estimate.plans.attached? && @estimate.save
      @estimate.processing!("Queued for analysis…")
      GenerateEstimateJob.perform_later(@estimate)
      redirect_to @estimate, notice: "Your estimate is being generated. This can take a few minutes."
    else
      @estimate.errors.add(:plans, "must be attached") unless @estimate.plans.attached?
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def edit
    @sections = @estimate.template_section_names
    @answered = Array(@estimate.clarifications)
    @skipped = Array(@estimate.open_questions).select { |q| q["skipped"] }
  end

  # Save brief/questionnaire/answers and re-cost only what changed — never
  # re-analyse. The re-cost set is the submitted checklist when the form
  # sent one, else computed from what changed.
  def update
    @estimate.assign_attributes(brief_params)
    # The name never affects pricing; the brief text and questionnaire do.
    brief_changed = @estimate.will_save_change_to_prompt? || @estimate.will_save_change_to_questionnaire?

    affected = []
    answers = params.fetch(:clarifications, {}).permit!.to_h
    clarifications = Array(@estimate.clarifications).each_with_index.map do |c, i|
      next c unless answers.key?(i.to_s)
      answer = answers[i.to_s].to_s.strip
      next c if answer == c["answer"].to_s || answer.blank?
      affected.concat(c["sections"].presence || @estimate.template_section_names)
      c.merge("answer" => answer)
    end
    skipped_answers = params.fetch(:skipped_answers, {}).permit!.to_h
    open = Array(@estimate.open_questions).reject do |q|
      answer = skipped_answers[q["id"].to_s].to_s.strip
      next false if answer.blank?
      clarifications << q.slice("question", "sections").merge("answer" => answer)
      affected.concat(Array(q["sections"]).presence || @estimate.template_section_names)
      true
    end
    @estimate.assign_attributes(clarifications: clarifications, open_questions: open)

    unless @estimate.save
      @sections = @estimate.template_section_names; @answered = clarifications; @skipped = open.select { |q| q["skipped"] }
      return render :edit, status: :unprocessable_entity
    end

    computed = brief_changed ? @estimate.template_section_names : affected.uniq
    chosen = params[:recost_submitted].present? ? Array(params[:recost_sections]) : computed
    @estimate.reapply_questionnaire_overrides! if brief_changed
    scheduled = @estimate.recost!(chosen)
    if scheduled.empty?
      redirect_to @estimate, notice: "Saved. Nothing re-costed."
    else
      GenerateEstimateJob.perform_later(@estimate, resume: true)
      redirect_to @estimate, notice: "Re-costing #{scheduled.size} #{'section'.pluralize(scheduled.size)}…"
    end
  end

  def status
    render json: { status: @estimate.status, progress: @estimate.progress, note: @estimate.progress_note }
  end

  # The questions wizard submits all answers at once. Answered questions bind
  # as clarified scope and their sections re-cost in ONE resume run; anything
  # left blank is marked skipped and never gates or re-asks again.
  def answer_questions
    return redirect_to(@estimate, alert: "The estimate is currently generating.") if @estimate.processing? && !@estimate.generation_stalled?
    answers = params.fetch(:answers, {}).permit!.to_h

    answered, skipped = Array(@estimate.open_questions).partition { |q| answers[q["id"].to_s].to_s.strip.present? }
    clarified = answered.map { |q| q.slice("question", "sections").merge("answer" => answers[q["id"].to_s].to_s.strip) }
    @estimate.update!(
      clarifications: Array(@estimate.clarifications) + clarified,
      open_questions: skipped.map { |q| q.merge("skipped" => true) }
    )
    return redirect_to(@estimate, notice: "No problem — here's the estimate as it stands.") if answered.empty?

    affected = @estimate.sections.where(name: answered.flat_map { |q| Array(q["sections"]) }.uniq)
    @estimate.update!(costed_sections: @estimate.costed_sections - affected.map(&:name))
    affected.destroy_all
    @estimate.update!(status: "processing", error_message: nil,
      progress_note: "Improving the estimate with your #{answered.size} answer#{'s' if answered.size > 1}…")
    GenerateEstimateJob.perform_later(@estimate, resume: true)
    redirect_to @estimate, notice: "Answers locked in — improving the estimate."
  end

  def regenerate
    # Only a genuinely live run is untouchable: a stalled one (its worker died,
    # and Solid Queue never re-dispatches it) must be retryable from the UI.
    return redirect_to(@estimate, alert: "This estimate is already being generated.") if @estimate.processing? && !@estimate.generation_stalled?
    resume = params[:resume].present? && (@estimate.failed? || @estimate.generation_stalled?) && @estimate.plan_summary.present?
    if resume
      @estimate.update!(status: "processing", error_message: nil, progress_note: "Resuming…")
    else
      @estimate.processing!("Queued for analysis…")
    end
    GenerateEstimateJob.perform_later(@estimate, resume: resume)
    redirect_to @estimate, notice: resume ? "Resuming the estimate from where it stopped." : "Regenerating the estimate."
  end

  # One export that does the right thing: the builder's own layout when they
  # have an agreed template, the standard layout otherwise. No export while
  # clarifying questions still gate the number.
  def csv
    return redirect_to(@estimate, alert: "The estimate isn't ready yet.") unless @estimate.completed?
    return redirect_to(@estimate, alert: "Answer or skip the open questions first — the number isn't final yet.") if @estimate.needs_answers?
    layout = account_template
    send_data EstimateCsv.new(@estimate, layout: layout).generate,
      filename: "#{@estimate.name.parameterize}-estimate.csv",
      type: "text/csv"
  end

  def destroy
    @estimate.destroy
    redirect_to estimates_path, notice: "Estimate deleted."
  end

  private

  def set_estimate
    @estimate = Current.account.estimates.find(params[:id])
  end

  # The account's own layout, learned and agreed from their training uploads.
  def account_template
    t = EstimateTemplate.for_account(Current.account)
    t&.account? ? t : nil
  end

  def estimate_params
    params.require(:estimate).permit(:name, :prompt, :estimate_template_id, plans: [], questionnaire: {})
  end

  def require_editable!
    editable = @estimate.plan_summary.present? && !(@estimate.processing? && !@estimate.generation_stalled?)
    redirect_to @estimate, alert: "This estimate can't be edited right now." unless editable
  end

  def brief_params
    params.require(:estimate).permit(:name, :prompt, questionnaire: {})
  end
end
