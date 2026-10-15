# frozen_string_literal: true

module Starlark
  # Turns Starlark source into tokens. See "Lexical elements" in docs/spec.md.
  class Lexer
    def self.tokenize(source)
      new(source).tokenize
    end

    def initialize(source)
      @source = source
    end

    def tokenize
      raise NotImplementedError, "lexer is not implemented yet"
    end
  end
end
