# frozen_string_literal: true

module Starlark
  # The spec's built-in functions. See "Built-in constants and functions" in
  # docs/spec.md. Messages follow starlark-go's library.go.
  module Builtins
    module_function

    def builtin(name, &impl)
      Builtin.new(name, &impl)
    end

    # Converts the value to an Array, or fails as starlark-go's typed
    # argument unpacking does.
    def iterable_arg(thread, fn_name, position, value)
      raise EvalError, "#{fn_name}: for parameter #{position}: got #{Value.type(value)}, want iterable" unless thread.iterable?(value)

      thread.to_array(value)
    end

    def int_arg(fn_name, position, value)
      Operators.int32(value)
    rescue EvalError => e
      raise EvalError, "#{fn_name}: for parameter #{position}: #{e.message}"
    end

    def string_arg(fn_name, position, value)
      return value if value.is_a?(String)

      raise EvalError, "#{fn_name}: for parameter #{position}: got #{Value.type(value)}, want string"
    end

    def no_keywords(fn_name, kwargs)
      raise EvalError, "#{fn_name} does not accept keyword arguments" unless kwargs.empty?
    end

    # The string form of bytes: invalid UTF-8 becomes U+FFFD.
    def utf8_transcode(raw)
      text = raw.dup.force_encoding(Encoding::UTF_8)
      return text.freeze if text.valid_encoding?

      text.scrub { |bad| "�" * bad.bytesize }.freeze
    end

    # Java's String.hashCode over the UTF-16 encoding, as the spec requires.
    def java_string_hash(text)
      hash = 0
      utf8_transcode(text).each_char do |char|
        char.encode(Encoding::UTF_16BE).unpack("n*").each do |unit|
          hash = ((31 * hash) + unit) & 0xFFFFFFFF
        end
      end
      hash >= 0x80000000 ? hash - 0x100000000 : hash
    end

    # 32-bit FNV-1a, as the spec requires for bytes.
    def fnv1a32(raw)
      hash = 2_166_136_261
      raw.each_byte { |byte| hash = ((hash ^ byte) * 16_777_619) & 0xFFFFFFFF }
      hash
    end

    def parse_float(text)
      raise EvalError, "float: empty string" if text.empty?

      case text.downcase
      when "inf", "+inf", "infinity", "+infinity" then return Float::INFINITY
      when "-inf", "-infinity" then return -Float::INFINITY
      when "nan", "+nan", "-nan" then return Float::NAN
      end
      unless text.match?(/\A[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+([eE][+-]?\d+)?)\z/)
        raise EvalError, "invalid float literal: #{text}"
      end

      value = text.to_f
      raise EvalError, "floating-point number too large" if value.infinite?

      value
    end

    # A port of starlark-go's parseInt. Returns nil for an invalid literal.
    def parse_int(text, base)
      negative = false
      if text.start_with?("+")
        text = text[1..]
      elsif text.start_with?("-")
        negative = true
        text = text[1..]
      end

      if text.length > 1 && text[0] == "0"
        prefix = text.length > 2 ? { "o" => 8, "x" => 16, "b" => 2 }[text[1].downcase] : nil
        if prefix
          if base.zero? || prefix == base
            base = prefix
            text = text[2..]
          end
        elsif base.zero?
          return text[1..].each_char.all?("0") ? 0 : nil
        end
      end
      base = 10 if base.zero?
      return nil if text.empty? || text.start_with?("+", "-")

      digits = "0123456789abcdefghijklmnopqrstuvwxyz"[0, base]
      return nil unless text.downcase.each_char.all? { |char| digits.include?(char) }

      value = text.to_i(base)
      negative ? -value : value
    end

    def update_dict(thread, dict, args, kwargs)
      if args.length == 1
        source = args.first
        if source.is_a?(Dict)
          source.items.each { |key, value| dict.set(key, value) }
        else
          raise EvalError, "got #{Value.type(source)}, want iterable" unless thread.iterable?(source)

          thread.to_array(source).each_with_index do |pair, i|
            unless thread.iterable?(pair)
              raise EvalError, "dictionary update sequence element ##{i} is not iterable (#{Value.type(pair)})"
            end

            items = thread.to_array(pair)
            unless items.length == 2
              raise EvalError, "dictionary update sequence element ##{i} has length #{items.length}, want 2"
            end

            dict.set(items[0], items[1])
          end
        end
      end

      before = dict.length
      kwargs.each { |key, value| dict.set(key, value) }
      return unless dict.length < before + kwargs.length

      seen = {}
      kwargs.each do |key, _|
        raise EvalError, "duplicate keyword arg: #{Value.repr(key)}" if seen[key]

        seen[key] = true
      end
    end

    def length_of(value)
      case value
      when String then value.bytesize
      when Bytes, List, Tuple, Dict, Set, Range then value.length
      else value.respond_to?(:starlark_length) ? value.starlark_length : nil
      end
    end

    def minmax(name, op, args, kwargs, thread)
      raise EvalError, "#{name} requires at least one positional argument" if args.empty?

      key_fn, = Args.unpack(name, [], kwargs, ["key?"])
      if kwargs.any? { |key, _| key == "key" } && !Args.callable?(key_fn)
        raise EvalError, "#{name}: for parameter #{Args.param_label("key", kwargs)}: got #{Value.type(key_fn)}, want callable"
      end
      source = args.length == 1 ? args.first : Tuple.new(args)
      raise EvalError, "#{name}: #{Value.type(source)} value is not iterable" unless thread.iterable?(source)

      values = thread.to_array(source)
      raise EvalError, "#{name}: argument is an empty sequence" if values.empty?

      best = values.first
      best_key = key_fn ? thread.call(key_fn, [best]) : best
      values.drop(1).each do |value|
        key = key_fn ? thread.call(key_fn, [value]) : value
        better = begin
          Value.compare(op, key, best_key)
        rescue EvalError => e
          raise EvalError, "#{name}: #{e.message}"
        end
        if better
          best = value
          best_key = key
        end
      end
      best
    end

    # A stable merge sort that reports the first comparison error, as
    # starlark-go's sort.Stable does.
    def stable_sort(pairs, reverse)
      return pairs if pairs.length < 2

      middle = pairs.length / 2
      left = stable_sort(pairs[0...middle], reverse)
      right = stable_sort(pairs[middle..], reverse)
      merged = []
      until left.empty? || right.empty?
        take_right = reverse ? Value.compare(:lt, left.first[0], right.first[0]) : Value.compare(:lt, right.first[0], left.first[0])
        merged << (take_right ? right.shift : left.shift)
      end
      merged.concat(left, right)
    end

    UNIVERSE = {
      "None" => nil,
      "True" => true,
      "False" => false,

      "abs" => builtin("abs") do |args, kwargs|
        x, = Args.positional("abs", args, kwargs, 1, 1)
        case x
        when Integer, Float then x.abs
        else raise EvalError, "got #{Value.type(x)}, want int or float"
        end
      end,

      "all" => builtin("all") do |args, kwargs, thread|
        x, = Args.positional("all", args, kwargs, 1, 1)
        iterable_arg(thread, "all", 1, x).all? { |elem| Value.truth(elem) }
      end,

      "any" => builtin("any") do |args, kwargs, thread|
        x, = Args.positional("any", args, kwargs, 1, 1)
        iterable_arg(thread, "any", 1, x).any? { |elem| Value.truth(elem) }
      end,

      "bool" => builtin("bool") do |args, kwargs|
        x, = Args.positional("bool", args, kwargs, 0, 1)
        args.empty? ? false : Value.truth(x)
      end,

      "bytes" => builtin("bytes") do |args, kwargs, thread|
        no_keywords("bytes", kwargs)
        raise EvalError, "bytes: got #{args.length} arguments, want exactly 1" unless args.length == 1

        x = args.first
        case x
        when Bytes then x
        when String then Bytes.new(utf8_transcode(x))
        else
          unless thread.iterable?(x)
            raise EvalError, "bytes: got #{Value.type(x)}, want string, bytes, or iterable of ints"
          end

          bytes = thread.to_array(x).each_with_index.map do |elem, i|
            raise EvalError, "bytes: at index #{i}, got #{Value.type(elem)}, want int" unless elem.is_a?(Integer)
            raise EvalError, "bytes: at index #{i}, #{elem} out of range (want value in unsigned 8-bit range)" unless (0..255).cover?(elem)

            elem
          end
          Bytes.new(bytes.pack("C*"))
        end
      end,

      "dict" => builtin("dict") do |args, kwargs, thread|
        raise EvalError, "dict: got #{args.length} arguments, want at most 1" if args.length > 1

        dict = Dict.new
        begin
          update_dict(thread, dict, args, kwargs)
        rescue EvalError => e
          raise EvalError, "dict: #{e.message}"
        end
        dict
      end,

      "dir" => builtin("dir") do |args, kwargs|
        no_keywords("dir", kwargs)
        raise EvalError, "dir: got #{args.length} arguments, want 1" unless args.length == 1

        List.new(Attributes.names(args.first).sort)
      end,

      "enumerate" => builtin("enumerate") do |args, kwargs, thread|
        x, start = Args.positional("enumerate", args, kwargs, 1, 2)
        elems = iterable_arg(thread, "enumerate", 1, x)
        start = start.nil? ? 0 : int_arg("enumerate", 2, start)
        List.new(elems.each_with_index.map { |elem, i| Tuple.new([start + i, elem]) })
      end,

      "fail" => builtin("fail") do |args, kwargs|
        sep, = Args.unpack("fail", [], kwargs, ["sep?"])
        sep = string_arg("fail", "sep", sep) if sep
        parts = args.map { |arg| arg.is_a?(String) ? arg : Value.repr(arg) }
        raise EvalError, "fail: #{parts.join(sep || " ")}"
      end,

      "float" => builtin("float") do |args, kwargs|
        no_keywords("float", kwargs)
        next 0.0 if args.empty?
        raise EvalError, "float got #{args.length} arguments, wants 1" unless args.length == 1

        x = args.first
        case x
        when true then 1.0
        when false then 0.0
        when Integer then Operators.float(x)
        when Float then x
        when String then parse_float(x)
        else raise EvalError, "float got #{Value.type(x)}, want number or string"
        end
      end,

      "getattr" => builtin("getattr") do |args, kwargs|
        object, name, default = Args.positional("getattr", args, kwargs, 2, 3)
        name = string_arg("getattr", 2, name)
        if Attributes.has?(object, name)
          Attributes.get(object, name)
        elsif args.length == 3
          default
        else
          raise EvalError, "getattr: #{Value.type(object)} has no .#{name} field or method"
        end
      end,

      "hasattr" => builtin("hasattr") do |args, kwargs|
        object, name = Args.positional("hasattr", args, kwargs, 2, 2)
        Attributes.has?(object, string_arg("hasattr", 2, name))
      end,

      "hash" => builtin("hash") do |args, kwargs|
        x, = Args.positional("hash", args, kwargs, 1, 1)
        case x
        when String then java_string_hash(x)
        when Bytes then fnv1a32(x.value)
        else raise EvalError, "hash: got #{Value.type(x)}, want string or bytes"
        end
      end,

      "int" => builtin("int") do |args, kwargs|
        x, base = Args.unpack("int", args, kwargs, ["x", "base?"])
        x = 0 if args.empty? && kwargs.none? { |name, _| name == "x" }
        if x.is_a?(String)
          b = 10
          unless base.nil?
            raise EvalError, "int: for base, got #{Value.type(base)}, want int" unless base.is_a?(Integer)

            b = base
            raise EvalError, "int: base must be an integer >= 2 && <= 36" if b != 0 && (b < 2 || b > 36)
          end
          result = parse_int(x, b)
          raise EvalError, "int: invalid literal with base #{b}: #{x}" if result.nil?

          next result
        end
        raise EvalError, "int: can't convert non-string with explicit base" unless base.nil?

        case x
        when true then 1
        when false then 0
        when Integer then x
        when Float
          raise EvalError, "int: cannot convert float infinity to integer" if x.infinite?
          raise EvalError, "int: cannot convert float NaN to integer" if x.nan?

          x.to_i
        else raise EvalError, "int: cannot convert #{Value.type(x)} to int"
        end
      end,

      "len" => builtin("len") do |args, kwargs|
        x, = Args.positional("len", args, kwargs, 1, 1)
        length = length_of(x)
        raise EvalError, "len: value of type #{Value.type(x)} has no len" if length.nil?

        length
      end,

      "list" => builtin("list") do |args, kwargs, thread|
        x, = Args.positional("list", args, kwargs, 0, 1)
        List.new(args.empty? ? [] : iterable_arg(thread, "list", 1, x))
      end,

      "max" => builtin("max") { |args, kwargs, thread| minmax("max", :gt, args, kwargs, thread) },
      "min" => builtin("min") { |args, kwargs, thread| minmax("min", :lt, args, kwargs, thread) },

      "print" => builtin("print") do |args, kwargs, thread|
        sep, = Args.unpack("print", [], kwargs, ["sep?"])
        sep = string_arg("print", "sep", sep) if sep
        parts = args.map do |arg|
          case arg
          when String then arg
          when Bytes then arg.value.dup.force_encoding(Encoding::UTF_8)
          else Value.repr(arg)
          end
        end
        thread.print_message(parts.join(sep || " "))
        nil
      end,

      "range" => builtin("range") do |args, kwargs|
        first, second, third = Args.positional("range", args, kwargs, 1, 3)
        start = int_arg("range", 1, first)
        stop = second.nil? ? nil : int_arg("range", 2, second)
        step = third.nil? ? 1 : int_arg("range", 3, third)
        start, stop = 0, start if args.length == 1
        raise EvalError, "range: step argument must not be zero" if step.zero?

        Range.new(start, stop, step)
      end,

      "repr" => builtin("repr") do |args, kwargs|
        x, = Args.positional("repr", args, kwargs, 1, 1)
        Value.repr(x).freeze
      end,

      "reversed" => builtin("reversed") do |args, kwargs, thread|
        x, = Args.positional("reversed", args, kwargs, 1, 1)
        List.new(iterable_arg(thread, "reversed", 1, x).reverse)
      end,

      "set" => builtin("set") do |args, kwargs, thread|
        x, = Args.positional("set", args, kwargs, 0, 1)
        elems = args.empty? ? [] : iterable_arg(thread, "set", 1, x)
        begin
          Set.new(elems)
        rescue EvalError => e
          raise EvalError, "set: #{e.message}"
        end
      end,

      "sorted" => builtin("sorted") do |args, kwargs, thread|
        x, key_fn, reverse = Args.unpack("sorted", args, kwargs, ["iterable", "key?", "reverse?"])
        given = ->(param, position) { args.length > position || kwargs.any? { |key, _| key == param } }
        unless thread.iterable?(x)
          raise EvalError, "sorted: for parameter #{Args.param_label("iterable", kwargs)}: got #{Value.type(x)}, want iterable"
        end
        if given.call("key", 1) && !Args.callable?(key_fn)
          raise EvalError, "sorted: for parameter #{Args.param_label("key", kwargs)}: got #{Value.type(key_fn)}, want callable"
        end
        if given.call("reverse", 2) && ![true, false].include?(reverse)
          raise EvalError, "sorted: for parameter #{Args.param_label("reverse", kwargs)}: got #{Value.type(reverse)}, want bool"
        end

        values = thread.to_array(x)
        keys = key_fn ? values.map { |value| thread.call(key_fn, [value]) } : values
        reverse = reverse == true

        List.new(stable_sort(keys.zip(values), reverse).map(&:last))
      end,

      "str" => builtin("str") do |args, kwargs|
        no_keywords("str", kwargs)
        raise EvalError, "str: got #{args.length} arguments, want exactly 1" unless args.length == 1

        x = args.first
        case x
        when String then x
        when Bytes then utf8_transcode(x.value)
        else Value.repr(x).freeze
        end
      end,

      "tuple" => builtin("tuple") do |args, kwargs, thread|
        x, = Args.positional("tuple", args, kwargs, 0, 1)
        Tuple.new(args.empty? ? [] : iterable_arg(thread, "tuple", 1, x))
      end,

      "type" => builtin("type") do |args, kwargs|
        no_keywords("type", kwargs)
        raise EvalError, "type: got #{args.length} arguments, want exactly 1" unless args.length == 1

        Value.type(args.first)
      end,

      "zip" => builtin("zip") do |args, kwargs, thread|
        no_keywords("zip", kwargs)
        columns = args.each_with_index.map do |arg, i|
          raise EvalError, "zip: argument ##{i + 1} is not iterable: #{Value.type(arg)}" unless thread.iterable?(arg)

          thread.to_array(arg)
        end
        rows = columns.map(&:length).min || 0
        List.new(Array.new(rows) { |i| Tuple.new(columns.map { |column| column[i] }) })
      end
    }.freeze
  end
end
