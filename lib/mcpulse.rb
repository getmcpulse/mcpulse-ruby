# frozen_string_literal: true

require 'json'

require_relative 'mcpulse/canonical'
require_relative 'mcpulse/emptiness'
require_relative 'mcpulse/hashing'
require_relative 'mcpulse/logger'
require_relative 'mcpulse/options'
require_relative 'mcpulse/stream'
require_relative 'mcpulse/version'

# MCPulse — analytics for MCP servers.
#
#   MCPulse.configure(key: "mp_live_…")
#
#   MCPulse.record("search", arguments) do
#     my_handler.call(arguments)
#   end
#
# Three rules this gem keeps, in order of how badly it would hurt to break one:
#
# 1. *Never raise.* Every entry point rescues. If MCPulse fails inside a customer's tool call,
#    their tool fails and they blame us.
# 2. *Never block.* Record, buffer, return. Nothing waits on the network on the path a model is
#    waiting on.
# 3. *Never store customer data.* Sizes and hashes leave this process. Arguments and results do
#    not, and no option turns that off.
module MCPulse
  class << self
    # Starts recording, or turns everything into a no-op if the options say not to.
    #
    # Idempotent: calling it twice reuses the same session rather than opening a second one. Left
    # unguarded, a server built per request would report every call under two sessions and double
    # both the customer's numbers and their bill.
    def configure(key:, endpoint: nil, enabled: true, debug: false)
      options = Options.new(key: key, endpoint: endpoint, enabled: enabled, debug: debug)
      log = DebugLog.new(options.debug?)

      unless options.active?
        log.call('disabled — no key, or enabled: false')
        @stream = nil
        return nil
      end

      @stream = Stream.for(options, log)
      log.call('watching')
      @stream
    rescue StandardError
      # Deliberately silent. Failing here must look like configure was never called, and there is
      # no logger to complain to if the options were the thing that was malformed.
      @stream = nil
    end

    # The session calls are being filed under, or nil when recording is off.
    #
    # Exposed so a server can log which session it joined, and so the shared-session guarantee can
    # be asserted rather than assumed.
    def session_id
      @stream&.session_id
    end

    # Notes who is connected, so calls can be attributed to a client.
    def remember_client(name)
      @stream&.remember_client(name)
      nil
    rescue StandardError
      nil
    end

    # Times one tool call and buffers the result.
    #
    # The block's return value is handed back untouched and an exception is re-raised untouched,
    # so a recorded call behaves exactly like an unrecorded one.
    #
    # Wrapping the handler rather than watching from outside is what lets MCPulse tell a handler
    # that raised from one that returned an error result — a distinction an MCP server erases by
    # converting both into +isError+ before anything outside can see it.
    def record(tool_name, arguments = nil, client_name: nil)
      stream = @stream
      return yield if stream.nil?

      stream.remember_client(client_name)

      started_at = Time.now.utc
      started = monotonic

      result = nil
      raised = false
      begin
        result = yield
        result
      rescue StandardError, ScriptError
        raised = true
        # Re-raised untouched: swallowing it would change what the customer's server does.
        raise
      ensure
        begin
          emit_call(stream, tool_name, arguments, result, raised, started_at, started)
        rescue StandardError
          # Recording must never be the reason a tool call fails.
          nil
        end
      end
    end

    # Reports the server's tool list, once per session.
    #
    # +schema_bytes+ is the cost of a tool's presence in the context window, so pass the JSON that
    # actually goes over the wire — what +tools/list+ returns — not the Ruby object the tool was
    # declared from.
    def record_startup(tools, client_name: nil)
      stream = @stream
      return nil if stream.nil? || !stream.claim_startup

      stream.remember_client(client_name)

      described = Array(tools).first(Options::MAX_TOOLS).filter_map do |tool|
        name = Emptiness.member(tool, 'name')
        next nil unless name.is_a?(String) && !name.empty?

        { name: name[0, Options::MAX_TOOL_NAME], schema_bytes: measure(tool) }
      end

      stream.emit(
        v: WIRE_VERSION,
        type: 'startup',
        session_id: stream.session_id,
        client_name: stream.client_name,
        tools: described
      )
      stream.log.call("startup: #{described.size} tools, client #{stream.client_name}")
      nil
    rescue StandardError
      nil
    end

    # Sends everything buffered and stops accepting more.
    #
    # An +at_exit+ hook already does this. Call it by hand only when the server stops without the
    # process exiting — a test suite, or a host that restarts servers in place.
    def flush_all
      Stream.flush_all
    end

    private

    def emit_call(stream, tool_name, arguments, result, raised, started_at, started)
      outcome = decide_outcome(result, raised)
      name = tool_name.to_s
      name = 'unknown' if name.empty?

      stream.emit(
        v: WIRE_VERSION,
        type: 'call',
        session_id: stream.session_id,
        client_name: stream.client_name,
        tool_name: name[0, Options::MAX_TOOL_NAME],
        started_at: started_at.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
        duration_ms: ((monotonic - started) * 1000).round,
        outcome: outcome,
        response_bytes: measure(result),
        # An error is not also an absence — it has its own outcome already.
        is_empty: outcome == Outcome::OK && Emptiness.empty_result?(result),
        args_hash: Hashing.args_hash(arguments)
      )
    end

    # What the outcome was, given that the handler is what we wrapped.
    #
    # Wrapping the block means a raise arrives here as a raise rather than as the +isError+ result
    # the server would have converted it into. What cannot be seen from here is +bad_args+: a
    # server that validates arguments before calling the handler rejects them outside this block.
    # Reporting it anyway would mean reading the difference back out of an error message, and error
    # strings are not an interface anyone promised to keep.
    def decide_outcome(result, raised)
      return Outcome::CRASHED if raised

      flag = Emptiness.member(result, 'isError')
      flag = Emptiness.member(result, 'is_error') if flag.nil?
      flag == true ? Outcome::TOOL_ERROR : Outcome::OK
    end

    # What something costs the context window. Unserialisable means unmeasurable.
    def measure(value)
      return 0 if value.nil?

      Sizes.utf16_length(JSON.generate(value))
    rescue StandardError
      0
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
