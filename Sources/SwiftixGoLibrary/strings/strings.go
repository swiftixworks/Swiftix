package strings

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// The functions of this file are built on the searches the run-time library
// does natively (Index, Count, Split, Join, ContainsRune), so that a call
// costs VM instructions for each piece or each character it must look at
// and not for each byte of the string. A tail s[i:] is a copy in the VM;
// no loop here takes one for each step.

// lastRune decodes the character that ends s[:end], and its width: for
// bytes that end no character, utf8.RuneError and 1.
func lastRune(s string, end int) (rune, int) {
	start := end - 1
	if s[start] < utf8.RuneSelf {
		return rune(s[start]), 1
	}
	for start > 0 && start > end-utf8.UTFMax && s[start]&0xC0 == 0x80 {
		start--
	}
	r, width := utf8.DecodeRuneInString(s[start:end])
	if start+width != end {
		return utf8.RuneError, 1
	}
	return r, width
}

// runeAt decodes the character that begins at s[i], and its width.
func runeAt(s string, i int) (rune, int) {
	if s[i] < utf8.RuneSelf {
		return rune(s[i]), 1
	}
	return utf8.DecodeRuneInString(s[i:min(i+utf8.UTFMax, len(s))])
}

// Compare is -1, 0, or 1 as a sorts before, with, or after b by its bytes.
func Compare(a, b string) int {
	switch {
	case a == b:
		return 0
	case a < b:
		return -1
	}
	return 1
}

// Cut divides s at the first sep: what is before it, what is after it, and
// whether it is there at all. Without it, before is s.
func Cut(s, sep string) (before, after string, found bool) {
	at := strings.Index(s, sep)
	if at < 0 {
		return s, "", false
	}
	return s[:at], s[at+len(sep):], true
}

// CutPrefix is s without the prefix it begins with, and whether it did.
func CutPrefix(s, prefix string) (after string, found bool) {
	if strings.HasPrefix(s, prefix) {
		return s[len(prefix):], true
	}
	return s, false
}

// CutSuffix is s without the suffix it ends with, and whether it did.
func CutSuffix(s, suffix string) (before string, found bool) {
	if strings.HasSuffix(s, suffix) {
		return s[:len(s)-len(suffix)], true
	}
	return s, false
}

// ReplaceAll is s with every old replaced by new.
func ReplaceAll(s, old, new string) string { return Replace(s, old, new, -1) }

// Replace is s with the first n occurrences of old replaced by new, all of
// them when n is negative. An empty old is found before each character
// and at the end.
func Replace(s, old, new string, n int) string {
	if old == new || n == 0 {
		return s
	}
	found := strings.Count(s, old)
	if found == 0 {
		return s
	}
	if n < 0 || n > found {
		n = found
	}
	// The pieces between occurrences, joined by new where an occurrence
	// is replaced and by old where it stays.
	pieces := strings.Split(s, old)
	if old == "" {
		// The pieces are the characters. An occurrence is before each
		// and after the last, so n of them are around an empty piece
		// and the first n-1 characters.
		around := append([]string{""}, pieces[:n-1]...)
		return strings.Join(around, new) + new + strings.Join(pieces[n-1:], "")
	}
	if n == found {
		return strings.Join(pieces, new)
	}
	return strings.Join(pieces[:n], new) + new + strings.Join(pieces[n:], old)
}

// split is the work of the four Split functions that take a count or keep
// the separator: at most n pieces of s, all of them for a negative n, each
// but the last with sep after it when after is set.
func split(s, sep string, after bool, n int) []string {
	if n == 0 {
		return nil
	}
	pieces := strings.Split(s, sep)
	if sep == "" {
		// One piece for each character, none for an empty string.
		if n < 0 || n >= len(pieces) {
			return pieces
		}
	} else if n < 0 {
		n = len(pieces)
	} else if n > len(s)+1 {
		n = len(s) + 1
	}
	if after && sep != "" {
		for i := 0; i < len(pieces)-1 && i < n-1; i++ {
			pieces[i] += sep
		}
	}
	if n == len(pieces) && cap(pieces) == n {
		return pieces
	}
	// Go's result has room for n pieces, however many there are.
	limited := make([]string, n)
	if len(pieces) <= n {
		return limited[:copy(limited, pieces)]
	}
	copy(limited, pieces[:n-1])
	limited[n-1] = strings.Join(pieces[n-1:], sep)
	return limited
}

