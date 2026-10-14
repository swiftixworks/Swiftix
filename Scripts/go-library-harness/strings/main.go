// Drives the strings of the run-time library's Go text and Go's own strings
// with the same inputs and compares what a program can see of them: the
// results with their lengths and capacities, the calls of every function
// they are given with their arguments, in order, and the calls a Replacer
// and a Reader make of the writer they are given.
//
// The inputs are random strings over a small alphabet, so that separators
// and prefixes are found often, with letters outside ASCII and, in half of
// the rounds, bytes that are no UTF-8, which the text must treat as Go
// does although a program of the dialect cannot make them.
//
// Run by ../run.sh, which puts the library's files beside this one.
package main

import (
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"reflect"
	"strings"
	"unicode"

	library "example/harness/strings"
)

var failures int

func fail(format string, args ...any) {
	failures++
	if failures <= 40 {
		fmt.Printf("DIFFERS: "+format+"\n", args...)
	}
}

func check(name string, got, want any, args ...any) {
	if !reflect.DeepEqual(got, want) {
		fail("%s%q: text %#v, Go %#v", name, args, got, want)
	}
}

// described is a slice of strings with what cap and a nil test show of it.
func described(a []string) string {
	return fmt.Sprintf("%q len %d cap %d nil %v", a, len(a), cap(a), a == nil)
}

var alphabets = [][]string{
	{"a", "b", "c", " ", ",", "A", "B"},
	{"a", "b", "é", "世", " ", "\t", "É", "K", "K", "ſ", "S", "s", "\U0001F600", "ǆ", "ა", "İ", "i", "ı", "I", " "},
	{"a", "b", "\xff", "\xc3", "\xa9", "é", "�", "世", "\xe4\xb8", " ", "A", "\xf0\x9f"},
}

func text(rng *rand.Rand, valid bool, most int) string {
	alphabet := alphabets[rng.Intn(len(alphabets))]
	if valid && len(alphabet) == len(alphabets[2]) {
		alphabet = alphabets[1]
	}
	var b strings.Builder
	for n := rng.Intn(most + 1); n > 0; n-- {
		b.WriteString(alphabet[rng.Intn(len(alphabet))])
	}
	return b.String()
}

// asked records the characters a function of the text or of Go was asked
// about.
type asked struct{ log []rune }

func (a *asked) is(set string) func(rune) bool {
	return func(r rune) bool {
		a.log = append(a.log, r)
		return strings.ContainsRune(set, r)
	}
}

func (a *asked) to(rng int) func(rune) rune {
	return func(r rune) rune {
		a.log = append(a.log, r)
		switch (int(r) + rng) % 7 {
		case 0:
			return -1
		case 1:
			return r + 1
		case 2:
			return 0xD800
		case 3:
			return unicode.MaxRune + 5
		case 4:
			return 'x'
		}
		return r
	}
}

// writer records every call, takes at most limit bytes, and then fails.
type writer struct {
	log   []string
	limit int
	short bool
}

func (w *writer) take(kind string, n int, p string) (int, error) {
	w.log = append(w.log, kind+p)
	if w.limit < n {
		taken := w.limit
		w.limit = 0
		if w.short {
			return taken, nil
		}
		return taken, errors.New("full")
	}
	w.limit -= n
	return n, nil
}

func (w *writer) Write(p []byte) (int, error) { return w.take("W:", len(p), string(p)) }

// stringWriter has WriteString too.
type stringWriter struct{ writer }

func (w *stringWriter) WriteString(s string) (int, error) { return w.take("S:", len(s), s) }

func message(err error) string {
	if err == nil {
		return "<nil>"
	}
	return err.Error()
}

func caught(f func()) (text string) {
	defer func() {
		if r := recover(); r != nil {
			text = fmt.Sprint(r)
		}
	}()
	f()
	return ""
}

