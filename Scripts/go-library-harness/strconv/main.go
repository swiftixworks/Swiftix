// Drives the strconv of the run-time library's Go text and Go's own strconv
// with the same inputs and compares what they return: for Unquote, every
// literal Go's Quote functions make and random texts of quotes, escapes,
// digits, and bytes that are no UTF-8, which are mostly no literals at all.
//
// Run by ../run.sh, which puts the library's files beside this one.
package main

import (
	"errors"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"

	library "example/harness/strconv"
)

var failures int

func fail(format string, args ...any) {
	failures++
	if failures <= 40 {
		fmt.Printf("DIFFERS: "+format+"\n", args...)
	}
}

var pieces = []string{
	"\"", "\"", "'", "'", "`", "\\", "\\", "\\\\", "\\\"", "\\'", "\\n", "\\x", "\\u", "\\U", "\\0", "\\3", "\\7", "\\8",
	"0", "1", "7", "9", "a", "f", "F", "g", "0000", "D800", "0010FFFF", "00110000", "41", "ff", "377", "400",
	"\n", "\r", "\t", " ", "é", "世", "\xff", "\xc3", "\U0001F600", "x", "\\a", "\\v", "\\e", "\x00", "\x7f",
}

func text(rng *rand.Rand, most int) string {
	var b strings.Builder
	for n := rng.Intn(most + 1); n > 0; n-- {
		b.WriteString(pieces[rng.Intn(len(pieces))])
	}
	return b.String()
}

func unquote(s string) {
	got, err1 := library.Unquote(s)
	want, err2 := strconv.Unquote(s)
	if got != want || (err1 == nil) != (err2 == nil) || err1 != nil && (err1 != library.ErrSyntax || err2 != strconv.ErrSyntax) {
		fail("Unquote(%q): text %q %v, Go %q %v", s, got, err1, want, err2)
	}
}

func main() {
	rng := rand.New(rand.NewSource(1))
	for round := 0; round < 1500000; round++ {
		s := text(rng, 6)
		unquote(s)
		quote := []string{"\"", "'", "`"}[rng.Intn(3)]
		unquote(quote + s + quote)
		unquote(strconv.Quote(s))
		unquote(strconv.QuoteToASCII(s))
		unquote(strconv.QuoteToGraphic(s))
		for _, r := range s {
			unquote(strconv.QuoteRune(r))
			unquote(strconv.QuoteRuneToASCII(r))
		}
		if strconv.CanBackquote(s) {
			unquote("`" + s + "`")
		}
		if got, want := library.Quote(s), strconv.Quote(s); got != want {
			fail("Quote(%q): text %s, Go %s", s, got, want)
		}
		if got, want := library.QuoteToASCII(s), strconv.QuoteToASCII(s); got != want {
			fail("QuoteToASCII(%q): text %s, Go %s", s, got, want)
		}
		prefix := []byte(text(rng, 2))
		if got, want := string(library.AppendQuote(prefix, s)), string(strconv.AppendQuote(prefix, s)); got != want {
			fail("AppendQuote(%q): text %s, Go %s", s, got, want)
		}
		i, base := rng.Int63()>>uint(rng.Intn(64))*int64(1-2*rng.Intn(2)), 2+rng.Intn(35)
		if got, want := string(library.AppendInt(prefix, i, base)), string(strconv.AppendInt(prefix, i, base)); got != want {
			fail("AppendInt(%d, %d): text %s, Go %s", i, base, got, want)
		}
	}
	numbers := []string{"", "0", "12", "-12", "+7", "x", "1x", "0x1f", "0b101", "0o17", "017", "1_000", "_1", "300", "-129", "255", "256",
		"9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "18446744073709551615",
		"18446744073709551616", "99999999999999999999", "1.5", "1e400", "-1e400", "1e-400", "inf", "-Inf", "NaN", "3.4e39",
		"0x1p-2", "1e", ".", "１", "\"q\"", "é"}
	sameError := func(name string, got, want error) {
		if (got == nil) != (want == nil) {
			fail("%s: text %v, Go %v", name, got, want)
			return
		}
		if got == nil {
			return
		}
		var mine *library.NumError
		var real *strconv.NumError
		if !errors.As(got, &mine) || !errors.As(want, &real) || got.Error() != want.Error() || mine.Func != real.Func ||
			mine.Num != real.Num || (real.Err == strconv.ErrSyntax) != (mine.Err == library.ErrSyntax) ||
			(real.Err == strconv.ErrRange) != (mine.Err == library.ErrRange) || mine.Err.Error() != real.Err.Error() {
			fail("%s: text %#v, Go %#v", name, got, want)
		}
	}
	for _, s := range numbers {
		a, e1 := library.Atoi(s)
		b, e2 := strconv.Atoi(s)
		if a != b {
			fail("Atoi(%q): text %d, Go %d", s, a, b)
		}
		sameError(fmt.Sprintf("Atoi(%q)", s), e1, e2)
		for _, base := range []int{0, 2, 8, 10, 16, 36, 1, 37} {
			for _, size := range []int{0, 8, 16, 32, 64, 65, -1} {
				i, e1 := library.ParseInt(s, base, size)
				j, e2 := strconv.ParseInt(s, base, size)
				if i != j {
					fail("ParseInt(%q, %d, %d): text %d, Go %d", s, base, size, i, j)
				}
				sameError(fmt.Sprintf("ParseInt(%q, %d, %d)", s, base, size), e1, e2)
				u, e1 := library.ParseUint(s, base, size)
				v, e2 := strconv.ParseUint(s, base, size)
				if u != v {
					fail("ParseUint(%q, %d, %d): text %d, Go %d", s, base, size, u, v)
				}
				sameError(fmt.Sprintf("ParseUint(%q, %d, %d)", s, base, size), e1, e2)
			}
		}
		for _, size := range []int{32, 64} {
			f, e1 := library.ParseFloat(s, size)
			g, e2 := strconv.ParseFloat(s, size)
			if fmt.Sprint(f) != fmt.Sprint(g) {
				fail("ParseFloat(%q, %d): text %v, Go %v", s, size, f, g)
			}
			sameError(fmt.Sprintf("ParseFloat(%q, %d)", s, size), e1, e2)
		}
	}
	for _, s := range []string{"1", "t", "T", "TRUE", "true", "True", "0", "f", "F", "FALSE", "false", "False", "", "tRUE", "yes", "2", "truE", " true", "é\"\n"} {
		got, err1 := library.ParseBool(s)
		want, err2 := strconv.ParseBool(s)
		same := got == want && (err1 == nil) == (err2 == nil)
		if err1 != nil && err2 != nil {
			var mine *library.NumError
			var real *strconv.NumError
			same = same && err1.Error() == err2.Error() && errors.As(err1, &mine) && errors.As(err2, &real) &&
				mine.Func == real.Func && mine.Num == real.Num && errors.Is(err1, library.ErrSyntax) && real.Err == strconv.ErrSyntax
		}
		if !same {
			fail("ParseBool(%q): text %v %v, Go %v %v", s, got, err1, want, err2)
		}
	}
	if library.FormatBool(true) != strconv.FormatBool(true) || library.FormatBool(false) != strconv.FormatBool(false) {
		fail("FormatBool")
	}
	if library.ErrSyntax.Error() != strconv.ErrSyntax.Error() || library.ErrRange.Error() != strconv.ErrRange.Error() {
		fail("the texts of ErrSyntax and ErrRange")
	}
	if failures > 0 {
		fmt.Println(failures, "differences")
		os.Exit(1)
	}
	fmt.Println("strconv: the text and Go agree")
}
