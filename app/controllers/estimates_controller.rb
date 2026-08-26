class EstimatesController < ApplicationController
  before_action :set_estimate, only: %i[ show csv status regenerate answer_questions destroy ]

  PER_PAGE = 15

  def index
    scope = Current.user.estimates.recent_first
    scope = scope.where("name LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%") if params[:q].present?
    @total_count = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @total_pages = [ (@total_count / PER_PAGE.to_f).ceil, 1 ].max
    @page = @total_pages if @page > @total_pages
    @estimates = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def new
    @estimate = Current.user.estimates.new(estimate_template: EstimateTemplate.for_user(Current.user))
  end

  def create
    @estimate = Current.user.estimates.new(estimate_params)
    # estimate_template_id arrives from a form the user controls: only their
    # own agreed template and the shared default are theirs to build on.
    @estimate.estimate_template = nil unless EstimateTemplate.available_to(Current.user).include?(@estimate.estimate_template)
    @estimate.estimate_template ||= EstimateTemplate.for_user(Current.user)
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
    clarified = answered.map { |q| q.slice("question").merge("answer" => answers[q["id"].to_s].to_s.strip) }
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
    layout = personal_template
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
    @estimate = Current.user.estimates.find(params[:id])
  end

  # The builder's own layout, learned and agreed from their training uploads.
  def personal_template
    t = EstimateTemplate.for_user(Current.user)
    t&.personal? ? t : nil
  end

  def estimate_params
    params.require(:estimate).permit(:name, :prompt, :estimate_template_id, plans: [], questionnaire: {})
  end
end