func functions(rng *rand.Rand, valid bool) {
	s, t, u := text(rng, valid, 12), text(rng, valid, 3), text(rng, valid, 3)
	n := rng.Intn(8) - 2
	check("Compare", library.Compare(s, t), strings.Compare(s, t), s, t)
	{
		a, b, c := library.Cut(s, t)
		x, y, z := strings.Cut(s, t)
		check("Cut", []any{a, b, c}, []any{x, y, z}, s, t)
	}
	{
		a, b := library.CutPrefix(s, t)
		x, y := strings.CutPrefix(s, t)
		check("CutPrefix", []any{a, b}, []any{x, y}, s, t)
		a, b = library.CutSuffix(s, t)
		x, y = strings.CutSuffix(s, t)
		check("CutSuffix", []any{a, b}, []any{x, y}, s, t)
	}
	check("Replace", library.Replace(s, t, u, n), strings.Replace(s, t, u, n), s, t, u, n)
	check("ReplaceAll", library.ReplaceAll(s, t, u), strings.ReplaceAll(s, t, u), s, t, u)
	check("SplitN", described(library.SplitN(s, t, n)), described(strings.SplitN(s, t, n)), s, t, n)
	check("SplitAfter", described(library.SplitAfter(s, t)), described(strings.SplitAfter(s, t)), s, t)
	check("SplitAfterN", described(library.SplitAfterN(s, t, n)), described(strings.SplitAfterN(s, t, n)), s, t, n)
	check("IndexAny", library.IndexAny(s, t), strings.IndexAny(s, t), s, t)
	check("ContainsAny", library.ContainsAny(s, t), strings.ContainsAny(s, t), s, t)
	check("LastIndexAny", library.LastIndexAny(s, t), strings.LastIndexAny(s, t), s, t)
	for _, c := range []byte{'a', ' ', 0xff, 0xa9, 0xc3, byte(rng.Intn(256))} {
		check("LastIndexByte", library.LastIndexByte(s, c), strings.LastIndexByte(s, c), s, c)
	}
	check("Trim", library.Trim(s, t), strings.Trim(s, t), s, t)
	check("TrimLeft", library.TrimLeft(s, t), strings.TrimLeft(s, t), s, t)
	check("TrimRight", library.TrimRight(s, t), strings.TrimRight(s, t), s, t)
	check("ToTitle", library.ToTitle(s), strings.ToTitle(s), s)
	check("Title", library.Title(s), strings.Title(s), s)
	check("EqualFold", library.EqualFold(s, t), strings.EqualFold(s, t), s, t)
	folded := strings.Map(func(r rune) rune {
		if rng.Intn(2) == 0 {
			return unicode.SimpleFold(r)
		}
		return r
	}, s)
	if !valid {
		folded = s[:rng.Intn(len(s)+1)] + strings.ToUpper(s[rng.Intn(len(s)+1):])
	}
	check("EqualFold", library.EqualFold(s, folded), strings.EqualFold(s, folded), s, folded)
	check("EqualFold", library.EqualFold(folded, s+t), strings.EqualFold(folded, s+t), folded, s+t)

	type predicate struct {
		name string
		text func(string, func(rune) bool) any
		real func(string, func(rune) bool) any
	}
	for _, p := range []predicate{
		{"IndexFunc", func(s string, f func(rune) bool) any { return library.IndexFunc(s, f) }, func(s string, f func(rune) bool) any { return strings.IndexFunc(s, f) }},
		{"LastIndexFunc", func(s string, f func(rune) bool) any { return library.LastIndexFunc(s, f) }, func(s string, f func(rune) bool) any { return strings.LastIndexFunc(s, f) }},
		{"ContainsFunc", func(s string, f func(rune) bool) any { return library.ContainsFunc(s, f) }, func(s string, f func(rune) bool) any { return strings.ContainsFunc(s, f) }},
		{"TrimFunc", func(s string, f func(rune) bool) any { return library.TrimFunc(s, f) }, func(s string, f func(rune) bool) any { return strings.TrimFunc(s, f) }},
		{"TrimLeftFunc", func(s string, f func(rune) bool) any { return library.TrimLeftFunc(s, f) }, func(s string, f func(rune) bool) any { return strings.TrimLeftFunc(s, f) }},
		{"TrimRightFunc", func(s string, f func(rune) bool) any { return library.TrimRightFunc(s, f) }, func(s string, f func(rune) bool) any { return strings.TrimRightFunc(s, f) }},
		{"FieldsFunc", func(s string, f func(rune) bool) any { return described(library.FieldsFunc(s, f)) }, func(s string, f func(rune) bool) any { return described(strings.FieldsFunc(s, f)) }},
	} {
		var mine, real asked
		check(p.name, p.text(s, mine.is(t)), p.real(s, real.is(t)), s, t)
		check(p.name+" calls", mine.log, real.log, s, t)
	}
	var mine, real asked
	check("Map", library.Map(mine.to(n), s), strings.Map(real.to(n), s), s, n)
	check("Map calls", mine.log, real.log, s, n)
}

