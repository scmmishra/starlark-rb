# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "yaml"
require_relative "../support/ast_dump"

# Compares Starlark::Parser against the parser oracles in tools/oracle.
# Set ORACLE to "go" (the default), "java", or "all".
#
# The Go comparison checks the whole dump, positions included. If FILE.star
# has a sibling FILE.expected, the Go comparison uses that file instead. It
# records a case where the spec and starlark-go disagree.
#
# The Java comparison ignores positions and error messages. Java columns and
# wording differ from Go's. A file listed in java_parser_known_differences.yml
# is pending with its reasons.
#
# Conformance files hold independent chunks separated by "---" lines. Each
# chunk is compared on its own, padded with blank lines so that line numbers
# match the original file.
module ParserOracle
  PARSE = File.expand_path("../../tools/oracle/parse", __dir__)
  CACHE = File.expand_path("../../tools/oracle/.cache", __dir__)
  SPEC_DIR = File.expand_path("..", __dir__)
  CHUNK_DIR = File.join(CACHE, "parser_chunks")
  CHUNK_SEPARATOR = "---"
  ORACLES = { "go" => ["go"], "java" => ["java"], "all" => %w[go java] }.freeze
  JAVA_KNOWN_DIFFERENCES = YAML.load_file(File.join(__dir__, "java_parser_known_differences.yml")) || {}

  module_function

  # Returns [name, path] pairs. Conformance chunks are written to CHUNK_DIR.
  def inputs
    corpus = Dir[File.join(SPEC_DIR, "parser/corpus/**/*.star")].map { |path| [relative(path), path] }
    chunks = Dir[File.join(SPEC_DIR, "conformance/testdata/**/*.star")].flat_map { |path| chunk(path) }
    (chunks + corpus).sort
  end

  def relative(path)
    path.delete_prefix("#{SPEC_DIR}/")
  end

  def chunk(path)
    lines = File.binread(path).lines
    starts = [0] + lines.each_index.select { |i| lines[i].chomp == CHUNK_SEPARATOR }.map { |i| i + 1 }
    starts.each_with_index.map do |start, n|
      stop = starts[n + 1] ? starts[n + 1] - 1 : lines.size
      name = "#{relative(path)}:#{start + 1}"
      chunk_path = File.join(CHUNK_DIR, "#{name.tr("/:", "__")}.star")
      FileUtils.mkdir_p(CHUNK_DIR)
      File.binwrite(chunk_path, ("\n" * start) + lines[start...stop].join)
      [name, chunk_path]
    end
  end

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

  def expected(oracle, path)
    override = path.sub(/\.star\z/, ".expected")
    return File.read(override) if oracle == "go" && File.exist?(override)

    run(oracle, path)
  end

  def run(oracle, path)
    out, err, status = Open3.capture3(PARSE, oracle, path)
    raise "#{oracle} parse oracle failed on #{path}: #{err}" unless status.success?

    out
  end

  # Drops positions and error messages, keeping the tree structure.
  def structure(dump)
    dump.gsub(/^( *)\d+:\d+ /, '\1').gsub(/^( *)ERROR .*$/, '\1ERROR')
  end
end

RSpec.describe "Parser against oracles" do
  before(:all) do
    raise "Oracles are not built. Run: mise run oracle:setup" unless File.exist?(File.join(ParserOracle::CACHE, "bin/parsedump-go"))
  end

  ParserOracle.oracles.each do |oracle|
    describe "#{oracle} oracle" do
      ParserOracle.inputs.each do |name, path|
        it name do
          if oracle == "java"
            reasons = ParserOracle::JAVA_KNOWN_DIFFERENCES[name]
            pending(reasons.join("; ")) if reasons
            expect(ParserOracle.structure(ParserOracle.ours(path)))
              .to eq(ParserOracle.structure(ParserOracle.expected(oracle, path)))
          else
            expect(ParserOracle.ours(path)).to eq(ParserOracle.expected(oracle, path))
          end
        end
      end
    end
  end
end
