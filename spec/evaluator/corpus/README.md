# Evaluator corpus

Each `.star` file is one interpreter test case. `spec/oracle/evaluator_oracle_spec.rb` runs it with our interpreter and compares print output, the final globals, and any error message with starlark-go's. The spec also runs every chunk of the conformance files in `spec/conformance/testdata`.

- Files named `error_*` end in a dynamic or static error.
- Files named `override_*` have a sibling `.expected` file. In those cases the spec and starlark-go disagree, and we follow the spec.

## Overrides

| File | starlark-go | This interpreter |
|---|---|---|
| `override_bytes_index` | `b"abc"[0]` is the bytes `b"a"` | the int 97 |
| `override_hash_astral` | hashes a character above U+FFFF as one unit | as two UTF-16 surrogate units, like Java's `String.hashCode` |
| `override_range_contains_float` | `1.5 in range(5)` is True | False |
| `override_set_spec_methods` | no `difference_update`, `intersection_update`, `symmetric_difference_update`, or `isdisjoint`, and one argument for `difference` and `intersection` | as the spec defines them |
| `override_splitlines_cr` | splits at `"\n"` only | also at `"\r"` and `"\r\n"` |

## Kept from starlark-go

The spec leaves these open, and we follow starlark-go so the oracle comparison stays exact:

- Error messages and their wording.
- A left shift of 512 bits or more fails with `shift count too large`.
- Repetition that would build 2**30 elements or more fails with `excessive repeat`.
- Comparing nested structures deeper than 10 levels fails with `comparison exceeded maximum recursion depth`.
- `'%F' % x` prints `%F`, because Go's `strconv.FormatFloat` does not support `F`.

Our own size and step limits are host settings, see `lib/starlark/limits.rb`. The corpus stays below them.

## Adding a case

1. Add a `.star` file here.
2. Run `mise run oracle:golden`, then `mise run oracle:go`. Our interpreter must match starlark-go.
3. If the spec sides against starlark-go, add an `override_` case with a `.expected` file, and explain the reason in a comment at the top.
