# frozen_string_literal: true

require "spec_helper"

# Runtime behavior is checked against starlark-go in spec/oracle and
# spec/conformance. These examples cover the host-facing API.
RSpec.describe Starlark::Embedding do
  describe ".exec" do
    it "returns the module's globals" do
      globals = Starlark.exec("x = 1 + 2\ny = [x]\n")

      expect(globals.keys).to eq(%w[x y])
      expect(globals["x"]).to eq(3)
    end

    it "freezes the globals after the module runs" do
      globals = Starlark.exec("x = [1]\n")

      expect(globals["x"]).to be_frozen_value
    end

    it "passes host values in as predeclared names" do
      globals = Starlark.exec("y = greeting + ', ' + name\n", globals: { greeting: "hello", "name" => "world" })

      expect(globals["y"]).to eq("hello, world")
    end

    it "sends print output to the host" do
      lines = []
      Starlark.exec("print('a', 1)\nprint('b', sep='-')\n", print: ->(line) { lines << line })

      expect(lines).to eq(["a 1", "b"])
    end

    it "loads modules through the host's callback" do
      library = Starlark.exec("def double(x):\n    return 2 * x\nlimit = 10\n")
      globals = Starlark.exec("load('lib.star', 'double', max = 'limit')\nx = double(max)\n",
                              load: ->(name) { name == "lib.star" ? library : raise(Starlark::Error, "no such module") })

      expect(globals["x"]).to eq(20)
    end

    it "reports a name the loaded module does not export" do
      expect { Starlark.exec("load('lib.star', 'doubel')\n", load: ->(_) { { "double" => 1 } }) }
        .to raise_error(Starlark::EvalError, "load: name doubel not found in module lib.star (did you mean double?)")
    end

    it "reports a module the host cannot load" do
      expect { Starlark.exec("load('missing.star', 'x')\n", load: ->(_) { raise Starlark::Error, "no such module" }) }
        .to raise_error(Starlark::EvalError, "cannot load missing.star: no such module")
    end

    it "raises syntax, static, and dynamic errors as Starlark errors" do
      expect { Starlark.exec("x = (\n") }.to raise_error(Starlark::SyntaxError)
      expect { Starlark.exec("x = y\n") }.to raise_error(Starlark::ResolveError)
      expect { Starlark.exec("x = 1 // 0\n") }.to raise_error(Starlark::EvalError, "floored division by zero")
    end

    it "records the Starlark call stack on a dynamic error" do
      source = "def inner():\n    return 1 // 0\ndef outer():\n    return inner()\nx = outer()\n"

      expect { Starlark.exec(source) }.to raise_error(Starlark::EvalError) { |error|
        expect(error.backtrace_frames.map(&:first)).to eq(%w[<toplevel> outer inner])
      }
    end
  end

  describe "limits" do
    it "stops a program that exceeds the step budget" do
      source = "def f():\n    for i in range(1000000):\n        pass\nf()\n"

      expect { Starlark.exec(source, max_steps: 1000) }
        .to raise_error(Starlark::EvalError, "Starlark computation cancelled: too many steps")
    end

    it "stops a shift before it allocates a huge integer" do
      expect { Starlark.exec("x = 1 << 2000000000\n") }
        .to raise_error(Starlark::EvalError, "shift count too large: 2000000000")
      expect { Starlark.exec("x = (1 << 400) << 400\n", max_int_bits: 500) }
        .to raise_error(Starlark::EvalError, "integer too large: 801 bits, limit is 500")
    end

    it "stops repeated squaring before the integer grows too large" do
      source = "def f():\n    x = 3\n    for i in range(25):\n        x = x * x\n    return x\ny = f()\n"

      expect { Starlark.exec(source) }.to raise_error(Starlark::EvalError, /integer too large/)
    end

    it "stops repetition, concatenation, and joins that build huge values" do
      expect { Starlark.exec("x = 'ab' * 100000000\n") }.to raise_error(Starlark::EvalError, /value too large/)
      expect { Starlark.exec("x = list(range(100000000))\n") }.to raise_error(Starlark::EvalError, /value too large/)
      source = "def f():\n    s = 'x'\n    for i in range(40):\n        s = s + s\nf()\n"
      expect { Starlark.exec(source) }.to raise_error(Starlark::EvalError, /value too large/)
      expect { Starlark.exec("x = ''.join(['a' * 1000] * 20000)\n", max_value_size: 1_000_000) }
        .to raise_error(Starlark::EvalError, /value too large/)
    end

    it "lets the host raise or remove the size limits" do
      globals = Starlark.exec("x = len('ab' * 6000000)\n", max_value_size: nil)

      expect(globals["x"]).to eq(12_000_000)
    end

    it "keeps starlark-go's repetition cap when the size limit is off" do
      expect { Starlark.exec("x = 'a' * (1 << 30)\n", max_value_size: nil) }
        .to raise_error(Starlark::EvalError, "excessive repeat (1 * 1073741824 elements)")
    end
  end

  describe ".from_ruby and .to_ruby" do
    it "converts nested Ruby values both ways" do
      value = { "a" => [1, 2.5, nil, true], b: Set[1], "c" => "text" }
      starlark = Starlark.from_ruby(value)

      expect(Starlark::Value.repr(starlark)).to eq('{"a": [1, 2.5, None, True], "b": set([1]), "c": "text"}')
      expect(Starlark.to_ruby(starlark)).to eq("a" => [1, 2.5, nil, true], "b" => Set[1], "c" => "text")
    end

    it "turns binary Ruby strings into bytes" do
      expect(Starlark.from_ruby("\xFF".b)).to be_a(Starlark::Bytes)
    end

    it "converts bytes and ranges to Ruby" do
      globals = Starlark.exec("b = b'ab'\nr = range(3)\n")

      expect(Starlark.to_ruby(globals["b"])).to eq("ab".b)
      expect(Starlark.to_ruby(globals["r"])).to eq([0, 1, 2])
    end

    it "wraps Ruby procs as functions" do
      globals = Starlark.exec("x = triple(4)\n", globals: { "triple" => ->(n) { n * 3 } })

      expect(globals["x"]).to eq(12)
    end

    it "rejects Ruby values it cannot convert" do
      expect { Starlark.from_ruby(Object.new) }.to raise_error(ArgumentError, /cannot convert Object/)
    end

    it "refuses to hand invalid UTF-8 text to the host" do
      broken = Starlark.exec("x = 'é'[:1]\n")["x"]

      expect { Starlark.to_ruby(broken) }.to raise_error(Starlark::Error, /not valid UTF-8/)
    end
  end

  describe ".function" do
    it "exposes a Ruby block that takes and returns Ruby values" do
      add = Starlark.function("add") { |a, b, scale: 1| (a + b) * scale }
      globals = Starlark.exec("x = add(1, 2, scale = 10)\n", globals: { "add" => add })

      expect(globals["x"]).to eq(30)
    end

    it "lets Starlark see the function's name" do
      globals = Starlark.exec("x = str(f)\n", globals: { "f" => Starlark.function("lookup") { nil } })

      expect(globals["x"]).to eq("<built-in function lookup>")
    end
  end

  describe "host values" do
    # A host value with fields, as an application might expose a record.
    let(:contact_class) do
      Class.new do
        def initialize = @fields = { "name" => "Ada", "email" => "ada@example.com" }
        def starlark_type = "contact"
        def starlark_repr = "<contact #{@fields["name"]}>"
        def starlark_attr_names = @fields.keys
        def starlark_attr(name) = @fields.fetch(name, Starlark::Value::UNBOUND)
        def starlark_set_attr(name, value) = @fields[name] = value
      end
    end

    it "reads, writes, and lists fields" do
      contact = contact_class.new
      source = "def f(c):\n    c.name = 'Grace'\n    return [type(c), str(c), c.email, dir(c), hasattr(c, 'name')]\nx = f(contact)\n"
      globals = Starlark.exec(source, globals: { "contact" => contact })

      expect(Starlark::Value.repr(globals["x"])).to eq('["contact", "<contact Grace>", "ada@example.com", ["email", "name"], True]')
    end

    it "reports a missing field with a hint" do
      expect { Starlark.exec("x = contact.emial\n", globals: { "contact" => contact_class.new }) }
        .to raise_error(Starlark::EvalError, "contact has no .emial field or method (did you mean .email?)")
    end
  end

  RSpec::Matchers.define :be_frozen_value do
    match { |value| value.frozen_value? }
  end
end
