# frozen_string_literal: true

module Starlark
  # A function defined by def or lambda.
  class Function
    attr_reader :name, :node, :info, :defaults, :free_cells, :module_env

    # info is the Resolver::Function. defaults holds one value per
    # parameter, or Value::UNBOUND for a parameter without a default.
    # free_cells holds the Cells the function captures.
    def initialize(name:, node:, info:, defaults:, free_cells:, module_env:)
      @name = name
      @node = node
      @info = info
      @defaults = defaults
      @free_cells = free_cells
      @module_env = module_env
    end
  end

  # A function implemented in Ruby. The block receives the positional
  # arguments as an Array, the keyword arguments as an Array of [name, value]
  # pairs, and the Thread. A builtin with a receiver is a bound method.
  class Builtin
    attr_reader :name, :receiver

    def initialize(name, receiver = nil, &impl)
      @name = name
      @receiver = receiver
      @impl = impl
    end

    def call(thread, args, kwargs)
      @impl.call(args, kwargs, thread)
    end

    def repr
      return "<built-in function #{name}>" unless receiver

      "<built-in method #{name} of #{Value.type(receiver)} value>"
    end
  end

  # Argument unpacking for builtins. Ports starlark-go's UnpackArgs and
  # UnpackPositionalArgs, so messages match the eval oracle.
  module Args
    module_function

    # params lists parameter names. A trailing "?" marks an optional
    # parameter, and every later parameter is optional too. A trailing "??"
    # also treats an explicit None as missing. Returns the values in order,
    # with nil for a missing optional parameter.
    def unpack(fn_name, args, kwargs, params)
      names = params.map { |param| param.sub(/\?+\z/, "") }
      skip_none = params.map { |param| param.end_with?("??") }
      if args.length > params.length
        raise EvalError, "#{fn_name}: got #{args.length} arguments, want at most #{params.length}"
      end

      values = Array.new(params.length)
      defined = Array.new(params.length, false)
      args.each_with_index do |arg, i|
        defined[i] = true
        values[i] = arg unless skip_none[i] && arg.nil?
      end

      kwargs.each do |name, arg|
        i = names.index(name)
        unless i
          # starlark-go formats a keyword name as a Starlark string, so it is quoted.
          message = "#{fn_name}: unexpected keyword argument #{Value.repr(name)}"
          hint = Spell.nearest(name, half_names(names))
          message += " (did you mean #{hint}?)" if hint
          raise EvalError, message
        end
        raise EvalError, "#{fn_name}: got multiple values for keyword argument #{Value.repr(name)}" if defined[i]

        defined[i] = true
        values[i] = arg unless skip_none[i] && arg.nil?
      end

      params.each_with_index do |param, i|
        break if param.end_with?("?")
        next if i < args.length

        raise EvalError, "#{fn_name}: missing argument for #{param}" unless defined[i]
      end
      values
    end

    # The parameter name as starlark-go prints it in a type error: quoted if
    # the argument came as a keyword.
    def param_label(name, kwargs)
      kwargs.any? { |key, _| key == name } ? Value.repr(name) : name
    end

    def callable?(value)
      value.is_a?(Function) || value.is_a?(Builtin) || value.respond_to?(:starlark_call)
    end

    # The names starlark-go's spelling hint considers: the parameter at each
    # even position of its name-and-pointer list, which covers the first half.
    def half_names(names)
      (0...names.length).step(2).map { |i| names[i / 2] }
    end

    # For builtins that take only positional arguments. Returns them padded
    # with nil to max entries.
    def positional(fn_name, args, kwargs, min, max)
      raise EvalError, "#{fn_name}: unexpected keyword arguments" unless kwargs.empty?

      if args.length < min
        raise EvalError, "#{fn_name}: got #{args.length} arguments, want #{min < max ? "at least " : ""}#{min}"
      end
      if args.length > max
        raise EvalError, "#{fn_name}: got #{args.length} arguments, want #{max > min ? "at most " : ""}#{max}"
      end

      args + Array.new(max - args.length)
    end
  end
end
