# starlark-rb

A Starlark interpreter written in pure Ruby, shipped as a gem. It has no FFI, no C extensions, and no runtime gem dependencies.

Chatwoot will use it to run untrusted scripts written by customers. Examples: fetch a customer's invoices from Stripe by email, or cancel an order in Shopify. Chatwoot exposes its own host functions to these scripts. This gem implements only the language.

## Source of truth

- The language spec is `docs/spec.md`. It is a copy of `bazelbuild/starlark/spec.md`.
- Follow the spec strictly. Do not add behavior from other dialects. starlark-go extensions such as `while`, recursion flags, `ord`, `chr`, and `codepoints()` are out of scope.
- If the spec is unclear, read the Java implementation's behavior. Its conformance tests are the only ones the upstream project still runs in CI. Record the decision in a code comment that names the spec section.
- Host helpers (for example a `text` module for character-level work) belong to the embedding application. They are not part of this gem.

## Decisions already made

- **Ruby version.** Ruby 3.4.4, matching Chatwoot. It is pinned in `.mise.toml` and `Gemfile`.
- **String model.** Strings use 8-bit elements (K=8). Text is UTF-8, as in starlark-go and starlark-rust. So `len("é")` is 2, and `s[i]` returns one byte.
  - Index, slice, and measure with byte methods: `bytesize`, `byteslice`, `byteindex`, `byterindex`. Never use `size`, `[]`, or `index` on Starlark strings.
  - Strings may hold invalid UTF-8, because slicing can cut a character in half. Every Starlark string stays tagged as `Encoding::UTF_8`, even when its bytes are invalid. Mixed encodings break `==` and `hash` in Ruby.
  - Many Ruby string methods raise on invalid UTF-8 (`downcase`, `upcase`, regex matching, `split` with a regex). Each string builtin needs a test with invalid input.
  - The `bytes` type is a separate wrapper around a frozen `Encoding::BINARY` string.
- **Values.** Starlark `int`, `float`, `string`, `bool`, and `None` use Ruby `Integer`, `Float`, frozen `String`, `true`/`false`, and `nil`. `list`, `tuple`, `dict`, `set`, `bytes`, functions, and builtins use our own classes.

## Ruby semantics that differ from Starlark

Do not rely on Ruby behavior for these:

- **Truthiness.** `0`, `0.0`, `""`, `b""`, and empty containers are false in Starlark. Every condition goes through one `truth(value)` helper. Never write `if value` on a Starlark value.
- **Equality and dict keys.** `1 == 1.0` is true in Starlark, so `1` and `1.0` are the same dict or set key. Ruby `Hash` uses `eql?` and treats them as different keys. Dicts and sets must normalize keys.
- **Hashability.** Lists, dicts, and sets cannot be keys. A tuple can be a key only if all its elements can. Check this before insertion and raise a Starlark error.
- **Freezing.** A module's values are frozen after it loads. Mutating a list, dict, or set while iterating over it is an error, even if the value is not frozen. Track this with an iteration counter on each container.
- **`hash()`.** Ruby's `String#hash` is randomized per process. Never use it for the Starlark `hash` builtin. The spec requires Java's `String.hashCode` over the UTF-16 transcoding for strings, and 32-bit FNV-1a for bytes.
- **`repr` and `str`.** Never use Ruby's `inspect` or `to_s` for output. Ruby 3.4 changed `Hash#inspect`, and Ruby float formatting differs from Starlark. Write our own formatting. `repr` must detect cycles (`x = []; x.append(x)`).

## Security rules

Scripts are untrusted. These rules apply to every change:

- **No dynamic dispatch into Ruby.** Never map a Starlark attribute or method call to `send`, `public_send`, `method`, `instance_variable_get`, or `const_get`. Each type declares an explicit table of allowed attributes and methods. `dir`, `getattr`, and `hasattr` read only that table.
- **Size checks before allocation.** The step limit cannot stop a single Ruby C call. `1 << 2000000000` allocates 250 MB in one step. Squaring an integer 25 times uses about 9 seconds of CPU. Every operation that can grow a value checks the estimated result size against a limit first, then raises a Starlark error if the size is too large. This covers:
  - Integer `*`, `<<`, `+`, and `-`. Estimate the result from `bit_length`.
  - String and bytes repetition, `+`, `join`, `replace`, `format`, `%`, and `split`.
  - List and tuple repetition, `+`, `extend`, and conversion of large ranges.
  - Comprehensions, `sorted`, `zip`, `list()`, `tuple()`, `dict()`, and `set()`.
- **Step limit.** The evaluator counts steps and raises when the host's budget runs out. The limit is a host setting, not a language feature.
- **Depth limit.** The parser rejects nesting deeper than a fixed limit. Recursive Ruby code must not reach `SystemStackError`. This applies to the parser, the evaluator, `repr`, equality, and comparison of nested values.
- **No ambient access.** The interpreter has no IO, clock, randomness, environment, or filesystem access. The host provides every predeclared name except the spec's builtins. `print` calls a host callback.
- **Host boundary.** If a string with invalid UTF-8 leaves Starlark through the embedding API, raise by default. Do not scrub silently.

## Architecture

The pipeline has these stages:

1. **Lexer.** Emits INDENT and DEDENT tokens. Handles implicit line joining inside brackets.
2. **Parser.** Hand-written recursive descent. Do not add `racc` or other parser generators. Errors carry file, line, and column.
3. **Resolver.** Classifies each name as local, global, free, predeclared, or universal. Reports undefined names and invalid rebinding before execution. Assigns local variables to slot indices.
4. **Evaluator.** Walks the resolved AST. Do not build a bytecode VM unless benchmarks show the tree-walker is too slow.
5. **Embedding API.** The host defines predeclared names, converts values between Ruby and Starlark, sets limits, and resolves `load()` through a loader callback.

Code lives under `lib/starlark/`. The entry point is `lib/starlark.rb`.

## Testing

- The lexer is tested against starlark-go and Java Starlark. See `tools/oracle/README.md` and `spec/lexer/corpus/README.md`. Run `mise run oracle:setup` once, then `mise run oracle:go`. Every lexer change must keep `oracle:go` passing.
- Where the spec and starlark-go disagree, the lexer follows the spec. Each such case has an `override_` file in `spec/lexer/corpus/` with a `.expected` file.
- Port the upstream conformance suite from `bazelbuild/starlark/test_suite/testdata/{go,java,rust}`. Do not vendor the 4 MB Java jar.
- The file format:
  - A line containing only `---` separates independent chunks.
  - A trailing `### regex` comment marks a line that must raise an error matching the regex. Matching is case-insensitive and tries both substring and regex.
  - A tag such as `### go: message` applies to one implementation only. Our runner follows the `go` tags, because Go uses the same string model.
- The upstream runner ignores failed `assert_eq` calls when the process exits with code 0. Our runner must treat a failed assert as a test failure.
- Many upstream cases are commented out with `_inconsistency_` notes. Do not enable a commented case unless the spec defines its behavior.
- The upstream suite is small. Also write RSpec tests for each spec section as it is implemented.

## Commands

```bash
mise install        # install Ruby 3.4.4
bundle install
bundle exec rspec
bundle exec rubocop
```
