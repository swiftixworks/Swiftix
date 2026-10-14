package bytes

import (
	"errors"
	"io"
)

// A Reader reads the bytes of a slice, which it does not change: it is an
// io.Reader that can also go back and forth in what it reads.
type Reader struct {
	s []byte
	i int64 // how far reading has come
	// Where the rune of the last ReadRune began, or -1.
	prevRune int
}

// NewReader returns a Reader of b.
func NewReader(b []byte) *Reader { return &Reader{s: b, i: 0, prevRune: -1} }

// Len is the number of bytes not yet read.
func (r *Reader) Len() int {
	if r.i >= int64(len(r.s)) {
		return 0
	}
	return int(int64(len(r.s)) - r.i)
}

// Size is the length of the whole slice, read or not.
func (r *Reader) Size() int64 { return int64(len(r.s)) }

// Read copies the next bytes into b.
func (r *Reader) Read(b []byte) (n int, err error) {
	if r.i >= int64(len(r.s)) {
		return 0, io.EOF
	}
	r.prevRune = -1
	n = copy(b, r.s[r.i:])
	r.i += int64(n)
	return n, nil
}

// ReadAt copies into b the bytes from the offset off on, and leaves where
// reading has come alone. Fewer than len(b) come with io.EOF.
func (r *Reader) ReadAt(b []byte, off int64) (n int, err error) {
	if off < 0 {
		return 0, errors.New("bytes.Reader.ReadAt: negative offset")
	}
	if off >= int64(len(r.s)) {
		return 0, io.EOF
	}
	n = copy(b, r.s[off:])
	if n < len(b) {
		err = io.EOF
	}
	return n, err
}

// ReadByte reads one byte.
func (r *Reader) ReadByte() (byte, error) {
	r.prevRune = -1
	if r.i >= int64(len(r.s)) {
		return 0, io.EOF
	}
	b := r.s[r.i]
	r.i++
	return b, nil
}

// UnreadByte steps one byte back.
func (r *Reader) UnreadByte() error {
	if r.i <= 0 {
		return errors.New("bytes.Reader.UnreadByte: at beginning of slice")
	}
	r.prevRune = -1
	r.i--
	return nil
}

// ReadRune reads one character in UTF-8 and returns it with its size.
func (r *Reader) ReadRune() (ch rune, size int, err error) {
	if r.i >= int64(len(r.s)) {
		r.prevRune = -1
		return 0, 0, io.EOF
	}
	r.prevRune = int(r.i)
	ch, size = decodeRune(r.s[r.i:])
	r.i += int64(size)
	return ch, size, nil
}

// UnreadRune steps back over the rune of a ReadRune that was the most
// recent read.
func (r *Reader) UnreadRune() error {
	if r.i <= 0 {
		return errors.New("bytes.Reader.UnreadRune: at beginning of slice")
	}
	if r.prevRune < 0 {
		return errors.New("bytes.Reader.UnreadRune: previous operation was not ReadRune")
	}
	r.i = int64(r.prevRune)
	r.prevRune = -1
	return nil
}

// Seek sets where the next read begins: offset from the start, from where
// reading has come, or from the end, as whence says. It returns the new
// place, which may lie past the end.
func (r *Reader) Seek(offset int64, whence int) (int64, error) {
	r.prevRune = -1
	var from int64
	switch whence {
	case io.SeekStart:
		from = 0
	case io.SeekCurrent:
		from = r.i
	case io.SeekEnd:
		from = int64(len(r.s))
	default:
		return 0, errors.New("bytes.Reader.Seek: invalid whence")
	}
	to := from + offset
	if to < 0 {
		return 0, errors.New("bytes.Reader.Seek: negative position")
	}
	r.i = to
	return to, nil
}

// WriteTo writes what is not yet read to w and returns the number of
// bytes written.
func (r *Reader) WriteTo(w io.Writer) (n int64, err error) {
	r.prevRune = -1
	if r.i >= int64(len(r.s)) {
		return 0, nil
	}
	rest := r.s[r.i:]
	m, err := w.Write(rest)
	if m > len(rest) {
		panic("bytes.Reader.WriteTo: invalid Write count")
	}
	r.i += int64(m)
	n = int64(m)
	if m != len(rest) && err == nil {
		err = io.ErrShortWrite
	}
	return n, err
}

// Reset makes r a Reader of b, from its start.
func (r *Reader) Reset(b []byte) { *r = Reader{s: b, i: 0, prevRune: -1} }