func replacers(rng *rand.Rand, valid bool) {
	var pairs []string
	count := rng.Intn(5)
	shape := rng.Intn(5)
	for i := 0; i < 2*count; i++ {
		var p string
		switch shape {
		case 0: // bytes for bytes
			p = string(rune('a' + rng.Intn(3)))
		case 1: // bytes for strings
			if p = string(rune('a' + rng.Intn(3))); i%2 == 1 {
				p = text(rng, valid, 2)
			}
		case 2: // nothing empty
			if p = text(rng, valid, 3); p == "" && i%2 == 0 {
				p = "b"
			}
		default:
			p = text(rng, valid, 3)
		}
		pairs = append(pairs, p)
	}
	s := text(rng, valid, 14)
	mine, real := library.NewReplacer(pairs...), strings.NewReplacer(pairs...)
	check("Replacer.Replace", mine.Replace(s), real.Replace(s), pairs, s)
	limit := 1 << 20
	if rng.Intn(3) == 0 {
		limit = rng.Intn(2 * (len(s) + 1))
	}
	short := rng.Intn(2) == 0
	{
		a, b := &writer{limit: limit, short: short}, &writer{limit: limit, short: short}
		n1, err1 := mine.WriteString(a, s)
		n2, err2 := real.WriteString(b, s)
		check("Replacer.WriteString", []any{n1, message(err1), a.log}, []any{n2, message(err2), b.log}, pairs, s, limit, short)
	}
	{
		a, b := &stringWriter{writer{limit: limit, short: short}}, &stringWriter{writer{limit: limit, short: short}}
		n1, err1 := mine.WriteString(a, s)
		n2, err2 := real.WriteString(b, s)
		check("Replacer.WriteString to a StringWriter", []any{n1, message(err1), a.log}, []any{n2, message(err2), b.log}, pairs, s, limit, short)
	}
}

func builders(rng *rand.Rand, valid bool) {
	var mine library.Builder
	var real strings.Builder
	for step := rng.Intn(20); step > 0; step-- {
		s := text(rng, valid, 6)
		var a, b []any
		switch rng.Intn(8) {
		case 0:
			n1, err1 := mine.WriteString(s)
			n2, err2 := real.WriteString(s)
			a, b = []any{n1, err1}, []any{n2, err2}
		case 1:
			n1, err1 := mine.Write([]byte(s))
			n2, err2 := real.Write([]byte(s))
			a, b = []any{n1, err1}, []any{n2, err2}
		case 2:
			c := byte(rng.Intn(256))
			a, b = []any{mine.WriteByte(c)}, []any{real.WriteByte(c)}
		case 3:
			r := []rune{'a', 'é', '世', -1, 0xD800, unicode.MaxRune + 1, 0x1F600}[rng.Intn(7)]
			n1, err1 := mine.WriteRune(r)
			n2, err2 := real.WriteRune(r)
			a, b = []any{n1, err1}, []any{n2, err2}
		case 4:
			n := rng.Intn(40) - 2
			a = []any{caught(func() { mine.Grow(n) }), n < 0 || mine.Cap()-mine.Len() >= n}
			b = []any{caught(func() { real.Grow(n) }), n < 0 || real.Cap()-real.Len() >= n}
		case 5:
			if rng.Intn(4) == 0 {
				mine.Reset()
				real.Reset()
			}
		case 6:
			// A copy of a Builder that was written to panics when
			// written to; a copy of an empty one does not.
			mineCopy, realCopy := mine, real
			a = []any{caught(func() { mineCopy.WriteString(s) }), mineCopy.String()}
			b = []any{caught(func() { realCopy.WriteString(s) }), realCopy.String()}
		}
		check("Builder step", a, b, s)
		check("Builder", []any{mine.String(), mine.Len(), mine.Cap() >= mine.Len()}, []any{real.String(), real.Len(), real.Cap() >= real.Len()})
	}
}

