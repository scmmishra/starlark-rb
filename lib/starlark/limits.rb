# frozen_string_literal: true

module Starlark
  # Resource limits for untrusted code. The step limit bounds total work.
  # The size limits stop a single operation from allocating without bound,
  # which the step limit alone cannot do: 1 << 2000000000 is one step.
  #
  # max_steps: evaluation steps per run, or nil for no limit.
  # max_value_size: elements or bytes in one list, tuple, dict, set, string,
  # or bytes value built by an operation.
  # max_int_bits: bits in one integer result.
  class Limits
    DEFAULT_MAX_VALUE_SIZE = 10_000_000
    DEFAULT_MAX_INT_BITS = 1_000_000

    attr_reader :max_steps, :max_value_size, :max_int_bits

    def initialize(max_steps: nil, max_value_size: DEFAULT_MAX_VALUE_SIZE, max_int_bits: DEFAULT_MAX_INT_BITS)
      @max_steps = max_steps
      @max_value_size = max_value_size
      @max_int_bits = max_int_bits
    end

    def check_size!(size)
      return if max_value_size.nil? || size <= max_value_size

      raise EvalError, "value too large: #{size} elements, limit is #{max_value_size}"
    end

    def check_int_bits!(bits)
      return if max_int_bits.nil? || bits <= max_int_bits

      raise EvalError, "integer too large: #{bits} bits, limit is #{max_int_bits}"
    end

    # Checks the projected size of a binary operation's result before the
    # operation runs.
    def check_binary!(op, x, y)
      case op
      when :plus then check_concat!(x, y)
      when :minus then check_int_bits!([x.bit_length, y.bit_length].max + 1) if both_ints?(x, y)
      when :star then check_product!(x, y)
      when :ltlt
        # Counts that starlark-go rejects fail in Operators.shift with its messages.
        if x.is_a?(Integer) && y.is_a?(Integer) && y.positive? && y < Operators::MAX_SHIFT
          check_int_bits!(x.bit_length + y)
        end
      end
    end

    private

    def both_ints?(x, y) = x.is_a?(Integer) && y.is_a?(Integer)

    def size_of(value)
      case value
      when String then value.bytesize
      when Bytes, List, Tuple then value.length
      end
    end

    def check_concat!(x, y)
      if both_ints?(x, y)
        check_int_bits!([x.bit_length, y.bit_length].max + 1)
      elsif x.instance_of?(y.class) && (xs = size_of(x)) && (ys = size_of(y))
        check_size!(xs + ys)
      end
    end

    def check_product!(x, y)
      if both_ints?(x, y)
        check_int_bits!(x.bit_length + y.bit_length)
      elsif x.is_a?(Integer) && size_of(y)
        check_repeat!(size_of(y), x)
      elsif y.is_a?(Integer) && size_of(x)
        check_repeat!(size_of(x), y)
      end
    end

    # A count outside the int32 range fails in Operators.repeat with
    # starlark-go's message, so it is left to that check.
    def check_repeat!(size, count)
      return unless Operators::INT32.cover?(count)

      check_size!(size * [count, 0].max)
    end
  end
end
