// Command parsedump prints starlark-go's syntax tree for one file in the
// oracle format described in tools/oracle/README.md.
// tools/oracle/setup copies it into starlark-go as cmd/parsedump.
package main

import (
	"bufio"
	"fmt"
	"math"
	"math/big"
	"os"
	"strings"

	"go.starlark.net/syntax"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: parsedump FILE")
		os.Exit(2)
	}
	src, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()

	// All dialect options stay off. They only affect the resolver anyway.
	f, err := (&syntax.FileOptions{}).Parse(os.Args[1], src, 0)
	if err != nil {
		if e, ok := err.(syntax.Error); ok {
			fmt.Fprintf(w, "%d:%d ERROR %s\n", e.Pos.Line, e.Pos.Col, e.Msg)
			return
		}
		w.Flush()
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	d := dumper{w: w}
	for _, stmt := range f.Stmts {
		d.node(stmt, 0)
	}
}

type dumper struct{ w *bufio.Writer }

func (d dumper) line(n syntax.Node, depth int, text string) {
	start, _ := n.Span()
	fmt.Fprintf(d.w, "%s%d:%d %s\n", strings.Repeat("  ", depth), start.Line, start.Col, text)
}

func (d dumper) label(depth int, text string) {
	fmt.Fprintf(d.w, "%s%s\n", strings.Repeat("  ", depth), text)
}

func (d dumper) stmts(label string, stmts []syntax.Stmt, depth int) {
	d.label(depth, label)
	for _, s := range stmts {
		d.node(s, depth+1)
	}
}

func (d dumper) node(n syntax.Node, depth int) {
	switch n := n.(type) {
	case *syntax.ParenExpr:
		d.node(n.X, depth)

	case *syntax.DefStmt:
		d.line(n, depth, "DefStmt "+n.Name.Name)
		for _, p := range n.Params {
			d.param(p, depth+1)
		}
		d.stmts("body", n.Body, depth+1)

	case *syntax.IfStmt:
		d.line(n, depth, "IfStmt")
		d.node(n.Cond, depth+1)
		d.stmts("then", n.True, depth+1)
		if len(n.False) > 0 {
			d.stmts("else", n.False, depth+1)
		}

	case *syntax.ForStmt:
		d.line(n, depth, "ForStmt")
		d.node(n.Vars, depth+1)
		d.node(n.X, depth+1)
		d.stmts("body", n.Body, depth+1)

	case *syntax.WhileStmt:
		d.line(n, depth, "WhileStmt")
		d.node(n.Cond, depth+1)
		d.stmts("body", n.Body, depth+1)

	case *syntax.ReturnStmt:
		d.line(n, depth, "ReturnStmt")
		if n.Result != nil {
			d.node(n.Result, depth+1)
		}

	case *syntax.BranchStmt:
		d.line(n, depth, "BranchStmt "+n.Token.String())

	case *syntax.AssignStmt:
		d.line(n, depth, "AssignStmt "+n.Op.String())
		d.node(n.LHS, depth+1)
		d.node(n.RHS, depth+1)

	case *syntax.ExprStmt:
		d.line(n, depth, "ExprStmt")
		d.node(n.X, depth+1)

	case *syntax.LoadStmt:
		d.line(n, depth, "LoadStmt "+quote(n.Module.Value.(string)))
		for i := range n.To {
			d.line(n.To[i], depth+1, "LoadBinding "+n.To[i].Name+" "+n.From[i].Name)
		}

	case *syntax.Ident:
		d.line(n, depth, "Ident "+n.Name)

	case *syntax.Literal:
		d.line(n, depth, "Literal "+literal(n))

	case *syntax.ListExpr:
		d.line(n, depth, "ListExpr")
		for _, x := range n.List {
			d.node(x, depth+1)
		}

	case *syntax.TupleExpr:
		d.line(n, depth, "TupleExpr")
		for _, x := range n.List {
			d.node(x, depth+1)
		}

	case *syntax.DictExpr:
		d.line(n, depth, "DictExpr")
		for _, x := range n.List {
			d.node(x, depth+1)
		}

	case *syntax.DictEntry:
		d.line(n, depth, "DictEntry")
		d.node(n.Key, depth+1)
		d.node(n.Value, depth+1)

	case *syntax.Comprehension:
		kind := "list"
		if n.Curly {
			kind = "dict"
		}
		d.line(n, depth, "Comprehension "+kind)
		d.node(n.Body, depth+1)
		for _, c := range n.Clauses {
			d.node(c, depth+1)
		}

	case *syntax.ForClause:
		d.line(n, depth, "ForClause")
		d.node(n.Vars, depth+1)
		d.node(n.X, depth+1)

	case *syntax.IfClause:
		d.line(n, depth, "IfClause")
		d.node(n.Cond, depth+1)

	case *syntax.CondExpr:
		d.line(n, depth, "IfExpr")
		d.node(n.Cond, depth+1)
		d.node(n.True, depth+1)
		d.node(n.False, depth+1)

	case *syntax.UnaryExpr:
		d.line(n, depth, "UnaryExpr "+n.Op.String())
		d.node(n.X, depth+1)

	case *syntax.BinaryExpr:
		d.line(n, depth, "BinaryExpr "+n.Op.String())
		d.node(n.X, depth+1)
		d.node(n.Y, depth+1)

	case *syntax.LambdaExpr:
		d.line(n, depth, "LambdaExpr")
		for _, p := range n.Params {
			d.param(p, depth+1)
		}
		d.label(depth+1, "body")
		d.node(n.Body, depth+2)

	case *syntax.DotExpr:
		d.line(n, depth, "DotExpr "+n.Name.Name)
		d.node(n.X, depth+1)

	case *syntax.CallExpr:
		d.line(n, depth, "CallExpr")
		d.node(n.Fn, depth+1)
		for _, a := range n.Args {
			d.arg(a, depth+1)
		}

	case *syntax.IndexExpr:
		d.line(n, depth, "IndexExpr")
		d.node(n.X, depth+1)
		d.node(n.Y, depth+1)

	case *syntax.SliceExpr:
		d.line(n, depth, "SliceExpr")
		d.node(n.X, depth+1)
		for _, part := range []struct {
			label string
			x     syntax.Expr
		}{{"start", n.Lo}, {"stop", n.Hi}, {"step", n.Step}} {
			if part.x != nil {
				d.label(depth+1, part.label)
				d.node(part.x, depth+2)
			}
		}

	default:
		d.label(depth, fmt.Sprintf("UNKNOWN %T", n))
	}
}

