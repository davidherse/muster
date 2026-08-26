# The new-workspace wizard: upload example estimates → review and agree the
# derived template → start estimating. Uploads are broken down into the
# account's price book by the same ingest pipeline as the training page.
class OnboardingController < ApplicationController
  # Step 1 — upload example estimate spreadsheets/CSVs.
  def uploads
    @documents = Current.account.training_documents.order(created_at: :desc)
    @document = Current.account.training_documents.new(user: Current.user)
  end

  def create_upload
    @document = Current.account.training_documents.new(document_params.merge(user: Current.user))
    if @document.files.attached? && @document.save
      TrainingIngestJob.perform_later(@document)
      redirect_to onboarding_path, notice: "Got it — #{@document.name} is being read. Add more examples, or continue when you're done."
    else
      @document.errors.add(:files, "must be attached") unless @document.files.attached?
      @documents = Current.account.training_documents.order(created_at: :desc)
      render :uploads, status: :unprocessable_entity
    end
  end

  # Step 2 — review the derived template. Polls while ingest/synthesis runs.
  def template
    @documents = Current.account.training_documents
    @proposal = EstimateTemplate.proposal_for(Current.account)
    # Ingest enqueues synthesis, but cover the gap (job lost, docs ingested
    # before this feature) by re-enqueueing when everything is done and no
    # proposal exists yet.
    if @proposal.nil? && @documents.where(status: %w[pending processing]).none? && @documents.where(status: "completed").any?
      SynthesizeTemplateJob.perform_later(Current.account)
    end
  end

  def status
    pending = Current.account.training_documents.where(status: %w[pending processing]).count
    completed = Current.account.training_documents.where(status: "completed").count
    proposal_ready = EstimateTemplate.proposed.where(account: Current.account).exists?
    render json: {
      status: proposal_ready || (pending.zero? && completed.zero?) ? "ready" : "processing",
      progress: proposal_ready ? 100 : (pending.zero? ? 80 : 40),
      note: pending.positive? ? "Reading #{pending} document#{'s' if pending > 1}…" : "Deriving your estimate template…"
    }
  end

  def agree
    proposal = EstimateTemplate.proposal_for(Current.account)
    return redirect_to onboarding_template_path, alert: "Your template isn't ready yet." unless proposal

    proposal.activate!
    Current.account.update!(onboarded_at: Time.current)
    redirect_to new_estimate_path, notice: "Template agreed. Your estimates will follow your structure — let's build the first one."
  end

  def skip
    Current.account.update!(onboarded_at: Time.current)
    redirect_to estimates_path, notice: "No problem — you can train Muster any time from the Training page."
  end

  private

  def document_params
    params.require(:training_document).permit(:name, :priced_on, :description, files: [])
  end
end
