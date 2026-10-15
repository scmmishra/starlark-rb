# frozen_string_literal: true

require "fileutils"

# Lists the inputs for the parser and resolver oracle specs.
#
# Conformance files hold independent chunks separated by "---" lines. Each
# chunk is written to its own file, padded with blank lines so that line
# numbers match the original file.
module OracleInputs
  SPEC_DIR = File.expand_path("..", __dir__)
  CHUNK_DIR = File.expand_path("../../tools/oracle/.cache/chunks", __dir__)
  CHUNK_SEPARATOR = "---"

  module_function

  # Returns [name, path] pairs for a corpus directory and every conformance chunk.
  def collect(corpus)
    files = Dir[File.join(SPEC_DIR, corpus, "**/*.star")].map { |path| [relative(path), path] }
    chunks = Dir[File.join(SPEC_DIR, "conformance/testdata/**/*.star")].flat_map { |path| chunk(path) }
    (chunks + files).sort
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

  # The expected output: an override file for Go if one exists, else the oracle's.
  def expected(tool, oracle, path)
    override = path.sub(/\.star\z/, ".expected")
    return File.read(override) if oracle == "go" && File.exist?(override)

    out, err, status = Open3.capture3(File.expand_path("../../tools/oracle/#{tool}", __dir__), oracle, path)
    raise "#{oracle} #{tool} oracle failed on #{path}: #{err}" unless status.success?

    out
  end
end
