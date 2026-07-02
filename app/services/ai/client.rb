module Ai
  # Thin wrapper over the Anthropic SDK that returns schema-validated JSON.
  # Inject a fake in tests via Ai::Client.new(anthropic: fake).
  class Client
    MODEL = "claude-opus-4-8".freeze
    MAX_TOKENS = 16_000
    FILES_BETA = "files-api-2025-04-14".freeze

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
      params = {
        model: MODEL,
        max_tokens: max_tokens,
        thinking: { type: "adaptive" },
        system_: system,
        messages: [ { role: "user", content: content } ],
        output_config: { format: { type: "json_schema", schema: schema } }
      }

      # File references (Files API uploads) need the beta messages endpoint.
      message = if file_reference?(content)
        @anthropic.beta.messages.create(**params, betas: [ FILES_BETA ])
      else
        @anthropic.messages.create(**params)
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
        @anthropic.beta.files.upload(file: Pathname(f.path)).id
      end
    end

    private

    def file_reference?(content)
      content.any? { |block| block.is_a?(Hash) && block.dig(:source, :type) == "file" }
    end
  end
end
