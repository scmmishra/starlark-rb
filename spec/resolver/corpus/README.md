# Resolver corpus

Each `.star` file is one resolver test case. `spec/oracle/resolver_oracle_spec.rb` resolves it with our resolver and compares the bindings, slots, and static errors with starlark-go's. The spec also compares each chunk of the conformance files in `spec/conformance/testdata`.

- Files named `error_*` hold static errors. The resolver reports every error in a file, so one file may hold several.
- Files named `override_*` have a sibling `.expected` file. In those cases the spec and starlark-go disagree, and we follow the spec.

## Overrides

| File | starlark-go | This resolver | Java Starlark |
|---|---|---|---|
| `override_call_256_positional` | rejects more than 255 positional arguments | accepts them | accepts them |
| `override_call_256_keyword` | rejects more than 255 keyword arguments | accepts them | accepts them |
| `override_load_invalid_identifier` | accepts any loaded name | rejects names that are not identifiers, such as `"x-y"` or `"if"` | accepts any loaded name |

The spec has no limit on the number of arguments. The 255 limit comes from starlark-go's compiler. The spec says a loaded name "must denote a valid identifier".

## Adding a case

1. Add a `.star` file here.
2. Run `mise run oracle:go`. Our resolver must match starlark-go.
3. Run `mise run oracle:java` or `tools/oracle/resolve java FILE`. If Java disagrees, check the spec. If the spec sides against Go, add an `override_` case with a `.expected` file. Otherwise add the file to `spec/oracle/java_resolver_known_differences.yml` with a reason.
