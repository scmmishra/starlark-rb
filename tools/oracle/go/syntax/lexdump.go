// tools/oracle/setup copies this file into starlark-go's syntax package.
// It must live inside that package because the scanner is unexported.
// Editors report undefined names here, because the file does not build in place.

package syntax

import (
	"fmt"
	"io"
	"math"
)

var lexDumpNames = map[Token]string{
	ILLEGAL: "ILLEGAL", EOF: "EOF", NEWLINE: "NEWLINE", INDENT: "INDENT", OUTDENT: "OUTDENT",
	IDENT: "IDENT", INT: "INT", FLOAT: "FLOAT", STRING: "STRING", BYTES: "BYTES",
	PLUS: "PLUS", MINUS: "MINUS", STAR: "STAR", SLASH: "SLASH", SLASHSLASH: "SLASHSLASH",
	PERCENT: "PERCENT", AMP: "AMP", PIPE: "PIPE", CIRCUMFLEX: "CIRCUMFLEX", LTLT: "LTLT",
	GTGT: "GTGT", TILDE: "TILDE", DOT: "DOT", COMMA: "COMMA", EQ: "EQ", SEMI: "SEMI",
	COLON: "COLON", LPAREN: "LPAREN", RPAREN: "RPAREN", LBRACK: "LBRACK", RBRACK: "RBRACK",
	LBRACE: "LBRACE", RBRACE: "RBRACE", LT: "LT", GT: "GT", GE: "GE", LE: "LE", EQL: "EQL",
	NEQ: "NEQ", PLUS_EQ: "PLUS_EQ", MINUS_EQ: "MINUS_EQ", STAR_EQ: "STAR_EQ",
	SLASH_EQ: "SLASH_EQ", SLASHSLASH_EQ: "SLASHSLASH_EQ", PERCENT_EQ: "PERCENT_EQ",
	AMP_EQ: "AMP_EQ", PIPE_EQ: "PIPE_EQ", CIRCUMFLEX_EQ: "CIRCUMFLEX_EQ", LTLT_EQ: "LTLT_EQ",
	GTGT_EQ: "GTGT_EQ", STARSTAR: "STARSTAR",
	AND: "AND", BREAK: "BREAK", CONTINUE: "CONTINUE", DEF: "DEF", ELIF: "ELIF", ELSE: "ELSE",
	FOR: "FOR", IF: "IF", IN: "IN", LAMBDA: "LAMBDA", LOAD: "LOAD", NOT: "NOT",
	NOT_IN: "NOT_IN", OR: "OR", PASS: "PASS", RETURN: "RETURN", WHILE: "WHILE",
	AS: "AS", ASYNC: "ASYNC", AWAIT: "AWAIT", CLASS: "CLASS", DEL: "DEL",
	EXCEPT: "EXCEPT", FINALLY: "FINALLY", FROM: "FROM", GLOBAL: "GLOBAL", IMPORT: "IMPORT",
	IS: "IS", NONLOCAL: "NONLOCAL", RAISE: "RAISE", TRY: "TRY", WITH: "WITH", YIELD: "YIELD",
}

// LexDump writes one line per token in the oracle format described in
// tools/oracle/README.md. It stops at the first lexical error.
func LexDump(filename string, src []byte, w io.Writer) error {
	sc, err := newScanner(filename, src, false)
	if err != nil {
		return err
	}

	scanErr := func() (err error) {
		defer sc.recover(&err)
		var val tokenValue
		for {
			tok := sc.nextToken(&val)
			name, ok := lexDumpNames[tok]
			if !ok {
				name = fmt.Sprintf("UNKNOWN(%d)", tok)
			}
			fmt.Fprintf(w, "%d:%d\t%s\t%s\n", val.pos.Line, val.pos.Col, name, lexDumpValue(tok, &val))
			if tok == EOF {
				return nil
			}
		}
	}()

	if e, ok := scanErr.(Error); ok {
		fmt.Fprintf(w, "%d:%d\tERROR\t%s\n", e.Pos.Line, e.Pos.Col, e.Msg)
		return nil
	}
	return scanErr
}

func lexDumpValue(tok Token, val *tokenValue) string {
	switch tok {
	case IDENT:
		return val.raw
	case INT:
		if val.bigInt != nil {
			return val.bigInt.String()
		}
		return fmt.Sprintf("%d", val.int)
	case FLOAT:
		return fmt.Sprintf("%016x", math.Float64bits(val.float))
	case STRING, BYTES:
		return lexDumpQuote([]byte(val.string))
	}
	return ""
}

// lexDumpQuote prints printable ASCII as is and every other byte as \xHH.
func lexDumpQuote(b []byte) string {
	out := []byte{'"'}
	for _, c := range b {
		if c >= 0x20 && c < 0x7f && c != '"' && c != '\\' {
			out = append(out, c)
		} else {
			out = append(out, fmt.Sprintf("\\x%02x", c)...)
		}
	}
	return string(append(out, '"'))
}
