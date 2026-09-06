# frozen_string_literal: true

require 'json'

module MCPulse
  # Did this call succeed while returning nothing useful?
  #
  # This is the metric that catches the failures nobody reports: a search that finds no rows, a
  # lookup that misses, a query that comes back +[]+. The protocol calls all of those success, the
  # model gets nothing it can use, and the author never hears about it.
  #
  # Only ever asked of a call that already succeeded — an error has its own outcome and is not also
  # "empty".
  module Emptiness
    module_function

    def empty_result?(result)
      return true if result.nil?

      structured = member(result, 'structuredContent')
      unless structured.nil?
        inner = unwrap_result_envelope(structured)
        # What comes out of the envelope is whatever the tool returned. When that is a string it
        # gets the same reading a text part does.
        return inner.is_a?(String) ? hollow_text?(inner) : hollow?(inner)
      end

      content = member(result, 'content')
      return empty_content?(content) if content.is_a?(Array)

      # Not a tool result shape at all — judge the thing itself.
      hollow?(result)
    end

    # Undoes a single-key <tt>{"result" => …}</tt> wrapper.
    #
    # SDKs that derive an output schema from a handler's return type wrap a non-object return: a
    # tool that returns +"[]"+ arrives as <tt>{"result" => "[]"}</tt>. Judging the envelope would
    # quietly kill this metric — every result would be a Hash with one key, so nothing would ever
    # be empty, and the one thing +is_empty+ exists to catch would never fire.
    def unwrap_result_envelope(structured)
      return structured unless structured.is_a?(Hash) && structured.size == 1

      structured['result'] || structured[:result] || structured
    end

    # MCP returns content as a list of parts.
    #
    # No parts is empty. One text part is the common case, and it is empty when the text is blank
    # or when the text is itself a serialised empty collection — +"[]"+ is the single most common
    # way a tool says "nothing found" while reporting success.
    def empty_content?(content)
      return true if content.empty?
      return false if content.size > 1

      part = content.first
      return false unless member(part, 'type') == 'text'

      text = member(part, 'text')
      text.is_a?(String) && hollow_text?(text)
    end

    def hollow_text?(text)
      trimmed = text.strip
      return true if trimmed.empty?

      hollow?(JSON.parse(trimmed))
    rescue JSON::ParserError
      # Prose, not JSON. A tool that answers in a sentence has said something.
      false
    end

    # Empty array, empty hash, blank string, or nothing at all.
    def hollow?(value)
      case value
      when nil then true
      when String then value.strip.empty?
      when Array, Hash then value.empty?
      else
        # A number or a boolean is an answer. 0 and false are results, not absences, and counting
        # them as empty would report working tools as broken.
        false
      end
    end

    # Reads a named member off a Hash with either key type, or off an object with a reader.
    def member(value, name)
      case value
      when nil then nil
      when Hash then value[name].nil? ? value[name.to_sym] : value[name]
      else
        value.respond_to?(name) ? value.public_send(name) : nil
      end
    rescue StandardError
      nil
    end
  end
end
