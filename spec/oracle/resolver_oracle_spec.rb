# frozen_string_literal: true

require "spec_helper"
require "open3"
require "yaml"
require_relative "../support/resolve_dump"
require_relative "../support/oracle_inputs"

# Compares Starlark::Resolver against the resolver oracles in tools/oracle.
# Set ORACLE to "go" (the default), "java", or "all".
#
# The Go comparison checks the whole dump. If FILE.star has a sibling
# FILE.expected, the Go comparison uses that file instead. It records a case
# where the spec and starlark-go disagree.
#
# The Java comparison collapses any error output to "has errors", because
# Java's wording, order, and extra notes differ. A file listed in
# java_resolver_known_differences.yml is pending with its reasons.
module ResolverOracle
  CACHE = File.expand_path("../../tools/oracle/.cache", __dir__)
  ORACLES = { "go" => ["go"], "java" => ["java"], "all" => %w[go java] }.freeze
  JAVA_KNOWN_DIFFERENCES = YAML.load_file(File.join(__dir__, "java_resolver_known_differences.yml")) || {}

  module_function

  def oracles
    ORACLES.fetch(ENV.fetch("ORACLE", "go")) do
      raise ArgumentError, "ORACLE must be one of: #{ORACLES.keys.join(", ")}"
    end
  end

  def ours(path)
    ResolveDump.call(File.binread(path).force_encoding(Encoding::UTF_8))
  end

  def structure(dump)
    dump.include?(" ERROR ") ? "ERROR\n" : dump
  end
end

RSpec.describe "Resolver against oracles" do
  before(:all) do
    unless File.exist?(File.join(ResolverOracle::CACHE, "bin/resolvedump-go"))
      raise "Oracles are not built. Run: mise run oracle:setup"
    end
  end

  ResolverOracle.oracles.each do |oracle|
    describe "#{oracle} oracle" do
      OracleInputs.collect("resolver/corpus").each do |name, path|
        it name do
          expected = OracleInputs.expected("resolve", oracle, path)
          if oracle == "java"
            reasons = ResolverOracle::JAVA_KNOWN_DIFFERENCES[name]
            pending(reasons.join("; ")) if reasons
            expect(ResolverOracle.structure(ResolverOracle.ours(path))).to eq(ResolverOracle.structure(expected))
          else
            expect(ResolverOracle.ours(path)).to eq(expected)
          end
        end
      end
    end
  end
end
