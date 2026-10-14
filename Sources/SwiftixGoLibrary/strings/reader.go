// Package strings is the part of strings that is written in Go.
package strings

import (
	"errors"
	"io"
	"unicode/utf8"
)

// A Reader reads the bytes of a string, as an io.Reader, and a byte or a
// character at a time, from any place of it.
type Reader struct {
	s        string
	i        int // how far reading has come
	prevRune int // where the character just read began, or negative
}

// Len is the number of bytes not yet read.
func (r *Reader) Len() int {
	if r.i >= len(r.s) {
		return 0
	}
	return len(r.s) - r.i
}

// Size is the length of the whole string, read or not.
func (r *Reader) Size() int64 { return int64(len(r.s)) }

// Read copies the next bytes of the string into b.
func (r *Reader) Read(b []byte) (n int, err error) {
	if r.i >= len(r.s) {
		return 0, io.EOF
	}
	r.prevRune = -1
	n = r.copyFrom(b, r.i)
	r.i += n
	return n, nil
}

// copyFrom copies the bytes of the string from at on into b, as
// copy(b, r.s[at:]) does, and returns how many. A string of the VM is
// whole characters and a slice of one is a copy, so the bytes that end a
// character begun before at are copied one by one, and the rest as the
// characters that reach the end of b and no more of the string.
func (r *Reader) copyFrom(b []byte, at int) int {
	n := 0
	for n < len(b) && at < len(r.s) && r.s[at]&0xC0 == 0x80 {
		b[n] = r.s[at]
		n++
		at++
	}
	end := min(at+len(b)-n, len(r.s))
	for end < len(r.s) && r.s[end]&0xC0 == 0x80 {
		end++
	}
	return n + copy(b[n:], r.s[at:end])
}

// NewReader returns a Reader of s.
func NewReader(s string) *Reader { return &Reader{s: s, i: 0, prevRune: -1} }

// ReadAt copies the bytes from off on into b, and moves nothing. Fewer
// bytes than b holds come with io.EOF.
func (r *Reader) ReadAt(b []byte, off int64) (n int, err error) {
	if off < 0 {
		return 0, errors.New("strings.Reader.ReadAt: negative offset")
	}
	if off >= int64(len(r.s)) {
		return 0, io.EOF
	}
	n = r.copyFrom(b, int(off))
	if n < len(b) {
		err = io.EOF
	}
	return n, err
}

// ReadByte reads the next byte.
func (r *Reader) ReadByte() (byte, error) {
	r.prevRune = -1
	if r.i >= len(r.s) {
		return 0, io.EOF
	}
	b := r.s[r.i]
	r.i++
	return b, nil
}

// UnreadByte steps back over one byte.
func (r *Reader) UnreadByte() error {
	if r.i <= 0 {
		return errors.New("strings.Reader.UnreadByte: at beginning of string")
	}
	r.prevRune = -1
	r.i--
	return nil
}

// ReadRune reads the next character, and says how many bytes it is.
func (r *Reader) ReadRune() (ch rune, size int, err error) {
	if r.i >= len(r.s) {
		r.prevRune = -1
		return 0, 0, io.EOF
	}
	r.prevRune = r.i
	ch, size = rune(r.s[r.i]), 1
	switch {
	case ch < utf8.RuneSelf:
	case ch < 0xC0:
		// A byte from inside a character, after a read that ended
		// there: no character, and nothing to slice the string at.
		ch = utf8.RuneError
	default:
		ch, size = utf8.DecodeRuneInString(r.s[r.i:min(r.i+utf8.UTFMax, len(r.s))])
	}
	r.i += size
	return ch, size, nil
}

// UnreadRune steps back over the character ReadRune has just read. After
// anything else it is an error.
func (r *Reader) UnreadRune() error {
	if r.i <= 0 {
		return errors.New("strings.Reader.UnreadRune: at beginning of string")
	}
	if r.prevRune < 0 {
		return errors.New("strings.Reader.UnreadRune: previous operation was not ReadRune")
	}
	r.i = r.prevRune
	r.prevRune = -1
	return nil
}

// Seek moves to offset, counted from the start, from here, or from the
// end as whence says, and returns the place from the start. It may be
// past the end; before the start is an error.
func (r *Reader) Seek(offset int64, whence int) (int64, error) {
	r.prevRune = -1
	var from int64
	switch whence {
	case io.SeekStart:
	case io.SeekCurrent:
		from = int64(r.i)
	case io.SeekEnd:
		from = int64(len(r.s))
	default:
		return 0, errors.New("strings.Reader.Seek: invalid whence")
	}
	if from+offset < 0 {
		return 0, errors.New("strings.Reader.Seek: negative position")
	}
	r.i = int(from + offset)
	return from + offset, nil
}

// WriteTo writes what has not been read to w, and has then read it.
func (r *Reader) WriteTo(w io.Writer) (n int64, err error) {
	r.prevRune = -1
	if r.i >= len(r.s) {
		return 0, nil
	}
	rest := r.s[r.i:]
	wrote, err := io.WriteString(w, rest)
	if wrote > len(rest) {
		panic("strings.Reader.WriteTo: invalid WriteString count")
	}
	r.i += wrote
	if wrote != len(rest) && err == nil {
		err = io.ErrShortWrite
	}
	return int64(wrote), err
}

// Reset makes r a Reader of s, at its start.
func (r *Reader) Reset(s string) {
	r.s = s
	r.i = 0
	r.prevRune = -1
}
