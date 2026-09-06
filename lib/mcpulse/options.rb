# frozen_string_literal: true

module MCPulse
  # Everything +MCPulse.watch+ accepts, and what it means when you leave it out.
  class Options
    # Where payloads go when no endpoint is given.
    DEFAULT_ENDPOINT = 'https://api.getmcpulse.com'

    # Flush when either is reached, whichever comes first.
    FLUSH_AT_ITEMS = 30
    FLUSH_EVERY_SECONDS = 5.0

    # Hard ceiling on the buffer. Reached only when the network is gone; past it the oldest
    # payloads are dropped, because a customer's server running out of memory over our analytics
    # is the one failure we must never cause.
    MAX_BUFFERED = 1000

    # Best-effort window for the final flush on the way out, and the cap on one batch.
    EXIT_FLUSH_SECONDS = 1.0
    SEND_TIMEOUT_SECONDS = 10.0

    # Caps, so one malformed name cannot bloat a batch.
    MAX_TOOL_NAME = 200
    MAX_CLIENT_NAME = 128
    MAX_TOOLS = 500

    attr_reader :key, :endpoint

    def initialize(key:, endpoint: nil, enabled: true, debug: false)
      @key = key.is_a?(String) ? key.strip : ''
      target = endpoint.is_a?(String) && !endpoint.strip.empty? ? endpoint : DEFAULT_ENDPOINT
      @endpoint = target.sub(%r{/+\z}, '')
      @enabled = enabled
      @debug = debug
    end

    def debug?
      @debug
    end

    # Whether anything should be recorded at all.
    #
    # An empty key turns the SDK off: a server started without its key configured should be
    # silent, not a source of 401s on every flush.
    def active?
      @enabled && !@key.empty?
    end

    def stream_key
      "#{@endpoint}|#{@key}"
    end
  end

  # How a tool call ended. Exactly one of these, always.
  module Outcome
    OK = 'ok'
    BAD_ARGS = 'bad_args'
    TOOL_ERROR = 'tool_error'
    CRASHED = 'crashed'

    ALL = [OK, BAD_ARGS, TOOL_ERROR, CRASHED].freeze
  end

  # How MCPulse measures what a payload costs a context window.
  module Sizes
    module_function

    # The length of +text+ in UTF-16 code units.
    #
    # +response_bytes+ and +schema_bytes+ are, today, what JavaScript's +String.length+ returns —
    # code units, not bytes. The fields are named for bytes and hold code units, so "café" measures
    # 4 and an emoji measures 2.
    #
    # That is a known wart in the wire format, and fixing it is a pending decision. Until it is
    # made, every port reproduces the TypeScript behaviour rather than each inventing its own,
    # because the whole value of these numbers is that they are comparable across a customer's
    # servers. When the wire fixes it, this method is the one line that changes.
    def utf16_length(text)
      text.encode(Encoding::UTF_16BE, invalid: :replace, undef: :replace).bytesize / 2
    rescue StandardError
      text.length
    end
  end
end