// param converts starlark-go's encoding of parameters into Param lines.
func (d dumper) param(p syntax.Expr, depth int) {
	switch p := p.(type) {
	case *syntax.Ident:
		d.line(p, depth, "Param required "+p.Name)
	case *syntax.BinaryExpr:
		d.line(p, depth, "Param optional "+p.X.(*syntax.Ident).Name)
		d.node(p.Y, depth+1)
	case *syntax.UnaryExpr:
		switch {
		case p.Op == syntax.STARSTAR:
			d.line(p, depth, "Param kwargs "+p.X.(*syntax.Ident).Name)
		case p.X == nil:
			d.line(p, depth, "Param star")
		default:
			d.line(p, depth, "Param args "+p.X.(*syntax.Ident).Name)
		}
	default:
		d.label(depth, fmt.Sprintf("UNKNOWN param %T", p))
	}
}

// arg converts starlark-go's encoding of call arguments into Arg lines.
func (d dumper) arg(a syntax.Expr, depth int) {
	switch x := a.(type) {
	case *syntax.BinaryExpr:
		if x.Op == syntax.EQ {
			d.line(x, depth, "Arg keyword "+x.X.(*syntax.Ident).Name)
			d.node(x.Y, depth+1)
			return
		}
	case *syntax.UnaryExpr:
		if x.Op == syntax.STAR || x.Op == syntax.STARSTAR {
			kind := "args"
			if x.Op == syntax.STARSTAR {
				kind = "kwargs"
			}
			d.line(x, depth, "Arg "+kind)
			d.node(x.X, depth+1)
			return
		}
	}
	d.line(a, depth, "Arg positional")
	d.node(a, depth+1)
}

func literal(n *syntax.Literal) string {
	switch n.Token {
	case syntax.INT:
		switch v := n.Value.(type) {
		case int64:
			return fmt.Sprintf("int %d", v)
		case *big.Int:
			return "int " + v.String()
		}
	case syntax.FLOAT:
		return fmt.Sprintf("float %016x", math.Float64bits(n.Value.(float64)))
	case syntax.STRING:
		return "string " + quote(n.Value.(string))
	case syntax.BYTES:
		return "bytes " + quote(n.Value.(string))
	}
	return fmt.Sprintf("UNKNOWN %v", n.Value)
}

// quote prints printable ASCII as is and every other byte as \xHH,
// like the lexer oracle.
func quote(s string) string {
	out := []byte{'"'}
	for _, c := range []byte(s) {
		if c >= 0x20 && c < 0x7f && c != '"' && c != '\\' {
			out = append(out, c)
		} else {
			out = append(out, fmt.Sprintf("\\x%02x", c)...)
		}
	}
	return string(append(out, '"'))
}
