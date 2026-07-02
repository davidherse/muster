require "test_helper"

class AiClientTest < ActiveSupport::TestCase
  SCHEMA = { type: "object" }.freeze

  # Minimal stand-in for the Anthropic SDK: raises the queued errors, then
  # returns a canned message.
  class StubAnthropic
    Message = Struct.new(:stop_reason, :content)
    TextBlock = Struct.new(:type, :text)

    attr_reader :requests

    def initialize(errors: [], response_json: { "ok" => true })
      @errors = errors
      @response_json = response_json
      @requests = 0
    end

    class StubStream
      def initialize(message) = @message = message
      def accumulated_message = @message
    end

    def messages = self
    def beta = self

    def stream(**_params)
      @requests += 1
      raise @errors.shift if @errors.any?
      StubStream.new(Message.new(:end_turn, [ TextBlock.new(:text, @response_json.to_json) ]))
    end
  end

  def rate_limit_error
    Anthropic::Errors::RateLimitError.new(
      url: URI("https://api.anthropic.com/v1/messages"), status: 429,
      headers: {}, body: nil, request: nil, response: nil, message: "rate limited"
    )
  end

  def auth_error
    Anthropic::Errors::AuthenticationError.new(
      url: URI("https://api.anthropic.com/v1/messages"), status: 401,
      headers: {}, body: nil, request: nil, response: nil, message: "bad key"
    )
  end

  test "retries rate limits with backoff then succeeds" do
    stub = StubAnthropic.new(errors: [ rate_limit_error, rate_limit_error ])
    waits = []
    retries = []
    client = Ai::Client.new(
      anthropic: stub,
      sleeper: ->(s) { waits << s },
      on_retry: ->(error, attempt, delay) { retries << [ error.class, attempt, delay ] }
    )

    result = client.complete_json(system: [], content: [ { type: "text", text: "hi" } ], schema: SCHEMA)

    assert_equal({ "ok" => true }, result)
    assert_equal 3, stub.requests
    assert_equal [ 15, 30 ], waits
    assert_equal [ [ Anthropic::Errors::RateLimitError, 1, 15 ], [ Anthropic::Errors::RateLimitError, 2, 30 ] ], retries
  end

  test "gives up after max attempts" do
    stub = StubAnthropic.new(errors: Array.new(10) { rate_limit_error })
    client = Ai::Client.new(anthropic: stub, sleeper: ->(_s) { })

    assert_raises(Anthropic::Errors::RateLimitError) do
      client.complete_json(system: [], content: [], schema: SCHEMA)
    end
    assert_equal Ai::Client::MAX_ATTEMPTS, stub.requests
  end

  test "does not retry permanent errors" do
    stub = StubAnthropic.new(errors: [ auth_error ])
    waits = []
    client = Ai::Client.new(anthropic: stub, sleeper: ->(s) { waits << s })

    assert_raises(Anthropic::Errors::AuthenticationError) do
      client.complete_json(system: [], content: [], schema: SCHEMA)
    end
    assert_equal 1, stub.requests
    assert_empty waits
  end
end
