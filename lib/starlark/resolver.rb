# frozen_string_literal: true

module Starlark
  # Binds every name in an AST::File to a scope and a slot, and reports the
  # static errors that need names, such as undefined names or a for loop at
  # top level. See "Name binding and variables" in docs/spec.md.
  #
  # The resolver ports starlark-go's resolver, so bindings, slot numbers, and
  # error messages match tools/oracle exactly. It differs where the spec
  # differs from starlark-go: it allows calls with more than 255 arguments,
  # and it rejects load names that are not valid identifiers.
  #
  # AST nodes are frozen, so the result is a separate Resolution. It maps
  # each node that names a variable to its Binding: every AST::Ident, and
  # the DefStmt, Param, and LoadBinding nodes that declare a name.
  class Resolver
    include AST

    # The spec's builtins.
    UNIVERSAL = %w[
      None True False abs any all bool bytes dict dir enumerate fail float getattr hasattr hash int len
      list max min print range repr reversed set sorted str tuple type zip
    ].to_set.freeze

    # scope is :local, :cell, :free, :global, :predeclared, :universal, or
    # :undefined. A cell is a local that a nested function captures.
    # index is the slot in the function's or module's locals for :local and
    # :cell, in the function's free_vars for :free, and in the module's
    # globals for :global. name, line, and column describe the first binding
    # occurrence, and are nil for predeclared, universal, and undefined names.
    Binding = Struct.new(:scope, :index, :name, :line, :column)

    # One per def or lambda. name is "lambda" for a lambda. locals lists
    # parameters first. free_vars lists the enclosing bindings it captures.
    Function = Struct.new(:name, :line, :column, :params, :has_varargs, :has_kwargs, :num_kwonly_params,
                          :locals, :free_vars)

    # locals holds load bindings and top-level comprehension variables.
    Module = Struct.new(:locals, :globals)

    # functions maps each DefStmt and LambdaExpr node to its Function.
    # bindings maps each naming node to its Binding. Both compare nodes by
    # identity.
    Resolution = Struct.new(:module, :functions, :bindings)

    # starlark-go's type names, used in "can't assign to" messages.
    GO_TYPE_NAMES = {
      Literal => "literal", CallExpr => "callexpr", BinaryExpr => "binaryexpr", UnaryExpr => "unaryexpr",
      IfExpr => "condexpr", LambdaExpr => "lambdaexpr", SliceExpr => "sliceexpr",
      Comprehension => "comprehension", DictExpr => "dictexpr"
    }.freeze

    IDENTIFIER = /\A[\p{L}_][\p{L}_0-9]*\z/

    Block = Struct.new(:parent, :function, :bindings, :children, :uses) do
      def bind(name, binding)
        bindings[name] = binding
      end
    end

    # A name occurrence. node is the key in Resolution#bindings.
    Use = Struct.new(:node, :name, :line, :column, :env)

    # Resolves file and returns a Resolution. Raises ResolveError if the file
    # has static errors. predeclared lists the names the host adds. filename
    # appears in messages that point at an earlier declaration.
    def self.resolve(file, predeclared: [], filename: "<input>")
      new(predeclared, filename).resolve(file)
    end

    def initialize(predeclared, filename)
      @predeclared_names = predeclared.to_set
      @filename = filename
      @file = new_block(nil, nil)
      @env = @file
      @module_locals = []
      @module_globals = []
      @globals = {}
      @predeclared = {}
      @functions = {}.compare_by_identity
      @bindings = {}.compare_by_identity
      @loops = 0
      @ifstmts = 0
      @errors = []
    end

    def resolve(file)
      statements(file.statements)
      resolve_local_uses(@env)
      # Function bodies may refer to globals declared later in the file, so
      # these are resolved at the end of the module.
      resolve_non_local_uses(@env)
      raise ResolveError, @errors unless @errors.empty?

      Resolution.new(Module.new(@module_locals, @module_globals), @functions, @bindings)
    end

    private

    def new_block(parent, function)
      Block.new(parent, function, {}, [], [])
    end

    def error(message, line, column)
      @errors << SyntaxError.new(message, line: line, column: column)
    end

    # The innermost function block, or the file block.
    def container
      block = @env
      block = block.parent until block.function || block.equal?(@file)
      block
    end

    def push(block)
      @env.children << block
      @env = block
    end

    def pop
      @env = @env.parent
    end

    def top_level?
      container.function.nil?
    end

    # Statements

    def statements(list)
      list.each { |statement| statement(statement) }
    end

    def statement(stmt)
      case stmt
      when ExprStmt then expr(stmt.expr)
      when BranchStmt
        if @loops.zero? && stmt.kind != :pass
          error("#{stmt.kind} not in a loop", stmt.line, stmt.column)
        end
      when IfStmt then if_stmt(stmt)
      when AssignStmt
        expr(stmt.value)
        assign(stmt.target, augmented: stmt.op != :eq)
      when DefStmt
        bind(Use.new(stmt, stmt.name, stmt.name_line, stmt.name_column))
        function(stmt, stmt.name, stmt.params) { statements(stmt.body) }
      when ForStmt
        error("for loop not within a function", stmt.line, stmt.column) if top_level?
        expr(stmt.iterable)
        assign(stmt.vars, augmented: false)
        @loops += 1
        statements(stmt.body)
        @loops -= 1
      when ReturnStmt
        error("return statement not within a function", stmt.line, stmt.column) if top_level?
        expr(stmt.value) if stmt.value
      when LoadStmt then load_stmt(stmt)
      # :nocov:
      # The parser builds no other node types.
      else raise ArgumentError, "unexpected statement #{stmt.class}"
      # :nocov:
      end
    end

    # An elif is a nested IfStmt alone in else_body. The chain is walked in a
    # loop, so a long elif chain cannot exhaust the Ruby stack.
    # Each elif counts as one more enclosing if, as in a recursive walk.
    def if_stmt(stmt)
      depth = 0
      loop do
        error("if statement not within a function", stmt.line, stmt.column) if top_level?
        expr(stmt.condition)
        @ifstmts += 1
        depth += 1
        statements(stmt.then_body)
        else_body = stmt.else_body
        break statements(else_body) unless else_body.size == 1 && else_body.first.is_a?(IfStmt)

        stmt = else_body.first
      end
      @ifstmts -= depth
    end

    def load_stmt(stmt)
      if !top_level?
        error("load statement within a function", stmt.line, stmt.column)
      elsif @loops.positive?
        error("load statement within a loop", stmt.line, stmt.column)
      elsif @ifstmts.positive?
        error("load statement within a conditional", stmt.line, stmt.column)
      end

      stmt.bindings.each do |binding|
        name = binding.name
        if name.empty?
          error("load: empty identifier", binding.name_line, binding.name_column)
          next
        end
        # Spec, "Load statements": the name must denote a valid identifier.
        # starlark-go and Java Starlark accept any string.
        unless valid_identifier?(name)
          error("load: not a valid identifier: #{name}", binding.name_line, binding.name_column)
          next
        end
        if name.start_with?("_")
          error("load: names with leading underscores are not exported: #{name}", binding.name_line,
                binding.name_column)
        end

        use = Use.new(binding, binding.local, binding.line, binding.column)
        error("cannot reassign top-level #{binding.local}", binding.line, binding.column) if bind_local(use)
      end
    end

    def valid_identifier?(name)
      name.match?(IDENTIFIER) && !Lexer::KEYWORDS.key?(name)
    end

    def assign(target, augmented:)
      case target
      when Ident
        bind(Use.new(target, target.name, target.line, target.column))
      when IndexExpr
        expr(target.object)
        expr(target.index)
      when DotExpr
        expr(target.object)
      when TupleExpr, ListExpr
        if augmented
          kind = target.is_a?(TupleExpr) ? "tuple" : "list"
          error("can't use #{kind} expression in augmented assignment", target.line, target.column)
        end
        target.elements.each { |element| assign(element, augmented: augmented) }
      else
        error("can't assign to #{GO_TYPE_NAMES.fetch(target.class)}", target.line, target.column)
      end
    end

    # Bindings

    # Binds a name: as a global at top level, as a local elsewhere. Returns
    # true if the name was already bound.
    def bind(use)
      return bind_local(use) unless @env.equal?(@file)

      binding = @file.bindings[use.name] || @globals[use.name]
      existed = !binding.nil?
      unless binding
        binding = Binding.new(:global, @module_globals.size, use.name, use.line, use.column)
        @globals[use.name] = binding
        @module_globals << binding
      end
      if existed
        error("cannot reassign #{binding.scope} #{use.name} declared at " \
              "#{@filename}:#{binding.line}:#{binding.column}", use.line, use.column)
      end
      @bindings[use.node] = binding
      existed
    end

    def bind_local(use)
      existed = @env.bindings.key?(use.name)
      unless existed
        locals = container.function ? container.function.locals : @module_locals
        binding = Binding.new(:local, locals.size, use.name, use.line, use.column)
        @env.bind(use.name, binding)
        locals << binding
      end
      self.use(use)
      existed
    end

    def use(use)
      use.env = @env
      container.uses << use
    end

    # Resolves the uses within a function or the module that refer to its own
    # locals. The rest stay, to be resolved at the end of the module.
    def resolve_local_uses(block)
      block.uses.select! do |use|
        binding = lookup_local(use)
        if binding && %i[local cell].include?(binding.scope)
          @bindings[use.node] = binding
          false
        else
          true
        end
      end
    end

    def lookup_local(use)
      env = use.env
      while env
        binding = env.bindings[use.name]
        return binding if binding
        break if env.function

        env = env.parent
      end
      nil
    end

    def resolve_non_local_uses(block)
      block.children.each { |child| resolve_non_local_uses(child) }
      block.uses.each { |use| @bindings[use.node] = lookup_lexical(use, use.env) }
    end

    # Looks up a name in the enclosing blocks. A local of an enclosing
    # function becomes a cell, and each function in between captures it as a
    # free variable.
    def lookup_lexical(use, env)
      return use_top_level(use) if env.equal?(@file)

      binding = env.bindings[use.name]
      return binding if binding

      binding = lookup_lexical(use, env.parent)
      if env.function && %i[local free cell].include?(binding.scope)
        binding.scope = :cell if binding.scope == :local
        free_vars = env.function.free_vars
        free_vars << binding
        binding = Binding.new(:free, free_vars.size - 1, binding.name, binding.line, binding.column)
      end
      env.bind(use.name, binding)
      binding
    end

    def use_top_level(use)
      name = use.name
      binding = @file.bindings[name] || @globals[name] || @predeclared[name]
      binding ||=
        if @predeclared_names.include?(name)
          @predeclared[name] = Binding.new(:predeclared, 0)
        elsif UNIVERSAL.include?(name)
          @predeclared[name] = Binding.new(:universal, 0)
        else
          hint = Spell.nearest(name, spellcheck_names(use))
          error("undefined: #{name}#{" (did you mean #{hint}?)" if hint}", use.line, use.column)
          Binding.new(:undefined, 0)
        end
      @bindings[use.node] = binding
      binding
    end

    # The names visible from a use, for the "did you mean" hint.
    def spellcheck_names(use)
      names = []
      env = use.env
      while env
        names.concat(env.bindings.keys)
        env = env.parent
      end
      names.concat(@module_globals.map(&:name))
      names.sort
    end

    # Functions

    def function(node, name, params)
      # Defaults are resolved in the enclosing block.
      params.each { |param| expr(param.default) if param.default }

      fn = Function.new(name, node.line, node.column, params, false, false, 0, [], [])
      @functions[node] = fn
      block = new_block(@env, fn)
      block.parent = @env
      push(block)
      outer_loops = @loops
      @loops = 0

      bind_params(fn, params)
      yield

      resolve_local_uses(block)
      pop
      @loops = outer_loops
    end

    def bind_params(fn, params)
      seen_optional = false
      star = nil
      star_star = nil
      params.each do |param|
        case param.kind
        when :required
          if star_star
            error("required parameter may not follow **#{star_star.name}", param.line, param.column)
          elsif star
            fn.num_kwonly_params += 1
          elsif seen_optional
            error("required parameter may not follow optional", param.line, param.column)
          end
          if bind(param_use(param))
            error("duplicate parameter: #{param.name}", param.line, param.column)
          end
        when :optional
          if star_star
            error("optional parameter may not follow **#{star_star.name}", param.eq_line, param.eq_column)
          elsif star
            fn.num_kwonly_params += 1
          end
          if bind(param_use(param))
            error("duplicate parameter: #{param.name}", param.eq_line, param.eq_column)
          end
          seen_optional = true
        when :star, :args
          if star_star
            error("* parameter may not follow **#{star_star.name}", param.line, param.column)
          elsif star
            error("multiple * parameters not allowed", param.line, param.column)
          else
            star = param
          end
        when :kwargs
          error("multiple ** parameters not allowed", param.line, param.column) if star_star
          star_star = param
        end
      end

      # *args and **kwargs are bound last, so the other parameters take
      # contiguous slots.
      if star&.kind == :args
        if bind(param_use(star))
          error("duplicate parameter: #{star.name}", star.name_line, star.name_column)
        end
        fn.has_varargs = true
      elsif star && fn.num_kwonly_params.zero?
        error("bare * must be followed by keyword-only parameters", star.line, star.column)
      end
      return unless star_star

      if bind(param_use(star_star))
        error("duplicate parameter: #{star_star.name}", star_star.name_line, star_star.name_column)
      end
      fn.has_kwargs = true
    end

    def param_use(param)
      Use.new(param, param.name, param.name_line, param.name_column)
    end

    # Expressions

    def expr(node)
      case node
      when Ident then use(Use.new(node, node.name, node.line, node.column))
      when Literal then nil
      when ListExpr, TupleExpr then node.elements.each { |element| expr(element) }
      when DictExpr then node.entries.each { |entry| expr(entry) }
      when DictEntry
        expr(node.key)
        expr(node.value)
      when IfExpr
        expr(node.condition)
        expr(node.then)
        expr(node.else)
      when UnaryExpr then expr(node.operand)
      when BinaryExpr, DotExpr, CallExpr, IndexExpr, SliceExpr then chain(node)
      when Comprehension then comprehension(node)
      when LambdaExpr then function(node, "lambda", node.params) { expr(node.body) }
      # :nocov:
      # The parser builds no other node types.
      else raise ArgumentError, "unexpected expression #{node.class}"
      # :nocov:
      end
    end

    # Binary operators and suffixes nest on the left, so "a + b + c + ..."
    # and "a.b.c..." can be very deep. The left spine is walked in a loop,
    # in the same order as a recursive walk.
    def chain(node)
      spine = []
      while (left = spine_child(node))
        spine << node
        node = left
      end
      expr(node)
      spine.reverse_each do |link|
        case link
        when BinaryExpr then expr(link.right)
        when CallExpr then call_args(link)
        when IndexExpr then expr(link.index)
        when SliceExpr then [link.start, link.stop, link.step].compact.each { |part| expr(part) }
        end
      end
    end

    def spine_child(node)
      case node
      when BinaryExpr then node.left
      when DotExpr, IndexExpr, SliceExpr then node.object
      when CallExpr then node.callee
      end
    end

    def call_args(call)
      seen_args = false
      seen_kwargs = false
      names = {}
      call.args.each do |arg|
        case arg.kind
        when :kwargs
          error("multiple **kwargs not allowed", arg.line, arg.column) if seen_kwargs
          seen_kwargs = true
        when :args
          if seen_kwargs
            error("*args may not follow **kwargs", arg.line, arg.column)
          elsif seen_args
            error("multiple *args not allowed", arg.line, arg.column)
          end
          seen_args = true
        when :keyword
          if seen_kwargs
            error("keyword argument may not follow **kwargs", arg.line, arg.column)
          elsif seen_args
            error("keyword argument may not follow *args", arg.line, arg.column)
          end
          if names.key?(arg.name)
            error("keyword argument #{arg.name.inspect} is repeated", arg.line, arg.column)
          else
            names[arg.name] = true
          end
        else
          if seen_args
            error("positional argument may not follow *args", arg.line, arg.column)
          elsif seen_kwargs
            error("positional argument may not follow **kwargs", arg.line, arg.column)
          elsif names.any?
            error("positional argument may not follow named", arg.line, arg.column)
          end
        end
        # The spec has no limit on the number of arguments. starlark-go
        # rejects more than 255, a limit of its compiler. Java Starlark has none.
        expr(arg.value)
      end
    end

    def comprehension(node)
      # The first iterable is resolved outside the comprehension, as in
      # [x for x in x].
      first, *rest = node.clauses
      expr(first.iterable)

      push(new_block(@env, nil))
      assign(first.vars, augmented: false)
      rest.each do |clause|
        case clause
        when IfClause then expr(clause.condition)
        when ForClause
          assign(clause.vars, augmented: false)
          expr(clause.iterable)
        end
      end
      expr(node.body)
      pop
    end
  end
end
