module Ai
  # Thin wrapper over the Anthropic SDK that returns schema-validated JSON.
  # Inject a fake in tests via Ai::Client.new(anthropic: fake).
  class Client
    MODEL = "claude-opus-4-8".freeze
    MAX_TOKENS = 16_000

    class Error < StandardError; end
    class RefusalError < Error; end
    class TruncatedError < Error; end

    def initialize(anthropic: nil)
      @anthropic = anthropic || Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    end

    # system: array of text blocks (put cache_control on the last stable block)
    # content: user content blocks (documents, text)
    # schema: JSON Schema the response must conform to
    def complete_json(system:, content:, schema:, max_tokens: MAX_TOKENS)
      message = @anthropic.messages.create(
        model: MODEL,
        max_tokens: max_tokens,
        thinking: { type: "adaptive" },
        system_: system,
        messages: [ { role: "user", content: content } ],
        output_config: { format: { type: "json_schema", schema: schema } }
      )

      raise RefusalError, "The model declined this request." if message.stop_reason == :refusal
      raise TruncatedError, "Response hit the #{max_tokens} token limit." if message.stop_reason == :max_tokens

      text = message.content.select { |b| b.type == :text }.map(&:text).join
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise Error, "Model returned invalid JSON: #{e.message}"
    end
  end
end
