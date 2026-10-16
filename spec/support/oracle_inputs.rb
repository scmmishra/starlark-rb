# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

# Lists the inputs for the oracle specs, and supplies the oracles' output.
#
# The output comes from golden files in spec/oracle/golden, one JSON file per
# tool and oracle. Set ORACLE_LIVE=1 to run the oracles instead. Run
# `mise run oracle:golden` to regenerate the files after adding an input.
#
# Conformance files hold independent chunks separated by "---" lines. For
# the parser and resolver, each chunk is written to its own file, padded with
# blank lines so that line numbers match the original file.
module OracleInputs
  ROOT = File.expand_path("../..", __dir__)
  SPEC_DIR = File.join(ROOT, "spec")
  ORACLE_DIR = File.join(ROOT, "tools/oracle")
  GOLDEN_DIR = File.join(SPEC_DIR, "oracle/golden")
  CHUNK_DIR = File.join(ORACLE_DIR, ".cache/chunks")
  CHUNK_SEPARATOR = "---"
  TOOLS = %w[lex parse resolve eval].freeze
  ORACLES = %w[go java].freeze

  module_function

  # The oracles each tool has. There is no Java eval oracle yet.
  def oracles_for(tool)
    tool == "eval" ? %w[go] : ORACLES
  end

  def live?
    ENV["ORACLE_LIVE"] == "1"
  end

  # Returns [name, path] pairs for one tool.
  def for_tool(tool)
    case tool
    when "lex" then whole_files("{conformance/testdata,lexer/corpus}")
    when "parse" then collect("parser/corpus")
    when "resolve" then collect("resolver/corpus")
    when "eval" then collect("evaluator/corpus")
    end
  end

  def whole_files(pattern)
    Dir[File.join(SPEC_DIR, pattern, "**/*.star")].sort.map { |path| [relative(path), path] }
  end

  # A corpus directory, plus every conformance chunk.
  def collect(corpus)
    chunks = Dir[File.join(SPEC_DIR, "conformance/testdata/**/*.star")].flat_map { |path| chunk(path) }
    (chunks + whole_files(corpus)).sort
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

  # The expected output: an override file for Go if one exists, else the
  # oracle's output from the golden file or a live run.
  def expected(tool, oracle, name, path)
    override = path.sub(/\.star\z/, ".expected")
    return File.read(override) if oracle == "go" && File.exist?(override)
    return run(tool, oracle, path) if live?

    golden(tool, oracle).fetch(name) do
      raise "No golden #{oracle} #{tool} output for #{name}. Run: mise run oracle:golden"
    end
  end

  def run(tool, oracle, path)
    out, err, status = Open3.capture3(File.join(ORACLE_DIR, tool), oracle, path)
    raise "#{oracle} #{tool} oracle failed on #{path}: #{err}" unless status.success?

    out
  end

  def golden_path(tool, oracle)
    File.join(GOLDEN_DIR, "#{tool}-#{oracle}.json")
  end

  def golden(tool, oracle)
    @golden ||= {}
    @golden[[tool, oracle]] ||= JSON.parse(File.read(golden_path(tool, oracle))).transform_values { |entry| decode(entry) }
  end

  # JSON holds only valid UTF-8. Output with invalid bytes, such as a print
  # of a bytes value, is stored as {"base64": ...}.
  def encode(text)
    utf8 = text.dup.force_encoding(Encoding::UTF_8)
    utf8.valid_encoding? ? utf8 : { "base64" => [text].pack("m0") }
  end

  def decode(entry)
    entry.is_a?(Hash) ? entry.fetch("base64").unpack1("m0").force_encoding(Encoding::UTF_8) : entry
  end

  # Raises unless the oracles are built. Only live runs need them.
  def require_oracles!(binary)
    return unless live?
    return if File.exist?(File.join(ORACLE_DIR, ".cache/bin", binary))

    raise "Oracles are not built. Run: mise run oracle:setup"
  end
end
