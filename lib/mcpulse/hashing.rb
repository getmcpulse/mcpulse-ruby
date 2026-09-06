# frozen_string_literal: true

require 'digest'
require 'securerandom'

require_relative 'canonical'

module MCPulse
  # Fingerprinting a call's arguments.
  module Hashing
    # What an argument set hashes to when it cannot be serialised at all.
    UNHASHABLE = '000000000000'

    module_function

    # A short, one-way fingerprint of a call's arguments.
    #
    # This is the only thing MCPulse ever learns about what was passed to a tool, and it is
    # deliberately not enough to learn anything: 12 hex characters of a SHA-256 over the RFC 8785
    # canonical form, with no way back. All the product asks of it is "were these two calls made
    # with the same arguments or different ones" — which is what separates a model retrying a
    # reworded request from a client paging through results.
    def args_hash(args)
      # A tool that takes no arguments is called with +arguments+ absent. That is an ordinary
      # call, not a failure, and it hashes as the empty object it is — otherwise every no-argument
      # tool shares one hash with every call whose arguments blew up.
      value = args.nil? ? {} : args

      Digest::SHA256.hexdigest(Canonical.canonicalize(value))[0, 12]
    rescue StandardError
      # Arguments JSON cannot represent. The call still happened and still deserves a row; it
      # simply cannot be compared to another, so give it a constant that says exactly that.
      UNHASHABLE
    end

    # Identifies one run of the customer's server, so calls can be grouped and a cost-per-session
    # worked out.
    #
    # Random rather than derived — there is nothing about the process worth encoding here, and
    # anything derived from the machine would be an identifier we did not intend to collect.
    def new_session_id
      "s_#{SecureRandom.hex(6)}"
    end
  end
end
