// Command resolvedump prints starlark-go's name resolution for one file in
// the oracle format described in tools/oracle/README.md.
// tools/oracle/setup copies it into starlark-go as cmd/resolvedump.
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"

	"go.starlark.net/resolve"
	"go.starlark.net/syntax"
)

// The spec's builtins. Keep in sync with tools/oracle/README.md.
var universal = names("None True False abs any all bool bytes dict dir enumerate fail float getattr hasattr hash int len list max min print range repr reversed set sorted str tuple type zip")

// Names the host adds. The conformance tests use these. The fuzzer replaces
// them through STARLARK_ORACLE_PREDECLARED, a space-separated list.
var predeclared = names(predeclaredList())

func predeclaredList() string {
	if list, ok := os.LookupEnv("STARLARK_ORACLE_PREDECLARED"); ok {
		return list
	}
	return "assert_eq assert_ne assert_"
}

func names(s string) map[string]bool {
	m := map[string]bool{}
	for _, n := range strings.Fields(s) {
		m[n] = true
	}
	return m
}

type entry struct {
	pos  syntax.Position
	text []string
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: resolvedump FILE")
		os.Exit(2)
	}
	src, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()

	// Set is on because set is a spec builtin. All other dialect options stay
	// off, which matches the spec: no while, no top-level if or for, no
	// global reassignment, and file-local load bindings.
	// The file is parsed under a fixed name, because some messages include
	// it, such as "cannot reassign global x declared at input.star:3:1".
	f, err := (&syntax.FileOptions{Set: true}).Parse("input.star", src, 0)
	if err != nil {
		if e, ok := err.(syntax.Error); ok {
			fmt.Fprintf(w, "%d:%d ERROR %s\n", e.Pos.Line, e.Pos.Col, e.Msg)
			return
		}
		w.Flush()
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	err = resolve.File(f, func(n string) bool { return predeclared[n] }, func(n string) bool { return universal[n] })
	if err != nil {
		list, ok := err.(resolve.ErrorList)
		if !ok {
			w.Flush()
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		for _, e := range list {
			fmt.Fprintf(w, "%d:%d ERROR %s\n", e.Pos.Line, e.Pos.Col, e.Msg)
		}
		return
	}

	module := f.Module.(*resolve.Module)
	fmt.Fprintf(w, "module\n  locals: %s\n  globals: %s\n", bindingNames(module.Locals), bindingNames(module.Globals))

	// Identifiers that declare a name without being an expression: def
	// names, parameters, load names, attribute names, and keyword argument
	// names. The function headers cover the declarations.
	skip := map[*syntax.Ident]bool{}
	var entries []entry
	syntax.Walk(f, func(n syntax.Node) bool {
		switch n := n.(type) {
		case *syntax.DefStmt:
			skip[n.Name] = true
			skipParams(skip, n.Params)
			entries = append(entries, function(n.Def, n.Function.(*resolve.Function)))
		case *syntax.LambdaExpr:
			skipParams(skip, n.Params)
			entries = append(entries, function(n.Lambda, n.Function.(*resolve.Function)))
		case *syntax.LoadStmt:
			for i := range n.To {
				skip[n.To[i]] = true
				skip[n.From[i]] = true
			}
		case *syntax.DotExpr:
			skip[n.Name] = true
		case *syntax.CallExpr:
			for _, a := range n.Args {
				if b, ok := a.(*syntax.BinaryExpr); ok && b.Op == syntax.EQ {
					skip[b.X.(*syntax.Ident)] = true
				}
			}
		case *syntax.Ident:
			if !skip[n] {
				entries = append(entries, entry{n.NamePos, []string{ident(n)}})
			}
		}
		return true
	})

	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i].pos, entries[j].pos
		return a.Line < b.Line || (a.Line == b.Line && a.Col < b.Col)
	})
	for _, e := range entries {
		fmt.Fprintf(w, "%d:%d %s\n", e.pos.Line, e.pos.Col, e.text[0])
		for _, line := range e.text[1:] {
			fmt.Fprintf(w, "  %s\n", line)
		}
	}
}

func skipParams(skip map[*syntax.Ident]bool, params []syntax.Expr) {
	for _, p := range params {
		switch p := p.(type) {
		case *syntax.Ident:
			skip[p] = true
		case *syntax.BinaryExpr:
			skip[p.X.(*syntax.Ident)] = true
		case *syntax.UnaryExpr:
			if id, ok := p.X.(*syntax.Ident); ok {
				skip[id] = true
			}
		}
	}
}

func function(pos syntax.Position, fn *resolve.Function) entry {
	flags := []string{}
	if fn.HasVarargs {
		flags = append(flags, "varargs")
	}
	if fn.HasKwargs {
		flags = append(flags, "kwargs")
	}
	if fn.NumKwonlyParams > 0 {
		flags = append(flags, fmt.Sprintf("kwonly=%d", fn.NumKwonlyParams))
	}
	header := "function " + fn.Name
	if len(flags) > 0 {
		header += " " + strings.Join(flags, " ")
	}
	return entry{pos, []string{
		header,
		"locals: " + bindingNames(fn.Locals),
		"free: " + bindingNames(fn.FreeVars),
	}}
}

// bindingNames lists names in slot order. A trailing * marks a cell, a local
// that a nested function captures.
func bindingNames(bindings []*resolve.Binding) string {
	out := make([]string, len(bindings))
	for i, b := range bindings {
		out[i] = b.First.Name
		if b.Scope == resolve.Cell {
			out[i] += "*"
		}
	}
	return strings.Join(out, " ")
}

func ident(id *syntax.Ident) string {
	b, ok := id.Binding.(*resolve.Binding)
	if !ok || b == nil {
		return "Ident " + id.Name + " unresolved"
	}
	switch b.Scope {
	case resolve.Predeclared, resolve.Universal:
		return fmt.Sprintf("Ident %s %s", id.Name, b.Scope)
	}
	return fmt.Sprintf("Ident %s %s %d", id.Name, b.Scope, b.Index)
}
