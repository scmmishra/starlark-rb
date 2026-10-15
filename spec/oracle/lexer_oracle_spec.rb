# frozen_string_literal: true

require "spec_helper"
require "yaml"
require_relative "../support/token_dump"
require_relative "../support/oracle_inputs"

# Compares Starlark::Lexer with starlark-go and Java Starlark. The oracles'
# output comes from spec/oracle/golden. See spec/support/oracle_inputs.rb.
# Set ORACLE to "go" (the default), "java", or "all".
#
# If FILE.star has a sibling FILE.expected, the Go comparison uses that file
# instead. It records a case where the spec and starlark-go disagree. The
# .star file explains the reason in a comment.
#
# With ORACLE=java, a file listed in java_lexer_known_differences.yml is
# pending with its reasons.
module LexerOracle
  ORACLES = { "go" => ["go"], "java" => ["java"], "all" => %w[go java] }.freeze
  JAVA_KNOWN_DIFFERENCES = YAML.load_file(File.join(__dir__, "java_lexer_known_differences.yml")).freeze

  module_function

  def oracles
    ORACLES.fetch(ENV.fetch("ORACLE", "go")) do
      raise ArgumentError, "ORACLE must be one of: #{ORACLES.keys.join(", ")}"
    end
  end

  def ours(path)
    TokenDump.call(File.binread(path).force_encoding(Encoding::UTF_8))
  end
end

RSpec.describe Starlark::Lexer, "against oracles" do
  before(:all) { OracleInputs.require_oracles!("lexdump-go") }

  LexerOracle.oracles.each do |oracle|
    describe "#{oracle} oracle" do
      OracleInputs.for_tool("lex").each do |name, path|
        it name do
          reasons = LexerOracle::JAVA_KNOWN_DIFFERENCES[name] if oracle == "java"
          pending(reasons.join("; ")) if reasons
          expect(LexerOracle.ours(path)).to eq(OracleInputs.expected("lex", oracle, name, path))
        end
      end
    end
  end
end
