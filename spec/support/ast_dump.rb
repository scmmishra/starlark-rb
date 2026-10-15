# frozen_string_literal: true

require_relative "oracle_format"

# Prints a Starlark::AST tree in the parser oracle format. See tools/oracle/README.md.
class AstDump
  include Starlark::AST

  def self.call(file)
    new.dump(file)
  end

  def dump(file)
    @lines = []
    file.statements.each { |statement| node(statement, 0) }
    @lines.map { |line| "#{line}\n" }.join
  end

  private

  def line(node, depth, text)
    @lines << "#{"  " * depth}#{node.line}:#{node.column} #{text}"
  end

  def label(depth, text)
    @lines << "#{"  " * depth}#{text}"
  end

  def statements(text, statements, depth)
    label(depth, text)
    statements.each { |statement| node(statement, depth + 1) }
  end

  def op(kind)
    Starlark::Parser::TOKEN_NAMES.fetch(kind) { kind.to_s }
  end

  def node(n, depth)
    case n
    in DefStmt
      line(n, depth, "DefStmt #{n.name}")
      n.params.each { |param| param(param, depth + 1) }
      statements("body", n.body, depth + 1)
    in IfStmt
      line(n, depth, "IfStmt")
      node(n.condition, depth + 1)
      statements("then", n.then_body, depth + 1)
      statements("else", n.else_body, depth + 1) unless n.else_body.empty?
    in ForStmt
      line(n, depth, "ForStmt")
      node(n.vars, depth + 1)
      node(n.iterable, depth + 1)
      statements("body", n.body, depth + 1)
    in ReturnStmt
      line(n, depth, "ReturnStmt")
      node(n.value, depth + 1) if n.value
    in BranchStmt
      line(n, depth, "BranchStmt #{n.kind}")
    in AssignStmt
      line(n, depth, "AssignStmt #{op(n.op)}")
      node(n.target, depth + 1)
      node(n.value, depth + 1)
    in ExprStmt
      line(n, depth, "ExprStmt")
      node(n.expr, depth + 1)
    in LoadStmt
      line(n, depth, "LoadStmt #{OracleFormat.quote(n.module.value)}")
      n.bindings.each { |binding| line(binding, depth + 1, "LoadBinding #{binding.local} #{binding.name}") }
    in Ident
      line(n, depth, "Ident #{n.name}")
    in Literal
      line(n, depth, "Literal #{literal(n)}")
    in ListExpr | TupleExpr
      line(n, depth, n.class.name.split("::").last)
      n.elements.each { |element| node(element, depth + 1) }
    in DictExpr
      line(n, depth, "DictExpr")
      n.entries.each { |entry| node(entry, depth + 1) }
    in DictEntry
      line(n, depth, "DictEntry")
      node(n.key, depth + 1)
      node(n.value, depth + 1)
    in Comprehension
      line(n, depth, "Comprehension #{n.kind}")
      node(n.body, depth + 1)
      n.clauses.each { |clause| node(clause, depth + 1) }
    in ForClause
      line(n, depth, "ForClause")
      node(n.vars, depth + 1)
      node(n.iterable, depth + 1)
    in IfClause
      line(n, depth, "IfClause")
      node(n.condition, depth + 1)
    in IfExpr
      line(n, depth, "IfExpr")
      node(n.condition, depth + 1)
      node(n.then, depth + 1)
      node(n.else, depth + 1)
    in UnaryExpr
      line(n, depth, "UnaryExpr #{op(n.op)}")
      node(n.operand, depth + 1)
    in BinaryExpr
      line(n, depth, "BinaryExpr #{op(n.op)}")
      node(n.left, depth + 1)
      node(n.right, depth + 1)
    in LambdaExpr
      line(n, depth, "LambdaExpr")
      n.params.each { |param| param(param, depth + 1) }
      label(depth + 1, "body")
      node(n.body, depth + 2)
    in DotExpr
      line(n, depth, "DotExpr #{n.name}")
      node(n.object, depth + 1)
    in CallExpr
      line(n, depth, "CallExpr")
      node(n.callee, depth + 1)
      n.args.each { |arg| arg(arg, depth + 1) }
    in IndexExpr
      line(n, depth, "IndexExpr")
      node(n.object, depth + 1)
      node(n.index, depth + 1)
    in SliceExpr
      line(n, depth, "SliceExpr")
      node(n.object, depth + 1)
      { "start" => n.start, "stop" => n.stop, "step" => n.step }.each do |text, part|
        next unless part

        label(depth + 1, text)
        node(part, depth + 2)
      end
    end
  end

  def param(param, depth)
    line(param, depth, ["Param", param.kind, param.name].compact.join(" "))
    node(param.default, depth + 1) if param.default
  end

  def arg(arg, depth)
    line(arg, depth, ["Arg", arg.kind, arg.name].compact.join(" "))
    node(arg.value, depth + 1)
  end

  def literal(n)
    case n.kind
    when :int then "int #{n.value}"
    when :float then "float #{OracleFormat.float_bits(n.value)}"
    else "#{n.kind} #{OracleFormat.quote(n.value)}"
    end
  end
end