// SplitN is the pieces of s between separators, at most n of them: the
// last is then the rest of s. A negative n means all, and 0 none.
func SplitN(s, sep string, n int) []string { return split(s, sep, false, n) }

// SplitAfter is the pieces of s that each end with a separator, and what
// follows the last one.
func SplitAfter(s, sep string) []string { return split(s, sep, true, -1) }

// SplitAfterN is SplitAfter with a count as that of SplitN.
func SplitAfterN(s, sep string, n int) []string { return split(s, sep, true, n) }

// IndexAny is where the first character of s that is one of chars begins,
// or -1.
func IndexAny(s, chars string) int {
	if chars == "" {
		return -1
	}
	for i, r := range s {
		if strings.ContainsRune(chars, r) {
			return i
		}
	}
	return -1
}

// ContainsAny reports whether a character of chars is in s.
func ContainsAny(s, chars string) bool { return IndexAny(s, chars) >= 0 }

// LastIndexAny is where the last character of s that is one of chars
// begins, or -1.
func LastIndexAny(s, chars string) int {
	if chars == "" {
		return -1
	}
	for end := len(s); end > 0; {
		r, width := lastRune(s, end)
		end -= width
		if strings.ContainsRune(chars, r) {
			return end
		}
	}
	return -1
}

// LastIndexByte is the index of the last byte c of s, or -1.
func LastIndexByte(s string, c byte) int {
	if c < utf8.RuneSelf {
		// A byte of ASCII is a character, which a search finds whole.
		return strings.LastIndex(s, string(rune(c)))
	}
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// firstWhere is where the first character c of s with f(c) == want
// begins, or -1.
func firstWhere(s string, f func(rune) bool, want bool) int {
	for i, r := range s {
		if f(r) == want {
			return i
		}
	}
	return -1
}

// lastWhere is where the last character c of s with f(c) == want begins
// and ends, or -1 and 0.
func lastWhere(s string, f func(rune) bool, want bool) (start, end int) {
	for end = len(s); end > 0; end = start {
		r, width := lastRune(s, end)
		start = end - width
		if f(r) == want {
			return start, end
		}
	}
	return -1, 0
}

// IndexFunc is where the first character of s that satisfies f begins, or
// -1.
func IndexFunc(s string, f func(rune) bool) int { return firstWhere(s, f, true) }

// LastIndexFunc is where the last character of s that satisfies f begins,
// or -1.
func LastIndexFunc(s string, f func(rune) bool) int {
	start, _ := lastWhere(s, f, true)
	return start
}

// ContainsFunc reports whether a character of s satisfies f.
func ContainsFunc(s string, f func(rune) bool) bool { return firstWhere(s, f, true) >= 0 }

// TrimLeftFunc is s without the characters at its start that satisfy f.
func TrimLeftFunc(s string, f func(rune) bool) string {
	start := firstWhere(s, f, false)
	if start < 0 {
		return ""
	}
	return s[start:]
}

// TrimRightFunc is s without the characters at its end that satisfy f.
func TrimRightFunc(s string, f func(rune) bool) string {
	_, end := lastWhere(s, f, false)
	return s[:end]
}

// TrimFunc is s without the characters at its start and at its end that
// satisfy f.
func TrimFunc(s string, f func(rune) bool) string {
	return TrimRightFunc(TrimLeftFunc(s, f), f)
}

// TrimLeft is s without the characters at its start that are in cutset.
func TrimLeft(s, cutset string) string {
	if s == "" || cutset == "" {
		return s
	}
	for i, r := range s {
		if !strings.ContainsRune(cutset, r) {
			return s[i:]
		}
	}
	return ""
}

// TrimRight is s without the characters at its end that are in cutset.
func TrimRight(s, cutset string) string {
	if cutset == "" {
		return s
	}
	end := len(s)
	for end > 0 {
		r, width := lastRune(s, end)
		if !strings.ContainsRune(cutset, r) {
			break
		}
		end -= width
	}
	return s[:end]
}

// Trim is s without the characters at its start and at its end that are
// in cutset.
func Trim(s, cutset string) string {
	if s == "" || cutset == "" {
		return s
	}
	return TrimRight(TrimLeft(s, cutset), cutset)
}

// FieldsFunc is the runs of characters of s that do not satisfy f, which
// is asked once about each character, in order.
func FieldsFunc(s string, f func(rune) bool) []string {
	// Where each field begins and ends, one after the other.
	var bounds []int
	inside := false
	for i, r := range s {
		if f(r) == inside {
			bounds = append(bounds, i)
			inside = !inside
		}
	}
	if inside {
		bounds = append(bounds, len(s))
	}
	fields := make([]string, len(bounds)/2)
	for i := range fields {
		fields[i] = s[bounds[2*i]:bounds[2*i+1]]
	}
	return fields
}

// Map is s with each character replaced by what mapping makes of it, and
// dropped where that is negative.
func Map(mapping func(rune) rune, s string) string {
	var mapped []byte
	for _, r := range s {
		if to := mapping(r); to >= 0 {
			mapped = append(mapped, string(to)...)
		}
	}
	return string(mapped)
}

// titleCase is unicode.ToTitle: the upper case of r, but for the letters
// that are two letters in one, whose title case has only the first in
// upper case, and for Georgian, whose title case is the letter itself.
func titleCase(r rune) rune {
	switch {
	case r >= 0x1C4 && r <= 0x1CC:
		return r - (r-0x1C4)%3 + 1
	case r >= 0x1F1 && r <= 0x1F3:
		return 0x1F2
	case r >= 0x10D0 && r <= 0x10FA, r >= 0x10FD && r <= 0x10FF:
		return r
	}
	return unicode.ToUpper(r)
}

// ToTitle is s with every letter in its title case.
func ToTitle(s string) string {
	var mapped []byte
	for _, r := range s {
		mapped = append(mapped, string(titleCase(r))...)
	}
	return string(mapped)
}

// beginsWord reports whether a letter after r is the first of a word, as
// Title sees words: r is no letter, digit, or underscore, and is ASCII or
// white space.
func beginsWord(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_':
		return false
	case r < utf8.RuneSelf:
		return true
	case unicode.IsLetter(r), unicode.IsDigit(r):
		return false
	}
	return unicode.IsSpace(r)
}

