# frozen_string_literal: true

require_relative 'options'
require_relative 'transport'

module MCPulse
  # Holds payloads and sends them in batches, on a thread of its own.
  #
  # The contract with the tool call that produced a payload is that +add+ returns immediately and
  # never raises. Everything expensive happens on a background thread, so no model ever waits on
  # MCPulse to answer.
  #
  # A Thread rather than a Fiber or a queue with a bound: a bounded +Queue#push+ blocks when full,
  # which is exactly what must never happen on the path a model is waiting on. This keeps its own
  # array and drops the oldest entry instead.
  class PayloadBuffer
    def initialize(options, log)
      @options = options
      @log = log

      @mutex = Mutex.new
      @wake = ConditionVariable.new
      @pending = []
      @closed = false
      # Held for the duration of a batch, so a flush waits for a real send.
      @sending = Mutex.new

      @worker = Thread.new { run }
      # Never hold the customer's process open over analytics.
      @worker.abort_on_exception = false
    end

    # Buffers one payload. Returns immediately, never raises.
    def add(payload)
      ready = false

      @mutex.synchronize do
        return if @closed

        if @pending.size >= Options::MAX_BUFFERED
          # Oldest first: recent calls describe what the server is doing now, and that is the more
          # useful half of a buffer that could not be sent.
          @pending.shift
          @log.call('buffer full, dropped oldest payload')
        end

        @pending << payload
        ready = @pending.size >= Options::FLUSH_AT_ITEMS
        @wake.signal if ready
      end

      nil
    rescue StandardError
      # Recording must never be the reason a tool call fails.
      nil
    end

    # Final flush, best effort. After this the buffer accepts nothing more.
    def close(timeout: Options::EXIT_FLUSH_SECONDS)
      @mutex.synchronize do
        return if @closed

        @closed = true
        @wake.broadcast
      end

      send_once
      @worker.join(timeout)
      nil
    rescue StandardError
      nil
    end

    private

    def run
      loop do
        @mutex.synchronize do
          # Either something asked for a flush, or the five seconds elapsed.
          @wake.wait(@mutex, Options::FLUSH_EVERY_SECONDS) if @pending.empty? && !@closed
        end

        send_once

        break if @mutex.synchronize { @closed && @pending.empty? }
      end
    rescue StandardError => e
      @log.call('sender stopped', e)
    end

    def send_once
      @sending.synchronize do
        batch = @mutex.synchronize do
          next [] if @pending.empty?

          # Taken in one go: anything added while this is in flight belongs to the next batch, not
          # this one.
          @pending.slice!(0, @pending.size)
        end
        return if batch.empty?

        sent = Transport.post_batch(batch, @options)
        @log.call("#{sent ? 'sent' : 'dropped'} #{batch.size} payloads")
      end
    rescue StandardError => e
      @log.call('send failed', e)
    end
  end
end
