// Command evaldump runs one file with starlark-go and prints the result in
// the oracle format described in tools/oracle/README.md.
// tools/oracle/setup copies it into starlark-go as cmd/evaldump.
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"

	"go.starlark.net/resolve"
	"go.starlark.net/starlark"
	"go.starlark.net/syntax"
)

// Builtins that starlark-go has and the spec does not. Removing them keeps
// programs that use them from passing here and failing in our interpreter.
var notInSpec = []string{"chr", "ord"}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: evaldump FILE")
		os.Exit(2)
	}
	src, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()

	for _, name := range notInSpec {
		delete(starlark.Universe, name)
	}

	thread := &starlark.Thread{
		Name: "main",
		Print: func(_ *starlark.Thread, msg string) {
			fmt.Fprintf(w, "print %s\n", escape(msg))
		},
	}
	predeclared := starlark.StringDict{
		"assert_eq": starlark.NewBuiltin("assert_eq", assertEq),
		"assert_ne": starlark.NewBuiltin("assert_ne", assertNe),
		"assert_":   starlark.NewBuiltin("assert_", assertTrue),
	}

	// Set is on because set is a spec builtin. All other dialect options stay
	// off, which matches the spec.
	opts := &syntax.FileOptions{Set: true}
	globals, err := starlark.ExecFileOptions(opts, thread, "input.star", src, predeclared)
	if err != nil {
		fmt.Fprintf(w, "ERROR %s\n", escape(message(err)))
		return
	}

	names := make([]string, 0, len(globals))
	for name := range globals {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Fprintf(w, "global %s = %s\n", name, escape(globals[name].String()))
	}
}

// message returns an error's text without file positions or a backtrace.
func message(err error) string {
	switch err := err.(type) {
	case *starlark.EvalError:
		return err.Msg
	case syntax.Error:
		return err.Msg
	case resolve.ErrorList:
		return err[0].Msg
	}
	return err.Error()
}

// escape keeps each record on one line.
func escape(s string) string {
	return strings.NewReplacer(`\`, `\\`, "\n", `\n`).Replace(s)
}

func assertEq(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x, y starlark.Value
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &x, &y); err != nil {
		return nil, err
	}
	if ok, err := starlark.Equal(x, y); err != nil {
		return nil, err
	} else if !ok {
		return nil, fmt.Errorf("%s != %s", x.String(), y.String())
	}
	return starlark.None, nil
}

func assertNe(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x, y starlark.Value
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &x, &y); err != nil {
		return nil, err
	}
	if ok, err := starlark.Equal(x, y); err != nil {
		return nil, err
	} else if ok {
		return nil, fmt.Errorf("%s == %s", x.String(), y.String())
	}
	return starlark.None, nil
}

func assertTrue(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var cond starlark.Value
	msg := "assertion failed"
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &cond, &msg); err != nil {
		return nil, err
	}
	if !cond.Truth() {
		return nil, fmt.Errorf("%s", msg)
	}
	return starlark.None, nil
}
