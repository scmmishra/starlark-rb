# frozen_string_literal: true

module Starlark
  # Quotes a string or bytes value for repr. A port of starlark-go's
  # syntax.Quote, so output matches the eval oracle.
  module Quote
    module_function

    NAMED = { 0x07 => "\\a", 0x08 => "\\b", 0x0C => "\\f", 0x0A => "\\n", 0x0D => "\\r", 0x09 => "\\t",
              0x0B => "\\v" }.freeze

    def call(value, bytes: false)
      out = +""
      out << "b" if bytes
      out << '"'
      raw = value.b
      i = 0
      while i < raw.bytesize
        char, width = decode(raw, i)
        if char.nil?
          # An invalid byte. The result is not a legal literal.
          out << format("\\x%02x", raw.getbyte(i))
        else
          out << escape(char)
        end
        i += width
      end
      out << '"'
      out.force_encoding(Encoding::UTF_8)
    end

    # Returns the character at byte i and its width, or [nil, 1] for an
    # invalid byte.
    def decode(raw, i)
      lead = raw.getbyte(i)
      return [lead.chr, 1] if lead < 0x80

      width = if lead >= 0xF0 then 4 elsif lead >= 0xE0 then 3 elsif lead >= 0xC0 then 2 else 1 end
      char = raw.byteslice(i, width).force_encoding(Encoding::UTF_8)
      char.valid_encoding? && char.length == 1 ? [char, width] : [nil, 1]
    end

    def escape(char)
      return "\\#{char}" if char == '"' || char == "\\"
      return char if char.match?(Lexer::GO_PRINTABLE)

      code = char.ord
      return NAMED[code] if NAMED.key?(code)
      return format("\\x%02x", code) if code < 0x20 || code == 0x7F
      return format("\\u%04x", code) if code < 0x10000

      format("\\U%08x", code)
    end
  end
end
