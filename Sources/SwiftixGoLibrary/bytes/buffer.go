// Package bytes is for slices of bytes what strings is for strings, and
// has the Buffer: bytes that are written at one end and read at the other.
//
// A slice of bytes holds any bytes, where a string of this dialect holds
// text: the functions here work on the bytes as they are, and decode
// UTF-8 as Go does, a byte that begins no character being U+FFFD of
// width 1.
package bytes

import (
	"errors"
	"io"
	"unicode/utf8"
)

// MinRead is the room ReadFrom makes before each Read of its source.
const MinRead = 512

// The capacity of the first allocation of a small Buffer.
const smallBufferSize = 64

// ErrTooLarge is the panic of a Buffer that cannot grow to hold what it
// is given.
var ErrTooLarge = errors.New("bytes.Buffer: too large")

var errNegativeRead = errors.New("bytes.Buffer: reader returned negative count from Read")

// What the last operation on a Buffer read, for the Unread methods: a
// rune of one to four bytes is its size.
type readOp int8

const (
	opRead    readOp = -1
	opInvalid readOp = 0
)

// A Buffer is a queue of bytes with Write and Read methods. Its zero
// value is an empty buffer, ready to use.
type Buffer struct {
	buf []byte
	// buf[off:] is what has been written and not yet read.
	off      int
	lastRead readOp
}

// NewBuffer returns a Buffer whose content is buf, which it takes over:
// the caller writes to buf no more. To write into the room of a slice
// instead, give buf[:0].
func NewBuffer(buf []byte) *Buffer { return &Buffer{buf: buf} }

// NewBufferString returns a Buffer whose content is s.
func NewBufferString(s string) *Buffer {
	buf := make([]byte, len(s), roundCapacity(len(s)))
	copy(buf, s)
	return &Buffer{buf: buf}
}

// Bytes is the unread content where it lies in the buffer: good until the
// next write, Reset, or Truncate, and what is written into it is read
// later.
func (b *Buffer) Bytes() []byte { return b.buf[b.off:] }

// AvailableBuffer is an empty slice over the room left in the buffer, to
// append to and hand to Write at once.
func (b *Buffer) AvailableBuffer() []byte { return b.buf[len(b.buf):] }

// String is the unread content as a string. A nil *Buffer is "<nil>".
func (b *Buffer) String() string {
	if b == nil {
		return "<nil>"
	}
	return string(b.buf[b.off:])
}

func (b *Buffer) empty() bool { return len(b.buf) <= b.off }

// Len is the number of unread bytes.
func (b *Buffer) Len() int { return len(b.buf) - b.off }

// Cap is the size of the storage the buffer has.
func (b *Buffer) Cap() int { return cap(b.buf) }

// Available is the room left for writing without growing.
func (b *Buffer) Available() int { return cap(b.buf) - len(b.buf) }

// Truncate drops all but the first n unread bytes and keeps the storage.
// It panics if n is negative or more than there are.
func (b *Buffer) Truncate(n int) {
	if n == 0 {
		b.Reset()
		return
	}
	b.lastRead = opInvalid
	if n < 0 || n > b.Len() {
		panic("bytes.Buffer: truncation out of range")
	}
	b.buf = b.buf[:b.off+n]
}

// Reset empties the buffer and keeps the storage.
func (b *Buffer) Reset() {
	b.buf = b.buf[:0]
	b.off = 0
	b.lastRead = opInvalid
}

// extend makes n more bytes part of the content if the storage has the
// room, and returns where they begin.
func (b *Buffer) extend(n int) (int, bool) {
	if l := len(b.buf); n <= cap(b.buf)-l {
		b.buf = b.buf[:l+n]
		return l, true
	}
	return 0, false
}

