# Lexer oracles

These tools print the tokens that starlark-go and Java Starlark produce for a file. We compare our lexer's output against them.

The gem does not depend on these tools. They need Go and Java, which `.mise.toml` installs.

## Setup

```bash
mise install
tools/oracle/setup
```

`setup` downloads pinned sources into `tools/oracle/.cache` and builds both oracles. The pins are at the top of the script.

- starlark-go: `edf86ebe07b2546ad597b165247c644c2782691b`. The Go file is copied into its `syntax` package, because the scanner is unexported.
- Java Starlark: the jar from `bazelbuild/starlark` at `c0af0ea03dc90d3bbc021394b693e6957cc15030`, the same commit as `docs/spec.md`. The Java class is in the `net.starlark.java.syntax` package, because `Lexer` is package-private.

## Usage

```bash
tools/oracle/lex go FILE
tools/oracle/lex java FILE
diff <(tools/oracle/lex go FILE) <(tools/oracle/lex java FILE)
```

## Output format

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

If the lexer reports an error, the last line is:

```
LINE:COL	ERROR	MESSAGE
```

The output stops after the first error. Java can continue past errors, but the oracle stops at the first one so both outputs compare the same way.

## Known differences between the two

Java follows the spec more closely in a few places. `spec/lexer/corpus/README.md` lists the cases where we follow Java and the spec over Go. `spec/oracle/java_known_differences.yml` lists every file where Java differs from our lexer, with a reason.

In these places Go follows the spec and Java does not:

- Java has no `BYTES` token. The jar does not support bytes literals.
- Java rejects non-ASCII identifiers. The spec allows Unicode letters.
- Java rejects `\x` escapes. The spec defines them.
- Java lexes `async` and `await` as identifiers. The spec reserves them.
- Java keeps the CR of a CRLF line ending inside a multiline string. The spec says such a line ending denotes `\n`.

These differences are outside the spec:

- Java emits a `NEWLINE` before `EOF`. Go does not.
- Java columns for `INDENT` and `OUTDENT` differ from Go's.
- Error messages and some error positions differ.
