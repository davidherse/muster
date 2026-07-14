class EstimatesController < ApplicationController
  before_action :set_estimate, only: %i[ show csv status regenerate answer_question destroy ]

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

  # Answering a clarifying question binds the answer and re-costs only the
  # sections it affects (the resume machinery re-costs whatever is missing
  # from costed_sections, then re-reviews).
  def answer_question
    return redirect_to(@estimate, alert: "The estimate is currently generating.") if @estimate.processing?
    question = Array(@estimate.open_questions).find { |q| q["id"].to_s == params[:question_id].to_s }
    answer = params[:answer].to_s.strip
    return redirect_to(@estimate, alert: "Pick a question and give an answer.") if question.nil? || answer.blank?

    @estimate.update!(
      clarifications: Array(@estimate.clarifications) + [ question.slice("question").merge("answer" => answer) ],
      open_questions: Array(@estimate.open_questions) - [ question ]
    )
    affected = @estimate.sections.where(name: Array(question["sections"]))
    @estimate.update!(costed_sections: @estimate.costed_sections - affected.map(&:name))
    affected.destroy_all
    @estimate.update!(status: "processing", error_message: nil, progress_note: "Re-costing #{question['sections'].to_a.join(', ')}…")
    GenerateEstimateJob.perform_later(@estimate, resume: true)
    redirect_to @estimate, notice: "Answer locked in — re-costing the affected sections."
  end

  def regenerate
    return redirect_to(@estimate, alert: "This estimate is already being generated.") if @estimate.processing?
    resume = params[:resume].present? && @estimate.failed? && @estimate.plan_summary.present?
    if resume
      @estimate.update!(status: "processing", error_message: nil, progress_note: "Resuming…")
    else
      @estimate.processing!("Queued for analysis…")
    end
    GenerateEstimateJob.perform_later(@estimate, resume: resume)
    redirect_to @estimate, notice: resume ? "Resuming the estimate from where it stopped." : "Regenerating the estimate."
  end

  def csv
    return redirect_to(@estimate, alert: "The estimate isn't ready yet.") unless @estimate.completed?
    layout = personal_template if params[:layout] == "mine"
    send_data EstimateCsv.new(@estimate, layout: layout).generate,
      filename: "#{@estimate.name.parameterize}-estimate#{layout ? '-my-format' : ''}.csv",
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
