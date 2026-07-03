class TrainingIngestJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(training_document)
    TrainingIngestor.new(training_document).call
  end
end
