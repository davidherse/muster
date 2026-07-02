class EstimatesController < ApplicationController
  before_action :set_estimate, only: %i[ show csv status regenerate destroy ]

  def index
    @estimates = Current.user.estimates.recent_first
  end

  def new
    @estimate = Current.user.estimates.new(estimate_template: EstimateTemplate.default)
  end

  def create
    @estimate = Current.user.estimates.new(estimate_params)
    @estimate.estimate_template ||= EstimateTemplate.default
    if @estimate.plan.attached? && @estimate.save
      @estimate.processing!("Queued for analysis…")
      GenerateEstimateJob.perform_later(@estimate)
      redirect_to @estimate, notice: "Your estimate is being generated. This can take a few minutes."
    else
      @estimate.errors.add(:plan, "must be attached") unless @estimate.plan.attached?
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def status
    render json: { status: @estimate.status, progress: @estimate.progress, note: @estimate.progress_note }
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
    send_data EstimateCsv.new(@estimate).generate,
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

  def estimate_params
    params.require(:estimate).permit(:name, :prompt, :plan, :estimate_template_id, questionnaire: {})
  end
end
