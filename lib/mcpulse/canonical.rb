# frozen_string_literal: true

module MCPulse
  # JSON Canonicalization Scheme (RFC 8785).
  #
  # +args_hash+ only means anything if every MCPulse SDK, in every language, turns the same
  # arguments into the same bytes. Ruby's +JSON.generate+ does not get there on its own: it writes
  # +1.0+ where ECMAScript writes +1+, it leaves keys in insertion order, and Ruby's own string
  # ordering is by UTF-8 byte where JCS sorts by UTF-16 code unit. Each of those silently sends the
  # same call to a different bucket than the TypeScript SDK would.
  #
  # So none of the serialisation below goes through +JSON+. Every rule is spelled out, and
  # +spec/fixtures/canonical.json+ — the same file every other MCPulse SDK runs — is what holds
  # this module to them.
  module Canonical
    # Raised for anything JSON cannot represent: a NaN, an infinity, a cycle, an unknown type.
    class NotJSON < StandardError; end

    SHORT_ESCAPES = {
      "\b" => '\b',
      "\t" => '\t',
      "\n" => '\n',
      "\f" => '\f',
      "\r" => '\r',
      '"' => '\"',
      '\\' => '\\\\'
    }.freeze

    module_function

    # The canonical JSON form of +value+, as a UTF-8 String.
    def canonicalize(value)
      out = +''
      write(out, value, [])
      out
    end

    def write(out, value, seen)
      case value
      when nil then out << 'null'
      when true then out << 'true'
      when false then out << 'false'
      when String, Symbol then write_string(out, value.to_s)
      # Numeric covers Integer, Float, Rational and BigDecimal. Anything Float() cannot accept —
      # a Complex, say — raises below and becomes a NotJSON, which is the right answer for it.
      when Numeric then write_number(out, value)
      when Array then write_array(out, value, seen)
      when Hash then write_object(out, value, seen)
      else
        # A struct, or an object that knows how to become JSON. Round-trip it so it arrives here
        # as one of the shapes above; the escaping its encoder applies on the way out is undone by
        # the parse on the way back in, so it cannot leak into the canonical form.
        write_via_json(out, value, seen)
      end
    end

    def write_via_json(out, value, seen)
      raise NotJSON, "cannot canonicalize #{value.class}" unless value.respond_to?(:to_json)

      decoded = JSON.parse(value.to_json)
      write(out, decoded, seen)
    rescue JSON::JSONError, NoMethodError => e
      raise NotJSON, "cannot canonicalize #{value.class}: #{e.message}"
    end

    def write_array(out, value, seen)
      raise NotJSON, 'circular structure' if seen.any? { |item| item.equal?(value) }

      seen.push(value)
      out << '['
      value.each_with_index do |item, index|
        out << ',' if index.positive?
        write(out, item, seen)
      end
      out << ']'
      seen.pop
    end

    def write_object(out, value, seen)
      raise NotJSON, 'circular structure' if seen.any? { |item| item.equal?(value) }

      seen.push(value)
      out << '{'
      # Keys are carried alongside their original form, so a symbol-keyed Hash — which is what a
      # Ruby MCP server most often has — still finds its values after sorting by the string.
      sorted_entries(value).each_with_index do |(name, original), index|
        out << ',' if index.positive?
        write_string(out, name)
        out << ':'
        write(out, value[original], seen)
      end
      out << '}'
      seen.pop
    end

    # Keys in RFC 8785 order: by UTF-16 code unit, not by UTF-8 byte.
    #
    # The two agree for everything in the Basic Multilingual Plane and disagree above it. U+1F680
    # encodes as the surrogate pair D83D DE80, so JCS sorts it *before* U+FFFD while Ruby's default
    # comparison puts it after. Encoding to UTF-16BE and comparing bytes is exactly the code-unit
    # comparison JCS asks for.
    def sorted_entries(hash)
      hash.keys.map do |key|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise NotJSON, "object key must be a string, got #{key.class}"
        end

        [key.to_s, key]
      end.sort_by { |(name, _original)| utf16_bytes(name) }
    end

    def utf16_bytes(text)
      text.encode(Encoding::UTF_16BE, invalid: :replace, undef: :replace).bytes
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      text.bytes
    end

    # ─── Strings ───────────────────────────────────────────────────────────────

    # A JSON string per JCS 3.2.2.2, which is ECMAScript's escaping: the short escapes where one
    # exists, lowercase \u00xx for the rest of the C0 range, and nothing else touched.
    #
    # In particular non-ASCII is written literally, and so are <, > and &.
    def write_string(out, text)
      out << '"'
      text.each_char do |char|
        short = SHORT_ESCAPES[char]
        if short
          out << short
        elsif char.ord < 0x20
          out << format('\u%04x', char.ord)
        else
          out << char
        end
      end
      out << '"'
    end

    # ─── Numbers ───────────────────────────────────────────────────────────────

    # ECMAScript +Number::toString+, which is what JCS 3.2.2.3 defers to.
    #
    # Every number is treated as an IEEE-754 double, including Ruby's arbitrary-precision Integer:
    # RFC 8785 limits JSON to double precision, and matching JavaScript is the entire point. An
    # integer past 2**53 therefore loses precision here exactly as it would there, which is what
    # keeps the two SDKs' hashes equal.
    def write_number(out, value)
      number = Float(value)
      raise NotJSON, 'non-finite number' if number.nan? || number.infinite?

      if number.zero?
        # Covers -0.0, which JCS writes as "0".
        out << '0'
        return
      end

      if number.negative?
        out << '-'
        number = -number
      end

      digits, n = shortest(number)
      k = digits.length

      # The five cases of ECMAScript Number::toString, in its own order.
      if k <= n && n <= 21
        out << digits << ('0' * (n - k))
      elsif n.positive? && n <= 21
        out << digits[0, n] << '.' << digits[n..]
      elsif n > -6 && n <= 0
        out << '0.' << ('0' * -n) << digits
      else
        exponent = n - 1
        out << (k == 1 ? digits : "#{digits[0]}.#{digits[1..]}")
        out << 'e' << (exponent.negative? ? '-' : '+') << exponent.abs.to_s
      end
    rescue TypeError, RangeError => e
      raise NotJSON, "number out of range: #{e.message}"
    end

    # Decomposes a positive finite double into its shortest round-tripping digits and the position
    # of the decimal point: the value is +digits * 10**(n - digits.length)+.
    #
    # Ruby's +Float#to_s+ is already shortest-round-tripping, so this only has to re-read it — the
    # exponent formatting is what differs between the two languages, not the digits.
    def shortest(number)
      formatted = number.to_s
      mantissa, exponent_text = formatted.split(/e/i, 2)
      exponent = exponent_text ? exponent_text.to_i : 0

      integer_part, fraction_part = mantissa.split('.', 2)
      fraction_part ||= ''
      digits = "#{integer_part}#{fraction_part}"
      n = exponent + integer_part.length

      stripped = digits.sub(/\A0+/, '')
      n -= digits.length - stripped.length
      digits = stripped.sub(/0+\z/, '')

      digits.empty? ? ['0', 1] : [digits, n]
    end
  end
end
