# Parser corpus

Each `.star` file is one parser test case. `spec/oracle/parser_oracle_spec.rb` parses it with our parser and compares the tree with starlark-go's, positions included. The spec also compares each chunk of the conformance files in `spec/conformance/testdata`.

- Files named `error_*` hold one syntax error each. The parser stops at the first error.
- Files named `override_*` have a sibling `.expected` file. In those cases the spec and starlark-go disagree, and we follow the spec.

## Overrides

| File | starlark-go | This parser | Java Starlark |
|---|---|---|---|
| `override_while_statement` | parses a while statement | error, with Java's message | error |

The lexer overrides in `spec/lexer/corpus/README.md` also apply here, because the parser reads our lexer's tokens.

## Adding a case

1. Add a `.star` file here.
2. Run `mise run oracle:go`. Our parser must match starlark-go.
3. Run `mise run oracle:java` or `tools/oracle/parse java FILE`. If Java disagrees, check the spec. If the spec sides against Go, add an `override_` case with a `.expected` file. Otherwise add the file to `spec/oracle/java_parser_known_differences.yml` with a reason.
