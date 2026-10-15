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
end
