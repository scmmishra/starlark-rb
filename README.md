# starlark-rb

A [Starlark](https://github.com/bazelbuild/starlark) interpreter written in pure Ruby. It has no C extensions, no FFI, and no runtime gem dependencies.

Starlark is a small, Python-like language for configuration and scripting. A Starlark script cannot read files, open sockets, or loop forever by itself. The host program decides what a script can do, which makes the language a good fit for running code that users write. This gem is built to run untrusted plugin scripts inside [Chatwoot](https://github.com/chatwoot/chatwoot).

## Status

The interpreter is not usable yet. The front end is complete and tested. The evaluator is next.

| Stage | Status |
|---|---|
| Lexer | Done |
| Parser | Done |
| Resolver (names and static errors) | Done |
| Evaluator | Not started |
| Builtins and the embedding API | Not started |

The gem is not published yet.

## Example

The front end turns source into a syntax tree and binds every name in it.

```ruby
require "starlark"

source = <<~STAR
  def invoice_total(items):
      return sum_amounts([item["amount"] for item in items])
STAR

file = Starlark::Parser.parse(source)
resolution = Starlark::Resolver.resolve(file, predeclared: ["sum_amounts"], filename: "plugin.star")

fn = resolution.functions.fetch(file.statements.first)
fn.locals.map(&:name)                      # => ["items", "item"]
resolution.module.globals.map(&:name)      # => ["invoice_total"]
```

`predeclared` lists the names the host provides. The spec's builtins, such as `len` and `None`, are always available.

Errors carry a line and column. The resolver reports every static error in a file at once.

```ruby
source = <<~STAR
  def total(amounts):
      for amount in amounts:
          count += amount
      return cuont

  if True:
      total([])
STAR

begin
  Starlark::Resolver.resolve(Starlark::Parser.parse(source), filename: "plugin.star")
rescue Starlark::ResolveError => e
  e.errors.each { |error| puts "#{error.line}:#{error.column}: #{error.message}" }
end
# 6:1: if statement not within a function
# 4:12: undefined: cuont (did you mean count?)
```

## Goals

- **Follow the spec.** The target is the [Bazel Starlark spec](docs/spec.md), with no extra dialect features. There is no `while`, no recursion, and no `if` or `for` at the top level of a file.
- **Run untrusted code safely.** The host will set limits on steps and memory, and no script will be able to reach the file system, the network, or Ruby objects the host did not expose. These limits come with the evaluator. The rules are listed in [CLAUDE.md](CLAUDE.md).
- **Stay pure Ruby.** It installs anywhere Ruby runs, with nothing to compile.

## How it is tested

Starlark has three main implementations: in Go, Java, and Rust. This gem is tested by comparing its output with two of them, the Go and Java implementations, which we call "oracles". The oracles are built from pinned sources, and are only needed for development.

- **Oracle comparison.** For every test input, the lexer's tokens, the parser's syntax tree, and the resolver's bindings must match starlark-go exactly, including positions and error messages. The inputs are the upstream conformance suite plus about 260 corpus files of edge cases and errors.
- **The spec decides.** Where starlark-go and the spec disagree, we follow the spec, and record the case as an override with its reason. Java Starlark helps find those cases. See the READMEs in `spec/lexer/corpus`, `spec/parser/corpus`, and `spec/resolver/corpus`.
- **Golden files.** The oracles' output is stored in `spec/oracle/golden`, so the full suite runs in a few seconds without Go or Java. CI checks that the files are current.
- **Differential fuzzing.** `tools/fuzz` generates random programs from the grammar, mutates corpus files, and compares every result with starlark-go. It also checks every Unicode letter and random float literals.
- **Mutation testing.** [mutant](https://github.com/mbj/mutant) changes the code in small ways and reports changes that no test catches.
- **Coverage.** Line coverage is 100%.

Two independent spec audits found two real bugs and two starlark-go bugs. All four now have test cases.

## Design decisions

- **Which behavior to follow.** The spec text comes first. If the spec is silent and a script could see the difference, we follow Java Starlark. If no script can see it, we follow starlark-go.
- **Strings are UTF-8 bytes.** The spec allows 8-bit or 16-bit string elements. This gem uses UTF-8 bytes, as starlark-go and starlark-rust do. So `len("é")` is 2.
- **Ported, not reinvented.** The lexer, parser, and resolver port starlark-go's algorithms, so positions, slot numbers, and messages match exactly. They differ from starlark-go where the spec requires it.

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
| `lib/starlark/` | The interpreter: `lexer.rb`, `parser.rb`, `ast.rb`, `resolver.rb` |
| `docs/spec.md` | The Starlark spec, pinned to one upstream commit |
| `spec/` | RSpec tests, corpora, conformance data, and golden files |
| `tools/oracle/` | The Go and Java oracles and their setup |
| `tools/fuzz/` | The differential fuzzer |
| `CLAUDE.md` | Project rules and decisions |

## License

MIT, except `docs/spec.md` and `spec/conformance/testdata/`. Those come from [bazelbuild/starlark](https://github.com/bazelbuild/starlark) under the Apache License 2.0, included next to them as `LICENSE`.
