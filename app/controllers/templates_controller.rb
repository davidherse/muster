# Where a workspace sees and adjusts the template its estimates are built on:
# the account's agreed template, the shared default, and any AI-derived
# proposal awaiting review. Editing is account-only for an account's own
# template and admin-only for the shared default.
class TemplatesController < ApplicationController
  REDERIVE_WINDOW = 10.minutes

  before_action :set_template, only: %i[ edit update ]
  before_action :authorise_edit!, only: %i[ edit update ]

  def index
    @account_template = EstimateTemplate.active_for(Current.account)
    @default = EstimateTemplate.default
    @proposal = EstimateTemplate.proposal_for(Current.account)
    @completed_docs = Current.account.training_documents.where(status: "completed").count
    @deriving = Current.account.training_documents.where(status: %w[pending processing]).exists? ||
      (rederive_pending? && @proposal.nil?)
  end

  def edit
  end

  def update
    @template.name = template_params[:name]
    @template.sections_form = template_params[:sections]
    if @template.save
      redirect_to templates_path, notice: "Template saved. New estimates will follow it."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Copy the shared default into a template the workspace can edit.
  def customise
    copy = EstimateTemplate.default&.customise_for(Current.account)
    if copy
      redirect_to edit_template_path(copy), notice: "This copy is yours — adjust it however you estimate."
    else
      redirect_to templates_path, alert: "You already have a personal template."
    end
  end

  # Ask the AI to re-derive a proposal from every completed training document.
  def rederive
    unless Current.account.training_documents.where(status: "completed").exists?
      return redirect_to templates_path, alert: "Upload at least one training document first."
    end
    session[:template_rederive] = { "user_id" => Current.user.id, "at" => Time.current.iso8601 }
    SynthesizeTemplateJob.perform_later(Current.account)
    redirect_to templates_path, notice: "Re-deriving your template from your training documents — this takes a minute or two."
  end

  def accept
    proposal = EstimateTemplate.proposal_for(Current.account)
    return redirect_to templates_path, alert: "There is no proposal to accept." unless proposal
    proposal.activate!
    session.delete(:template_rederive)
    redirect_to templates_path, notice: "Template accepted. New estimates will follow it."
  end

  def discard
    proposal = EstimateTemplate.proposal_for(Current.account)
    proposal&.destroy
    session.delete(:template_rederive)
    redirect_to templates_path, notice: "Proposal discarded — your current template stands."
  end

  # Polled while a re-derive runs; same shape as onboarding#status.
  #
  # Terminal as soon as there is a proposal to review OR nothing is deriving
  # any more — the window expired, the job failed, or the documents finished
  # without one. Without that second case the card spins forever and the index
  # never re-offers Re-derive. The "still deriving" test mirrors index's
  # @deriving exactly, so the spinner and the poll can never disagree.
  def status
    proposal_ready = EstimateTemplate.proposal_for(Current.account).present?
    pending = Current.account.training_documents.where(status: %w[pending processing]).count
    session.delete(:template_rederive) if proposal_ready
    ready = proposal_ready || (pending.zero? && !rederive_pending?)
    render json: {
      status: ready ? "ready" : "processing",
      progress: ready ? 100 : (pending.zero? ? 80 : 40),
      note: pending.positive? ? "Reading #{pending} document#{'s' if pending > 1}…" : "Deriving your estimate template…"
    }
  end

  private

  # Whether a re-derive this user requested is still within its window.
  # User-scoped so one account's request never shows another as "deriving"
  # on a shared browser session; time-boxed so a lost or failed job doesn't
  # leave the polling card stuck forever. A stale or malformed flag is
  # cleared as soon as it's found not to apply.
  def rederive_pending?
    data = session[:template_rederive]
    return false unless data

    requested_at = begin
      Time.iso8601(data["at"].to_s)
    rescue ArgumentError, TypeError
      nil
    end

    if requested_at && data["user_id"] == Current.user.id && requested_at > REDERIVE_WINDOW.ago
      true
    else
      session.delete(:template_rederive)
      false
    end
  end

  def set_template
    @template = EstimateTemplate.find(params[:id])
  end

  def authorise_edit!
    allowed = @template.account? ? @template.account_id == Current.account.id : Current.user.admin?
    redirect_to templates_path, alert: "You can't edit that template." unless allowed
  end

  def template_params
    params.expect(template: [ :name, sections: [ [ :name, :hint, :typical_items ] ] ])
  end
end
