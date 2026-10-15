# Lexer corpus

Each `.star` file is one lexer test case. `spec/oracle/lexer_oracle_spec.rb` lexes it with our lexer and compares the result with starlark-go's output.

- Files named `error_*` hold one lexical error each. The oracle output stops at the first error, so each error needs its own file.
- Files named `override_*` have a sibling `.expected` file. In those cases the spec and starlark-go disagree, and we follow the spec. The Go comparison uses the `.expected` file instead of the Go oracle. Each `.star` file explains its reason in a comment.

## Overrides

| File | starlark-go | This lexer | Java Starlark |
|---|---|---|---|
| `override_assert_reserved` | `assert` is an identifier | `assert` is a reserved word | reserved word |
| `override_binary_literal` | accepts `0b101` | error | error |
| `override_double_zero` | accepts `00` as 0 | error | error |
| `override_tab_indent` | accepts tabs in indentation | error | error |
| `override_br_prefix` | lexes `br'x'` as `br` and `'x'` | raw bytes literal | has no bytes literals |
| `override_lone_cr` | a lone CR is a newline | a lone CR is white space, or a literal character in a string | same as this lexer |
| `override_nul_byte` | a NUL byte ends the file | error | error |

The spec does not mention NUL bytes. We reject them so that no part of a script is skipped without an error.

## Adding a case

1. Add a `.star` file here.
2. Run `mise run oracle:go`. Our lexer must match starlark-go.
3. Run `mise run oracle:java` or `tools/oracle/lex java FILE`. If Java disagrees, check the spec. If the spec sides against Go, add an `override_` case with a `.expected` file. If Java differs and the spec does not side against Go, add the file to `spec/oracle/java_lexer_known_differences.yml` with a reason.
