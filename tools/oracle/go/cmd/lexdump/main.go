// Command lexdump prints starlark-go's tokens for one file.
// tools/oracle/setup copies it into starlark-go as cmd/lexdump.
package main

import (
	"bufio"
	"fmt"
	"os"

	"go.starlark.net/syntax"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: lexdump FILE")
		os.Exit(2)
	}
	src, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	if err := syntax.LexDump(os.Args[1], src, w); err != nil {
		w.Flush()
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
