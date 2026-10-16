# frozen_string_literal: true

module Starlark
  # Starlark values. None, bool, int, float, and string use Ruby's nil,
  # true/false, Integer, Float, and frozen UTF-8 String. The other types are
  # classes in this file.
  #
  # Messages follow starlark-go, so they match the eval oracle.

  # Raised for a dynamic error. backtrace_frames lists the Starlark call
  # stack, innermost last, as [function name, line, column] triples.
  class EvalError < Error
    attr_accessor :backtrace_frames

    def initialize(message, backtrace_frames = [])
      super(message)
      @backtrace_frames = backtrace_frames
    end
  end

  # A mutable container: list, dict, or set. Freezing is a Starlark flag,
  # separate from Ruby's freeze, because iteration still updates a counter.
  module Container
    def frozen_value? = @frozen

    # Freezes this container and everything it holds.
    def freeze_value!
      return if @frozen

      @frozen = true
      each_held { |value| Value.freeze(value) }
    end

    # Runs the block with mutation forbidden, as the spec requires during
    # iteration. A frozen container needs no counter.
    def iterating
      return yield if @frozen

      @iterators += 1
      begin
        yield
      ensure
        @iterators -= 1
      end
    end

    def check_mutable(verb, type)
      raise EvalError, "cannot #{verb} frozen #{type}" if @frozen
      raise EvalError, "cannot #{verb} #{type} during iteration" if @iterators.positive?
    end
  end

  class List
    include Container
    attr_reader :elems

    def initialize(elems = [])
      @elems = elems
      @frozen = false
      @iterators = 0
    end

    def each_held(&) = @elems.each(&)
    def length = @elems.length

    def check_mutable!(verb = "assign to element of")
      check_mutable(verb, "list")
    end
  end

  class Tuple
    attr_reader :elems

    def initialize(elems)
      @elems = elems.frozen? ? elems : elems.dup.freeze
    end

    def length = @elems.length
  end

  # A dict keeps insertion order. Keys are stored under their Value.key form,
  # so 1 and 1.0 are the same key, as Starlark equality requires.
  class Dict
    include Container

    def initialize
      @table = {}
      @frozen = false
      @iterators = 0
    end

    def each_held
      @table.each_value do |key, value|
        yield key
        yield value
      end
    end

    def length = @table.length
    def keys = @table.each_value.map(&:first)
    def values = @table.each_value.map(&:last)
    def items = @table.each_value.to_a

    def get(key)
      entry = @table[Value.key(key)]
      entry && entry[1]
    end

    def key?(key) = @table.key?(Value.key(key))

    def fetch(key)
      entry = @table[Value.key(key)]
      entry ? entry[1] : yield
    end

    # Inserts or replaces. Replacing keeps the original key and position.
    def set(key, value)
      check_mutable("insert into", "hash table")
      hash_key = Value.key(key)
      if (entry = @table[hash_key])
        entry[1] = value
      else
        @table[hash_key] = [key, value]
      end
    end

    def delete(key)
      check_mutable("delete from", "hash table")
      entry = @table.delete(Value.key(key))
      entry && entry[1]
    end

    def clear
      check_mutable("clear", "hash table")
      @table.clear
    end

    def pop_first
      check_mutable("delete from", "hash table")
      hash_key, entry = @table.first
      @table.delete(hash_key)
      entry
    end

    def each_key(&)
      iterating { keys.each(&) }
    end
  end

  class Set
    include Container

    def initialize(elems = [])
      @table = {}
      @frozen = false
      @iterators = 0
      elems.each { |elem| @table[Value.key(elem)] ||= elem }
    end

    def each_held(&) = @table.each_value(&)
    def length = @table.length
    def elems = @table.values
    def include?(value) = @table.key?(Value.key(value))

    def add(value)
      check_mutable("insert into", "hash table")
      @table[Value.key(value)] ||= value
    end

    def delete(value)
      check_mutable("delete from", "hash table")
      hash_key = Value.key(value)
      return false unless @table.key?(hash_key)

      @table.delete(hash_key)
      true
    end

    def clear
      check_mutable("clear", "hash table")
      @table.clear
    end

    def pop_first
      check_mutable("delete from", "hash table")
      hash_key, elem = @table.first
      @table.delete(hash_key)
      elem
    end
  end

  # An immutable sequence of bytes.
  class Bytes
    attr_reader :value

    def initialize(value)
      @value = value.b.freeze
    end

    def length = @value.bytesize
    def ==(other) = other.is_a?(Bytes) && other.value == @value
    alias eql? ==
    def hash = [Bytes, @value].hash
  end

  # The value range() returns.
  class Range
    attr_reader :start, :stop, :step, :length

    def initialize(start, stop, step)
      @start = start
      @stop = stop
      @step = step
      @length = range_length
    end

    def index(i) = @start + (i * @step)

    def each
      @length.times { |i| yield index(i) }
    end

    # Spec, "range": x in range reports whether x equals a member, and fails
    # unless x is a number. starlark-go truncates a float first, so it finds
    # 1.5 in range(3).
    def include?(value)
      unless value.is_a?(Integer) || value.is_a?(Float)
        raise EvalError, "'in <range>' requires integer as left operand, not #{Value.type(value)}"
      end
      return false if value.is_a?(Float) && !(value.finite? && value == value.floor)

      value = value.to_i
      return false if @length.zero?

      if @step.positive?
        return false unless value >= @start && value < @stop
      else
        return false unless value <= @start && value > @stop
      end
      ((value - @start) % @step).zero?
    end

    private

    def range_length
      if @step.positive?
        @start < @stop ? ((@stop - @start - 1) / @step) + 1 : 0
      else
        @start > @stop ? ((@start - @stop - 1) / -@step) + 1 : 0
      end
    end
  end

  # A captured local variable, shared between a function and its closures.
  Cell = Struct.new(:value)

  # Helpers that apply Starlark semantics to any value.
  module Value
    module_function

    # Marks a slot that has no value yet. Starlark's None is Ruby's nil.
    UNBOUND = Object.new.freeze

    COMPARE_LIMIT = 10
    COMPARISONS = %i[eql neq lt gt le ge].freeze
    OPERATOR_TEXT = { eql: "==", neq: "!=", lt: "<", gt: ">", le: "<=", ge: ">=" }.freeze

    def type(value)
      case value
      when nil then "NoneType"
      when true, false then "bool"
      when Integer then "int"
      when Float then "float"
      when String then "string"
      when Bytes then "bytes"
      when List then "list"
      when Tuple then "tuple"
      when Dict then "dict"
      when Set then "set"
      when Range then "range"
      when Function then "function"
      when Builtin then "builtin_function_or_method"
      else value.respond_to?(:starlark_type) ? value.starlark_type : value.class.name
      end
    end

    def truth(value)
      case value
      when nil, false then false
      when true then true
      when Integer then !value.zero?
      when Float then value != 0.0
      when String then !value.empty?
      when Bytes, List, Tuple, Dict, Set, Range then value.length.positive?
      else true
      end
    end

    def freeze(value)
      value.freeze_value! if value.is_a?(Container)
      value.elems.each { |elem| freeze(elem) } if value.is_a?(Tuple)
      value.freeze_value! if value.respond_to?(:freeze_value!) && !value.is_a?(Container)
    end

    # The Ruby hash key for a Starlark value, so that values equal in
    # Starlark map to the same key. Raises for unhashable values.
    def key(value)
      case value
      when Float
        if value.nan? then :nan
        elsif value.finite? && value == value.floor then value.to_i
        else value
        end
      when Tuple then [:tuple, *value.elems.map { |elem| key(elem) }].freeze
      when List, Dict, Set then raise EvalError, "unhashable type: #{type(value)}"
      when Range then raise EvalError, "unhashable: range"
      else value
      end
    end

    # Equality

    def equal?(x, y, depth = COMPARE_LIMIT)
      compare(:eql, x, y, depth)
    end

    def compare(op, x, y, depth = COMPARE_LIMIT)
      raise EvalError, "comparison exceeded maximum recursion depth" if depth < 1

      if same_type?(x, y)
        compare_same_type(op, x, y, depth)
      elsif x.is_a?(Integer) && y.is_a?(Float) || x.is_a?(Float) && y.is_a?(Integer)
        threeway(op, numeric_cmp(x, y))
      elsif op == :eql
        false
      elsif op == :neq
        true
      else
        not_implemented(op, x, y)
      end
    end

    def same_type?(x, y)
      type(x) == type(y)
    end

    def compare_same_type(op, x, y, depth)
      case x
      when Integer, String then threeway(op, x <=> y)
      when Float then threeway(op, float_cmp(x, y))
      when true, false then threeway(op, (x ? 1 : 0) - (y ? 1 : 0))
      when Bytes then threeway(op, x.value <=> y.value)
      when Tuple, List then sequence_compare(op, x.elems, y.elems, depth)
      when Dict then equality_only(op, x, y) { dicts_equal?(x, y, depth) }
      when Set then equality_only(op, x, y) { sets_equal?(x, y) }
      when Range then equality_only(op, x, y) { ranges_equal?(x, y) }
      else equality_only(op, x, y) { x.equal?(y) }
      end
    end

    def equality_only(op, x, y)
      case op
      when :eql then yield
      when :neq then !yield
      else not_implemented(op, x, y)
      end
    end

    def not_implemented(op, x, y)
      raise EvalError, "#{type(x)} #{OPERATOR_TEXT.fetch(op)} #{type(y)} not implemented"
    end

    def threeway(op, cmp)
      case op
      when :eql then cmp.zero?
      when :neq then !cmp.zero?
      when :lt then cmp.negative?
      when :le then cmp <= 0
      when :gt then cmp.positive?
      when :ge then cmp >= 0
      end
    end

    # NaN equals NaN and sorts above every other float. See "Floating-point
    # numbers" in docs/spec.md.
    def float_cmp(x, y)
      if x.nan? || y.nan?
        return 0 if x.nan? && y.nan?

        return x.nan? ? 1 : -1
      end
      x <=> y
    end

    # Exact comparison of an int with a float.
    def numeric_cmp(x, y)
      return -1 if y.is_a?(Float) && y.nan?
      return 1 if x.is_a?(Float) && x.nan?

      x <=> y
    end

    def sequence_compare(op, xs, ys, depth)
      return op == :neq if xs.length != ys.length && %i[eql neq].include?(op)

      xs.each_with_index do |a, i|
        break if i >= ys.length
        next if equal?(a, ys[i], depth - 1)

        return false if op == :eql
        return true if op == :neq

        return compare(op, a, ys[i], depth - 1)
      end
      threeway(op, xs.length <=> ys.length)
    end

    def dicts_equal?(x, y, depth)
      return false unless x.length == y.length

      x.items.all? do |key, value|
        y.key?(key) && equal?(value, y.get(key), depth - 1)
      end
    end

    def sets_equal?(x, y)
      x.length == y.length && x.elems.all? { |elem| y.include?(elem) }
    end

    def ranges_equal?(x, y)
      return false unless x.length == y.length
      return true if x.length.zero?

      x.start == y.start && (x.length == 1 || x.step == y.step)
    end

    # Text

    def repr(value, path = [])
      case value
      when nil then "None"
      when true then "True"
      when false then "False"
      when Integer then value.to_s
      when Float then float_str(value)
      when String then Quote.call(value)
      when Bytes then Quote.call(value.value, bytes: true)
      when List
        return "[...]" if path.any? { |seen| seen.equal?(value) }

        "[#{value.elems.map { |elem| repr(elem, path + [value]) }.join(", ")}]"
      when Tuple
        inner = value.elems.map { |elem| repr(elem, path) }.join(", ")
        value.length == 1 ? "(#{inner},)" : "(#{inner})"
      when Dict
        return "{...}" if path.any? { |seen| seen.equal?(value) }

        "{#{value.items.map { |k, v| "#{repr(k, path)}: #{repr(v, path + [value])}" }.join(", ")}}"
      when Set then "set([#{value.elems.map { |elem| repr(elem, path) }.join(", ")}])"
      when Range then range_repr(value)
      when Function then "<function #{value.name}>"
      when Builtin then value.repr
      else value.respond_to?(:starlark_repr) ? value.starlark_repr : value.to_s
      end
    end

    def range_repr(range)
      if range.step != 1 then "range(#{range.start}, #{range.stop}, #{range.step})"
      elsif range.start != 0 then "range(#{range.start}, #{range.stop})"
      else "range(#{range.stop})"
      end
    end

    # Like Go's strconv.FormatFloat(f, 'g', -1, 64), with ".0" added when the
    # result has neither a point nor an exponent.
    def float_str(value)
      return "nan" if value.nan?
      return value.positive? ? "+inf" : "-inf" if value.infinite?

      text = format_g_shortest(value)
      text.include?(".") || text.include?("e") ? text : "#{text}.0"
    end

    def format_g_shortest(value)
      digits, exponent = shortest_digits(value.abs)
      sign = value.negative? || (value.zero? && (1.0 / value).negative?) ? "-" : ""
      # Go's %g with the shortest digits uses exponent form when the decimal
      # exponent is below -4, or at least 6.
      decimal_exponent = exponent - 1
      body =
        if decimal_exponent < -4 || decimal_exponent >= 6
          mantissa = digits.length > 1 ? "#{digits[0]}.#{digits[1..]}" : digits
          exp_sign = decimal_exponent.negative? ? "-" : "+"
          "#{mantissa}e#{exp_sign}#{decimal_exponent.abs.to_s.rjust(2, "0")}"
        elsif exponent <= 0
          "0.#{"0" * -exponent}#{digits}"
        elsif exponent >= digits.length
          digits + ("0" * (exponent - digits.length))
        else
          "#{digits[0, exponent]}.#{digits[exponent..]}"
        end
      sign + body
    end

    # The shortest decimal digits that round-trip, and the position of the
    # decimal point: value = 0.DIGITS * 10**exponent.
    def shortest_digits(value)
      return ["0", 1] if value.zero?

      text = value.to_s # Ruby prints the shortest round-trip digits.
      mantissa, exp = text.split("e")
      exp = exp.to_i
      int_part, frac_part = mantissa.split(".")
      frac_part = "" if frac_part == "0"
      digits = int_part + frac_part
      point = int_part.length + exp
      stripped = digits.sub(/\A0+/, "")
      point -= digits.length - stripped.length
      [stripped.sub(/0+\z/, ""), point]
    end
  end
end
