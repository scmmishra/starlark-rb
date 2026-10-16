# frozen_string_literal: true

require "set"
require_relative "starlark/errors"
require_relative "starlark/lexer"
require_relative "starlark/ast"
require_relative "starlark/parser"
require_relative "starlark/spell"
require_relative "starlark/resolver"
require_relative "starlark/quote"
require_relative "starlark/values"
require_relative "starlark/limits"
require_relative "starlark/callable"
require_relative "starlark/operators"
require_relative "starlark/format"
require_relative "starlark/attributes"
require_relative "starlark/methods"
require_relative "starlark/builtins"
require_relative "starlark/evaluator"
require_relative "starlark/embedding"

module Starlark
  VERSION = "0.1.0"
end