// Title is s with the first letter of each word in title case.
//
// Deprecated: as in Go, its words are not those of Unicode.
func Title(s string) string {
	var mapped []byte
	before := ' '
	for _, r := range s {
		if beginsWord(before) {
			mapped = append(mapped, string(titleCase(r))...)
		} else {
			mapped = append(mapped, string(r)...)
		}
		before = r
	}
	return string(mapped)
}

// folded is one character for all those that differ from r by case only:
// the lower case of the upper case, but for the two letters i of Turkish,
// which fold to nothing else.
func folded(r rune) rune {
	if r == 0x130 || r == 0x131 {
		return r
	}
	return unicode.ToLower(unicode.ToUpper(r))
}

// EqualFold reports whether s and t are equal but for the case of their
// letters, by Unicode's simple case folding.
func EqualFold(s, t string) bool {
	if s == t {
		return true
	}
	if utf8.RuneCountInString(s) == len(s) && utf8.RuneCountInString(t) == len(t) {
		// One byte to a character: letters of ASCII fold among
		// themselves alone, as ToLower maps them.
		return len(s) == len(t) && strings.ToLower(s) == strings.ToLower(t)
	}
	at := 0
	for _, a := range s {
		if at >= len(t) {
			return false
		}
		b, width := runeAt(t, at)
		at += width
		if a != b && folded(a) != folded(b) {
			return false
		}
	}
	return at == len(t)
}
