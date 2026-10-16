# frozen_string_literal: true

module Starlark
  # The API a host application uses to run Starlark code.
  module Embedding
    module_function

    # Runs a module and returns its globals as a Hash of Starlark values.
    #
    # globals: names the host adds, mapped to Ruby or Starlark values. Ruby
    #   values pass through from_ruby.
    # print: called with each print() message. The default writes to stderr.
    # load: called with a module name. Returns a Hash of the module's
    #   exports, or raises.
    # max_steps, max_value_size, max_int_bits: see Limits.
    def exec(source, filename: "<input>", globals: {}, print: nil, load: nil, max_steps: nil,
             max_value_size: Limits::DEFAULT_MAX_VALUE_SIZE, max_int_bits: Limits::DEFAULT_MAX_INT_BITS)
      limits = Limits.new(max_steps: max_steps, max_value_size: max_value_size, max_int_bits: max_int_bits)
      loader = load && ->(name) { load.call(name).transform_keys(&:to_s).transform_values { |value| from_ruby(value) } }
      thread = Thread.new(print: print, load: loader, limits: limits)
      predeclared = globals.to_h { |name, value| [name.to_s, from_ruby(value)] }
      thread.exec_file(source, filename: filename, predeclared: predeclared)
    end

    # Converts a Ruby value to a Starlark value. Starlark values pass through.
    def from_ruby(value)
      case value
      when nil, true, false, Integer, Float, Bytes, List, Tuple, Dict, Set, Range, Function, Builtin then value
      when String then string_from_ruby(value)
      when Symbol then value.to_s.freeze
      when Array then List.new(value.map { |elem| from_ruby(elem) })
      when Hash
        dict = Dict.new
        value.each { |key, elem| dict.set(from_ruby(key), from_ruby(elem)) }
        dict
      when ::Set then Set.new(value.map { |elem| from_ruby(elem) })
      when Proc, Method then function(value.respond_to?(:name) ? value.name.to_s : "function", &value)
      else
        return value if value.respond_to?(:starlark_type)

        raise ArgumentError, "cannot convert #{value.class} to a Starlark value"
      end
    end

    # Binary Ruby strings become bytes. Other strings must be valid UTF-8.
    def string_from_ruby(value)
      return Bytes.new(value) if value.encoding == Encoding::BINARY

      text = value.encode(Encoding::UTF_8)
      raise ArgumentError, "string is not valid UTF-8" unless text.valid_encoding?

      text.frozen? ? text : text.dup.freeze
    end

    # Converts a Starlark value to a plain Ruby value. A string with invalid
    # UTF-8 raises, rather than leaving Starlark with broken text.
    def to_ruby(value)
      case value
      when String
        raise Error, "string is not valid UTF-8: #{Value.repr(value)}" unless value.valid_encoding?

        value
      when Bytes then value.value
      when List, Tuple then value.elems.map { |elem| to_ruby(elem) }
      when Dict then value.items.to_h { |key, elem| [to_ruby(key), to_ruby(elem)] }
      when Set then ::Set.new(value.elems.map { |elem| to_ruby(elem) })
      when Range then value.to_enum(:each).to_a
      else value
      end
    end

    # A builtin that calls a Ruby block with Ruby values and converts its
    # result back. Keyword arguments arrive as symbols.
    def function(name, &block)
      Builtin.new(name) do |args, kwargs, _thread|
        ruby_args = args.map { |arg| to_ruby(arg) }
        ruby_kwargs = kwargs.to_h { |key, arg| [key.to_sym, to_ruby(arg)] }
        from_ruby(ruby_kwargs.empty? ? block.call(*ruby_args) : block.call(*ruby_args, **ruby_kwargs))
      end
    end
  end

  module_function

  # See Embedding.exec.
  def exec(source, **options) = Embedding.exec(source, **options)

  # See Embedding.from_ruby.
  def from_ruby(value) = Embedding.from_ruby(value)

  # See Embedding.to_ruby.
  def to_ruby(value) = Embedding.to_ruby(value)

  # See Embedding.function.
  def function(name, &) = Embedding.function(name, &)
end
