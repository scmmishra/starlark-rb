// Command unicodeletters prints the code point ranges that unicode.IsLetter
// accepts, one "FIRST LAST" pair of hex numbers per line. starlark-go's
// scanner uses unicode.IsLetter for identifiers. tools/fuzz compares these
// ranges with Ruby's \p{L}.
package main

import (
	"bufio"
	"fmt"
	"os"
	"unicode"
)

func main() {
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	start := -1
	for r := 0; r <= unicode.MaxRune+1; r++ {
		letter := r <= unicode.MaxRune && unicode.IsLetter(rune(r))
		if letter && start < 0 {
			start = r
		} else if !letter && start >= 0 {
			fmt.Fprintf(w, "%X %X\n", start, r-1)
			start = -1
		}
	}
}
