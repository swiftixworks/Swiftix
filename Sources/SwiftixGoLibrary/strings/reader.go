// Package strings is the part of strings that is written in Go.
package strings

import "io"

// A Reader reads the bytes of a string, as an io.Reader.
type Reader struct {
	s string
	i int // how far reading has come
}

// Len is the number of bytes not yet read.
func (r *Reader) Len() int {
	if r.i >= len(r.s) {
		return 0
	}
	return len(r.s) - r.i
}

// Size is the length of the whole string, read or not.
func (r *Reader) Size() int { return len(r.s) }

// Read copies the next bytes of the string into b.
func (r *Reader) Read(b []byte) (n int, err error) {
	if r.i >= len(r.s) {
		return 0, io.EOF
	}
	n = copy(b, r.s[r.i:])
	r.i += n
	return n, nil
}

// NewReader returns a Reader of s.
func NewReader(s string) *Reader { return &Reader{s: s, i: 0} }
