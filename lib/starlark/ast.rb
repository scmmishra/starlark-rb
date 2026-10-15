# frozen_string_literal: true

module Starlark
  # Syntax tree nodes. Names follow the grammar reference in docs/spec.md.
  #
  # Every node records the line and column of its first token. A parenthesized
  # expression has no node of its own, but an expression that starts with "("
  # records the position of that parenthesis, as starlark-go does.
  module AST
    def self.node(*fields)
      Data.define(*fields, :line, :column)
    end

    File = node(:statements)

    # Statements
    # name_line and name_column locate the function name.
    DefStmt = node(:name, :params, :body, :name_line, :name_column)
    # An elif becomes a nested IfStmt, alone in else_body.
    IfStmt = node(:condition, :then_body, :else_body)
    ForStmt = node(:vars, :iterable, :body)
    ReturnStmt = node(:value)
    # kind is :break, :continue, or :pass.
    BranchStmt = node(:kind)
    # op is :eq for plain assignment, or an augmented operator such as :plus_eq.
    AssignStmt = node(:op, :target, :value)
    ExprStmt = node(:expr)
    # module is a Literal. bindings is a list of LoadBinding.
    LoadStmt = node(:module, :bindings)

    # Expressions
    Ident = node(:name)
    # kind is :int, :float, :string, or :bytes.
    Literal = node(:kind, :value)
    ListExpr = node(:elements)
    TupleExpr = node(:elements)
    DictExpr = node(:entries)
    # kind is :list or :dict. For :dict, body is a DictEntry.
    Comprehension = node(:kind, :body, :clauses)
    IfExpr = node(:condition, :then, :else)
    # op is :plus, :minus, :tilde, or :not.
    UnaryExpr = node(:op, :operand)
    # op is a token kind such as :plus or :and, or :not_in for "not in".
    BinaryExpr = node(:op, :left, :right)
    LambdaExpr = node(:params, :body)
    DotExpr = node(:object, :name)
    CallExpr = node(:callee, :args)
    IndexExpr = node(:object, :index)
    SliceExpr = node(:object, :start, :stop, :step)

    # Parts of other nodes
    # kind is :required, :optional, :star, :args, or :kwargs. name is nil for a bare "*".
    # name_line and name_column locate the name, after any "*" or "**".
    # eq_line and eq_column locate the "=" of an optional parameter.
    Param = node(:kind, :name, :default, :name_line, :name_column, :eq_line, :eq_column)
    # kind is :positional, :keyword, :args, or :kwargs. name is set only for :keyword.
    Arg = node(:kind, :name, :value)
    DictEntry = node(:key, :value)
    ForClause = node(:vars, :iterable)
    IfClause = node(:condition)
    # local is the bound name. name is the name exported by the loaded module.
    # The node's position is the local name's. name_line and name_column
    # locate the exported name, just inside its opening quote.
    LoadBinding = node(:local, :name, :name_line, :name_column)
  end
end
