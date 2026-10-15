# frozen_string_literal: true

# Prints our resolution of a source file in the resolver oracle format.
# See tools/oracle/README.md.
module ResolveDump
  # The oracles use the same names and file name.
  PREDECLARED = %w[assert_eq assert_ne assert_].freeze
  FILENAME = "input.star"

  module_function

  def call(source, predeclared: PREDECLARED)
    file = Starlark::Parser.parse(source)
    resolution = Starlark::Resolver.resolve(file, predeclared: predeclared, filename: FILENAME)
    dump(file, resolution)
  rescue Starlark::SyntaxError => e
    "#{e.line}:#{e.column} ERROR #{e.message}\n"
  rescue Starlark::ResolveError => e
    e.errors.map { |error| "#{error.line}:#{error.column} ERROR #{error.message}\n" }.join
  end

  def dump(file, resolution)
    lines = ["module", "  locals: #{names(resolution.module.locals)}", "  globals: #{names(resolution.module.globals)}"]
    entries(file).sort_by { |node| [node.line, node.column] }.each do |node|
      if node.is_a?(Starlark::AST::Ident)
        lines << "#{node.line}:#{node.column} #{ident(node, resolution.bindings[node])}"
      else
        function(lines, node, resolution.functions.fetch(node))
      end
    end
    lines.map { |line| "#{line}\n" }.join
  end

  # Every Ident, DefStmt, and LambdaExpr in the tree.
  def entries(file)
    found = []
    stack = file.statements.dup
    until stack.empty?
      node = stack.pop
      case node
      when Array then stack.concat(node)
      when Data
        found << node if node.is_a?(Starlark::AST::Ident) || node.is_a?(Starlark::AST::DefStmt) ||
                         node.is_a?(Starlark::AST::LambdaExpr)
        stack.concat(node.to_h.values)
      end
    end
    found
  end

  def function(lines, node, fn)
    flags = []
    flags << "varargs" if fn.has_varargs
    flags << "kwargs" if fn.has_kwargs
    flags << "kwonly=#{fn.num_kwonly_params}" if fn.num_kwonly_params.positive?
    lines << "#{node.line}:#{node.column} #{["function #{fn.name}", *flags].join(" ")}"
    lines << "  locals: #{names(fn.locals)}"
    lines << "  free: #{names(fn.free_vars)}"
  end

  # Names in slot order. A trailing * marks a cell.
  def names(bindings)
    bindings.map { |binding| binding.scope == :cell ? "#{binding.name}*" : binding.name }.join(" ")
  end

  def ident(node, binding)
    return "Ident #{node.name} unresolved" unless binding
    return "Ident #{node.name} #{binding.scope}" if %i[predeclared universal].include?(binding.scope)

    "Ident #{node.name} #{binding.scope} #{binding.index}"
  end
end
