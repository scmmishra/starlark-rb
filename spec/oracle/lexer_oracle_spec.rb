# frozen_string_literal: true

require "spec_helper"
require "open3"

# Compares Starlark::Lexer against the lexer oracles in tools/oracle.
# Set ORACLE to "go" (the default), "java", or "all".
#
# If FILE.star has a sibling FILE.expected, the Go comparison uses that file
# instead of the Go oracle. It records a case where the spec and starlark-go
# disagree. The .star file explains the reason in a comment.
#
# This spec expects:
# - Starlark::Lexer#next_token returns one token per call, ending with :eof.
# - Each token responds to kind, line, column, and value.
# - A lexical error is raised as an exception that responds to line and column.
module LexerOracle
  LEX = File.expand_path("../../tools/oracle/lex", __dir__)
  CACHE = File.expand_path("../../tools/oracle/.cache", __dir__)
  SPEC_DIR = File.expand_path("..", __dir__)
  INPUTS = Dir[File.join(SPEC_DIR, "{conformance/testdata,lexer/corpus}/**/*.star")].sort
  ORACLES = { "go" => ["go"], "java" => ["java"], "all" => %w[go java] }.freeze

  module_function

  def oracles
    ORACLES.fetch(ENV.fetch("ORACLE", "go")) do
      raise ArgumentError, "ORACLE must be one of: #{ORACLES.keys.join(", ")}"
    end
  end

  def expected(oracle, path)
    override = path.sub(/\.star\z/, ".expected")
    return File.read(override) if oracle == "go" && File.exist?(override)

    run(oracle, path)
  end

  def run(oracle, path)
    out, err, status = Open3.capture3(LEX, oracle, path)
    raise "#{oracle} oracle failed on #{path}: #{err}" unless status.success?

    out
  end

  def ours(path)
    source = File.binread(path).force_encoding(Encoding::UTF_8)
    lines = []
    begin
      lexer = Starlark::Lexer.new(source)
      loop do
        token = lexer.next_token
        lines << token_line(token)
        break if token.kind == :eof
      end
    rescue NotImplementedError
      raise
    rescue StandardError => e
      raise unless e.respond_to?(:line) && e.respond_to?(:column)

      lines << "#{e.line}:#{e.column}\tERROR\t#{e.message}"
    end
    lines.map { |line| "#{line}\n" }.join
  end

  def token_line(token)
    "#{token.line}:#{token.column}\t#{token.kind.to_s.upcase}\t#{value(token)}"
  end

  def value(token)
    case token.kind.to_s.upcase
    when "IDENT", "INT" then token.value.to_s
    when "FLOAT" then [token.value].pack("G").unpack1("H*")
    when "STRING", "BYTES" then quote(token.value)
    else ""
    end
  end

  # Matches the oracle format: printable ASCII as is, every other byte as \xHH.
  def quote(string)
    body = string.bytes.map do |byte|
      if byte >= 0x20 && byte < 0x7f && byte != 0x22 && byte != 0x5c
        byte.chr
      else
        format("\\x%02x", byte)
      end
    end
    "\"#{body.join}\""
  end
end

RSpec.describe "Lexer against oracles" do
  before(:all) do
    raise "Lexer oracles are not built. Run: mise run oracle:setup" unless Dir.exist?(LexerOracle::CACHE)
  end

  LexerOracle.oracles.each do |oracle|
    describe "#{oracle} oracle" do
      LexerOracle::INPUTS.each do |path|
        it path.delete_prefix("#{LexerOracle::SPEC_DIR}/") do
          expect(LexerOracle.ours(path)).to eq(LexerOracle.expected(oracle, path))
        end
      end
    end
  end
end
