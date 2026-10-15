# frozen_string_literal: true

require "set"
require_relative "starlark/errors"
require_relative "starlark/lexer"
require_relative "starlark/ast"
require_relative "starlark/parser"
require_relative "starlark/spell"
require_relative "starlark/resolver"

module Starlark
  VERSION = "0.1.0"
end
