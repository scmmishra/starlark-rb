# Oracles

These tools print what starlark-go and Java Starlark produce for a file: the tokens from their lexers, and the syntax trees from their parsers. Specs in `spec/oracle` compare our lexer and parser against them.

The gem does not depend on these tools. They need Go and Java, which `.mise.toml` installs.

## Setup

```bash
mise install
mise run oracle:setup
```

`setup` downloads pinned sources into `tools/oracle/.cache` and builds all four oracles. The pins are at the top of the script.

- starlark-go: `edf86ebe07b2546ad597b165247c644c2782691b`. The lexer dumper is copied into its `syntax` package, because the scanner is unexported. The parser dumper uses the exported `syntax.Parse`, with all dialect options off.
- Java Starlark: the jar from `bazelbuild/starlark` at `c0af0ea03dc90d3bbc021394b693e6957cc15030`, the same commit as `docs/spec.md`. Both Java dumpers are in the `net.starlark.java.syntax` package, because `Lexer` is package-private.

## Usage

```bash
tools/oracle/lex go|java FILE
tools/oracle/parse go|java FILE
mise run oracle:go      # compare our lexer and parser with Go
mise run oracle:java    # compare with Java
```

## Lexer output format

Each line is one token, with three tab-separated fields:

```
LINE:COL	KIND	VALUE
```

- `LINE` and `COL` are 1-based. `COL` counts Unicode code points, as starlark-go does. The Java oracle converts its UTF-16 columns to code points.
- `KIND` uses starlark-go's token names, such as `IDENT`, `STRING`, and `PLUS_EQ`. The Java oracle renames its token kinds to match.
- `VALUE` is empty for most tokens. Tokens with values print them as follows:
  - `IDENT`: the name.
  - `INT`: the value in decimal.
  - `FLOAT`: the IEEE 754 bits as 16 hex digits, so values compare exactly.
  - `STRING` and `BYTES`: the decoded bytes in double quotes. Printable ASCII appears as is. Every other byte, and `"` and `\`, appears as `\xHH`.

If the lexer reports an error, the last line is `LINE:COL	ERROR	MESSAGE`. The output stops after the first error. Java can continue past errors, but the oracle stops at the first one so both outputs compare the same way.

## Parser output format

Each line is one node, indented two spaces per level under its parent:

```
LINE:COL NODE DETAIL
```

`LINE:COL` is the node's first token. Node names follow `lib/starlark/ast.rb`. Both dumpers convert their own trees into these names. Top-level statements have no indentation.

```python
def f(x, y=1):
    return x + y
```

```
1:1 DefStmt f
  1:7 Param required x
  1:10 Param optional y
    1:12 Literal int 1
  body
    2:5 ReturnStmt
      2:12 BinaryExpr +
        2:12 Ident x
        2:16 Ident y
```

- **Details.** Operators print as source text, such as `+=` or `not in`. Literals print their kind and value, formatted as in the lexer output. `Param` and `Arg` print their kind and name.
- **Labels.** A line with only a word groups children that would otherwise be ambiguous: `body`, `then`, and `else` for statement lists, and `start`, `stop`, and `step` for slice parts. A missing part prints nothing.
- **Parentheses.** They have no node. An expression that starts with `(` takes the position of the `(`, as in starlark-go. The parenthesized expression itself keeps its own position.
- **Errors.** A syntax error prints a single line, `LINE:COL ERROR MESSAGE`, and no tree.

The Java comparison drops positions and error messages, because Java's columns and wording differ from Go's.

## Known differences

Where the spec and starlark-go disagree, we follow the spec. Those cases are `override_` files with `.expected` output, listed in `spec/lexer/corpus/README.md` and `spec/parser/corpus/README.md`.

Every file where Java differs from us is listed with a reason in `spec/oracle/java_lexer_known_differences.yml` or `spec/oracle/java_parser_known_differences.yml`. The Java specs mark those files as pending.

In these places Go follows the spec and Java does not:

- Java has no bytes literals.
- Java rejects non-ASCII identifiers. The spec allows Unicode letters.
- Java rejects `\x` escapes. The spec defines them.
- Java lexes `async` and `await` as identifiers. The spec reserves them.
- Java keeps the CR of a CRLF line ending inside a multiline string. The spec says such a line ending denotes `\n`.

These differences are outside the spec:

- Java emits a `NEWLINE` before `EOF`. Go does not.
- Java columns for `INDENT` and `OUTDENT` differ from Go's.
- Java folds concatenated string literals, such as `"a" + "b"`, into one literal.
- Java has no limit on expression nesting. Go and we stop at a fixed depth.
- Error messages and some error positions differ.
