package bytes

import (
	"unicode"
	"unicode/utf8"
)

// Equal says whether a and b hold the same bytes. A nil slice equals an
// empty one.
func Equal(a, b []byte) bool { return native.equal(a, b) }

// Compare orders a and b byte by byte: -1 if a comes first, 1 if b does,
// 0 if they are equal. A nil slice is an empty one.
func Compare(a, b []byte) int { return native.compare(a, b) }

// Clone returns a copy of b, and nil for nil.
func Clone(b []byte) []byte {
	if b == nil {
		return nil
	}
	c := make([]byte, len(b))
	copy(c, b)
	return c
}

// copyOf is what Go writes as append([]byte(nil), b...): a copy, which is
// nil when b is empty.
func copyOf(b []byte) []byte {
	if len(b) == 0 {
		return nil
	}
	return Clone(b)
}

// Index is where sep first lies in s, or -1.
func Index(s, sep []byte) int { return native.index(s, sep) }

// IndexByte is where c first is in b, or -1.
func IndexByte(b []byte, c byte) int { return native.indexByte(b, c) }

// LastIndex is where sep last lies in s, or -1.
func LastIndex(s, sep []byte) int {
	n := len(sep)
	for i := len(s) - n; i >= 0; i-- {
		if Equal(s[i:i+n], sep) {
			return i
		}
	}
	return -1
}

