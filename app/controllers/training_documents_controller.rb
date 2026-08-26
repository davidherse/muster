class TrainingDocumentsController < ApplicationController
  def index
    @documents = Current.account.training_documents.order(created_at: :desc)
  end

  def new
    @document = Current.account.training_documents.new(user: Current.user)
  end

  def create
    @document = Current.account.training_documents.new(document_params.merge(user: Current.user))
    if @document.files.attached? && @document.save
      TrainingIngestJob.perform_later(@document)
      redirect_to training_documents_path, notice: "Training started — your rates will appear in the price book shortly."
    else
      @document.errors.add(:files, "must be attached") unless @document.files.attached?
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    document = Current.account.training_documents.find(params[:id])
    PriceBookItem.from_training_doc(Current.account, document.id).delete_all
    document.destroy
    QuantityNorms.derive!(Current.account)
    redirect_to training_documents_path, notice: "Training document and its rates removed."
  end

  private

  def document_params
    params.require(:training_document).permit(:name, :priced_on, :description, files: [], questionnaire: {})
  end
end
