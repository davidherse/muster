# Re-derives a user's proposed personal estimate template from all their
# completed training uploads. Enqueued after each ingest; safe to run
# repeatedly (the proposal is replaced each time).
class SynthesizeTemplateJob < ApplicationJob
  queue_as :default

  def perform(user)
    TemplateSynthesizer.new(user).call
  end
end
