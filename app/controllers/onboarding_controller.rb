# The new-user wizard: upload example estimates → review and agree the
# derived personal template → start estimating. Uploads are broken down into
# the user's price book by the same ingest pipeline as the training page.
class OnboardingController < ApplicationController
  # Step 1 — upload example estimate spreadsheets/CSVs.
  def uploads
    @documents = Current.user.training_documents.order(created_at: :desc)
    @document = Current.user.training_documents.new
  end

  def create_upload
    @document = Current.user.training_documents.new(document_params)
    if @document.files.attached? && @document.save
      TrainingIngestJob.perform_later(@document)
      redirect_to onboarding_path, notice: "Got it — #{@document.name} is being read. Add more examples, or continue when you're done."
    else
      @document.errors.add(:files, "must be attached") unless @document.files.attached?
      @documents = Current.user.training_documents.order(created_at: :desc)
      render :uploads, status: :unprocessable_entity
    end
  end

  # Step 2 — review the derived template. Polls while ingest/synthesis runs.
  def template
    @documents = Current.user.training_documents
    @proposal = EstimateTemplate.proposed.find_by(user: Current.user)
    # Ingest enqueues synthesis, but cover the gap (job lost, docs ingested
    # before this feature) by re-enqueueing when everything is done and no
    # proposal exists yet.
    if @proposal.nil? && @documents.where(status: %w[pending processing]).none? && @documents.where(status: "completed").any?
      SynthesizeTemplateJob.perform_later(Current.user)
    end
  end

  def status
    pending = Current.user.training_documents.where(status: %w[pending processing]).count
    completed = Current.user.training_documents.where(status: "completed").count
    proposal_ready = EstimateTemplate.proposed.where(user: Current.user).exists?
    render json: {
      status: proposal_ready || (pending.zero? && completed.zero?) ? "ready" : "processing",
      progress: proposal_ready ? 100 : (pending.zero? ? 80 : 40),
      note: pending.positive? ? "Reading #{pending} document#{'s' if pending > 1}…" : "Deriving your estimate template…"
    }
  end

  def agree
    proposal = EstimateTemplate.proposed.find_by(user: Current.user)
    return redirect_to onboarding_template_path, alert: "Your template isn't ready yet." unless proposal

    proposal.activate!
    Current.user.update!(onboarded_at: Time.current)
    redirect_to new_estimate_path, notice: "Template agreed. Your estimates will follow your structure — let's build the first one."
  end

  def skip
    Current.user.update!(onboarded_at: Time.current)
    redirect_to estimates_path, notice: "No problem — you can train Muster any time from the Training page."
  end

  private

  def document_params
    params.require(:training_document).permit(:name, :priced_on, :description, files: [])
  end
end
