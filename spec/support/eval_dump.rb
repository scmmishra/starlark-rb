# frozen_string_literal: true

# Runs a source file with our interpreter and prints the result in the eval
# oracle format. See tools/oracle/README.md.
module EvalDump
  module_function

  # The same assertion helpers as tools/oracle/go/cmd/evaldump. They fail on
  # mismatch, unlike the upstream conformance prelude, which only prints.
  def predeclared
    {
      "assert_eq" => Starlark::Builtin.new("assert_eq") do |args, kwargs|
        x, y = Starlark::Args.positional("assert_eq", args, kwargs, 2, 2)
        raise Starlark::EvalError, "#{repr(x)} != #{repr(y)}" unless Starlark::Value.equal?(x, y)
      end,
      "assert_ne" => Starlark::Builtin.new("assert_ne") do |args, kwargs|
        x, y = Starlark::Args.positional("assert_ne", args, kwargs, 2, 2)
        raise Starlark::EvalError, "#{repr(x)} == #{repr(y)}" if Starlark::Value.equal?(x, y)
      end,
      "assert_" => Starlark::Builtin.new("assert_") do |args, kwargs|
        cond, message = Starlark::Args.positional("assert_", args, kwargs, 1, 2)
        unless message.nil? || message.is_a?(String)
          raise Starlark::EvalError, "assert_: for parameter 2: got #{Starlark::Value.type(message)}, want string"
        end
        raise Starlark::EvalError, message || "assertion failed" unless Starlark::Value.truth(cond)
      end
    }
  end

  def repr(value) = Starlark::Value.repr(value)

  def call(source)
    lines = []
    thread = Starlark::Thread.new(print: ->(message) { lines << "print #{escape(message)}" })
    begin
      globals = thread.exec_file(source, filename: "input.star", predeclared: predeclared)
      globals.keys.sort.each { |name| lines << "global #{name} = #{escape(repr(globals[name]))}" }
    rescue Starlark::Error => e
      lines << "ERROR #{escape(e.message)}"
    end
    lines.map { |line| "#{line}\n" }.join
  end

  def escape(text)
    text.gsub("\\", "\\\\\\\\").gsub("\n", "\\n")
  end
end
