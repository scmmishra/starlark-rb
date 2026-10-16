# frozen_string_literal: true

module Starlark
  # Runs resolved Starlark code. A Thread holds the call stack, the step
  # count, and the host's print and load callbacks. Messages follow
  # starlark-go, so they match the eval oracle.
  class Thread
    include AST

    # The globals and names visible to one module's code.
    ModuleEnv = Struct.new(:filename, :resolution, :globals, :predeclared)

    # One active call. locals holds values, or a Cell for a captured local.
    Frame = Struct.new(:name, :info, :locals, :free, :env, :line, :column)

    Return = Struct.new(:value)

    MAX_STACK_DEPTH = 400

    attr_reader :steps, :limits

    # print receives each print() message. load receives a module name and
    # returns a Hash of its globals, or raises. limits is a Limits.
    def initialize(print: nil, load: nil, limits: Limits.new)
      @print = print || ->(message) { warn(message) }
      @load = load
      @limits = limits
      @steps = 0
      @stack = []
    end

    def print_message(message)
      @print.call(message)
    end

    # Runs a module and returns its frozen globals as a Hash.
    def exec_file(source, filename: "<input>", predeclared: {})
      file = Parser.parse(source)
      resolution = Resolver.resolve(file, predeclared: predeclared.keys, filename: filename)
      env = ModuleEnv.new(filename, resolution, Array.new(resolution.module.globals.size, Value::UNBOUND), predeclared)
      frame = Frame.new("<toplevel>", nil, new_locals(resolution.module.locals), [], env, 1, 1)
      with_frame(frame) { exec_stmts(file.statements, frame) }

      globals = {}
      resolution.module.globals.each_with_index do |binding, i|
        value = env.globals[i]
        next if value.equal?(Value::UNBOUND)

        Value.freeze(value)
        globals[binding.name] = value
      end
      globals
    end

    # Calls a Starlark or Ruby callable with positional args and keyword
    # pairs.
    def call(callee, args, kwargs = [])
      case callee
      when Function then call_function(callee, args, kwargs)
      when Builtin then call_builtin(callee, args, kwargs)
      else
        return callee.starlark_call(self, args, kwargs) if callee.respond_to?(:starlark_call)

        raise EvalError, "invalid call of non-function (#{Value.type(callee)})"
      end
    end

    def call_function(function, args, kwargs)
      if @stack.any? { |frame| frame.info.equal?(function.info) }
        raise EvalError, "function #{function.name} called recursively"
      end
      raise EvalError, "Starlark stack overflow" if @stack.length >= MAX_STACK_DEPTH

      locals = Array.new(function.info.locals.size, Value::UNBOUND)
      bind_args(function, locals, args, kwargs)
      function.info.locals.each_with_index do |binding, i|
        locals[i] = Cell.new(locals[i]) if binding.scope == :cell
      end
      frame = Frame.new(function.name, function.info, locals, function.free_cells, function.module_env,
                        function.node.line, function.node.column)
      with_frame(frame) do
        if function.node.is_a?(LambdaExpr)
          eval_expr(function.node.body, frame)
        else
          result = exec_stmts(function.node.body, frame)
          result.is_a?(Return) ? result.value : nil
        end
      end
    end

    def call_builtin(builtin, args, kwargs)
      builtin.call(self, args, kwargs)
    end

    def step!
      @steps += 1
      return unless @limits.max_steps && @steps > @limits.max_steps

      raise EvalError, "Starlark computation cancelled: too many steps"
    end

    def backtrace_frames
      @stack.map { |frame| [frame.name, frame.line, frame.column] }
    end

    private

    def with_frame(frame)
      @stack.push(frame)
      yield
    rescue EvalError => e
      e.backtrace_frames = backtrace_frames if e.backtrace_frames.empty?
      raise
    ensure
      @stack.pop
    end

    def new_locals(bindings)
      bindings.map { |binding| binding.scope == :cell ? Cell.new(Value::UNBOUND) : Value::UNBOUND }
    end

    # Arguments

    # Binds arguments to parameter slots. A port of starlark-go's setArgs.
    def bind_args(function, locals, args, kwargs)
      info = function.info
      params = info.params.reject { |param| %i[star args kwargs].include?(param.kind) }
      nparams = params.size
      if info.params.empty?
        n = args.length + kwargs.length
        raise EvalError, "function #{function.name} accepts no arguments (#{n} given)" if n.positive?

        return
      end

      slot = nparams
      kwdict = nil
      if info.has_varargs
        varargs_slot = slot
        slot += 1
      end
      if info.has_kwargs
        kwdict = Dict.new
        locals[slot] = kwdict
      end

      positional = nparams - info.num_kwonly_params
      n = args.length
      if n > positional
        unless info.has_varargs
          first_default = function.defaults.index { |value| !value.equal?(Value::UNBOUND) } || nparams
          at_most = nparams - first_default > info.num_kwonly_params ? "at most " : ""
          raise EvalError, "function #{function.name} accepts #{at_most}#{positional} positional " \
                           "argument#{positional == 1 ? "" : "s"} (#{n} given)"
        end
        n = positional
      end
      n.times { |i| locals[i] = args[i] }
      locals[varargs_slot] = Tuple.new(args[n..] || []) if info.has_varargs

      kwargs.each do |name, value|
        i = params.index { |param| param.name == name }
        if i
          # starlark-go formats the name as a Starlark string, so it is quoted.
          raise EvalError, "function #{function.name} got multiple values for parameter #{Value.repr(name)}" unless locals[i].equal?(Value::UNBOUND)

          locals[i] = value
          next
        end
        raise EvalError, "function #{function.name} got an unexpected keyword argument #{Value.repr(name)}" unless kwdict

        size = kwdict.length
        kwdict.set(name, value)
        raise EvalError, "function #{function.name} got multiple values for parameter #{Value.repr(name)}" if kwdict.length == size
      end

      return unless n < nparams || info.num_kwonly_params.positive?

      missing = []
      (n...nparams).each do |i|
        next unless locals[i].equal?(Value::UNBOUND)

        default = function.defaults[i]
        if default.equal?(Value::UNBOUND)
          missing << params[i].name
        else
          locals[i] = default
        end
      end
      return if missing.empty?

      raise EvalError, "function #{function.name} missing #{missing.size} argument#{missing.size > 1 ? "s" : ""} " \
                       "(#{missing.join(", ")})"
    end

    # Statements

    def exec_stmts(statements, frame)
      statements.each do |statement|
        result = exec_stmt(statement, frame)
        return result if result
      end
      nil
    end

    def exec_stmt(stmt, frame)
      step!
      frame.line = stmt.line
      frame.column = stmt.column
      case stmt
      when ExprStmt
        eval_expr(stmt.expr, frame)
        nil
      when AssignStmt then exec_assign(stmt, frame)
      when IfStmt then exec_if(stmt, frame)
      when ForStmt then exec_for(stmt, frame)
      when ReturnStmt then Return.new(stmt.value ? eval_expr(stmt.value, frame) : nil)
      when BranchStmt then stmt.kind == :pass ? nil : stmt.kind
      when DefStmt
        write(stmt, make_function(stmt, stmt.name, stmt.params, frame), frame)
        nil
      when LoadStmt then exec_load(stmt, frame)
      end
    end

    def exec_assign(stmt, frame)
      if stmt.op == :eq
        assign(stmt.target, eval_expr(stmt.value, frame), frame)
        return nil
      end

      op = stmt.op.to_s.delete_suffix("_eq").to_sym
      target = stmt.target
      case target
      when Ident
        write(target, augmented(op, read(target, frame), eval_expr(stmt.value, frame)), frame)
      when IndexExpr
        object = eval_expr(target.object, frame)
        key = eval_expr(target.index, frame)
        current = Operators.index(object, key)
        Operators.set_index(object, key, augmented(op, current, eval_expr(stmt.value, frame)))
      when DotExpr
        object = eval_expr(target.object, frame)
        current = Attributes.get(object, target.name)
        Attributes.set(object, target.name, augmented(op, current, eval_expr(stmt.value, frame)))
      end
      nil
    end

    # x += y extends a list in place, and x |= y updates a dict in place.
    def augmented(op, x, y)
      if op == :plus && x.is_a?(List) && iterable?(y)
        x.check_mutable!("apply += to")
        values = to_array(y)
        @limits.check_size!(x.length + values.length)
        x.elems.concat(values)
        return x
      end
      if op == :pipe && x.is_a?(Dict) && y.is_a?(Dict)
        x.check_mutable("apply |= to", "hash table")
        y.items.each { |k, v| x.set(k, v) }
        return x
      end
      Operators.binary(op, x, y, @limits)
    end

    def exec_if(stmt, frame)
      loop do
        return exec_stmts(stmt.then_body, frame) if Value.truth(eval_expr(stmt.condition, frame))

        else_body = stmt.else_body
        return exec_stmts(else_body, frame) unless else_body.size == 1 && else_body.first.is_a?(IfStmt)

        stmt = else_body.first
        step!
      end
    end

    def exec_for(stmt, frame)
      iterate(eval_expr(stmt.iterable, frame)) do |value|
        assign(stmt.vars, value, frame)
        result = exec_stmts(stmt.body, frame)
        next if result == :continue
        break if result == :break
        return result if result
      end
      nil
    end

    def exec_load(stmt, frame)
      raise EvalError, "load not implemented by this application" unless @load

      name = stmt.module.value
      exports = begin
        @load.call(name)
      rescue EvalError, Error => e
        raise EvalError, "cannot load #{name}: #{e.message}"
      end
      stmt.bindings.each do |binding|
        unless exports.key?(binding.name)
          message = "load: name #{binding.name} not found in module #{name}"
          hint = Spell.nearest(binding.name, exports.keys)
          message += " (did you mean #{hint}?)" if hint
          raise EvalError, message
        end
        write(binding, exports.fetch(binding.name), frame)
      end
      nil
    end

    # Assignment

    def assign(target, value, frame)
      case target
      when Ident then write(target, value, frame)
      when IndexExpr then Operators.set_index(eval_expr(target.object, frame), eval_expr(target.index, frame), value)
      when DotExpr then Attributes.set(eval_expr(target.object, frame), target.name, value)
      when TupleExpr, ListExpr
        values = unpack(value, target.elements.size)
        target.elements.zip(values) { |element, element_value| assign(element, element_value, frame) }
      end
    end

    def unpack(value, count)
      raise EvalError, "got #{Value.type(value)} in sequence assignment" unless iterable?(value)

      values = to_array(value)
      if values.size > count
        raise EvalError, "too many values to unpack (got #{values.size}, want #{count})"
      elsif values.size < count
        raise EvalError, "too few values to unpack (got #{values.size}, want #{count})"
      end
      values
    end

    # Variables

    def binding_of(node, frame)
      frame.env.resolution.bindings.fetch(node)
    end

    def read(node, frame)
      binding = binding_of(node, frame)
      value =
        case binding.scope
        when :local then frame.locals[binding.index]
        when :cell then frame.locals[binding.index].value
        when :free then frame.free[binding.index].value
        when :global then frame.env.globals[binding.index]
        when :predeclared then frame.env.predeclared.fetch(node.name)
        when :universal then Builtins::UNIVERSE.fetch(node.name)
        end
      return value unless value.equal?(Value::UNBOUND)

      kind = binding.scope == :global ? "global" : "local"
      raise EvalError, "#{kind} variable #{node.name} referenced before assignment"
    end

    def write(node, value, frame)
      binding = binding_of(node, frame)
      # A name is never written through a free binding: assigning a name in a
      # nested function makes it local there.
      case binding.scope
      when :local then frame.locals[binding.index] = value
      when :cell then frame.locals[binding.index].value = value
      when :global then frame.env.globals[binding.index] = value
      end
    end

    # Functions

    def make_function(node, name, params, frame)
      info = frame.env.resolution.functions.fetch(node)
      defaults = params.reject { |param| %i[star args kwargs].include?(param.kind) }.map do |param|
        param.default ? eval_expr(param.default, frame) : Value::UNBOUND
      end
      free_cells = info.free_vars.map do |binding|
        binding.scope == :free ? frame.free[binding.index] : frame.locals[binding.index]
      end
      Function.new(name: name, node: node, info: info, defaults: defaults, free_cells: free_cells,
                   module_env: frame.env)
    end

    # Expressions

    def eval_expr(node, frame)
      step!
      case node
      when Ident then read(node, frame)
      when Literal then literal(node)
      when ListExpr then List.new(node.elements.map { |element| eval_expr(element, frame) })
      when TupleExpr then Tuple.new(node.elements.map { |element| eval_expr(element, frame) })
      when DictExpr then dict_literal(node, frame)
      when Comprehension then comprehension(node, frame)
      when IfExpr
        branch = Value.truth(eval_expr(node.condition, frame)) ? node.then : node.else
        eval_expr(branch, frame)
      when UnaryExpr then Operators.unary(node.op, eval_expr(node.operand, frame))
      when BinaryExpr, DotExpr, CallExpr, IndexExpr, SliceExpr then chain(node, frame)
      when LambdaExpr then make_function(node, "lambda", node.params, frame)
      end
    end

    def literal(node)
      node.kind == :bytes ? Bytes.new(node.value) : node.value
    end

    def dict_literal(node, frame)
      dict = Dict.new
      node.entries.each do |entry|
        key = eval_expr(entry.key, frame)
        value = eval_expr(entry.value, frame)
        size = dict.length
        dict.set(key, value)
        raise EvalError, "duplicate key: #{Value.repr(key)}" if dict.length == size
      end
      dict
    end

    # Binary operators and suffixes nest on the left, so long chains are
    # evaluated in a loop rather than by recursion.
    def chain(node, frame)
      spine = []
      while (left = spine_child(node))
        spine << node
        node = left
      end
      value = eval_expr(node, frame)
      spine.reverse_each do |link|
        step!
        value = apply_link(link, value, frame)
      end
      value
    end

    def spine_child(node)
      case node
      when BinaryExpr then node.left
      when DotExpr, IndexExpr, SliceExpr then node.object
      when CallExpr then node.callee
      end
    end

    def apply_link(link, value, frame)
      case link
      when BinaryExpr
        case link.op
        when :and then Value.truth(value) ? eval_expr(link.right, frame) : value
        when :or then Value.truth(value) ? value : eval_expr(link.right, frame)
        else Operators.binary(link.op, value, eval_expr(link.right, frame), @limits)
        end
      when DotExpr then Attributes.get(value, link.name)
      when IndexExpr then Operators.index(value, eval_expr(link.index, frame))
      when SliceExpr
        parts = [link.start, link.stop, link.step].map { |part| part && eval_expr(part, frame) }
        Operators.slice(value, *parts)
      when CallExpr then call_expr(value, link, frame)
      end
    end

    # Arguments are evaluated in source order. As in starlark-go, **kwargs is
    # then checked before *args.
    def call_expr(callee, node, frame)
      args = []
      kwargs = []
      star = nil
      star_star = nil
      node.args.each do |arg|
        value = eval_expr(arg.value, frame)
        case arg.kind
        when :positional then args << value
        when :keyword then kwargs << [arg.name, value]
        when :args then star = [value]
        when :kwargs then star_star = [value]
        end
      end

      if star_star
        mapping = star_star.first
        raise EvalError, "argument after ** must be a mapping, not #{Value.type(mapping)}" unless mapping.is_a?(Dict)

        mapping.items.each do |key, _|
          raise EvalError, "keywords must be strings, not #{Value.type(key)}" unless key.is_a?(String)
        end
        kwargs.concat(mapping.items)
      end
      if star
        iterable = star.first
        raise EvalError, "argument after * must be iterable, not #{Value.type(iterable)}" unless iterable?(iterable)

        args.concat(to_array(iterable))
      end

      frame.line = node.line
      frame.column = node.column
      call(callee, args, kwargs)
    end

    def comprehension(node, frame)
      result = node.kind == :list ? List.new : Dict.new
      run_clauses(node, 0, result, frame)
      result
    end

    def run_clauses(node, index, result, frame)
      clause = node.clauses[index]
      unless clause
        if node.kind == :list
          @limits.check_size!(result.elems.length + 1)
          result.elems << eval_expr(node.body, frame)
        else
          result.set(eval_expr(node.body.key, frame), eval_expr(node.body.value, frame))
        end
        return
      end

      case clause
      when ForClause
        iterate(eval_expr(clause.iterable, frame)) do |value|
          assign(clause.vars, value, frame)
          run_clauses(node, index + 1, result, frame)
        end
      when IfClause
        run_clauses(node, index + 1, result, frame) if Value.truth(eval_expr(clause.condition, frame))
      end
    end

    # Iteration

    def iterable?(value)
      case value
      when List, Tuple, Dict, Set, Range then true
      else value.respond_to?(:starlark_iterate)
      end
    end

    # Yields each element. A list, dict, or set cannot change meanwhile.
    def iterate(value, &)
      case value
      when List then value.iterating { value.elems.each(&) }
      when Tuple then value.elems.each(&)
      when Dict then value.each_key(&)
      when Set then value.iterating { value.elems.each(&) }
      when Range then value.each(&)
      else
        return value.starlark_iterate(&) if value.respond_to?(:starlark_iterate)

        raise EvalError, "#{Value.type(value)} value is not iterable"
      end
    end

    def to_array(value)
      # A range is the one value whose length is not already in memory.
      @limits.check_size!(value.length) if value.is_a?(Range)
      result = []
      iterate(value) { |element| result << element }
      result
    end

    public :iterate, :iterable?, :to_array
  end
end
