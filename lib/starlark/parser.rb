# frozen_string_literal: true

module Starlark
  # Builds an AST::File from Starlark source. See the grammar reference in
  # docs/spec.md.
  #
  # The parser follows starlark-go's recursive-descent parser, so node
  # positions and error messages match tools/oracle exactly. It stops at the
  # first error. Checks that need name resolution, such as an if statement
  # at top level, belong to the resolver.
  class Parser
    include AST

    MAX_DEPTH = 1000

    # Binary operators by precedence, lowest first. See "Binary operators" in
    # docs/spec.md. Unary not sits between and and the comparisons.
    PRECEDENCE_LEVELS = [
      %i[or],
      %i[and],
      %i[not],
      %i[eql neq lt gt le ge in not_in],
      %i[pipe],
      %i[circumflex],
      %i[amp],
      %i[ltlt gtgt],
      %i[minus plus],
      %i[star percent slash slashslash]
    ].freeze
    PRECEDENCE = PRECEDENCE_LEVELS.each_with_index.flat_map { |ops, level| ops.map { |op| [op, level] } }.to_h.freeze
    NOT_PRECEDENCE = PRECEDENCE.fetch(:not)
    COMPARISON_PRECEDENCE = PRECEDENCE.fetch(:eql)

    ASSIGN_OPS = %i[
      eq plus_eq minus_eq star_eq slash_eq slashslash_eq percent_eq amp_eq pipe_eq circumflex_eq ltlt_eq gtgt_eq
    ].freeze
    EXPR_LIST_TERMINATORS = %i[eof newline eq rbrace rbrack rparen semi].freeze

    # Token names in error messages, from starlark-go's tokenNames table.
    # starlark-go has no name for bytes literals, so they print as "".
    TOKEN_NAMES = {
      eof: "end of file", newline: "newline", indent: "indent", outdent: "outdent",
      ident: "identifier", int: "int literal", float: "float literal", string: "string literal", bytes: "",
      plus: "+", minus: "-", star: "*", slash: "/", slashslash: "//", percent: "%", amp: "&", pipe: "|",
      circumflex: "^", ltlt: "<<", gtgt: ">>", tilde: "~", dot: ".", comma: ",", eq: "=", semi: ";",
      colon: ":", lparen: "(", rparen: ")", lbrack: "[", rbrack: "]", lbrace: "{", rbrace: "}",
      lt: "<", gt: ">", ge: ">=", le: "<=", eql: "==", neq: "!=", plus_eq: "+=", minus_eq: "-=",
      star_eq: "*=", slash_eq: "/=", slashslash_eq: "//=", percent_eq: "%=", amp_eq: "&=", pipe_eq: "|=",
      circumflex_eq: "^=", ltlt_eq: "<<=", gtgt_eq: ">>=", starstar: "**", not_in: "not in"
    }.freeze
    # starlark-go quotes punctuation tokens in messages, but not keywords.
    QUOTED_TOKENS = (TOKEN_NAMES.keys - %i[eof newline indent outdent ident int float string bytes not_in]).freeze

    def self.parse(source)
      new(source).parse
    end

    def initialize(source)
      @lexer = Lexer.new(source)
      @depth = 0
      next_token
    end

    def parse
      statements = []
      until @tok.kind == :eof
        if @tok.kind == :newline
          next_token
          next
        end
        parse_statement(statements)
      end
      File.new(statements: statements, line: 1, column: 1)
    end

    private

    # Statements

    def parse_statement(statements)
      case @tok.kind
      when :def then statements << parse_def_stmt
      when :if then statements << parse_if_stmt
      when :for then statements << parse_for_stmt
      when :while
        # The spec grammar has no while statement. starlark-go parses one.
        # The message is Java Starlark's.
        error_at_token("'while' not supported, use 'for' instead")
      else parse_simple_stmt(statements)
      end
    end

    def parse_def_stmt
      start = next_token
      name = parse_ident
      consume(:lparen)
      params = parse_params
      consume(:rparen)
      consume(:colon)
      DefStmt.new(name: name.name, params: params, body: parse_suite,
                  name_line: name.line, name_column: name.column, **start)
    end

    # An elif becomes a nested IfStmt, alone in the else_body of the clause
    # before it. Clauses are read in a loop, not by recursion, so a long elif
    # chain cannot exhaust the Ruby stack.
    def parse_if_stmt
      clauses = [parse_if_clause]
      clauses << parse_if_clause while @tok.kind == :elif

      else_body = []
      if @tok.kind == :else
        next_token
        consume(:colon)
        else_body = parse_suite
      end

      clauses.reverse_each do |start, condition, then_body|
        else_body = [IfStmt.new(condition: condition, then_body: then_body, else_body: else_body, **start)]
      end
      else_body.first
    end

    # Reads "if cond: suite" or "elif cond: suite".
    def parse_if_clause
      start = next_token
      condition = parse_test
      consume(:colon)
      [start, condition, parse_suite]
    end

    def parse_for_stmt
      start = next_token
      vars = parse_loop_variables
      consume(:in)
      iterable = parse_expr(in_parens: false)
      consume(:colon)
      ForStmt.new(vars: vars, iterable: iterable, body: parse_suite, **start)
    end

    # LoopVariables = PrimaryExpr {',' PrimaryExpr} .
    def parse_loop_variables
      start = token_position
      first = parse_primary_with_suffix
      return first unless @tok.kind == :comma

      elements = [first]
      while @tok.kind == :comma
        next_token
        break if EXPR_LIST_TERMINATORS.include?(@tok.kind)

        elements << parse_primary_with_suffix
      end
      TupleExpr.new(elements: elements, **start)
    end

    # SimpleStmt = SmallStmt {';' SmallStmt} [';'] '\n' .
    def parse_simple_stmt(statements)
      loop do
        statements << parse_small_stmt
        break unless @tok.kind == :semi

        next_token
        break if @tok.kind == :newline || @tok.kind == :eof
      end
      # The newline is optional at end of file, as in "if x: pass".
      consume(:newline) unless @tok.kind == :eof
      statements
    end

    def parse_small_stmt
      case @tok.kind
      when :return
        start = next_token
        value = parse_expr(in_parens: false) unless %i[eof newline semi].include?(@tok.kind)
        return ReturnStmt.new(value: value, **start)
      when :break, :continue, :pass
        kind = @tok.kind
        return BranchStmt.new(kind: kind, **next_token)
      when :load
        return parse_load_stmt
      end

      start = token_position
      expr = parse_expr(in_parens: false)
      if ASSIGN_OPS.include?(@tok.kind)
        op = @tok.kind
        next_token
        value = parse_expr(in_parens: false)
        return AssignStmt.new(op: op, target: expr, value: value, **start)
      end
      ExprStmt.new(expr: expr, **start)
    end

    # LoadStmt = 'load' '(' string {',' [identifier '='] string} [','] ')' .
    def parse_load_stmt
      start = next_token
      lparen = consume(:lparen)
      error("first operand of load statement must be a string literal") unless @tok.kind == :string
      mod = parse_primary

      bindings = []
      until @tok.kind == :rparen || @tok.kind == :eof
        consume(:comma)
        break if @tok.kind == :rparen

        bindings << parse_load_binding
      end
      consume(:rparen)

      error("load statement must import at least 1 symbol", **lparen) if bindings.empty?
      LoadStmt.new(module: mod, bindings: bindings, **start)
    end

    def parse_load_binding
      case @tok.kind
      when :string
        literal = parse_primary
        # starlark-go places the name just inside the opening quote.
        LoadBinding.new(local: literal.value, name: literal.value, line: literal.line, column: literal.column + 1,
                        name_line: literal.line, name_column: literal.column + 1)
      when :ident
        local = parse_ident
        unless @tok.kind == :eq
          error(%(load operand must be "#{local.name}" or #{local.name}="originalname" ) +
                "(want '=' after #{local.name})")
        end
        consume(:eq)
        error(%(original name of loaded symbol must be quoted: #{local.name}="originalname")) unless @tok.kind == :string
        literal = parse_primary
        LoadBinding.new(local: local.name, name: literal.value, line: local.line, column: local.column,
                        name_line: literal.line, name_column: literal.column + 1)
      else
        error(%(load operand must be "name" or localname="name" (got #{describe(@tok.kind)})))
      end
    end

    # Suite = [newline indent {Statement} outdent] | SimpleStmt .
    def parse_suite
      nested do
        if @tok.kind == :newline
          next_token
          consume(:indent)
          statements = []
          parse_statement(statements) until @tok.kind == :outdent || @tok.kind == :eof
          consume(:outdent)
          statements
        else
          parse_simple_stmt([])
        end
      end
    end

    # Parameters

    def parse_params
      params = []
      until %i[rparen colon eof].include?(@tok.kind)
        consume(:comma) unless params.empty?
        break if @tok.kind == :rparen

        params << parse_param
      end
      params
    end

    def parse_param
      if @tok.kind == :star || @tok.kind == :starstar
        kind = @tok.kind == :starstar ? :kwargs : :args
        start = next_token
        return param(:star, nil, nil, start) unless kind == :kwargs || @tok.kind == :ident

        return param(kind, parse_ident, nil, start)
      end

      ident = parse_ident
      start = { line: ident.line, column: ident.column }
      return param(:required, ident, nil, start) unless @tok.kind == :eq

      eq = next_token
      param(:optional, ident, parse_test, start, eq)
    end

    def param(kind, ident, default, start, eq = nil)
      Param.new(kind: kind, name: ident&.name, default: default,
                name_line: ident&.line, name_column: ident&.column,
                eq_line: eq&.dig(:line), eq_column: eq&.dig(:column), **start)
    end

    # Expressions

    # Expressions = Expression {',' Expression} . A list of two or more is a tuple.
    def parse_expr(in_parens:)
      start = token_position
      first = parse_test
      return first unless @tok.kind == :comma

      TupleExpr.new(elements: parse_exprs([first], allow_trailing_comma: in_parens), **start)
    end

    # Parses the rest of a comma-separated list, starting at the comma.
    def parse_exprs(exprs, allow_trailing_comma:)
      while @tok.kind == :comma
        comma = next_token
        if EXPR_LIST_TERMINATORS.include?(@tok.kind)
          error("unparenthesized tuple with trailing comma", **comma) unless allow_trailing_comma
          break
        end
        exprs << parse_test
      end
      exprs
    end

    # A single expression, including a conditional or a lambda.
    def parse_test
      nested do
        next parse_lambda(allow_cond: true) if @tok.kind == :lambda

        start = token_position
        expr = parse_test_prec(0)
        next expr unless @tok.kind == :if

        if_pos = next_token
        condition = parse_test_prec(0)
        error("conditional expression without else clause", **if_pos) unless @tok.kind == :else
        next_token
        IfExpr.new(condition: condition, then: expr, else: parse_test, **start)
      end
    end

    # A single expression without a trailing "if ... else ...".
    def parse_test_no_cond
      return parse_lambda(allow_cond: false) if @tok.kind == :lambda

      parse_test_prec(0)
    end

    def parse_lambda(allow_cond:)
      nested do
        start = next_token
        params = @tok.kind == :colon ? [] : parse_params
        consume(:colon)
        body = allow_cond ? parse_test : parse_test_no_cond
        LambdaExpr.new(params: params, body: body, **start)
      end
    end

    def parse_test_prec(prec)
      nested do
        next parse_primary_with_suffix if prec >= PRECEDENCE_LEVELS.size

        if @tok.kind == :not && prec == NOT_PRECEDENCE
          start = next_token
          next UnaryExpr.new(op: :not, operand: parse_test_prec(prec), **start)
        end

        parse_binary_expr(prec)
      end
    end

    # Precedence climbing. Comparisons do not associate.
    def parse_binary_expr(prec)
      start = token_position
      left = parse_test_prec(prec + 1)
      first = true
      loop do
        if @tok.kind == :not
          next_token
          # Here, not must be followed by in.
          error("got #{describe(@tok.kind)}, want in") unless @tok.kind == :in
          @tok = @tok.with(kind: :not_in)
        end

        op_prec = PRECEDENCE[@tok.kind]
        return left if op_prec.nil? || op_prec < prec

        if !first && op_prec == COMPARISON_PRECEDENCE
          error("#{token_name(left.op)} does not associate with #{token_name(@tok.kind)} (use parens)")
        end

        op = @tok.kind
        next_token
        right = parse_test_prec(op_prec + 1)
        left = BinaryExpr.new(op: op, left: left, right: right, **start)
        first = false
      end
    end

    # PrimaryExpr with any number of .name, [...], and (...) suffixes.
    def parse_primary_with_suffix
      start = token_position
      expr = parse_primary
      loop do
        case @tok.kind
        when :dot
          next_token
          expr = DotExpr.new(object: expr, name: parse_ident.name, **start)
        when :lbrack
          expr = parse_slice_suffix(expr, start)
        when :lparen
          expr = parse_call_suffix(expr, start)
        else
          return expr
        end
      end
    end

    def parse_slice_suffix(object, start)
      next_token
      lo = hi = step = nil
      unless @tok.kind == :colon
        index = parse_expr(in_parens: false)
        if @tok.kind == :rbrack
          next_token
          return IndexExpr.new(object: object, index: index, **start)
        end
        lo = index
      end

      if @tok.kind == :colon
        next_token
        hi = parse_test unless @tok.kind == :colon || @tok.kind == :rbrack
      end
      if @tok.kind == :colon
        next_token
        step = parse_test unless @tok.kind == :rbrack
      end
      consume(:rbrack)
      SliceExpr.new(object: object, start: lo, stop: hi, step: step, **start)
    end

    def parse_call_suffix(callee, start)
      consume(:lparen)
      if @tok.kind == :rparen
        next_token
        return CallExpr.new(callee: callee, args: [], **start)
      end
      args = parse_args
      consume(:rparen)
      CallExpr.new(callee: callee, args: args, **start)
    end

    def parse_args
      args = []
      until @tok.kind == :rparen || @tok.kind == :eof
        consume(:comma) unless args.empty?
        break if @tok.kind == :rparen

        args << parse_arg
      end
      args
    end

    def parse_arg
      if @tok.kind == :star || @tok.kind == :starstar
        kind = @tok.kind == :star ? :args : :kwargs
        start = next_token
        return Arg.new(kind: kind, name: nil, value: parse_test, **start)
      end

      start = token_position
      value = parse_test
      return Arg.new(kind: :positional, name: nil, value: value, **start) unless @tok.kind == :eq

      # The name must be a bare identifier. "(a)" parses to an Ident too, but
      # it starts at the "(", not at the name.
      bare_ident = value.is_a?(Ident) && value.line == start[:line] && value.column == start[:column]
      error("keyword argument must have form name=expr") unless bare_ident
      next_token
      Arg.new(kind: :keyword, name: value.name, value: parse_test, **start)
    end

    def parse_primary
      nested do
        case @tok.kind
        when :ident
          parse_ident
        when :int, :float, :string, :bytes
          kind = @tok.kind
          value = @tok.value
          Literal.new(kind: kind, value: value, **next_token)
        when :lbrack
          parse_list
        when :lbrace
          parse_dict
        when :lparen
          parse_paren
        when :minus, :plus, :tilde
          op = @tok.kind
          start = next_token
          UnaryExpr.new(op: op, operand: parse_primary_with_suffix, **start)
        else
          error_at_token("got #{describe(@tok.kind)}, want primary expression")
        end
      end
    end

    # A parenthesized expression has no node of its own. An empty pair of
    # parentheses is an empty tuple.
    def parse_paren
      start = next_token
      if @tok.kind == :rparen
        next_token
        return TupleExpr.new(elements: [], **start)
      end
      expr = parse_expr(in_parens: true)
      consume(:rparen)
      expr
    end

    def parse_list
      start = next_token
      if @tok.kind == :rbrack
        next_token
        return ListExpr.new(elements: [], **start)
      end

      first = parse_test
      return parse_comprehension_suffix(:list, first, :rbrack, start) if @tok.kind == :for

      elements = [first]
      elements = parse_exprs(elements, allow_trailing_comma: true) if @tok.kind == :comma
      consume(:rbrack)
      ListExpr.new(elements: elements, **start)
    end

    def parse_dict
      start = next_token
      if @tok.kind == :rbrace
        next_token
        return DictExpr.new(entries: [], **start)
      end

      first = parse_dict_entry
      return parse_comprehension_suffix(:dict, first, :rbrace, start) if @tok.kind == :for

      entries = [first]
      while @tok.kind == :comma
        next_token
        break if @tok.kind == :rbrace

        entries << parse_dict_entry
      end
      consume(:rbrace)
      DictExpr.new(entries: entries, **start)
    end

    def parse_dict_entry
      start = token_position
      key = parse_test
      consume(:colon)
      DictEntry.new(key: key, value: parse_test, **start)
    end

    def parse_comprehension_suffix(kind, body, closing, start)
      clauses = []
      until @tok.kind == closing
        case @tok.kind
        when :for
          clause_start = next_token
          vars = parse_loop_variables
          consume(:in)
          # As in Python 3, the iterable cannot be a conditional, a lambda,
          # or an unparenthesized tuple.
          clauses << ForClause.new(vars: vars, iterable: parse_test_prec(0), **clause_start)
        when :if
          clause_start = next_token
          clauses << IfClause.new(condition: parse_test_no_cond, **clause_start)
        else
          error("got #{describe(@tok.kind)}, want '#{token_name(closing)}', for, or if")
        end
      end
      next_token
      Comprehension.new(kind: kind, body: body, clauses: clauses, **start)
    end

    def parse_ident
      error("not an identifier") unless @tok.kind == :ident
      ident = Ident.new(name: @tok.value, line: @tok.line, column: @tok.column)
      next_token
      ident
    end

    # Tokens

    # Advances to the next token. Returns the position of the token just consumed.
    def next_token
      previous = @tok && token_position
      @tok = @lexer.next_token
      previous
    end

    def token_position
      { line: @tok.line, column: @tok.column }
    end

    def consume(kind)
      error("got #{describe(@tok.kind)}, want #{describe(kind)}") unless @tok.kind == kind
      next_token
    end

    # Keywords are named by their own text.
    def token_name(kind)
      TOKEN_NAMES.fetch(kind) { kind.to_s }
    end

    # Formats a token kind like starlark-go's %#v verb.
    def describe(kind)
      QUOTED_TOKENS.include?(kind) ? "'#{token_name(kind)}'" : token_name(kind)
    end

    # Limits recursion, as starlark-go does, so deep nesting cannot exhaust the Ruby stack.
    def nested
      @depth += 1
      error("excessive nesting") if @depth > MAX_DEPTH
      yield
    ensure
      @depth -= 1
    end

    # Reports an error at the lexer position, just after the current token.
    def error(message, line: nil, column: nil)
      line, column = @lexer.position if line.nil?
      raise SyntaxError.new(message, line: line, column: column)
    end

    # Reports an error at the start of the current token.
    def error_at_token(message)
      error(message, **token_position)
    end
  end
end