// grow makes n more bytes part of the content, with new storage if it
// must, and returns where they begin.
func (b *Buffer) grow(n int) int {
	unread := b.Len()
	if unread == 0 && b.off != 0 {
		b.Reset()
	}
	if at, ok := b.extend(n); ok {
		return at
	}
	if b.buf == nil && n <= smallBufferSize {
		b.buf = make([]byte, n, smallBufferSize)
		return 0
	}
	c := cap(b.buf)
	const maxInt = int(^uint(0) >> 1)
	if n <= c/2-unread {
		// Less than half is in use with n more: slide the content down
		// rather than allocate.
		copy(b.buf, b.buf[b.off:])
	} else if c > maxInt-c-n {
		panic(ErrTooLarge)
	} else {
		// Twice the storage behind what was read, or what is needed
		// with the read part counted in, if that is more.
		need := b.off + n + unread
		if need < 2*(c-b.off) {
			need = 2 * (c - b.off)
		}
		grown := make([]byte, unread, roundCapacity(need))
		copy(grown, b.buf[b.off:])
		b.buf = grown
	}
	b.off = 0
	b.buf = b.buf[:unread+n]
	return unread
}

// Grow makes room for n more bytes, so that writing them allocates
// nothing. It panics if n is negative.
func (b *Buffer) Grow(n int) {
	if n < 0 {
		panic("bytes.Buffer.Grow: negative count")
	}
	at := b.grow(n)
	b.buf = b.buf[:at]
}

// Write appends p. It returns len(p) and no error.
func (b *Buffer) Write(p []byte) (n int, err error) {
	b.lastRead = opInvalid
	at, ok := b.extend(len(p))
	if !ok {
		at = b.grow(len(p))
	}
	return copy(b.buf[at:], p), nil
}

// WriteString appends s. It returns len(s) and no error.
func (b *Buffer) WriteString(s string) (n int, err error) {
	b.lastRead = opInvalid
	at, ok := b.extend(len(s))
	if !ok {
		at = b.grow(len(s))
	}
	return copy(b.buf[at:], s), nil
}

// ReadFrom reads r to its end and appends what it read. It returns the
// number of bytes read; the end of r is not an error.
func (b *Buffer) ReadFrom(r io.Reader) (n int64, err error) {
	b.lastRead = opInvalid
	for {
		at := b.grow(MinRead)
		b.buf = b.buf[:at]
		m, rerr := r.Read(b.buf[at:cap(b.buf)])
		if m < 0 {
			panic(errNegativeRead)
		}
		b.buf = b.buf[:at+m]
		n += int64(m)
		if rerr == io.EOF {
			return n, nil
		}
		if rerr != nil {
			return n, rerr
		}
	}
}

// WriteTo writes the unread content to w and returns the number of bytes
// written. What w took is read; the buffer is emptied if it took all.
func (b *Buffer) WriteTo(w io.Writer) (n int64, err error) {
	b.lastRead = opInvalid
	if unread := b.Len(); unread > 0 {
		m, werr := w.Write(b.buf[b.off:])
		if m > unread {
			panic("bytes.Buffer.WriteTo: invalid Write count")
		}
		b.off += m
		n = int64(m)
		if werr != nil {
			return n, werr
		}
		if m != unread {
			return n, io.ErrShortWrite
		}
	}
	b.Reset()
	return n, nil
}

// WriteByte appends c. It returns no error.
func (b *Buffer) WriteByte(c byte) error {
	b.lastRead = opInvalid
	at, ok := b.extend(1)
	if !ok {
		at = b.grow(1)
	}
	b.buf[at] = c
	return nil
}

// WriteRune appends r in UTF-8 and returns the number of bytes it took.
// It returns no error.
func (b *Buffer) WriteRune(r rune) (n int, err error) {
	if uint32(r) < utf8.RuneSelf {
		b.WriteByte(byte(r))
		return 1, nil
	}
	b.lastRead = opInvalid
	at, ok := b.extend(utf8.UTFMax)
	if !ok {
		at = b.grow(utf8.UTFMax)
	}
	n = utf8.EncodeRune(b.buf[at:at+utf8.UTFMax], r)
	b.buf = b.buf[:at+n]
	return n, nil
}

// Read reads the next bytes into p. With nothing left it returns io.EOF,
// unless p has no room.
func (b *Buffer) Read(p []byte) (n int, err error) {
	b.lastRead = opInvalid
	if b.empty() {
		b.Reset()
		if len(p) == 0 {
			return 0, nil
		}
		return 0, io.EOF
	}
	n = copy(p, b.buf[b.off:])
	b.off += n
	if n > 0 {
		b.lastRead = opRead
	}
	return n, nil
}

