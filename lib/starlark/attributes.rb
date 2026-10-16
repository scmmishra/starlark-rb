# frozen_string_literal: true

module Starlark
  # Attribute access, x.name. Built-in types have methods but no fields. A
  # host value may define fields with starlark_attr, starlark_attr_names,
  # and starlark_set_attr.
  module Attributes
    module_function

    def method_table(value)
      case value
      when String then Methods::STRING
      when Bytes then Methods::BYTES
      when List then Methods::LIST
      when Dict then Methods::DICT
      when Set then Methods::SET
      end
    end

    def names(value)
      table = method_table(value)
      return table.keys if table
      return value.starlark_attr_names if value.respond_to?(:starlark_attr_names)

      []
    end

    def has?(value, name)
      names(value).include?(name)
    end

    def get(value, name)
      table = method_table(value)
      if table&.key?(name)
        impl = table.fetch(name)
        return Builtin.new(name, value) { |args, kwargs, thread| impl.call(value, args, kwargs, thread) }
      end
      if value.respond_to?(:starlark_attr)
        result = value.starlark_attr(name)
        return result unless result.equal?(Value::UNBOUND)
      end

      message = "#{Value.type(value)} has no .#{name} field or method"
      hint = Spell.nearest(name, names(value))
      message += " (did you mean .#{hint}?)" if hint
      raise EvalError, message
    end

    def set(value, name, new_value)
      return value.starlark_set_attr(name, new_value) if value.respond_to?(:starlark_set_attr)

      raise EvalError, "can't assign to .#{name} field of #{Value.type(value)}"
    end
  end
end
