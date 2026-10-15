# Oracles

These tools print what starlark-go and Java Starlark produce for a file: the tokens from their lexers, the syntax trees from their parsers, and the name bindings and static errors from their resolvers. Specs in `spec/oracle` compare our code against them.

The gem does not depend on these tools. They need Go and Java, which `.mise.toml` installs.

## Setup

```bash
mise install
mise run oracle:setup
```

`setup` downloads pinned sources into `tools/oracle/.cache` and builds the oracles. The pins are at the top of the script.

- starlark-go: `edf86ebe07b2546ad597b165247c644c2782691b`. The lexer dumper is copied into its `syntax` package, because the scanner is unexported. The parser dumper uses the exported `syntax.Parse`, with all dialect options off.
- Java Starlark: the jar from `bazelbuild/starlark` at `c0af0ea03dc90d3bbc021394b693e6957cc15030`, the same commit as `docs/spec.md`. Both Java dumpers are in the `net.starlark.java.syntax` package, because `Lexer` is package-private.

## Usage

```bash
tools/oracle/lex go|java FILE
tools/oracle/parse go|java FILE
tools/oracle/resolve go|java FILE
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

## Resolver output format

The resolver dump runs after a successful parse.

```python
x = 1
def f(p):
    def g():
        return p + x
    return g
```

```
module
  locals: 
  globals: x f
1:1 Ident x global 0
2:1 function f
  locals: p* g
  free: 
3:5 function g
  locals: 
  free: p*
4:16 Ident p free 0
4:20 Ident x global 0
5:12 Ident g local 1
```

- **Module.** The first lines list the file's locals and globals in slot order. File locals are `load` bindings and top-level comprehension variables.
- **Functions.** Each `def` and `lambda` prints a header at its position, with its flags (`varargs`, `kwargs`, `kwonly=N`), then its locals in slot order, parameters first, then its free variables.
- **Identifiers.** Each identifier used in an expression prints its scope and slot index. Scopes are `local`, `cell`, `free`, `global`, `predeclared`, and `universal`. Predeclared and universal names have no index. Names that only declare, such as parameters, `def` names, `load` names, attribute names, and keyword argument names, are covered by the headers instead.
- **Cells.** A trailing `*` marks a cell: a local that a nested function captures. Its uses in the defining function print scope `cell`. Its uses in the nested function print scope `free`.
- **Errors.** A parse error prints one line. Resolver errors print one line each, in the order the resolver reports them, and nothing else. starlark-go reports undefined names last.

Both dumpers parse the file under the name `input.star`, because some messages include it. Both use the same known names:

- **Universal:** the spec's builtins, `None True False abs any all bool bytes dict dir enumerate fail float getattr hasattr hash int len list max min print range repr reversed set sorted str tuple type zip`.
- **Predeclared:** `assert_eq assert_ne assert_`, which the conformance tests use. The fuzzer replaces this list through the `STARLARK_ORACLE_PREDECLARED` environment variable, which only the Go dumper reads.

Both use options that match the spec. starlark-go has `Set` on, because `set` is a spec builtin, and every other option off. Java has loading private names, rebinding globals at top level, global load bindings, and loads-first all off.

The Java comparison collapses any error output to "has errors", because Java's wording, order, and extra notes differ.

## Known differences

Where the spec and starlark-go disagree, we follow the spec. Those cases are `override_` files with `.expected` output, listed in the README of each corpus under `spec/lexer`, `spec/parser`, and `spec/resolver`.

Every file where Java differs from us is listed with a reason in `spec/oracle/java_lexer_known_differences.yml`, `java_parser_known_differences.yml`, or `java_resolver_known_differences.yml`. The Java specs mark those files as pending.

In these places Go follows the spec and Java does not:

- Java has no bytes literals.
- Java rejects non-ASCII identifiers. The spec allows Unicode letters.
- Java rejects `\x` escapes. The spec defines them.
- Java lexes `async` and `await` as identifiers. The spec reserves them.
- Java keeps the CR of a CRLF line ending inside a multiline string. The spec says such a line ending denotes `\n`.
- Java accepts a parenthesized keyword argument name, as in `f((a)=1)`. The spec grammar requires `identifier "="`.
- Java accepts any string as a loaded name. The spec says it must be a valid identifier.
- Java allows `break` in a function nested inside a loop.

These differences are outside the spec:

- Java rejects tabs on blank and comment-only lines. Go accepts them, and we keep Go's behavior.
- Java emits a `NEWLINE` before `EOF`. Go does not.
- Java columns for `INDENT` and `OUTDENT` differ from Go's.
- Java folds concatenated string literals, such as `"a" + "b"`, into one literal.
- Java has no limit on expression nesting. Go and we stop at a fixed depth.
- Java orders comprehension variables after a function's other locals. Go orders all locals by first appearance, and so do we.
- Error messages and some error positions differ.
