# Differential fuzzer

`tools/fuzz/fuzz` compares our lexer, parser, and resolver with starlark-go on random inputs. It uses the oracles in `tools/oracle`, so run `mise run oracle:setup` first.

```bash
mise run fuzz                                  # all modes, 2000 inputs each, random seed
tools/fuzz/fuzz grammar --count 5000 --seed 7  # one mode, fixed seed
```

## Modes

| Mode | Inputs |
|---|---|
| `grammar` | Random programs from the spec's grammar reference. All of them parse, and about 90% also pass the resolver's static checks, so each input compares a full tree and full bindings. Operator chains without parentheses exercise precedence. |
| `mutate` | Corpus files and conformance chunks with random edits: inserted tokens, deleted or duplicated spans, swapped lines, shifted indentation. Most of them are invalid, so they exercise error positions and messages. |
| `unicode` | Every code point. Compares the letters our lexer accepts in identifiers with Go's `unicode.IsLetter`. |
| `floats` | Random float literals, compared by their exact bits. |

Each input is compared with the lexer, parser, and resolver oracles. For the resolver, the generator's names are predeclared, so most programs have no undefined names. A mismatch is saved to `tools/fuzz/findings/` as a `.star` file, with a `.txt` file that holds both outputs. Git ignores that directory. The script exits with status 1 if it finds a mismatch.

Inputs that match a known spec-over-Go case are skipped: tabs, carriage returns, NUL, `assert`, `while`, `0b` and `00` literals, and `br` prefixes. See `KNOWN_DIFFERENCE` in the script. Resolver mismatches on inputs that contain `load` are skipped too, because we reject load names that are not identifiers.

## When it finds a mismatch

1. Shrink the input by hand until the difference is obvious.
2. Decide which side is right. Use the order in `CLAUDE.md`: spec text, then Java, then Go.
3. If we are wrong, add the input to the corpus under `spec/lexer`, `spec/parser`, or `spec/resolver`, and fix the code.
4. If Go is wrong, add an `override_` case with a `.expected` file.

## Checking that it works

A fuzzer that finds nothing proves little unless it can find a planted bug. Swapping the precedence of `+` and `*` in the parser makes about 45% of `grammar` inputs mismatch. Removing the non-associative comparison check makes a few `mutate` inputs mismatch per thousand. In the resolver, never marking captured locals as cells makes about 20% of `grammar` inputs mismatch. Resolving nested functions in reverse order makes about 2% mismatch.
