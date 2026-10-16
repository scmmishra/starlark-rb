# frozen_string_literal: true

require "spec_helper"
require "yaml"
require_relative "../support/eval_dump"

# Runs the upstream conformance suite in spec/conformance/testdata, the way
# bazelbuild/starlark's test_suite/starlark_test.py does.
#
# - A line holding only "---" separates independent chunks.
# - A trailing "### regex" comment marks a chunk that must fail with an error
#   matching the regex, as a case-insensitive substring or regex search.
# - "### go: regex" applies to the Go implementation only. We follow the go
#   tags, because Go shares our string model, and skip java and rust tags.
#
# Unlike the upstream runner, a failed assert_eq fails the chunk.
#
# A chunk listed in known_failures.yml is pending with its reason.
module Conformance
  DIR = File.join(__dir__, "testdata")
  EXPECTATION = /\A(.*?) *### *((go|java|rust):)? *(.*)\z/
  KNOWN_FAILURES = YAML.load_file(File.join(__dir__, "known_failures.yml")) || {}

  Chunk = Struct.new(:name, :source, :expected)

  module_function

  def chunks
    Dir[File.join(DIR, "**/*.star")].sort.flat_map do |path|
      relative = path.delete_prefix("#{DIR}/")
      parse(relative, File.binread(path).force_encoding(Encoding::UTF_8))
    end
  end

  def parse(relative, text)
    chunks = []
    lines = []
    expected = []
    start = 1
    text.lines.each_with_index do |raw, index|
      line = raw.rstrip
      if line == "---"
        chunks << Chunk.new("#{relative}:#{start}", lines.join, expected)
        lines = []
        expected = []
        start = index + 2
        next
      end
      if (match = EXPECTATION.match(line))
        expected << match[4] if match[3].nil? || match[3] == "go"
        lines << "#{match[1]}\n"
      else
        lines << "#{line}\n"
      end
    end
    chunks << Chunk.new("#{relative}:#{start}", lines.join, expected)
  end

  # Returns the error message, or nil if the chunk ran without error.
  def run(source)
    thread = Starlark::Thread.new(print: ->(_message) {})
    thread.exec_file(source, filename: "chunk.star", predeclared: EvalDump.predeclared)
    nil
  rescue Starlark::Error => e
    e.message
  end

  def matches?(message, pattern)
    lower = message.downcase
    expected = pattern.downcase
    lower.include?(expected) || Regexp.new(expected).match?(lower)
  rescue RegexpError
    false
  end
end

RSpec.describe Starlark::Thread, "conformance" do
  Conformance.chunks.each do |chunk|
    it chunk.name do
      reason = Conformance::KNOWN_FAILURES[chunk.name]
      pending(reason) if reason
      message = Conformance.run(chunk.source)
      if chunk.expected.empty?
        expect(message).to be_nil, "unexpected error: #{message}"
      else
        expect(message).not_to be_nil, "expected an error matching: #{chunk.expected.first}"
        expect(Conformance.matches?(message, chunk.expected.first)).to be(true),
                                                                        "error #{message.inspect} does not match #{chunk.expected.first.inspect}"
      end
    end
  end
end
