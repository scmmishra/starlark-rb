# frozen_string_literal: true

module Starlark
  class Error < StandardError; end

  # A static error found before execution, with a 1-based position.
  # The column counts Unicode code points.
  class SyntaxError < Error
    attr_reader :line, :column

    def initialize(message, line:, column:)
      super(message)
      @line = line
      @column = column
    end
  end

  # Static errors found by the resolver. The resolver reports every error
  # it finds, not only the first. errors lists them as SyntaxError objects,
  # in the order the resolver found them.
  class ResolveError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.first.message)
    end

    def line = errors.first.line
    def column = errors.first.column
  end
end
