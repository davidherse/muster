module Ai
  # Thin wrapper over the Anthropic SDK that returns schema-validated JSON,
  # with long-backoff retries for rate limits and transient service errors
  # (the SDK's own fast retries run underneath). Inject a fake in tests via
  # Ai::Client.new(anthropic: fake).
  class Client
    MODEL = "claude-opus-4-8".freeze
    MAX_TOKENS = 24_000
    FILES_BETA = "files-api-2025-04-14".freeze

    MAX_ATTEMPTS = 5
    BACKOFF_SECONDS = [ 15, 30, 60, 120 ].freeze

    RETRYABLE_ERRORS = [
      "Anthropic::Errors::RateLimitError",      # 429
      "Anthropic::Errors::InternalServerError", # 5xx incl. 529 overloaded
      "Anthropic::Errors::APIConnectionError"   # network blips
    ].freeze

    class Error < StandardError; end
    class RefusalError < Error; end
    class TruncatedError < Error; end

    # on_retry: ->(error, attempt, delay_seconds) — e.g. to surface a progress note
    def initialize(anthropic: nil, on_retry: nil, sleeper: ->(seconds) { sleep(seconds) })
      @anthropic = anthropic || Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
      @on_retry = on_retry
      @sleeper = sleeper
    end

    # system: array of text blocks (put cache_control on the last stable block)
    # content: user content blocks (documents, text)
    # schema: JSON Schema the response must conform to
    def complete_json(system:, content:, schema:, max_tokens: MAX_TOKENS)
      params = {
        model: MODEL,
        max_tokens: max_tokens,
        thinking: { type: "adaptive" },
        system_: system,
        messages: [ { role: "user", content: content } ],
        output_config: { format: { type: "json_schema", schema: schema } }
      }

      message = with_backoff do
        # File references (Files API uploads) need the beta messages endpoint.
        if file_reference?(content)
          @anthropic.beta.messages.create(**params, betas: [ FILES_BETA ])
        else
          @anthropic.messages.create(**params)
        end
      end

      raise RefusalError, "The model declined this request." if message.stop_reason == :refusal
      raise TruncatedError, "Response hit the #{max_tokens} token limit." if message.stop_reason == :max_tokens

      text = message.content.select { |b| b.type == :text }.map(&:text).join
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise Error, "Model returned invalid JSON: #{e.message}"
    end

    # Uploads a PDF via the Files API and returns its file id, for plans too
    # large to send inline as base64.
    def upload_pdf(data, filename: "plan.pdf")
      Tempfile.create([ File.basename(filename, ".*"), ".pdf" ]) do |f|
        f.binmode
        f.write(data)
        f.flush
        with_backoff { @anthropic.beta.files.upload(file: Pathname(f.path)).id }
      end
    end

    private

    def with_backoff(&block)
      attempt = 0
      begin
        attempt += 1
        allow_code_reloads(&block)
      rescue StandardError => e
        raise unless retryable?(e) && attempt < MAX_ATTEMPTS
        delay = BACKOFF_SECONDS[attempt - 1] || BACKOFF_SECONDS.last
        @on_retry&.call(e, attempt, delay)
        @sleeper.call(delay)
        retry
      end
    end

    # API calls run for minutes inside background jobs. Without this, the
    # development reloader waits for the whole job before serving any request
    # after a code change — the app appears frozen. Releasing the load
    # interlock during the blocking call keeps the dev server responsive.
    def allow_code_reloads(&block)
      interlock = ActiveSupport::Dependencies.interlock
      interlock ? interlock.permit_concurrent_loads(&block) : yield
    end

    def retryable?(error)
      RETRYABLE_ERRORS.any? { |name| error.is_a?(name.constantize) }
    end

    def file_reference?(content)
      content.any? { |block| block.is_a?(Hash) && block.dig(:source, :type) == "file" }
    end
  end
end
