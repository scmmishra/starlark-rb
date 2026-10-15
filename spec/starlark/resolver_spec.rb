# frozen_string_literal: true

require "spec_helper"

# Bindings, slots, and error messages are checked against starlark-go in
# spec/oracle. These examples cover the Ruby API.
RSpec.describe Starlark::Resolver do
  def resolve(source, **options)
    file = Starlark::Parser.parse(source)
    [file, described_class.resolve(file, **options)]
  end

  it "maps identifiers to bindings" do
    file, resolution = resolve("x = len([])\n")
    assign = file.statements.first

    expect(resolution.bindings[assign.target].to_h).to include(scope: :global, index: 0)
    expect(resolution.bindings[assign.value.callee].scope).to eq(:universal)
  end

  it "maps declaring nodes to bindings" do
    file, resolution = resolve("load(\"m.star\", \"a\")\ndef f(p):\n    return p + a\n")
    load, def_stmt = file.statements

    expect(resolution.bindings[load.bindings.first].scope).to eq(:cell)
    expect(resolution.bindings[def_stmt].scope).to eq(:global)
    expect(resolution.bindings[def_stmt.params.first].to_h).to include(scope: :local, index: 0)
  end

  it "records functions with locals, free variables, and flags" do
    file, resolution = resolve("def f(a, *args, k, **kw):\n    return lambda: a\n")
    def_stmt = file.statements.first
    fn = resolution.functions.fetch(def_stmt)
    lambda_fn = resolution.functions.fetch(def_stmt.body.first.value)

    expect(fn.locals.map(&:name)).to eq(%w[a k args kw])
    expect([fn.has_varargs, fn.has_kwargs, fn.num_kwonly_params]).to eq([true, true, 1])
    expect(lambda_fn.free_vars.map(&:name)).to eq(["a"])
  end

  it "resolves names the host predeclares" do
    file, resolution = resolve("host_fn()\n", predeclared: ["host_fn"])

    expect(resolution.bindings[file.statements.first.expr.callee].scope).to eq(:predeclared)
  end

  it "reports every static error in a ResolveError" do
    file = Starlark::Parser.parse("x = 1\nx = 2\nif x:\n    pass\ny = z\n")

    expect { described_class.resolve(file, filename: "main.star") }.to raise_error(Starlark::ResolveError) { |error|
      expect(error.errors.map(&:message)).to eq([
        "cannot reassign global x declared at main.star:1:1",
        "if statement not within a function",
        "undefined: z"
      ])
      expect([error.line, error.column]).to eq([2, 1])
    }
  end

  it "resolves a long binary chain without exhausting the Ruby stack" do
    source = "def f(a):\n    return #{(["a"] * 50_000).join(" + ")}\n"

    expect { resolve(source) }.not_to raise_error
  end

  it "resolves a long elif chain without exhausting the Ruby stack" do
    source = "def f(x):\n    if x:\n        pass\n#{"    elif x:\n        pass\n" * 20_000}"

    expect { resolve(source) }.not_to raise_error
  end
end
