# frozen_string_literal: true

require "spec_helper"
require "yaml"
require_relative "../support/ast_dump"
require_relative "../support/oracle_inputs"

# Compares Starlark::Parser with starlark-go and Java Starlark. The oracles'
# output comes from spec/oracle/golden. See spec/support/oracle_inputs.rb.
# Set ORACLE to "go" (the default), "java", or "all".
#
# The Go comparison checks the whole dump, positions included. If FILE.star
# has a sibling FILE.expected, the Go comparison uses that file instead. It
# records a case where the spec and starlark-go disagree.
#
# The Java comparison ignores positions and error messages. Java columns and
# wording differ from Go's. A file listed in java_parser_known_differences.yml
# is pending with its reasons.
module ParserOracle
  ORACLES = { "go" => ["go"], "java" => ["java"], "all" => %w[go java] }.freeze
  JAVA_KNOWN_DIFFERENCES = YAML.load_file(File.join(__dir__, "java_parser_known_differences.yml")) || {}

  module_function

  def oracles
    ORACLES.fetch(ENV.fetch("ORACLE", "go")) do
      raise ArgumentError, "ORACLE must be one of: #{ORACLES.keys.join(", ")}"
    end
  end

  def ours(path)
    source = File.binread(path).force_encoding(Encoding::UTF_8)
    AstDump.call(Starlark::Parser.parse(source))
  rescue Starlark::SyntaxError => e
    "#{e.line}:#{e.column} ERROR #{e.message}\n"
  end

  # Drops positions and error messages, keeping the tree structure.
  def structure(dump)
    dump.gsub(/^( *)\d+:\d+ /, '\1').gsub(/^( *)ERROR .*$/, '\1ERROR')
  end
end

RSpec.describe Starlark::Parser, "against oracles" do
  before(:all) { OracleInputs.require_oracles!("parsedump-go") }

  ParserOracle.oracles.each do |oracle|
    describe "#{oracle} oracle" do
      OracleInputs.for_tool("parse").each do |name, path|
        it name do
          expected = OracleInputs.expected("parse", oracle, name, path)
          if oracle == "java"
            reasons = ParserOracle::JAVA_KNOWN_DIFFERENCES[name]
            pending(reasons.join("; ")) if reasons
            expect(ParserOracle.structure(ParserOracle.ours(path))).to eq(ParserOracle.structure(expected))
          else
            expect(ParserOracle.ours(path)).to eq(expected)
          end
        end
      end
    end
  end
end