// LastIndexByte is where c last is in s, or -1.
func LastIndexByte(s []byte, c byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// Contains says whether subslice lies in b.
func Contains(b, subslice []byte) bool { return Index(b, subslice) != -1 }

// Count is the number of times sep lies in s, no two overlapping. For an
// empty sep it is the number of characters of s and one more.
func Count(s, sep []byte) int {
	if len(sep) == 0 {
		n := 1
		for i := 0; i < len(s); n++ {
			_, size := decodeRune(s[i:])
			i += size
		}
		return n
	}
	n := 0
	for {
		i := Index(s, sep)
		if i < 0 {
			return n
		}
		n++
		s = s[i+len(sep):]
	}
}

// HasPrefix says whether s begins with prefix.
func HasPrefix(s, prefix []byte) bool {
	return len(s) >= len(prefix) && Equal(s[:len(prefix)], prefix)
}

// HasSuffix says whether s ends with suffix.
func HasSuffix(s, suffix []byte) bool {
	return len(s) >= len(suffix) && Equal(s[len(s)-len(suffix):], suffix)
}

// TrimPrefix is s without the prefix it begins with, if it does.
func TrimPrefix(s, prefix []byte) []byte {
	if HasPrefix(s, prefix) {
		return s[len(prefix):]
	}
	return s
}

// TrimSuffix is s without the suffix it ends with, if it does.
func TrimSuffix(s, suffix []byte) []byte {
	if HasSuffix(s, suffix) {
		return s[:len(s)-len(suffix)]
	}
	return s
}

// Cut cuts s around the first sep: what is before it, what is after it,
// and whether it was there. Without it, before is s and after is nil.
func Cut(s, sep []byte) (before, after []byte, found bool) {
	if i := Index(s, sep); i >= 0 {
		return s[:i], s[i+len(sep):], true
	}
	return s, nil, false
}

// SplitN cuts s at each sep into at most n parts, the last being the
// rest; a negative n is no limit, and 0 gives nil. The parts lie in s. An
// empty sep cuts after each character.
func SplitN(s, sep []byte, n int) [][]byte {
	if n == 0 {
		return nil
	}
	if n < 0 {
		n = Count(s, sep) + 1
	}
	if n > len(s)+1 {
		n = len(s) + 1
	}
	parts := make([][]byte, n)
	used := 0
	for used < n-1 {
		var end, next int
		if len(sep) == 0 {
			if len(s) == 0 {
				break
			}
			_, end = decodeRune(s)
			next = end
		} else {
			end = Index(s, sep)
			if end < 0 {
				break
			}
			next = end + len(sep)
		}
		parts[used] = s[:end]
		used++
		s = s[next:]
	}
	if len(sep) == 0 && len(s) == 0 {
		// Characters leave no rest.
		return parts[:used]
	}
	parts[used] = s
	return parts[:used+1]
}

// Split cuts s at each sep and returns the parts, which lie in s. An
// empty sep cuts after each character.
func Split(s, sep []byte) [][]byte { return SplitN(s, sep, -1) }

// Join returns the slices of s as one, with sep between them.
func Join(s [][]byte, sep []byte) []byte {
	if len(s) == 0 {
		return []byte{}
	}
	if len(s) == 1 {
		return copyOf(s[0])
	}
	n := len(sep) * (len(s) - 1)
	for _, part := range s {
		n += len(part)
	}
	joined := make([]byte, n)
	at := copy(joined, s[0])
	for _, part := range s[1:] {
		at += copy(joined[at:], sep)
		at += copy(joined[at:], part)
	}
	return joined
}

// Fields cuts s at each run of white space and returns the parts between,
// which lie in s. None is empty.
func Fields(s []byte) [][]byte {
	fields := [][]byte{}
	start := -1 // where the field being read began
	for i := 0; i < len(s); {
		r, size := decodeRune(s[i:])
		if unicode.IsSpace(r) {
			if start >= 0 {
				fields = append(fields, s[start:i])
				start = -1
			}
		} else if start < 0 {
			start = i
		}
		i += size
	}
	if start >= 0 {
		fields = append(fields, s[start:])
	}
	return fields
}

// TrimSpace is s without the white space it begins and ends with, as a
// part of s; nil if nothing is left.
func TrimSpace(s []byte) []byte {
	start, end := 0, len(s)
	for start < end {
		r, size := decodeRune(s[start:end])
		if !unicode.IsSpace(r) {
			break
		}
		start += size
	}
	for start < end {
		r, size := decodeLastRune(s[start:end])
		if !unicode.IsSpace(r) {
			break
		}
		end -= size
	}
	if start == end {
		return nil
	}
	return s[start:end]
}

// inSet says whether r is one of the characters of cutset.
func inSet(cutset string, r rune) bool {
	for _, c := range cutset {
		if c == r {
			return true
		}
	}
	return false
}

// TrimRight is s without the characters of cutset it ends with, as a part
// of s.
func TrimRight(s []byte, cutset string) []byte {
	end := len(s)
	for end > 0 {
		r, size := decodeLastRune(s[:end])
		if !inSet(cutset, r) {
			break
		}
		end -= size
	}
	return s[:end]
}

// TrimLeft is s without the characters of cutset it begins with, as a
// part of s; nil if nothing is left.
func TrimLeft(s []byte, cutset string) []byte {
	if len(s) == 0 {
		return nil
	}
	if cutset == "" {
		return s
	}
	start := 0
	for start < len(s) {
		r, size := decodeRune(s[start:])
		if !inSet(cutset, r) {
			break
		}
		start += size
	}
	if start == len(s) {
		return nil
	}
	return s[start:]
}

// Trim is s without the characters of cutset it begins and ends with, as
// a part of s; nil if nothing is left.
func Trim(s []byte, cutset string) []byte {
	if len(s) == 0 {
		return nil
	}
	if cutset == "" {
		return s
	}
	return TrimLeft(TrimRight(s, cutset), cutset)
}

// mapped is s with each character replaced by what change makes of it. A
// byte that begins no character is U+FFFD before and after.
func mapped(s []byte, change func(rune) rune) []byte {
	b := make([]byte, 0, len(s))
	var encoded [utf8.UTFMax]byte
	for i := 0; i < len(s); {
		if c := s[i]; c < utf8.RuneSelf {
			b = append(b, byte(change(rune(c))))
			i++
			continue
		}
		r, size := decodeRune(s[i:])
		n := utf8.EncodeRune(encoded[:], change(r))
		b = append(b, encoded[:n]...)
		i += size
	}
	return b
}

// ToUpper is a copy of s with every letter in upper case.
func ToUpper(s []byte) []byte { return mapped(s, upper) }

// ToLower is a copy of s with every letter in lower case.
func ToLower(s []byte) []byte { return mapped(s, lower) }

func upper(r rune) rune { return unicode.ToUpper(r) }

func lower(r rune) rune { return unicode.ToLower(r) }

// Repeat is count copies of b, one after the other. It panics if count is
// negative or the result too long.
func Repeat(b []byte, count int) []byte {
	if count == 0 {
		return []byte{}
	}
	if count < 0 {
		panic("bytes: negative Repeat count")
	}
	const maxInt = int(^uint(0) >> 1)
	if len(b) > maxInt/count {
		panic("bytes: Repeat output length overflow")
	}
	if len(b) == 0 {
		return []byte{}
	}
	repeated := make([]byte, len(b)*count)
	// Double what is there until it is all there.
	at := copy(repeated, b)
	for at < len(repeated) {
		at += copy(repeated[at:], repeated[:at])
	}
	return repeated
}

// Replace is a copy of s with the first n places where old lies, no two
// overlapping, holding new instead; all of them if n is negative. An
// empty old lies before each character and at the end.
func Replace(s, old, new []byte, n int) []byte {
	found := 0
	if n != 0 {
		found = Count(s, old)
	}
	if found == 0 {
		return copyOf(s)
	}
	if n < 0 || found < n {
		n = found
	}
	t := make([]byte, len(s)+n*(len(new)-len(old)))
	w, start := 0, 0
	for i := 0; i < n; i++ {
		j := start
		if len(old) == 0 {
			if i > 0 {
				_, size := decodeRune(s[start:])
				j += size
			}
		} else {
			j += Index(s[start:], old)
		}
		w += copy(t[w:], s[start:j])
		w += copy(t[w:], new)
		start = j + len(old)
	}
	w += copy(t[w:], s[start:])
	return t[0:w]
}

// ReplaceAll is a copy of s with new everywhere old lies.
func ReplaceAll(s, old, new []byte) []byte { return Replace(s, old, new, -1) }

// folded says whether a and b are one letter in different cases. The
// library has the case of a letter but not Go's table of the letters that
// fold together, so the cases are compared every way round: the harness
// checks this against the table for every pair of characters.
func folded(a, b rune) bool {
	if a == b {
		return true
	}
	// The dotted and the dotless i of Turkish fold with nothing.
	if a == 0x130 || a == 0x131 || b == 0x130 || b == 0x131 {
		return false
	}
	la, lb := unicode.ToLower(a), unicode.ToLower(b)
	if la == lb {
		return true
	}
	ua, ub := unicode.ToUpper(a), unicode.ToUpper(b)
	return ua == ub || unicode.ToUpper(la) == unicode.ToUpper(lb) || unicode.ToLower(ua) == unicode.ToLower(ub)
}

// EqualFold says whether s and t, read as UTF-8, are the same text when
// the case of letters is ignored.
func EqualFold(s, t []byte) bool {
	i, j := 0, 0
	for i < len(s) && j < len(t) {
		a, b := s[i], t[j]
		if a < utf8.RuneSelf && b < utf8.RuneSelf {
			if a != b {
				// The Kelvin sign and the long s are not ASCII, so two
				// ASCII bytes fold only as letters.
				if 'A' <= a && a <= 'Z' {
					a += 'a' - 'A'
				}
				if 'A' <= b && b <= 'Z' {
					b += 'a' - 'A'
				}
				if a != b {
					return false
				}
			}
			i++
			j++
			continue
		}
		r, sizeS := decodeRune(s[i:])
		u, sizeT := decodeRune(t[j:])
		if !folded(r, u) {
			return false
		}
		i += sizeS
		j += sizeT
	}
	return i == len(s) && j == len(t)
}

// runeShape says what the byte c begins in UTF-8: how many bytes the
// character has, and the range its second byte must be in. A byte that
// begins none has the size 1.
func runeShape(c byte) (size int, lo, hi byte) {
	lo, hi = 0x80, 0xBF
	switch {
	case c < 0xC2:
		size = 1
	case c < 0xE0:
		size = 2
	case c < 0xF0:
		size = 3
		if c == 0xE0 {
			lo = 0xA0 // no overlong forms
		} else if c == 0xED {
			hi = 0x9F // no surrogates
		}
	case c < 0xF5:
		size = 4
		if c == 0xF0 {
			lo = 0x90
		} else if c == 0xF4 {
			hi = 0x8F // nothing above U+10FFFF
		}
	default:
		size = 1
	}
	return size, lo, hi
}

// decodeRune is utf8.DecodeRune: the first character of p and its size,
// or U+FFFD and 1 for bytes that are none, and 0 for no bytes.
func decodeRune(p []byte) (rune, int) {
	if len(p) == 0 {
		return utf8.RuneError, 0
	}
	c := p[0]
	if c < utf8.RuneSelf {
		return rune(c), 1
	}
	size, lo, hi := runeShape(c)
	if size == 1 || len(p) < size || p[1] < lo || hi < p[1] {
		return utf8.RuneError, 1
	}
	// The lead byte gives the bits its size leaves it, each other six.
	r := rune(c) & (0x7F >> size)
	for i := 1; i < size; i++ {
		if i > 1 && (p[i] < 0x80 || 0xBF < p[i]) {
			return utf8.RuneError, 1
		}
		r = r<<6 | rune(p[i]&0x3F)
	}
	return r, size
}

// decodeLastRune is utf8.DecodeLastRune: the last character of p and its
// size, or U+FFFD and 1 for a last byte that ends none.
func decodeLastRune(p []byte) (rune, int) {
	end := len(p)
	if end == 0 {
		return utf8.RuneError, 0
	}
	if c := p[end-1]; c < utf8.RuneSelf {
		return rune(c), 1
	}
	// Back to the byte that begins the character, at most four in all.
	start := end - 1
	for start > 0 && start > end-utf8.UTFMax && p[start]&0xC0 == 0x80 {
		start--
	}
	if r, size := decodeRune(p[start:end]); start+size == end {
		return r, size
	}
	return utf8.RuneError, 1
}
