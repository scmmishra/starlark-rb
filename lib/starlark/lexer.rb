# frozen_string_literal: true

module Starlark
  # Turns Starlark source into tokens. See "Lexical elements" in docs/spec.md.
  #
  # The spec leaves INDENT, OUTDENT, NEWLINE, and EOF undefined, so those follow
  # starlark-go's scanner. Token positions and error messages also follow
  # starlark-go, so tools/oracle can compare the two outputs exactly.
  #
  # Kinds use starlark-go's token names in lowercase, for example :ident,
  # :plus_eq, and :outdent. Keywords and reserved words use their own text as
  # the kind, for example :def and :while.
  class Lexer
    Token = Data.define(:kind, :value, :line, :column)

    KEYWORDS = %w[
      and break continue def elif else for if in lambda load not or pass return
      as assert async await class del except finally from global import is
      nonlocal raise try while with yield
    ].to_h { |word| [word, word.to_sym] }.freeze

    # Characters that may be followed by "=" to form a compound token.
    SINGLE_OR_EQ = {
      "=" => %i[eq eql], "<" => %i[lt le], ">" => %i[gt ge], "+" => %i[plus plus_eq],
      "-" => %i[minus minus_eq], "%" => %i[percent percent_eq], "/" => %i[slash slash_eq],
      "&" => %i[amp amp_eq], "|" => %i[pipe pipe_eq], "^" => %i[circumflex circumflex_eq],
      "!" => [nil, :neq]
    }.freeze

    SINGLE = { ":" => :colon, ";" => :semi, "~" => :tilde, "," => :comma }.freeze
    OPEN_BRACKETS = { "(" => :lparen, "[" => :lbrack, "{" => :lbrace }.freeze
    CLOSE_BRACKETS = { ")" => :rparen, "]" => :rbrack, "}" => :rbrace }.freeze

    ONE_CHAR_ESCAPES = {
      "a" => 0x07, "b" => 0x08, "f" => 0x0C, "n" => 0x0A, "r" => 0x0D, "t" => 0x09,
      "v" => 0x0B, "\\" => 0x5C, "'" => 0x27, '"' => 0x22
    }.freeze

    MAX_NESTING = 1000
    MAX_CODE_POINT = 0x10FFFF
    SURROGATES = (0xD800..0xDFFF)
    ASCII = (0..127).map { |byte| byte.chr.freeze }.freeze
    QUOTE_BYTES = ["'".ord, '"'.ord].freeze
    GO_CONTROL_ESCAPES = {
      "\a" => "\\a", "\b" => "\\b", "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\v" => "\\v"
    }.freeze
    # Go's unicode.IsPrint, used when quoting a character in an error message.
    GO_PRINTABLE = /[\p{L}\p{M}\p{N}\p{P}\p{S} ]/
    TAB_INDENT_MESSAGE = "Tab characters are not allowed for indentation. Use spaces instead."

    def self.tokenize(source)
      new(source).tokenize
    end

    def initialize(source)
      @src = normalize(source)
      @pos = 0
      @line = 1
      @col = 1
      @depth = 0
      @indents = [0]
      @dents = 0
      @line_start = true
    end

    # The position just after the last token read. starlark-go reports many
    # parse errors here.
    def position
      [@line, @col]
    end

    def tokenize
      tokens = []
      loop do
        token = next_token
        tokens << token
        return tokens if token.kind == :eof
      end
    end

    def next_token
      loop do
        blank = false
        saved_line_start = @line_start
        if @line_start
          @line_start = false
          blank = scan_indentation
        end

        if @dents != 0
          start_token
          if @dents.negative?
            @dents += 1
            return token(:outdent)
          end
          @dents -= 1
          return token(:indent)
        end

        c = peek
        while c == " " || c == "\t" || c == "\r"
          advance
          c = peek
        end

        if c == "#"
          until c.nil? || c == "\n"
            advance
            c = peek
          end
        end

        if c == "\n"
          @line_start = true
          if @depth.positive? || blank
            advance
            next
          end
          start_token
          advance
          return token(:newline)
        end

        if c.nil?
          if @indents.size > 1
            if saved_line_start
              @dents = 1 - @indents.size
              @indents = [0]
              next
            end
            @line_start = true
            start_token
            return token(:newline)
          end
          start_token
          return token(:eof)
        end

        if c == "\\"
          advance
          error("stray backslash in program") unless peek == "\n"
          advance
          next
        end

        return scan_token(c)
      end
    end

    private

    # Reads the spaces at the start of a line and queues INDENT or OUTDENT
    # tokens. Returns true if the line is blank or holds only a comment.
    def scan_indentation
      col = 0
      tab = false
      c = peek
      while c == " " || c == "\t" || c == "\r"
        tab = true if c == "\t"
        # A lone carriage return is white space, but it does not count as indentation.
        col += 1 unless c == "\r"
        advance
        c = peek
      end

      blank = c.nil? || c == "#" || c == "\n"
      # A blank or comment-only line returns before the tab check below, so its
      # leading whitespace may contain tabs. This is starlark-go's behavior,
      # kept on purpose because it is more permissive. Java Starlark rejects
      # such tabs. The spec does not say whether these lines count as indentation.
      return blank if blank || @depth.positive?

      # Spec, "Special tokens": indentation can only be composed of spaces.
      # starlark-go accepts tabs here. Java Starlark rejects them, as does this lexer.
      error(TAB_INDENT_MESSAGE) if tab

      current = @indents.last
      if col > current
        @dents += 1
        @indents << col
      elsif col < current
        while col < @indents.last
          @dents -= 1
          @indents.pop
        end
        error("unindent does not match any outer indentation level") if col != @indents.last
      end
      false
    end

    def scan_token(c)
      start_token

      return scan_string(c) if c == '"' || c == "'"
      return scan_identifier(c) if ident_start?(c)

      if (kind = OPEN_BRACKETS[c])
        @depth += 1
        error("excessive nesting") if @depth > MAX_NESTING
        advance
        return token(kind)
      end

      if (kind = CLOSE_BRACKETS[c])
        error("unexpected '#{c}'") if @depth.zero?
        @depth -= 1
        advance
        return token(kind)
      end

      return scan_number(c) if digit?(c) || c == "."
      return scan_operator(c) if SINGLE_OR_EQ.key?(c) || c == "*"

      if (kind = SINGLE[c])
        advance
        return token(kind)
      end

      error("unexpected input character #{quote_rune(c)}")
    end

    def scan_operator(c)
      advance

      if c == "*"
        case peek
        when "*"
          advance
          return token(:starstar)
        when "="
          advance
          return token(:star_eq)
        end
        return token(:star)
      end

      single, with_eq = SINGLE_OR_EQ.fetch(c)
      if peek == "="
        advance
        return token(with_eq)
      end

      if (c == "<" || c == ">" || c == "/") && peek == c
        advance
        doubled = { "<" => :ltlt, ">" => :gtgt, "/" => :slashslash }.fetch(c)
        if peek == "="
          advance
          return token(:"#{doubled}_eq")
        end
        return token(doubled)
      end

      return token(single) unless c == "!"

      error("unexpected input character '!'", @tok_line, @tok_col)
    end

    def scan_identifier(c)
      if (c == "r" || c == "b") && quote_byte?(1)
        advance
        return scan_string(peek)
      end

      # Spec, "Bytes literals": both rb and br mark a raw bytes literal.
      # starlark-go only recognizes rb.
      if ((c == "r" && @src.getbyte(@pos + 1) == "b".ord) || (c == "b" && @src.getbyte(@pos + 1) == "r".ord)) &&
         quote_byte?(2)
        advance
        advance
        return scan_string(peek)
      end

      start = @pos
      advance while (c = peek) && ident?(c)
      name = @src.byteslice(start, @pos - start)
      kind = KEYWORDS[name]
      kind ? token(kind) : token(:ident, name)
    end

    def scan_string(quote)
      quote_line = @line
      quote_col = @col
      prefix_start = @tok_start
      triple = @src.byteslice(@pos, 3) == quote * 3

      advance
      if triple
        advance
        advance
        quotes = 0
        loop do
          error("unexpected EOF in string", @tok_line, @tok_col) if peek.nil?
          c = advance
          if c == quote
            quotes += 1
            break if quotes == 3
          else
            quotes = 0
          end
          next unless c == "\\"

          error("unexpected EOF in string", @tok_line, @tok_col) if peek.nil?
          advance
        end
      else
        loop do
          error("unexpected EOF in string", @tok_line, @tok_col) if peek.nil?
          c = advance
          break if c == quote

          error("unexpected newline in string", @tok_line, @tok_col) if c == "\n"
          next unless c == "\\"

          error("unexpected EOF in string", @tok_line, @tok_col) if peek.nil?
          advance
        end
      end

      raw = @src.byteslice(prefix_start, @pos - prefix_start)
      prefix = raw[0, raw.index(quote)]
      delimiter = triple ? 3 : 1
      body = raw.byteslice(prefix.bytesize + delimiter, raw.bytesize - prefix.bytesize - (2 * delimiter))
      bytes = prefix.include?("b")

      value =
        if prefix.include?("r")
          body.b
        else
          unescape(body, bytes: bytes, line: quote_line, column: quote_col)
        end

      if bytes
        token(:bytes, value.force_encoding(Encoding::BINARY).freeze)
      else
        token(:string, value.force_encoding(Encoding::UTF_8).freeze)
      end
    end

    # Decodes the escape sequences in a non-raw string or bytes literal.
    # Error messages match starlark-go's unquote function.
    def unescape(body, bytes:, line:, column:)
      return body.b unless body.include?("\\")

      out = String.new(capacity: body.bytesize, encoding: Encoding::BINARY)
      rest = body.b
      fail_with = ->(message) { error(message, line, column) }

      until rest.empty?
        index = rest.index("\\")
        unless index
          out << rest
          break
        end
        out << rest.byteslice(0, index)
        rest = rest.byteslice(index, rest.bytesize - index)

        fail_with.call("truncated escape sequence \\") if rest.bytesize == 1

        escape = rest.getbyte(1)
        case escape.chr
        # An escaped newline is ignored. A lone "\r" counts here too, as in
        # Java Starlark and starlark-go, though it is white space elsewhere.
        when "\n", "\r"
          rest = rest.byteslice(2..)
        when *ONE_CHAR_ESCAPES.keys
          out << ONE_CHAR_ESCAPES.fetch(escape.chr)
          rest = rest.byteslice(2..)
        when "0".."7"
          digits = rest.byteslice(1..)[/\A[0-7]{1,3}/]
          n = digits.to_i(8)
          if !bytes && n > 127
            fail_with.call(format("non-ASCII octal escape \\%o (use \\u%04X for the UTF-8 encoding of U+%04X)", n, n, n))
          end
          fail_with.call(format("invalid escape sequence \\%03o", n)) if n >= 256
          out << n
          rest = rest.byteslice((1 + digits.bytesize)..)
        when "x"
          fail_with.call("truncated escape sequence #{text(rest)}") if rest.bytesize < 4
          hex = rest.byteslice(2, 2)
          fail_with.call("invalid escape sequence #{text(rest.byteslice(0, 4))}") unless hex.match?(/\A\h\h\z/)
          n = hex.to_i(16)
          if !bytes && n > 127
            fail_with.call(format("non-ASCII hex escape %s (use \\u%04X for the UTF-8 encoding of U+%04X)",
                                  text(rest.byteslice(0, 4)), n, n))
          end
          out << n
          rest = rest.byteslice(4..)
        when "u", "U"
          size = escape.chr == "u" ? 6 : 10
          fail_with.call("truncated escape sequence #{text(rest)}") if rest.bytesize < size
          hex = rest.byteslice(2, size - 2)
          fail_with.call("invalid escape sequence #{text(rest.byteslice(0, size))}") unless hex.match?(/\A\h+\z/)
          n = hex.to_i(16)
          if n > MAX_CODE_POINT
            # starlark-go prints the escaped value after "max", not U+10FFFF. We match its text.
            fail_with.call(format("code point out of range: %s (max \\U%08x)", text(rest.byteslice(0, size)), n))
          end
          fail_with.call(format("invalid Unicode code point U+%04X", n)) if SURROGATES.cover?(n)
          out << [n].pack("U").b
          rest = rest.byteslice(size..)
        else
          # starlark-go formats the byte with %c, which prints it as a Latin-1 rune.
          fail_with.call("invalid escape sequence \\#{[escape].pack("U")}")
        end
      end

      out
    end

    # Follows starlark-go's scanNumber, except where noted.
    def scan_number(c)
      start = @pos
      fraction = false
      exponent = false

      if c == "."
        advance
        unless digit?(peek)
          return token(:dot)
        end

        fraction = true
      elsif c == "0"
        advance
        c = peek
        case c
        when "."
          fraction = true
        when "x", "X"
          advance
          error("invalid hex literal", @tok_line, @tok_col) unless hex_digit?(peek)
          advance while hex_digit?(peek)
        when "o", "O"
          advance
          error("invalid octal literal") unless octal_digit?(peek)
          advance while octal_digit?(peek)
        when "b", "B"
          # The spec has no binary literals. starlark-go accepts them, Java Starlark rejects them.
          error("invalid int literal", @tok_line, @tok_col)
        else
          all_zeros = true
          octal = true
          while digit?(c = peek)
            all_zeros = false if c != "0"
            octal = false if c > "7"
            advance
          end
          if c == "."
            fraction = true
          elsif c == "e" || c == "E"
            exponent = true
          elsif @pos - start > 1
            # The spec allows "0" only as a lone digit. starlark-go accepts "00" as 0,
            # Java Starlark rejects it, as does this lexer.
            if octal && !all_zeros
              error("obsolete form of octal literal; use 0o#{@src.byteslice(start + 1, @pos - start - 1)}")
            end
            error("invalid int literal", @tok_line, @tok_col)
          end
        end
      else
        advance while digit?(c = peek)
        if c == "."
          fraction = true
        elsif c == "e" || c == "E"
          exponent = true
        end
      end

      if fraction
        advance
        advance while digit?(c = peek)
        exponent = true if c == "e" || c == "E"
      end

      if exponent
        advance
        c = peek
        if c == "+" || c == "-"
          advance
          error("invalid float literal") unless digit?(peek)
        end
        error("invalid float literal") unless digit?(peek)
        advance while digit?(peek)
      end

      text = @src.byteslice(start, @pos - start)
      if fraction || exponent
        value = text.to_f
        # Spec, "Literals": a float literal too large to be finite is a static error.
        error("invalid float literal") unless value.finite?
        return token(:float, value)
      end

      token(:int, parse_int(text))
    end

    def parse_int(text)
      case text[0, 2]
      when "0x", "0X" then text[2..].to_i(16)
      when "0o", "0O" then text[2..].to_i(8)
      else text.to_i
      end
    end

    # Error messages that quote raw literal bytes must be UTF-8 strings.
    def text(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8)
    end

    def normalize(source)
      src = source.dup.force_encoding(Encoding::UTF_8)
      # starlark-go decodes each invalid byte as U+FFFD.
      src = src.scrub { |bad| "�" * bad.bytesize } unless src.valid_encoding?
      # "\r\n" is one newline, as in starlark-go. A lone "\r" is not a newline:
      # the spec lists carriage return as white space, and Java Starlark agrees.
      # starlark-go treats a lone "\r" as a newline.
      src.gsub("\r\n", "\n")
    end

    def peek
      byte = @src.getbyte(@pos)
      return nil if byte.nil?
      return ASCII[byte] if byte < 0x80

      @src.byteslice(@pos, utf8_length(byte))
    end

    def advance
      c = peek
      @pos += c.bytesize
      if c == "\n"
        @line += 1
        @col = 1
      else
        @col += 1
      end
      c
    end

    def utf8_length(lead)
      if lead >= 0xF0 then 4
      elsif lead >= 0xE0 then 3
      else 2
      end
    end

    def quote_byte?(offset)
      QUOTE_BYTES.include?(@src.getbyte(@pos + offset))
    end

    def start_token
      @tok_start = @pos
      @tok_line = @line
      @tok_col = @col
    end

    def token(kind, value = nil)
      Token.new(kind: kind, value: value, line: @tok_line, column: @tok_col)
    end

    def error(message, line = @line, column = @col)
      raise SyntaxError.new(message, line: line, column: column)
    end

    def digit?(c)
      !c.nil? && c >= "0" && c <= "9" && c.bytesize == 1
    end

    def octal_digit?(c)
      !c.nil? && c >= "0" && c <= "7" && c.bytesize == 1
    end

    def hex_digit?(c)
      !c.nil? && c.bytesize == 1 && c.match?(/\h/)
    end

    def ident_start?(c)
      c == "_" || c.match?(/\p{L}/)
    end

    def ident?(c)
      digit?(c) || ident_start?(c)
    end

    # Formats a character like Go's %q verb for runes.
    def quote_rune(c)
      code = c.ord
      body =
        if c == "'" then "\\'"
        elsif c == "\\" then "\\\\"
        elsif (name = GO_CONTROL_ESCAPES[c]) then name
        elsif code < 0x20 || code == 0x7F then format("\\x%02x", code)
        elsif c.match?(GO_PRINTABLE) then c
        elsif code < 0x10000 then format("\\u%04x", code)
        else format("\\U%08x", code)
        end
      "'#{body}'"
    end
  end
end
