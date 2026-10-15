# starlark-rb

A Starlark interpreter in pure Ruby, shipped as a gem. No FFI, no C extensions, no runtime gem dependencies. Chatwoot uses it to run untrusted customer scripts, such as Stripe or Shopify plugins. Chatwoot adds its own host functions. This gem implements only the language.

## Which behavior to follow

The spec is `docs/spec.md`, a copy of `bazelbuild/starlark/spec.md`. Decide behavior in this order:

1. **The spec text wins,** even over Java or Go. Java Starlark breaks the spec in places: it has no bytes literals, rejects non-ASCII identifiers, and rejects `\x` escapes.
2. **If the spec is silent and a script could see the difference, follow Java Starlark.** Examples: a lone `\r` is white space, and a NUL byte is an error.
3. **If no script can see the difference, follow starlark-go.** Examples: token columns, and whether a NEWLINE comes before EOF. Go uses our string model, so its output compares byte for byte.

Name the spec section in a code comment for each such decision. Add no behavior from other dialects. starlark-go's `while`, recursion, `ord`, `chr`, and `codepoints()` are out of scope. Helpers like a `text` module belong to the host, not this gem.

## Decisions

- **Ruby 3.4.4,** matching Chatwoot. Pinned in `.mise.toml` and `Gemfile`.
- **Strings are UTF-8 bytes (K=8).** `len("é")` is 2, and `s[i]` is one byte.
  - Use `bytesize`, `byteslice`, `byteindex`, `byterindex`. Never `size`, `[]`, or `index`.
  - Strings may hold invalid UTF-8, but always stay tagged `Encoding::UTF_8`. Mixed encodings break `==` and `hash`.
  - Ruby methods like `downcase`, `upcase`, and regexes raise on invalid UTF-8. Test each string builtin with invalid input.
  - `bytes` wraps a frozen `Encoding::BINARY` string.
- **Values.** `int`, `float`, `string`, `bool`, `None` are Ruby `Integer`, `Float`, frozen `String`, `true`/`false`, `nil`. Containers, `bytes`, and functions are our own classes.

## Ruby semantics that differ

- **Truthiness.** `0`, `0.0`, `""`, `b""`, and empty containers are false. Use one `truth(value)` helper, never `if value`.
- **Dict keys.** `1 == 1.0`, so they are the same key. Ruby `Hash` uses `eql?`, so normalize keys.
- **Hashability.** Lists, dicts, and sets cannot be keys. Tuples can only if all elements can.
- **Freezing.** Module values freeze after load. Mutating a container while iterating it is an error. Track iteration with a counter.
- **`hash()`.** Never use Ruby's randomized `String#hash`. The spec requires Java `String.hashCode` over UTF-16 for strings, and 32-bit FNV-1a for bytes.
- **`repr` and `str`.** Never use `inspect` or `to_s`. Write our own formatting. `repr` must detect cycles.

## Security rules

- **No dynamic dispatch into Ruby.** Never use `send`, `public_send`, `method`, `instance_variable_get`, or `const_get` for Starlark attributes. Each type has an explicit method table. `dir`, `getattr`, and `hasattr` read only that table.
- **Check sizes before allocating.** The step limit cannot stop one Ruby C call: `1 << 2000000000` allocates 250 MB in one step. Check the result size first for integer `*`, `<<`, `+`, `-`; string and bytes repetition, `+`, `join`, `replace`, `format`, `%`, `split`; list and tuple repetition, `+`, `extend`; ranges; comprehensions; `sorted`, `zip`, and the container constructors.
- **Step limit.** The evaluator counts steps against a host-set budget.
- **Depth limit.** Nothing recursive may reach `SystemStackError`: parser, evaluator, `repr`, equality, comparison. The lexer limits bracket nesting to 1000. The parser counts recursion depth like starlark-go and stops at 1000, which allows about 80 nested brackets. An `elif` chain becomes nested `IfStmt` nodes, so code that walks it must use a loop, as the parser does.
- **No ambient access.** No IO, clock, randomness, environment, or filesystem. `print` calls a host callback.
- **Host boundary.** Raise when a string with invalid UTF-8 leaves Starlark. Do not scrub.

## Architecture

Code is in `lib/starlark/`, loaded by `lib/starlark.rb`.

1. **Lexer** (`lexer.rb`, done). A port of starlark-go's scanner, except where the spec differs.
2. **Parser** (`parser.rb`, done). A port of starlark-go's recursive-descent parser, except where the spec differs. Builds the nodes in `ast.rb`. No parser generators.
3. **Resolver.** Binds each name as local, global, free, predeclared, or universal. Reports undefined names before execution. Assigns locals to slots.
4. **Evaluator.** Walks the resolved AST. No bytecode VM unless benchmarks demand it.
5. **Embedding API.** Host names, value conversion, limits, and a `load()` callback.

## Testing

- **Oracles.** `spec/oracle` compares our lexer and parser with starlark-go and Java Starlark. `oracle:go` and `oracle:java` must pass. Each case where we follow the spec over Go is an `override_` file with a `.expected` file in `spec/lexer/corpus/` or `spec/parser/corpus/`. Each known Java difference is listed with a reason in `spec/oracle/java_*_known_differences.yml`. See `tools/oracle/README.md`.
- **Conformance suite.** Vendored in `spec/conformance/testdata/`. The runner is not written yet. When writing it:
  - A `---` line separates chunks. A trailing `### regex` marks a line that must fail with a matching error, case-insensitive, as substring or regex.
  - Follow `### go:` tags, because Go shares our string model.
  - A failed `assert_eq` must fail the test. The upstream runner misses this.
  - Leave cases marked `_inconsistency_` commented out unless the spec defines them.
- Write RSpec tests for each spec section as it is implemented.

## Commands

```bash
mise install            # Ruby, Go, Java
bundle install
bundle exec rspec       # includes the Go oracle specs
mise run coverage       # full suite with line and branch coverage
mise run oracle:setup   # build the oracles once
mise run oracle:go      # or oracle:java, oracle:all
mise run fuzz           # random inputs against Go, see tools/fuzz/README.md
```
