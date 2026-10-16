# frozen_string_literal: true

module Starlark
  # Operators, indexing, slicing, and attribute access. Messages follow
  # starlark-go's eval.go.
  module Operators
    module_function

    TEXT = {
      plus: "+", minus: "-", star: "*", slash: "/", slashslash: "//", percent: "%", amp: "&", pipe: "|",
      circumflex: "^", ltlt: "<<", gtgt: ">>", in: "in", not_in: "not in", tilde: "~", not: "not"
    }.freeze

    # starlark-go limits repetition results to under 2**30 elements.
    MAX_ALLOC = 1 << 30
    # starlark-go limits left shifts to under 512 bits. The spec sets no limit,
    # but an unbounded shift allocates without limit.
    MAX_SHIFT = 512
    INT32 = (-(2**31))..((2**31) - 1)

    def unary(op, x)
      return !Value.truth(x) if op == :not

      case [op, x]
      in [:minus, Integer | Float] then -x
      in [:plus, Integer | Float] then x
      in [:tilde, Integer] then ~x
      else raise EvalError, "unknown unary op: #{TEXT.fetch(op)} #{Value.type(x)}"
      end
    end

    def binary(op, x, y, limits = nil)
      limits&.check_binary!(op, x, y)
      result = binary_op(op, x, y)
      return result unless result.equal?(Value::UNBOUND)

      raise EvalError, "unknown binary op: #{Value.type(x)} #{TEXT.fetch(op)} #{Value.type(y)}"
    end

    def binary_op(op, x, y)
      case op
      when :plus then plus(x, y)
      when :minus then minus(x, y)
      when :star then star(x, y)
      when :slash then slash(x, y)
      when :slashslash then floor_div(x, y)
      when :percent then percent(x, y)
      when :in then contains(y, x)
      when :not_in then !contains(y, x)
      when :pipe then pipe(x, y)
      when :amp then amp(x, y)
      when :circumflex then circumflex(x, y)
      when :ltlt, :gtgt then shift(op, x, y)
      else Value.compare(op, x, y)
      end
    end

    def plus(x, y)
      case [x, y]
      in [String, String] then (x + y).freeze
      in [Bytes, Bytes] then Bytes.new(x.value + y.value)
      in [Integer, Integer] then x + y
      in [Integer | Float, Integer | Float] then float(x) + float(y)
      in [List, List] then List.new(x.elems + y.elems)
      in [Tuple, Tuple] then Tuple.new(x.elems + y.elems)
      else Value::UNBOUND
      end
    end

    def minus(x, y)
      case [x, y]
      in [Integer, Integer] then x - y
      in [Integer | Float, Integer | Float] then float(x) - float(y)
      in [Set, Set] then Set.new(x.elems.reject { |elem| y.include?(elem) })
      else Value::UNBOUND
      end
    end

    def star(x, y)
      case [x, y]
      in [Integer, Integer] then x * y
      in [Integer | Float, Integer | Float] then float(x) * float(y)
      in [String | Bytes | List | Tuple, Integer] then repeat(x, y)
      in [Integer, String | Bytes | List | Tuple] then repeat(y, x)
      else Value::UNBOUND
      end
    end

    def slash(x, y)
      return Value::UNBOUND unless number?(x) && number?(y)

      xf = float(x)
      yf = float(y)
      raise EvalError, "floating-point division by zero" if yf.zero?

      xf / yf
    end

    def floor_div(x, y)
      return Value::UNBOUND unless number?(x) && number?(y)

      if x.is_a?(Integer) && y.is_a?(Integer)
        raise EvalError, "floored division by zero" if y.zero?

        return x.div(y)
      end
      xf = float(x)
      yf = float(y)
      raise EvalError, "floored division by zero" if yf.zero?

      float_floor(xf / yf)
    end

    def percent(x, y)
      return Format.interpolate(x, y) if x.is_a?(String)
      return Value::UNBOUND unless number?(x) && number?(y)

      if x.is_a?(Integer) && y.is_a?(Integer)
        raise EvalError, "integer modulo by zero" if y.zero?

        return x % y
      end
      raise EvalError, "floating-point modulo by zero" if y.zero?

      xf = float(x)
      yf = float(y)
      xf % yf
    end

    def pipe(x, y)
      case [x, y]
      in [Integer, Integer] then x | y
      in [Dict, Dict]
        result = Dict.new
        x.items.each { |k, v| result.set(k, v) }
        y.items.each { |k, v| result.set(k, v) }
        result
      in [Set, Set] then Set.new(x.elems + y.elems)
      else Value::UNBOUND
      end
    end

    def amp(x, y)
      case [x, y]
      in [Integer, Integer] then x & y
      in [Set, Set] then Set.new(x.elems.select { |elem| y.include?(elem) })
      else Value::UNBOUND
      end
    end

    def circumflex(x, y)
      case [x, y]
      in [Integer, Integer] then x ^ y
      in [Set, Set]
        Set.new(x.elems.reject { |elem| y.include?(elem) } + y.elems.reject { |elem| x.include?(elem) })
      else Value::UNBOUND
      end
    end

    def shift(op, x, y)
      return Value::UNBOUND unless x.is_a?(Integer)

      count = int32(y)
      raise EvalError, "negative shift count: #{count}" if count.negative?
      return x >> count if op == :gtgt
      raise EvalError, "shift count too large: #{count}" if count >= MAX_SHIFT

      x << count
    end

    def contains(container, value)
      case container
      when List, Tuple then container.elems.any? { |elem| Value.equal?(elem, value) }
      when Dict then container.key?(value)
      when Set then container.include?(value)
      when Range then container.include?(value)
      when String
        unless value.is_a?(String)
          raise EvalError, "'in <string>' requires string as left operand, not #{Value.type(value)}"
        end

        container.b.include?(value.b)
      when Bytes then bytes_contains(container, value)
      else
        raise EvalError, "unknown binary op: #{Value.type(value)} in #{Value.type(container)}"
      end
    rescue EvalError => e
      raise e unless container.is_a?(Dict) && e.message.start_with?("unhashable")

      false
    end

    def bytes_contains(container, value)
      case value
      when Bytes then container.value.include?(value.value)
      when Integer
        raise EvalError, "int in bytes: #{value} out of range (want value in unsigned 8-bit range)" unless (0..255).cover?(value)

        container.value.bytes.include?(value)
      else
        raise EvalError, "'in bytes' requires bytes or int as left operand, not #{Value.type(value)}"
      end
    end

    # Numbers

    def number?(value) = value.is_a?(Integer) || value.is_a?(Float)

    # Converts an int operand to float. Fails if it is too large to be finite.
    def float(value)
      return value if value.is_a?(Float)

      result = value.to_f
      raise EvalError, "int too large to convert to float" unless result.finite?

      result
    end

    # Like Go's math.Floor. Ruby's Float#floor returns an Integer, which
    # would lose the sign of -0.0.
    def float_floor(value)
      value.finite? && !value.zero? ? value.floor.to_f : value
    end

    def int32(value)
      raise EvalError, "got #{Value.type(value)}, want int" unless value.is_a?(Integer)
      raise EvalError, "#{value} out of range" unless INT32.cover?(value)

      value
    end

    def repeat(sequence, count)
      empty = case sequence
              when String then sequence.empty?
              else sequence.length.zero?
              end
      return empty_like(sequence) if empty

      raise EvalError, "repeat count #{count} too large" unless INT32.cover?(count)
      return empty_like(sequence) if count < 1

      size = (sequence.is_a?(String) ? sequence.bytesize : sequence.length) * count
      raise EvalError, "excessive repeat (#{sequence_size(sequence)} * #{count} elements)" if size >= MAX_ALLOC

      case sequence
      when String then (sequence * count).freeze
      when Bytes then Bytes.new(sequence.value * count)
      when List then List.new(sequence.elems * count)
      when Tuple then Tuple.new(sequence.elems * count)
      end
    end

    def sequence_size(sequence)
      sequence.is_a?(String) ? sequence.bytesize : sequence.length
    end

    def empty_like(sequence)
      case sequence
      when String then ""
      when Bytes then Bytes.new("")
      when List then List.new([])
      when Tuple then Tuple.new([])
      end
    end

    # Indexing

    def index(x, y)
      case x
      when Dict
        found = x.fetch(y) { Value::UNBOUND }
        raise EvalError, "key #{Value.repr(y)} not in dict" if found.equal?(Value::UNBOUND)

        found
      when String, Bytes, List, Tuple, Range, ->(value) { value.respond_to?(:starlark_index) }
        n = indexable_length(x)
        i = begin
          int32(y)
        rescue EvalError => e
          raise EvalError, "#{Value.type(x)} index: #{e.message}"
        end
        original = i
        i += n if i.negative?
        raise out_of_range(original, n, x) if i.negative? || i >= n

        element(x, i)
      else
        raise EvalError, "unhandled index operation #{Value.type(x)}[#{Value.type(y)}]"
      end
    end

    def indexable_length(x)
      return x.bytesize if x.is_a?(String)
      return x.starlark_length if x.respond_to?(:starlark_length)

      x.length
    end

    def element(x, i)
      case x
      when String then x.byteslice(i, 1).force_encoding(Encoding::UTF_8).freeze
      when Bytes then x.value.getbyte(i)
      when List, Tuple then x.elems[i]
      when Range then x.index(i)
      else x.starlark_index(i)
      end
    end

    def out_of_range(i, n, x)
      return EvalError.new("index #{i} out of range: empty #{Value.type(x)}") if n.zero?

      EvalError.new("#{Value.type(x)} index #{i} out of range [#{-n}:#{n - 1}]")
    end

    def set_index(x, y, z)
      case x
      when Dict then x.set(y, z)
      when List
        n = x.length
        i = int32(y)
        original = i
        i += n if i.negative?
        raise out_of_range(original, n, x) if i.negative? || i >= n

        x.check_mutable!
        x.elems[i] = z
      else
        raise EvalError, "#{Value.type(x)} value does not support item assignment"
      end
    end

    # Slicing

    def slice(x, lo, hi, step_value)
      unless x.is_a?(String) || x.is_a?(Bytes) || x.is_a?(List) || x.is_a?(Tuple) || x.is_a?(Range)
        raise EvalError, "invalid slice operand #{Value.type(x)}"
      end

      n = indexable_length(x)
      step = 1
      unless step_value.nil?
        step = begin
          int32(step_value)
        rescue EvalError => e
          raise EvalError, "invalid slice step: #{e.message}"
        end
        raise EvalError, "zero is not a valid slice step" if step.zero?
      end

      if step.positive?
        start = clamp(slice_index(lo, n, 0, "start"), 0, n)
        stop = clamp(slice_index(hi, n, n, "end"), 0, n)
        stop = start if stop < start
      else
        start = [slice_index(lo, n, n - 1, "start"), n - 1].min
        stop = [slice_index(hi, n, -1, "end"), -1].max
        start = stop if start < stop
      end
      slice_result(x, start, stop, step)
    end

    def slice_index(value, n, default, which)
      return default if value.nil?

      i = begin
        int32(value)
      rescue EvalError => e
        raise EvalError, "invalid #{which} index: #{e.message}"
      end
      i.negative? ? i + n : i
    end

    def clamp(value, low, high) = value.clamp(low, high)

    def slice_indices(start, stop, step)
      indices = []
      i = start
      if step.positive?
        while i < stop
          indices << i
          i += step
        end
      else
        while i > stop
          indices << i
          i += step
        end
      end
      indices
    end

    def slice_result(x, start, stop, step)
      case x
      when String
        return x.byteslice(start, stop - start).force_encoding(Encoding::UTF_8).freeze if step == 1

        slice_indices(start, stop, step).map { |i| x.byteslice(i, 1) }.join.force_encoding(Encoding::UTF_8).freeze
      when Bytes
        return Bytes.new(x.value.byteslice(start, stop - start)) if step == 1

        Bytes.new(slice_indices(start, stop, step).map { |i| x.value.byteslice(i, 1) }.join)
      when List then List.new(slice_indices(start, stop, step).map { |i| x.elems[i] })
      when Tuple then Tuple.new(slice_indices(start, stop, step).map { |i| x.elems[i] })
      when Range
        Range.new(x.index(start), x.index(stop), x.step * step)
      end
    end
  end
end
