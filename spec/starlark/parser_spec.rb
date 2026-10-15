# frozen_string_literal: true

require "spec_helper"

# Tree shapes, positions, and error messages are checked against starlark-go in
# spec/oracle. These examples cover the Ruby API.
RSpec.describe Starlark::Parser do
  def parse(source)
    described_class.parse(source)
  end

  it "returns an AST::File with the top-level statements" do
    file = parse("x = 1\nf()\n")

    expect(file).to be_a(Starlark::AST::File)
    expect(file.statements.map(&:class)).to eq([Starlark::AST::AssignStmt, Starlark::AST::ExprStmt])
  end

  it "returns frozen nodes" do
    expect(parse("x = [1]\n").statements.first).to be_frozen
  end

  it "keeps literal values and kinds" do
    literals = parse("x = 1, 2.5, 'a', b'b'\n").statements.first.value.elements

    expect(literals.map(&:kind)).to eq(%i[int float string bytes])
    expect(literals.map(&:value)).to eq([1, 2.5, "a", "b".b])
  end

  it "uses explicit kinds for parameters and arguments" do
    def_stmt = parse("def f(a, b=1, *c, **d): g(a, k=b, *c, **d)\n").statements.first
    call = def_stmt.body.first.expr

    expect(def_stmt.params.map(&:kind)).to eq(%i[required optional args kwargs])
    expect(call.args.map(&:kind)).to eq(%i[positional keyword args kwargs])
  end

  it "parses a top-level if, which the resolver rejects later" do
    expect(parse("if x:\n    pass\n").statements.first).to be_a(Starlark::AST::IfStmt)
  end

  it "raises Starlark::SyntaxError with a position" do
    expect { parse("x = (1, 2\n") }.to raise_error(Starlark::SyntaxError) { |error|
      expect([error.line, error.column]).to eq([2, 1])
      expect(error.message).to eq("got end of file, want ')'")
    }
  end

  it "stops deep nesting before the Ruby stack runs out" do
    expect { parse("x = #{"[" * 500}#{"]" * 500}\n") }.to raise_error(Starlark::SyntaxError, "excessive nesting")
  end
end
