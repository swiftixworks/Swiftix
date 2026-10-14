// Package strconv is the part of strconv that is written in Go: quoting,
// booleans, and the functions that append to a byte slice. The numbers are
// read and written by the run-time library, which this file imports under
// the same path.
package strconv

import (
	"errors"
	"fmt"
	"strconv"
	"unicode/utf8"
)

// ErrSyntax is the error of a text that is not what the function reads.
var ErrSyntax = errors.New("invalid syntax")

// ErrRange is the error of a value too large for its type.
var ErrRange = errors.New("value out of range")

// A NumError is a failed conversion: the function, its input, and why.
type NumError struct {
	Func string
	Num  string
	Err  error
}

func (e *NumError) Error() string {
	return "strconv." + e.Func + ": parsing " + Quote(e.Num) + ": " + e.Err.Error()
}

func (e *NumError) Unwrap() error { return e.Err }

// Quote is s as a string literal of Go in double quotes, with escapes for
// what does not print.
func Quote(s string) string { return fmt.Sprintf("%q", s) }

// QuoteToASCII is Quote with escapes for everything outside ASCII too.
func QuoteToASCII(s string) string { return fmt.Sprintf("%+q", s) }

// AppendQuote appends Quote(s) to dst.
func AppendQuote(dst []byte, s string) []byte { return append(dst, Quote(s)...) }

// AppendInt appends the digits of i in the given base to dst.
func AppendInt(dst []byte, i int64, base int) []byte {
	return append(dst, strconv.FormatInt(i, base)...)
}

// FormatBool is "true" or "false".
func FormatBool(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// ParseBool reads the boolean that 1, t, T, TRUE, true, True, 0, f, F,
// FALSE, false, or False names. Anything else is an error.
func ParseBool(str string) (bool, error) {
	switch str {
	case "1", "t", "T", "true", "TRUE", "True":
		return true, nil
	case "0", "f", "F", "false", "FALSE", "False":
		return false, nil
	}
	return false, &NumError{Func: "ParseBool", Num: str, Err: ErrSyntax}
}

// digit is the value of the digit c in a base up to 16, or -1.
func digit(c byte, base int) int {
	value := -1
	switch {
	case c >= '0' && c <= '9':
		value = int(c - '0')
	case c >= 'a' && c <= 'f':
		value = int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		value = int(c-'A') + 10
	}
	if value >= base {
		return -1
	}
	return value
}

// number reads count digits of s in base from i on, or gives -1.
func number(s string, i, count, base int) int {
	if i+count > len(s) {
		return -1
	}
	value := 0
	for _, c := range []byte(s[i : i+count]) {
		d := digit(c, base)
		if d < 0 {
			return -1
		}
		value = value*base + d
	}
	return value
}

// escaped reads the escape sequence that follows the backslash at
// s[i-1], inside a literal in the given quote. It appends what the escape
// stands for to out and returns where the escape ends, or -1.
func escaped(s string, i int, quote byte, out []byte) ([]byte, int) {
	if i >= len(s) {
		return out, -1
	}
	c := s[i]
	i++
	simple := "a\ab\bf\fn\nr\rt\tv\v\\\\"
	for k := 0; k < len(simple); k += 2 {
		if simple[k] == c {
			return append(out, simple[k+1]), i
		}
	}
	switch c {
	case '\'', '"':
		if c != quote {
			return out, -1
		}
		return append(out, c), i
	case 'x':
		value := number(s, i, 2, 16)
		if value < 0 {
			return out, -1
		}
		return append(out, byte(value)), i + 2
	case 'u', 'U':
		count := 4
		if c == 'U' {
			count = 8
		}
		value := number(s, i, count, 16)
		if value < 0 || value > utf8.MaxRune || value >= 0xD800 && value <= 0xDFFF {
			return out, -1
		}
		return append(out, string(rune(value))...), i + count
	case '0', '1', '2', '3', '4', '5', '6', '7':
		value := number(s, i-1, 3, 8)
		if value < 0 || value > 255 {
			return out, -1
		}
		return append(out, byte(value)), i + 2
	}
	return out, -1
}

// Unquote reads s as a literal of Go, a string in double quotes or in
// back quotes or a character in single quotes, and returns what it
// denotes. Anything else is ErrSyntax.
func Unquote(s string) (string, error) {
	if len(s) < 2 || s[0] != s[len(s)-1] {
		return "", ErrSyntax
	}
	quote := s[0]
	inside := s[1 : len(s)-1]
	var out []byte
	switch quote {
	case '`':
		// Everything stands for itself; a carriage return is dropped,
		// as it is from a source file.
		for _, c := range []byte(inside) {
			if c == '`' {
				return "", ErrSyntax
			}
			if c != '\r' {
				out = append(out, c)
			}
		}
		return string(out), nil
	case '"', '\'':
	default:
		return "", ErrSyntax
	}
	characters := 0
	for i := 0; i < len(inside); characters++ {
		c := inside[i]
		switch {
		case c == quote || c == '\n':
			return "", ErrSyntax
		case c == '\\':
			out, i = escaped(inside, i+1, quote, out)
			if i < 0 {
				return "", ErrSyntax
			}
		case c < utf8.RuneSelf:
			out = append(out, c)
			i++
		default:
			// Bytes that are no character read as U+FFFD, as Go has it.
			r, width := utf8.DecodeRuneInString(inside[i:min(i+utf8.UTFMax, len(inside))])
			out = append(out, string(r)...)
			i += width
		}
	}
	// Go takes a character literal of no character for an empty string.
	if quote == '\'' && characters > 1 {
		return "", ErrSyntax
	}
	return string(out), nil
}
