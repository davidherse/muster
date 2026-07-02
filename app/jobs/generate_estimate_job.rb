class GenerateEstimateJob < ApplicationJob
  queue_as :default

  # The generator marks the estimate failed with a friendly message; don't
  # retry automatically — the user can re-run from the UI.
  discard_on StandardError

  def perform(estimate)
    EstimateGenerator.new(estimate).call
  end
end
