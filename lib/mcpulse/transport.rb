# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

require_relative 'options'

module MCPulse
  # Posting one batch.
  #
  # +net/http+ from the standard library rather than Faraday or HTTParty: this gem loads into other
  # people's servers, and a dependency that conflicts with what the customer already bundles is a
  # support burden with no upside for a single POST. It runs on a background thread, so blocking
  # here costs nothing.
  module Transport
    module_function

    # Sends one batch and reports whether it landed. Never raises — a caller must not have to
    # rescue.
    #
    # A failed batch is dropped, deliberately. Retrying means either a queue that grows while the
    # network is down, or duplicate rows when a 202 is lost on the way back. Neither is worth it
    # for analytics: the next flush is five seconds away, and a gap in a chart is a far smaller
    # problem than memory growth inside someone else's server.
    def post_batch(payloads, options, timeout: Options::SEND_TIMEOUT_SECONDS)
      return true if payloads.empty?

      uri = URI.parse("#{options.endpoint}/v1/ingest")
      body = JSON.generate({ batch: payloads })

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)

      request = Net::HTTP::Post.new(uri.request_uri)
      request['content-type'] = 'application/json'
      request['authorization'] = "Bearer #{options.key}"
      request['user-agent'] = 'mcpulse-ruby'
      request.body = body

      response = http.request(request)
      response.code.to_i.between?(200, 299)
    rescue StandardError
      # DNS, TLS, a timeout, a proxy that hung up. All the same to us.
      false
    end
  end
end
