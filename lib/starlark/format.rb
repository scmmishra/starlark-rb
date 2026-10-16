# frozen_string_literal: true

module Starlark
  # String formatting: the % operator and str.format. Ports of
  # starlark-go's interpolate and string_format, so messages match.
  module Format
    module_function

    def interpolate(format, x)
      out = +"".b
      format = format.b
      index = 0
      nargs = x.is_a?(Tuple) ? x.length : 1
      until format.empty?
        i = format.index("%")
        unless i
          out << format
          break
        end
        out << format.byteslice(0, i)
        format = format.byteslice(i + 1..)

        if format.start_with?("%")
          out << "%"
          format = format.byteslice(1..)
          next
        end

        if format.start_with?("(")
          format = format.byteslice(1..)
          j = format.index(")")
          raise EvalError, "incomplete format key" unless j

          key = text(format.byteslice(0, j))
          raise EvalError, "format requires a mapping" unless x.is_a?(Dict)

          arg = x.fetch(key) { raise EvalError, "key not found: #{key}" }
          format = format.byteslice(j + 1..)
        else
          raise EvalError, "not enough arguments for format string" if index >= nargs

          arg = x.is_a?(Tuple) ? x.elems[index] : x
        end

        raise EvalError, "incomplete format" if format.empty?

        conversion = format.byteslice(0, 1)
        out << convert(conversion, arg).b
        format = format.byteslice(1..)
        index += 1
      end
      raise EvalError, "too many arguments for format string" if index < nargs && !x.is_a?(Dict)

      text(out)
    end

    def convert(conversion, arg)
      case conversion
      when "s" then arg.is_a?(String) ? arg : Value.repr(arg)
      when "r" then Value.repr(arg)
      when "d", "i", "o", "x", "X" then integer(conversion, arg)
      when "e", "f", "g", "E", "F", "G" then float(conversion, arg)
      when "c" then character(arg)
      else raise EvalError, "unknown conversion %#{text(conversion)}"
      end
    end

    def integer(conversion, arg)
      value = case arg
              when Integer then arg
              when Float
                raise EvalError, "%#{conversion} format requires integer: cannot convert float infinity to integer" if arg.infinite?
                raise EvalError, "%#{conversion} format requires integer: cannot convert float NaN to integer" if arg.nan?

                arg.to_i
              else
                raise EvalError, "%#{conversion} format requires integer: cannot convert #{Value.type(arg)} to int"
              end
      sign = value.negative? ? "-" : ""
      digits = case conversion
               when "o" then value.abs.to_s(8)
               when "x" then value.abs.to_s(16)
               when "X" then value.abs.to_s(16).upcase
               else value.abs.to_s
               end
      sign + digits
    end

    def float(conversion, arg)
      value = case arg
              when Float then arg
              when Integer then arg.to_f
              else raise EvalError, "%#{conversion} format requires float, not #{Value.type(arg)}"
              end
      return non_finite(value) unless value.finite?
      return Value.float_str(value) if conversion == "g"
      return Value.float_str(value).tr("e", "E") if conversion == "G"
      # starlark-go passes 'F' to Go's strconv.FormatFloat, which does not
      # support it and returns "%F".
      return "%F" if conversion == "F"

      format("%.6#{conversion}", value)
    end

    def non_finite(value)
      return "nan" if value.nan?

      value.positive? ? "+inf" : "-inf"
    end

    def character(arg)
      case arg
      when Integer
        if arg.negative? || arg > 0x10FFFF || !Operators::INT32.cover?(arg)
          raise EvalError, "%c format requires a valid Unicode code point, got #{arg}"
        end

        (0xD800..0xDFFF).cover?(arg) ? "\uFFFD" : [arg].pack("U")
      when String
        # An invalid byte counts as one character, U+FFFD, as in Go.
        chars = Methods.runes(arg)
        raise EvalError, "%c format requires a single-character string" unless chars.length == 1

        chars.first
      else
        raise EvalError, "%c format requires int or single-character string, not #{Value.type(arg)}"
      end
    end

    def text(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).freeze
    end

    # str.format

    def format_method(template, args, kwargs)
      out = +"".b
      rest = template.b
      auto = false
      manual = false
      index = 0
      loop do
        i = rest.index("{")
        literal = i ? rest.byteslice(0, i) : rest
        loop do
          j = literal.index("}")
          unless j
            out << literal
            break
          end
          raise EvalError, "format: single '}' in format" if literal.bytesize == j + 1 || literal.getbyte(j + 1) != 0x7D

          out << literal.byteslice(0, j + 1)
          literal = literal.byteslice(j + 2..)
        end
        break unless i

        if rest.getbyte(i + 1) == 0x7B
          out << "{"
          rest = rest.byteslice(i + 2..)
          next
        end

        rest = rest.byteslice(i + 1..)
        close = rest.index("}")
        raise EvalError, "format: unmatched '{' in format" unless close

        field = rest.byteslice(0, close)
        rest = rest.byteslice(close + 1..)
        name, conversion, spec = parse_field(field)

        arg =
          if name.empty?
            raise EvalError, "format: cannot switch from manual field specification to automatic field numbering" if manual

            auto = true
            raise EvalError, "format: tuple index out of range" if index >= args.length

            index += 1
            args[index - 1]
          elsif name.match?(/\A[0-9]+\z/n)
            raise EvalError, "format: cannot switch from automatic field numbering to manual field specification" if auto

            manual = true
            num = name.to_i
            raise EvalError, "format: tuple index out of range" if num >= args.length

            args[num]
          else
            keyword(name, kwargs)
          end

        raise EvalError, "format spec features not supported in replacement fields: #{text(spec)}" unless spec.empty?

        out << case text(conversion)
               when "s" then (arg.is_a?(String) ? arg : Value.repr(arg)).b
               when "r" then Value.repr(arg).b
               else raise EvalError, "format: unknown conversion #{Quote.call(text(conversion))}"
               end
      end
      text(out)
    end

    def parse_field(field)
      bang = field.index("!")
      if bang
        name = field.byteslice(0, bang)
        rest = field.byteslice(bang + 1..)
        colon = rest.index(":")
        colon ? [name, rest.byteslice(0, colon), rest.byteslice(colon + 1..)] : [name, rest, "".b]
      else
        colon = field.index(":")
        colon ? [field.byteslice(0, colon), "s".b, field.byteslice(colon + 1..)] : [field, "s".b, "".b]
      end
    end

    def keyword(name, kwargs)
      key = text(name)
      kwargs.each { |kw, value| return value if kw == key }
      raise EvalError, "format: attribute syntax x.y is not supported in replacement fields: #{key}" if key.include?(".")
      raise EvalError, "format: element syntax a[i] is not supported in replacement fields: #{key}" if key.include?("[")
      raise EvalError, "format: nested replacement fields not supported" if key.include?("{")

      raise EvalError, "format: keyword #{key} not found"
    end
  end
end
