# Re-derives an account's proposed estimate template from all of the
# account's completed training uploads. Enqueued after each ingest; safe to
# run repeatedly (the proposal is replaced each time).
class SynthesizeTemplateJob < ApplicationJob
  queue_as :default

  def perform(account)
    TemplateSynthesizer.new(account).call
  end
end
