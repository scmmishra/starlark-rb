# starlark-rb

A [Starlark](https://github.com/bazelbuild/starlark) interpreter written in pure Ruby. It has no C extensions, no FFI, and no runtime gem dependencies.

Starlark is a small, Python-like language for configuration and scripting. A Starlark script cannot read files, open sockets, or loop forever by itself. The host program decides what a script can do, which makes the language a good fit for running code that users write. This gem is built to run untrusted plugin scripts inside [Chatwoot](https://github.com/chatwoot/chatwoot).

## Status

The interpreter runs Starlark programs. Every stage is complete and tested against starlark-go. The gem is not published yet.

| Stage | Status |
|---|---|
| Lexer | Done |
| Parser | Done |
| Resolver (names and static errors) | Done |
| Evaluator | Done |
| Builtins and the embedding API | Done |

## Example

`Starlark.exec` runs a file and returns its globals as a Hash. Host values go in through `globals:`.

```ruby
require "starlark"

source = <<~STAR
  def invoice_total(items):
      total = 0
      for item in items:
          total += item["amount"]
      return total

  total = invoice_total(invoices)
  print("total:", total)
STAR

globals = Starlark.exec(
  source,
  filename: "plugin.star",
  globals: { "invoices" => [{ "amount" => 1200 }, { "amount" => 350 }] },
  print: ->(line) { puts line },
  max_steps: 100_000,
)
# prints "total: 1550"
globals["total"] # => 1550
```

`Starlark.exec` converts Ruby values in `globals:` to Starlark values. A Ruby proc becomes a function. `Starlark.function` gives the function a name and converts its arguments and result.

```ruby
fetch = Starlark.function("fetch_order") { |id| { "id" => id, "status" => "paid" } }
globals = Starlark.exec("order = fetch_order(42)\n", globals: { "fetch_order" => fetch })
Starlark.to_ruby(globals["order"]) # => {"id" => 42, "status" => "paid"}
```

A script with an error raises `Starlark::SyntaxError`, `Starlark::ResolveError`, or `Starlark::EvalError`. All three inherit from `Starlark::Error`.

```ruby
Starlark.exec("x = {}['missing']\n")
# Starlark::EvalError: key "missing" not in dict
```

### Limits

| Option | Default | Stops |
|---|---|---|
| `max_steps:` | none | a run after this many evaluation steps |
| `max_value_size:` | 10,000,000 | an operation that builds a string, bytes, list, tuple, dict, or set larger than this |
| `max_int_bits:` | 1,000,000 | an operation that builds an integer with more bits than this |

Pass `nil` to turn off a limit. Untrusted code should always run with `max_steps:` set. The size limits are checked before the operation allocates.

### Loading modules

`load:` takes a callback that receives a module name and returns that module's globals. The host decides where modules come from. A callback can raise `Starlark::Error` to report a missing module.

```ruby
library = Starlark.exec("def double(x):\n    return 2 * x\n")
Starlark.exec("load('lib.star', 'double')\nx = double(4)\n", load: ->(name) { library })
```

## Goals

- **Follow the spec.** The target is the [Bazel Starlark spec](docs/spec.md), with no extra dialect features. There is no `while`, no recursion, and no `if` or `for` at the top level of a file.
- **Run untrusted code safely.** The host sets limits on steps, value sizes, and integer sizes. A script cannot reach the file system, the network, or Ruby objects the host did not expose. The rules are listed in [CLAUDE.md](CLAUDE.md).
- **Stay pure Ruby.** It installs anywhere Ruby runs, with nothing to compile.

## How it is tested

Starlark has three main implementations: in Go, Java, and Rust. This gem is tested by comparing its output with two of them, the Go and Java implementations, which we call "oracles". The oracles are built from pinned sources, and are only needed for development.

- **Oracle comparison.** For every test input, the lexer's tokens, the parser's syntax tree, and the resolver's bindings must match starlark-go exactly, including positions and error messages. Running the input must produce the same print output, globals, and error message as starlark-go. The inputs are the upstream conformance suite plus about 430 corpus files of edge cases and errors.
- **The spec decides.** Where starlark-go and the spec disagree, we follow the spec, and record the case as an override with its reason. Java Starlark helps find those cases. See the READMEs in `spec/lexer/corpus`, `spec/parser/corpus`, `spec/resolver/corpus`, and `spec/evaluator/corpus`.
- **Conformance suite.** The upstream test files run as RSpec examples. A failed `assert_eq` fails the example.
- **Golden files.** The oracles' output is stored in `spec/oracle/golden`, so the full suite runs in a few seconds without Go or Java. CI checks that the files are current.
- **Differential fuzzing.** `tools/fuzz` generates random programs from the grammar, mutates corpus files, runs random expressions, and compares every result with starlark-go. It also checks every Unicode letter and random float literals.
- **Mutation testing.** [mutant](https://github.com/mbj/mutant) changes the code in small ways and reports changes that no test catches.
- **Coverage.** Line coverage is 100%.

Two independent spec audits found two real bugs and two starlark-go bugs. All four now have test cases.

## Design decisions

- **Which behavior to follow.** The spec text comes first. If the spec is silent and a script could see the difference, we follow Java Starlark. If no script can see it, we follow starlark-go.
- **Strings are UTF-8 bytes.** The spec allows 8-bit or 16-bit string elements. This gem uses UTF-8 bytes, as starlark-go and starlark-rust do. So `len("é")` is 2.
- **Ported, not reinvented.** The lexer, parser, resolver, and builtins port starlark-go's algorithms, so positions, slot numbers, and messages match exactly. They differ from starlark-go where the spec requires it.
- **A tree-walking evaluator.** The evaluator walks the resolved syntax tree. There is no bytecode compiler.

## Development

You need [mise](https://mise.jdx.dev), which installs Ruby, Go, and Java at the pinned versions.

```bash
curl https://mise.run | sh
mise install
bundle install
bundle exec rspec           # the full suite, against the golden files
```

Other tasks:

```bash
mise run coverage           # the full suite with line and branch coverage
mise run oracle:setup       # build the Go and Java oracles, once
mise run oracle:golden      # rewrite the golden files after a corpus change
mise run oracle:live        # compare with the oracles directly
mise run fuzz               # random inputs against starlark-go
mise run mutant             # mutation testing
```

See [tools/oracle/README.md](tools/oracle/README.md) for the oracle formats, and [tools/fuzz/README.md](tools/fuzz/README.md) for the fuzzer.

## Project layout

| Path | Contents |
|---|---|
| `lib/starlark/` | The interpreter. The front end is `lexer.rb`, `parser.rb`, `ast.rb`, and `resolver.rb`. The evaluator is `evaluator.rb` and its value, operator, and builtin files. The host API is `embedding.rb`. |
| `docs/spec.md` | The Starlark spec, pinned to one upstream commit |
| `spec/` | RSpec tests, corpora, conformance data, and golden files |
| `tools/oracle/` | The Go and Java oracles and their setup |
| `tools/fuzz/` | The differential fuzzer |
| `CLAUDE.md` | Project rules and decisions |

## License

MIT, except `docs/spec.md` and `spec/conformance/testdata/`. Those come from [bazelbuild/starlark](https://github.com/bazelbuild/starlark) under the Apache License 2.0, included next to them as `LICENSE`.
