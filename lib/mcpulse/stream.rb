# frozen_string_literal: true

require_relative 'buffer'
require_relative 'hashing'

module MCPulse
  # One session and one buffer per destination, for the life of the process.
  #
  # The obvious shape is to make both where the server is built, which is right for a stdio server
  # — one process, one server, one session — and wrong for an HTTP one. A streamable-HTTP server
  # builds a fresh handler per request, and every tool call would become a session of its own.
  #
  # That is not a cosmetic difference. Retries are found by looking for the same tool twice inside
  # one session, and first-call success is defined as no retry following. With one call per session
  # there can never be a retry, so the server reports a perfect score however badly it is doing —
  # the one number this product exists to tell the truth about.
  #
  # Keyed by endpoint and key rather than a bare singleton: two watched servers reporting to
  # different MCPs in one process are two different streams, and merging them would file one
  # customer's calls under another's.
  class Stream
    attr_reader :session_id, :buffer, :log

    # Diverts payloads away from the buffer. Only tests set it.
    class << self
      attr_accessor :sink
    end

    def initialize(options, log)
      @session_id = Hashing.new_session_id
      @buffer = PayloadBuffer.new(options, log)
      @log = log
      @client_name = 'unknown'
      @startup_sent = false
      @mutex = Mutex.new
    end

    # Whoever most recently identified themselves.
    #
    # One value per process per destination, last identification wins. For a server with two
    # concurrent clients that is an approximation, but it is the same approximation the shared
    # session already makes, and a name that is occasionally the other client's beats a column
    # that is always "unknown".
    def client_name
      @mutex.synchronize { @client_name }
    end

    def remember_client(name)
      return if name.nil? || !name.is_a?(String) || name.empty?

      @mutex.synchronize { @client_name = name[0, Options::MAX_CLIENT_NAME] }
    end

    def claim_startup
      @mutex.synchronize do
        return false if @startup_sent

        @startup_sent = true
        true
      end
    end

    # Hands one payload to the buffer, or to a test's capture.
    def emit(payload)
      capture = self.class.sink
      return capture.call(payload) if capture

      @buffer.add(payload)
    end

    @streams = {}
    @registry_mutex = Mutex.new
    @hook_registered = false

    class << self
      def for(options, log)
        @registry_mutex.synchronize do
          existing = @streams[options.stream_key]
          return existing if existing

          created = new(options, log)
          @streams[options.stream_key] = created

          unless @hook_registered
            # Registered once for the whole gem, however many servers are watched. at_exit runs
            # before the interpreter tears the threads down, which is what makes the final flush
            # possible at all.
            @hook_registered = true
            at_exit { flush_all }
          end

          created
        end
      end

      # One last flush on the way out, so the final few calls of a session are not lost.
      def flush_all
        pending = @registry_mutex.synchronize do
          taken = @streams.values
          @streams = {}
          taken
        end

        pending.each do |stream|
          stream.buffer.close
        rescue StandardError
          nil
        end
      end

      # Only tests reach for this.
      def reset!
        @registry_mutex.synchronize { @streams = {} }
      end
    end
  end
end