func readers(rng *rand.Rand, valid bool) {
	s := text(rng, valid, 10)
	mine, real := library.NewReader(s), strings.NewReader(s)
	if rng.Intn(8) == 0 {
		mine, real = &library.Reader{}, &strings.Reader{}
	}
	for step := rng.Intn(24); step > 0; step-- {
		var a, b []any
		op := rng.Intn(10)
		switch op {
		case 0:
			p, q := make([]byte, rng.Intn(5)), make([]byte, 5)
			q = q[:len(p)]
			n1, err1 := mine.Read(p)
			n2, err2 := real.Read(q)
			a, b = []any{n1, err1, p}, []any{n2, err2, q}
		case 1:
			off := int64(rng.Intn(14) - 2)
			p, q := make([]byte, rng.Intn(5)), make([]byte, 5)
			q = q[:len(p)]
			n1, err1 := mine.ReadAt(p, off)
			n2, err2 := real.ReadAt(q, off)
			a, b = []any{n1, message(err1), p}, []any{n2, message(err2), q}
		case 2:
			c1, err1 := mine.ReadByte()
			c2, err2 := real.ReadByte()
			a, b = []any{c1, err1}, []any{c2, err2}
		case 3:
			a, b = []any{message(mine.UnreadByte())}, []any{message(real.UnreadByte())}
		case 4, 5:
			r1, n1, err1 := mine.ReadRune()
			r2, n2, err2 := real.ReadRune()
			a, b = []any{r1, n1, err1}, []any{r2, n2, err2}
		case 6:
			a, b = []any{message(mine.UnreadRune())}, []any{message(real.UnreadRune())}
		case 7:
			offset, whence := int64(rng.Intn(16)-6), rng.Intn(4)
			n1, err1 := mine.Seek(offset, whence)
			n2, err2 := real.Seek(offset, whence)
			a, b = []any{n1, message(err1)}, []any{n2, message(err2)}
		case 8:
			limit := rng.Intn(2 * (len(s) + 1))
			short := rng.Intn(2) == 0
			var w1, w2 io.Writer = &writer{limit: limit, short: short}, &writer{limit: limit, short: short}
			if rng.Intn(2) == 0 {
				w1, w2 = &stringWriter{writer{limit: limit, short: short}}, &stringWriter{writer{limit: limit, short: short}}
			}
			n1, err1 := mine.WriteTo(w1)
			n2, err2 := real.WriteTo(w2)
			a, b = []any{n1, message(err1), fmt.Sprint(w1)}, []any{n2, message(err2), fmt.Sprint(w2)}
		case 9:
			if rng.Intn(4) == 0 {
				s = text(rng, valid, 10)
				mine.Reset(s)
				real.Reset(s)
			}
		}
		check("Reader step", a, b, s, op)
		check("Reader", []any{mine.Len(), mine.Size()}, []any{real.Len(), real.Size()}, s, op)
	}
}

// everyCharacter holds the text to Go for each code point by itself: its
// title case, and what it equals but for case.
func everyCharacter() {
	for r := rune(0); r <= unicode.MaxRune; r++ {
		s := string(r)
		if got, want := library.ToTitle(s), strings.ToTitle(s); got != want {
			fail("ToTitle(%U): text %q, Go %q", r, got, want)
		}
		if got, want := library.Title("a "+s+s), strings.Title("a "+s+s); got != want {
			fail("Title(%U): text %q, Go %q", r, got, want)
		}
		for _, other := range []rune{unicode.SimpleFold(r), unicode.ToUpper(r), unicode.ToLower(r), unicode.ToTitle(r), r + 1, r ^ 0x20, 'i', 'I', 'k', 's'} {
			t := string(other)
			if got, want := library.EqualFold(s, t), strings.EqualFold(s, t); got != want {
				fail("EqualFold(%U, %U): text %v, Go %v", r, other, got, want)
			}
			if got, want := library.EqualFold("x"+t+"é", "X"+s+"É"), strings.EqualFold("x"+t+"é", "X"+s+"É"); got != want {
				fail("EqualFold inside (%U, %U): text %v, Go %v", r, other, got, want)
			}
		}
	}
}

func main() {
	rng := rand.New(rand.NewSource(1))
	for round := 0; round < 400000; round++ {
		valid := round%2 == 0
		functions(rng, valid)
		replacers(rng, valid)
		if round%4 < 2 {
			builders(rng, valid)
			readers(rng, valid)
		}
	}
	check("NewReplacer with a string alone", caught(func() { library.NewReplacer("a") }), caught(func() { strings.NewReplacer("a") }))
	everyCharacter()
	if failures > 0 {
		fmt.Println(failures, "differences")
		os.Exit(1)
	}
	fmt.Println("strings: the text and Go agree")
}
