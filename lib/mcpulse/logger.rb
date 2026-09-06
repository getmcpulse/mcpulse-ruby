# frozen_string_literal: true

module MCPulse
  # Debug output, on stderr.
  #
  # stdout is the transport for a stdio MCP server — a single stray line there corrupts the
  # JSON-RPC stream and takes the customer's server down with it. This is the one thing in the gem
  # that would be trivially easy to get wrong and catastrophic to ship, so it goes through one
  # place.
  #
  # Deliberately not +Logger+ or a Rails logger: a library that writes through the host's
  # configuration can end up on stdout because of a setting it never saw.
  class DebugLog
    def initialize(debug)
      @debug = debug
    end

    def call(message, detail = nil)
      return unless @debug

      suffix = detail.nil? ? '' : " #{format_detail(detail)}"
      warn("[mcpulse] #{message}#{suffix}")
    rescue StandardError
      # Logging is never worth an exception.
      nil
    end

    private

    def format_detail(detail)
      detail.is_a?(Exception) ? "#{detail.class}: #{detail.message}" : detail.to_s
    end
  end
end
