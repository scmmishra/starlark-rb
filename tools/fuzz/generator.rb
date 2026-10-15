# frozen_string_literal: true

module Fuzz
  # Builds random Starlark programs from the grammar reference in docs/spec.md.
  # Programs are mostly valid, including the static rules the resolver checks:
  # top-level code holds only definitions, loads, and assignments to fresh
  # names, return appears only in functions, break and continue only in loops,
  # and parameters and arguments come in a valid order. Random spacing,
  # comments, line breaks inside brackets, and trailing commas vary the layout.
  #
  # It avoids the inputs where we follow the spec over starlark-go on purpose:
  # tabs, carriage returns, NUL, assert, while, 0b and 00 literals, and br prefixes.
  class Generator
    NAMES = %w[x y z a b f g h i j k v w n s t None True False _ _x x1 éclair π 世界].freeze
    BINARY_OPS = %w[or and == != < > <= >= in not\ in | ^ & << >> - + * % / //].freeze
    # Unary not binds looser than comparisons, so it only starts a whole expression.
    UNARY_OPS = ["-", "+", "~"].freeze
    COMPARISON_OPS = %w[== != < > <= >= in not\ in].freeze
    AUGMENTED_OPS = %w[= += -= *= /= //= %= &= |= ^= <<= >>=].freeze
    MAX_DEPTH = 3
    ESCAPES = ['\\n', '\\t', '\\\\', "\\'", '\\"', '\\0', '\\101', '\\x41', '\\x7f', '\\u00e9', '\\U0001F600', '\\a', '\\v'].freeze

    def initialize(random)
      @random = random
    end

    # Simple names that locals, parameters, and keywords use.
    LOCAL_NAMES = %w[x y z a b f g h i j k v w n s t x1 éclair π 世界].freeze

    def program
      @fresh = 0
      @in_function = false
      @in_loop = false
      Array.new(rand(1..6)) { top_level_statement }.join
    end

    private

    def rand(range) = @random.rand(range)
    def chance(probability) = @random.rand < probability
    def pick(list) = list[rand(list.size)]

    # A rare top-level if or for keeps the resolver's errors in the mix.
    def top_level_statement
      return pick([if_stmt(0, 0), for_stmt(0, 0)]) if chance(0.03)

      case rand(10)
      when 0, 1 then def_stmt(0)
      when 2 then load_stmt
      when 3, 4, 5 then "#{fresh_name} = #{expr_list}#{comment}\n"
      else simple_stmt(0, 0)
      end
    end

    # A name no other statement binds, so top-level bindings never repeat.
    def fresh_name
      @fresh += 1
      "g#{@fresh}"
    end

    # Runs the block with the context changed, then restores it.
    def within(function: @in_function, loop: @in_loop)
      saved = [@in_function, @in_loop]
      @in_function = function
      @in_loop = loop
      yield
    ensure
      @in_function, @in_loop = saved
    end

    def indent(level) = "    " * level

    def statement(level, depth)
      return simple_stmt(level, depth) if depth > 2

      case rand(8)
      when 0 then if_stmt(level, depth + 1)
      when 1 then for_stmt(level, depth + 1)
      when 2 then def_stmt(level, depth + 1)
      else simple_stmt(level, depth)
      end
    end

    def suite(level, depth)
      return " #{small_stmts(depth)}#{comment}\n" if chance(0.2)

      body = Array.new(rand(1..3)) { statement(level + 1, depth) }.join
      blank = chance(0.2) ? "\n" : ""
      "#{comment}\n#{blank}#{body}"
    end

    def def_stmt(level, depth = 0)
      name = @in_function ? pick(LOCAL_NAMES) : fresh_name
      "#{indent(level)}def #{name}(#{params}):#{within(function: true, loop: false) { suite(level, depth) }}"
    end

    def if_stmt(level, depth)
      text = "#{indent(level)}if #{expr(1)}:#{suite(level, depth)}"
      rand(0..2).times { text += "#{indent(level)}elif #{expr(1)}:#{suite(level, depth)}" }
      text += "#{indent(level)}else:#{suite(level, depth)}" if chance(0.5)
      text
    end

    def for_stmt(level, depth)
      "#{indent(level)}for #{loop_vars} in #{expr_list}:#{within(loop: true) { suite(level, depth) }}"
    end

    def load_stmt
      # Loaded names must be identifiers. Names starting with "_" are a static error.
      bindings = Array.new(rand(1..3)) do
        exported = "\"#{pick(LOCAL_NAMES)}\""
        chance(0.5) ? exported : "#{fresh_name} = #{exported}"
      end
      trailing = chance(0.3) ? "," : ""
      "load(#{string_literal}, #{bindings.join(", ")}#{trailing})#{comment}\n"
    end

    def simple_stmt(level, depth)
      "#{indent(level)}#{small_stmts(depth)}#{comment}\n"
    end

    def small_stmts(depth)
      stmts = Array.new(chance(0.15) ? rand(2..3) : 1) { small_stmt(depth) }
      stmts.join(pick(["; ", ";"])) + (chance(0.05) ? ";" : "")
    end

    def small_stmt(depth)
      case rand(10)
      when 0 then return_stmt
      when 1 then pick(%w[pass] + (@in_loop ? %w[break continue] : []))
      when 2, 3, 4 then assignment
      else expr_list(depth)
      end
    end

    def return_stmt
      return "pass" unless @in_function

      chance(0.3) ? "return" : "return #{expr_list}"
    end

    # At top level, only a fresh name may be assigned. A tuple or list target
    # takes plain "=" only.
    def assignment
      return "#{fresh_name} = #{expr_list}" unless @in_function

      case rand(5)
      when 0 then "#{pick(LOCAL_NAMES)}, #{pick(LOCAL_NAMES)} = #{expr_list}"
      when 1 then "[#{pick(LOCAL_NAMES)}, #{pick(LOCAL_NAMES)}] = #{expr_list}"
      when 2 then "#{pick(LOCAL_NAMES)}.#{pick(LOCAL_NAMES)} #{pick(AUGMENTED_OPS)} #{expr_list}"
      when 3 then "#{pick(LOCAL_NAMES)}[#{expr(2)}] #{pick(AUGMENTED_OPS)} #{expr_list}"
      else "#{pick(LOCAL_NAMES)} #{pick(AUGMENTED_OPS)} #{expr_list}"
      end
    end

    def loop_vars
      vars = Array.new(chance(0.3) ? rand(2..3) : 1) do
        case rand(6)
        when 0 then "#{pick(LOCAL_NAMES)}.#{pick(LOCAL_NAMES)}"
        when 1 then "#{pick(LOCAL_NAMES)}[#{expr(3)}]"
        else pick(LOCAL_NAMES)
        end
      end
      vars.size > 1 && chance(0.2) ? "(#{vars.join(", ")})" : vars.join(", ")
    end

    # Distinct names in a valid order: required, optional, then * or *args
    # with keyword-only names after it, then **kwargs. A bare * needs at least
    # one keyword-only name. A lambda's list cannot end with a comma.
    def params(trailing_comma: true)
      names = LOCAL_NAMES.shuffle(random: @random)
      list = []
      list << names.pop if chance(0.7)
      list << "#{names.pop}=#{expr(3)}" if chance(0.4)
      if chance(0.3)
        bare = chance(0.5)
        list << (bare ? "*" : "*#{names.pop}")
        list << (chance(0.5) ? names.pop : "#{names.pop}=#{expr(3)}") if bare || chance(0.5)
      end
      list << "**#{names.pop}" if chance(0.2)
      list.join(spacing_comma) + (trailing_comma && list.any? && chance(0.2) && !list.last.start_with?("*") ? "," : "")
    end

    def expr_list(depth = 0)
      return expr(depth) unless chance(0.15)

      Array.new(rand(2..3)) { expr(depth + 1) }.join(", ")
    end

    def expr(depth)
      return primary(depth) if depth > MAX_DEPTH

      case rand(14)
      when 0, 1, 2, 3 then binary_chain(depth)
      when 5 then "not #{condition(depth + 1)}"
      when 6 then "#{pick(UNARY_OPS)}#{primary(depth + 1)}"
      when 7 then "#{expr(depth + 1)} if #{condition(depth + 1)} else #{expr(depth + 1)}"
      when 8 then "lambda #{params(trailing_comma: false)}: #{expr(depth + 1)}"
      when 9 then "(#{expr(depth + 1)})"
      else primary(depth)
      end
    end

    # Two to four operands with random operators, so precedence and
    # associativity get exercised without parentheses.
    # Comparisons do not associate, so a chain holds at most one.
    def binary_chain(depth)
      operands = Array.new(rand(2..4)) { chance(0.3) ? "#{pick(UNARY_OPS)}#{primary(depth + 1)}" : primary(depth + 1) }
      compared = false
      operands.each_with_index.map do |operand, i|
        next operand if i.zero?

        op = pick(compared ? BINARY_OPS - COMPARISON_OPS : BINARY_OPS)
        compared ||= COMPARISON_OPS.include?(op)
        " #{op} #{operand}"
      end.join
    end

    # The condition of a conditional expression cannot be a lambda or another conditional.
    def condition(depth)
      chance(0.5) ? binary_chain(depth) : primary(depth)
    end

    def primary(depth)
      base = operand(depth)
      (depth > MAX_DEPTH ? 0 : rand(0..2)).times do
        base += case rand(3)
                # "1.x" lexes as the float "1." and the name "x", so a decimal number gets a space.
                when 0 then "#{" " if base.match?(/\A\.?\d/)}.#{pick(LOCAL_NAMES)}"
                when 1 then subscript(depth)
                else "(#{args(depth)})"
                end
      end
      base
    end

    def subscript(depth)
      parts = [chance(0.6) ? expr(depth + 1) : ""]
      if chance(0.5)
        parts << (chance(0.5) ? expr(depth + 1) : "")
        parts << (chance(0.5) ? expr(depth + 1) : "") if chance(0.4)
        return "[#{parts.join(":")}]"
      end
      parts[0] = expr(depth + 1) if parts[0].empty?
      "[#{parts[0]}]"
    end

    # Arguments in a valid order: positional, keyword with distinct names,
    # then *args, then **kwargs.
    def args(depth)
      list = Array.new(rand(0..2)) { expr(depth + 1) }
      list.concat(LOCAL_NAMES.sample(rand(0..2), random: @random).map { |name| "#{name}=#{expr(depth + 1)}" })
      list << "*#{expr(depth + 1)}" if chance(0.2)
      list << "**#{expr(depth + 1)}" if chance(0.2)
      list.join(spacing_comma) + (list.any? && chance(0.2) ? "," : "")
    end

    def operand(depth)
      return pick(NAMES) if depth > MAX_DEPTH

      case rand(16)
      when 0, 1, 2, 3 then pick(NAMES)
      when 4, 5 then int_literal
      when 6 then float_literal
      when 7, 8 then string_literal
      when 9 then bytes_literal
      when 10 then "[#{elements(depth)}]"
      when 11 then "{#{entries(depth)}}"
      when 12
        items = elements(depth)
        "(#{items}#{!items.empty? && !items.end_with?(",") && chance(0.5) ? "," : ""})"
      when 13 then "[#{expr(depth + 1)} #{clauses(depth)}]"
      when 14 then "{#{expr(depth + 1)}: #{expr(depth + 1)} #{clauses(depth)}}"
      else "()"
      end
    end

    def elements(depth)
      list = Array.new(rand(0..3)) { expr(depth + 1) }
      separator = chance(0.2) ? ",\n    " : spacing_comma
      list.join(separator) + (list.any? && chance(0.3) ? "," : "")
    end

    def entries(depth)
      list = Array.new(rand(0..3)) { "#{expr(depth + 1)}: #{expr(depth + 1)}" }
      list.join(spacing_comma) + (list.any? && chance(0.3) ? "," : "")
    end

    def clauses(depth)
      text = "for #{comprehension_vars} in #{primary(depth + 1)}"
      rand(0..2).times do
        text += chance(0.5) ? " if #{primary(depth + 1)}" : " for #{comprehension_vars} in #{primary(depth + 1)}"
      end
      text
    end

    def comprehension_vars
      names = LOCAL_NAMES.sample(chance(0.3) ? 2 : 1, random: @random)
      names.size > 1 && chance(0.3) ? "(#{names.join(", ")})" : names.join(", ")
    end

    def int_literal
      case rand(6)
      when 0 then "0"
      when 1 then "0x#{rand(0..0xFFFF).to_s(16)}"
      when 2 then "0o#{rand(0..0o777).to_s(8)}"
      when 3 then (2**rand(60..130) + rand(0..1000)).to_s
      else rand(1..100_000).to_s
      end
    end

    def float_literal
      pick(["0.0", "1.", ".5", "1e10", "1.5e-3", "2.5E+7", "#{rand(1..999)}.#{rand(0..999)}", "1e308", "5e-324", "1e-400"])
    end

    TEXT = (%w[a b é 😀 {] + [" ", "x y"]).freeze

    # Escaped quotes are safe in any quote style. Raw strings get plain text only,
    # because a raw backslash before the closing quote would escape it.
    def string_literal
      body = Array.new(rand(0..4)) { chance(0.3) ? pick(ESCAPES) : pick(TEXT) }.join
      case rand(8)
      when 0 then "'''#{body}\nmore'''"
      when 1 then "r'#{Array.new(rand(0..4)) { pick(TEXT) }.join}'"
      when 2 then "\"#{body}\""
      else "'#{body}'"
      end
    end

    def bytes_literal
      (chance(0.3) ? "rb" : "b") + string_literal.sub(/\Ar/, "").gsub("\\U0001F600", "\\xff")
    end

    def spacing_comma = pick([", ", ",", " , "])

    def comment = chance(0.1) ? "  # #{pick(%w[note é TODO])}" : ""
  end
end