// Next reads the next n bytes, or all there are, and returns them where
// they lie in the buffer: good until the next read or write.
func (b *Buffer) Next(n int) []byte {
	b.lastRead = opInvalid
	if unread := b.Len(); n > unread {
		n = unread
	}
	data := b.buf[b.off : b.off+n]
	b.off += n
	if n > 0 {
		b.lastRead = opRead
	}
	return data
}

// ReadByte reads one byte.
func (b *Buffer) ReadByte() (byte, error) {
	if b.empty() {
		b.Reset()
		return 0, io.EOF
	}
	c := b.buf[b.off]
	b.off++
	b.lastRead = opRead
	return c, nil
}

// ReadRune reads one character in UTF-8 and returns it with its size.
// Bytes that are no character are read one at a time as U+FFFD.
func (b *Buffer) ReadRune() (r rune, size int, err error) {
	if b.empty() {
		b.Reset()
		return 0, 0, io.EOF
	}
	r, size = decodeRune(b.buf[b.off:])
	b.off += size
	b.lastRead = readOp(size)
	return r, size, nil
}

// UnreadRune gives back the rune of a ReadRune that was the most recent
// operation.
func (b *Buffer) UnreadRune() error {
	if b.lastRead <= opInvalid {
		return errors.New("bytes.Buffer: UnreadRune: previous operation was not a successful ReadRune")
	}
	if b.off >= int(b.lastRead) {
		b.off -= int(b.lastRead)
	}
	b.lastRead = opInvalid
	return nil
}

var errUnreadByte = errors.New("bytes.Buffer: UnreadByte: previous operation was not a successful read")

// UnreadByte gives back the last byte of the most recent operation, if
// that was a read of at least one byte.
func (b *Buffer) UnreadByte() error {
	if b.lastRead == opInvalid {
		return errUnreadByte
	}
	b.lastRead = opInvalid
	if b.off > 0 {
		b.off--
	}
	return nil
}

// ReadBytes reads up to and including delim into a slice of its own. With
// no delim left it returns the rest and io.EOF.
func (b *Buffer) ReadBytes(delim byte) (line []byte, err error) {
	part, err := b.readSlice(delim)
	if len(part) > 0 {
		line = make([]byte, len(part))
		copy(line, part)
	}
	return line, err
}

// readSlice is ReadBytes with the bytes where they lie.
func (b *Buffer) readSlice(delim byte) (line []byte, err error) {
	end := len(b.buf)
	if i := IndexByte(b.buf[b.off:], delim); i >= 0 {
		end = b.off + i + 1
	} else {
		err = io.EOF
	}
	line = b.buf[b.off:end]
	b.off = end
	b.lastRead = opRead
	return line, err
}

// ReadString is ReadBytes with the result as a string.
func (b *Buffer) ReadString(delim byte) (line string, err error) {
	part, err := b.readSlice(delim)
	return string(part), err
}

// roundCapacity is the capacity Go gives an allocation of n bytes: the
// size class of its allocator that holds them. A Buffer grows to these so
// that Cap is what it is in Go.
func roundCapacity(n int) int {
	switch {
	case n <= 0:
		return 0
	case n <= 32:
		return (n + 7) / 8 * 8
	case n <= 256:
		if n <= 48 {
			return 48
		}
		return (n + 15) / 16 * 16
	case n <= 512:
		return (n + 31) / 32 * 32
	case n > 32768:
		// Whole pages.
		return (n + 8191) / 8192 * 8192
	}
	for _, class := range largeClasses {
		if n <= class {
			return class
		}
	}
	return n
}

// The size classes above 512 bytes.
var largeClasses = []int{
	576, 640, 704, 768, 896, 1024, 1152, 1280, 1408, 1536, 1792, 2048, 2304, 2688, 3072, 3200, 3456,
	4096, 4864, 5376, 6144, 6528, 6784, 6912, 8192, 9472, 9728, 10240, 10880, 12288, 13568,
	14336, 16384, 18432, 19072, 20480, 21760, 24576, 27264, 28672, 32768,
}
