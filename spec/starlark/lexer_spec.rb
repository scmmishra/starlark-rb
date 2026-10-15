# frozen_string_literal: true

require "spec_helper"

# Token kinds, positions, and error messages are checked against starlark-go in
# spec/oracle. These examples cover the Ruby values the oracle format cannot show.
RSpec.describe Starlark::Lexer do
  def values(source)
    described_class.tokenize(source).map(&:value).compact
  end

  it "ends the token list with :eof" do
    expect(described_class.tokenize("x").map(&:kind)).to eq(%i[ident eof])
  end

  it "returns string values as frozen UTF-8 strings" do
    value = values('"éé"').first

    expect(value).to eq("éé")
    expect(value.encoding).to eq(Encoding::UTF_8)
    expect(value).to be_frozen
  end

  it "returns bytes values as frozen binary strings" do
    value = values("b'\\xff\\u00e9'").first

    expect(value.bytes).to eq([0xFF, 0xC3, 0xA9])
    expect(value.encoding).to eq(Encoding::BINARY)
    expect(value).to be_frozen
  end

  it "returns int values as Integers of any size" do
    expect(values("0x10 18446744073709551616")).to eq([16, 2**64])
  end

  it "returns float values as Floats" do
    expect(values("1.5 .5e1")).to eq([1.5, 5.0])
  end

  it "accepts source with a binary encoding" do
    expect(values("'é'".b)).to eq(["é"])
  end

  it "accepts frozen source" do
    expect(values("x".freeze)).to eq(["x"])
  end

  it "raises Starlark::SyntaxError with a position" do
    expect { described_class.tokenize("if x:\n    y\n  z\n") }.to raise_error(Starlark::SyntaxError) { |error|
      expect([error.line, error.column]).to eq([3, 3])
      expect(error.message).to eq("unindent does not match any outer indentation level")
    }
  end
end
