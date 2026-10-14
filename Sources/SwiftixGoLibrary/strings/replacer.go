package strings

import (
	"io"
	"strings"
)

// A Replacer replaces each of a list of strings by the string that is paired
// with it. It looks for them at one place of the text after another, from
// the start, and where several are found at one place it takes the one
// that came first among the arguments. What it has replaced is not looked
// at again.
type Replacer struct {
	olds, news []string
	how        int
	// starts[b] is set when an old string begins with the byte b; nil
	// when one of them is empty, which is found everywhere.
	starts []bool
}

// How a Replacer writes, which is all that tells Go's four algorithms
// apart: the text between two replacements and the replacements are
// written as they are found, each with a call of its own.
const (
	// One pair, of an old string longer than a byte.
	replacesOneString = iota
	// Every old string is one byte and so is every new one: a byte that
	// is replaced by itself is not found at all.
	replacesBytes
	// Every old string is one byte.
	replacesBytesByStrings
	// Anything else.
	replacesStrings
)

// NewReplacer returns a Replacer of the pairs oldnew: an old string, then
// what replaces it. A string without its pair panics.
func NewReplacer(oldnew ...string) *Replacer {
	if len(oldnew)%2 == 1 {
		panic("strings.NewReplacer: odd argument count")
	}
	r := &Replacer{how: replacesBytes}
	if len(oldnew) == 2 && len(oldnew[0]) > 1 {
		r.how = replacesOneString
	}
	seen := make([]bool, 256)
	r.starts = make([]bool, 256)
	for i := 0; i < len(oldnew); i += 2 {
		old, new := oldnew[i], oldnew[i+1]
		switch {
		case r.how == replacesOneString:
		case len(old) != 1:
			r.how = replacesStrings
		case len(new) != 1 && r.how == replacesBytes:
			r.how = replacesBytesByStrings
		}
		if old == "" {
			r.starts = nil
		} else if r.starts != nil {
			r.starts[old[0]] = true
		}
		r.olds = append(r.olds, old)
		r.news = append(r.news, new)
	}
	if r.how != replacesBytes {
		return r
	}
	// The first pair of a byte decides, also that it stays what it is.
	for i, old := range r.olds {
		if !seen[old[0]] && old == r.news[i] {
			r.starts[old[0]] = false
		}
		seen[old[0]] = true
	}
	return r
}

// match is the pair whose old string is at s[i:], the first of them, or
// -1. An empty old string is not found when skipEmpty is set.
func (r *Replacer) match(s string, i int, skipEmpty bool) int {
	for k, old := range r.olds {
		end := i + len(old)
		if end > len(s) || end == i && skipEmpty {
			continue
		}
		if end == i || s[i] == old[0] && s[i:end] == old {
			return k
		}
	}
	return -1
}

// each calls kept with every stretch of s that stays and replaced with
// what replaces every string found, in order, as the algorithm of Go that
// r.how names writes them. It stops at the first error either returns.
func (r *Replacer) each(s string, kept, replaced func(string) error) error {
	if r.how == replacesOneString {
		pieces := strings.Split(s, r.olds[0])
		for _, piece := range pieces[:len(pieces)-1] {
			if err := kept(piece); err != nil {
				return err
			}
			if err := replaced(r.news[0]); err != nil {
				return err
			}
		}
		return kept(pieces[len(pieces)-1])
	}
	bytes := r.how != replacesStrings
	last := 0
	afterEmpty := false
	for i := 0; i <= len(s); {
		k := -1
		if r.starts == nil || i < len(s) && r.starts[s[i]] {
			k = r.match(s, i, afterEmpty)
		}
		if k < 0 {
			afterEmpty = false
			i++
			continue
		}
		afterEmpty = r.olds[k] == ""
		// Go's byte algorithms write no empty stretch; the general
		// one writes every stretch.
		if !bytes || last != i {
			if err := kept(s[last:i]); err != nil {
				return err
			}
		}
		if err := replaced(r.news[k]); err != nil {
			return err
		}
		i += len(r.olds[k])
		last = i
	}
	if last != len(s) {
		return kept(s[last:])
	}
	return nil
}

// Replace is s with every replacement made.
func (r *Replacer) Replace(s string) string {
	var pieces []string
	add := func(piece string) error {
		pieces = append(pieces, piece)
		return nil
	}
	r.each(s, add, add)
	return strings.Join(pieces, "")
}

// WriteString writes s to w with every replacement made, and returns the
// number of bytes written and the first error of w.
func (r *Replacer) WriteString(w io.Writer, s string) (n int, err error) {
	sw, hasWriteString := w.(io.StringWriter)
	text := func(piece string) error {
		var wrote int
		var failure error
		if hasWriteString {
			wrote, failure = sw.WriteString(piece)
		} else {
			wrote, failure = w.Write([]byte(piece))
		}
		n += wrote
		return failure
	}
	replaced := text
	if r.how == replacesBytes || r.how == replacesBytesByStrings {
		// Go keeps the replacements of bytes as bytes, and writes them
		// so to a writer that takes strings too.
		replaced = func(piece string) error {
			wrote, failure := w.Write([]byte(piece))
			n += wrote
			return failure
		}
	}
	err = r.each(s, text, replaced)
	return n, err
}
