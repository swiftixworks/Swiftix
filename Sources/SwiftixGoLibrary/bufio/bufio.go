// Package bufio puts a buffer between a program and an io.Reader or an
// io.Writer, so that many small reads and writes become few large ones,
// and gives the reader the ways of taking text apart: a byte, a rune, a
// line, everything up to a delimiter.
//
// What a Reader asks of its source and a Writer hands to its destination,
// call by call, is what Go's package asks and hands: the harness in
// Scripts/go-library-harness/bufio compares the two.
package bufio

import (
	"errors"
	"io"
	"unicode/utf8"
)

const (
	defaultBufSize = 4096
	// The smallest buffer a Reader works with: room for a rune and a few
	// bytes to look ahead.
	minReadBufferSize = 16
	// How many reads may return nothing, and no error, before the source
	// is taken to make no progress.
	maxConsecutiveEmptyReads = 100
)

var (
	ErrInvalidUnreadByte = errors.New("bufio: invalid use of UnreadByte")
	ErrInvalidUnreadRune = errors.New("bufio: invalid use of UnreadRune")
	ErrBufferFull        = errors.New("bufio: buffer full")
	ErrNegativeCount     = errors.New("bufio: negative count")
)

var (
	errNegativeRead  = errors.New("bufio: reader returned negative count from Read")
	errNegativeWrite = errors.New("bufio: writer returned negative count from Write")
)

// A Reader reads from an io.Reader through a buffer.
type Reader struct {
	buf []byte
	rd  io.Reader
	// buf[r:w] is what has been read from rd and not yet handed out.
	r, w int
	// An error of rd, kept until the bytes read before it are handed out.
	err error
	// The last byte handed out, for UnreadByte, or -1 when there is none
	// to give back; the size of the last rune, for UnreadRune, likewise.
	lastByte     int
	lastRuneSize int
}

// NewReaderSize returns a Reader of rd whose buffer has at least size
// bytes. A Reader that is large enough already is returned as it is.
func NewReaderSize(rd io.Reader, size int) *Reader {
	if b, ok := rd.(*Reader); ok && len(b.buf) >= size {
		return b
	}
	if size < minReadBufferSize {
		size = minReadBufferSize
	}
	b := new(Reader)
	b.start(make([]byte, size), rd)
	return b
}

// NewReader returns a Reader of rd with a buffer of the default size.
func NewReader(rd io.Reader) *Reader {
	return NewReaderSize(rd, defaultBufSize)
}

// Size is the size of the buffer.
func (b *Reader) Size() int { return len(b.buf) }

// Reset drops what is buffered and makes b read from r. A zero Reader gets
// a buffer of the default size; resetting a Reader to itself does nothing.
func (b *Reader) Reset(r io.Reader) {
	if same, ok := r.(*Reader); ok && same == b {
		return
	}
	if b.buf == nil {
		b.buf = make([]byte, defaultBufSize)
	}
	b.start(b.buf, r)
}

func (b *Reader) start(buf []byte, r io.Reader) {
	*b = Reader{buf: buf, rd: r, lastByte: -1, lastRuneSize: -1}
}

// fill moves what is buffered to the front and reads once more into the
// room behind it.
func (b *Reader) fill() {
	if b.r > 0 {
		copy(b.buf, b.buf[b.r:b.w])
		b.w -= b.r
		b.r = 0
	}
	if b.w >= len(b.buf) {
		panic("bufio: tried to fill full buffer")
	}
	for attempt := 0; attempt < maxConsecutiveEmptyReads; attempt++ {
		n, err := b.rd.Read(b.buf[b.w:])
		if n < 0 {
			panic(errNegativeRead)
		}
		b.w += n
		if err != nil {
			b.err = err
			return
		}
		if n > 0 {
			return
		}
	}
	b.err = io.ErrNoProgress
}

// takeErr hands out the kept error, once.
func (b *Reader) takeErr() error {
	err := b.err
	b.err = nil
	return err
}

func (b *Reader) forgetLast() {
	b.lastByte = -1
	b.lastRuneSize = -1
}

// Peek returns the next n bytes without reading them. The bytes are the
// buffer's own, good until the next read. Fewer than n come with the
// error that explains it: ErrBufferFull when n is more than the buffer
// holds.
func (b *Reader) Peek(n int) ([]byte, error) {
	if n < 0 {
		return nil, ErrNegativeCount
	}
	b.forgetLast()
	for b.w-b.r < n && b.w-b.r < len(b.buf) && b.err == nil {
		b.fill()
	}
	if n > len(b.buf) {
		return b.buf[b.r:b.w], ErrBufferFull
	}
	var err error
	if have := b.w - b.r; have < n {
		n = have
		err = b.takeErr()
		if err == nil {
			err = ErrBufferFull
		}
	}
	return b.buf[b.r : b.r+n], err
}

// Discard skips the next n bytes and says how many it skipped. Fewer than
// n come with the error that stopped it.
func (b *Reader) Discard(n int) (discarded int, err error) {
	if n < 0 {
		return 0, ErrNegativeCount
	}
	if n == 0 {
		return 0, nil
	}
	b.forgetLast()
	left := n
	for {
		skip := b.Buffered()
		if skip == 0 {
			b.fill()
			skip = b.Buffered()
		}
		if skip > left {
			skip = left
		}
		b.r += skip
		left -= skip
		if left == 0 {
			return n, nil
		}
		if b.err != nil {
			return n - left, b.takeErr()
		}
	}
}

// Read reads into p. It asks the source at most once, so it may return
// fewer bytes than p has room for. At the end of the data it returns 0 and
// io.EOF.
func (b *Reader) Read(p []byte) (n int, err error) {
	if len(p) == 0 {
		if b.Buffered() > 0 {
			return 0, nil
		}
		return 0, b.takeErr()
	}
	if b.r == b.w {
		if b.err != nil {
			return 0, b.takeErr()
		}
		if len(p) >= len(b.buf) {
			// As much room as the buffer has: read past the buffer.
			n, b.err = b.rd.Read(p)
			if n < 0 {
				panic(errNegativeRead)
			}
			if n > 0 {
				b.lastByte = int(p[n-1])
				b.lastRuneSize = -1
			}
			return n, b.takeErr()
		}
		// One read, where fill would go on until it has something.
		b.r = 0
		b.w = 0
		n, b.err = b.rd.Read(b.buf)
		if n < 0 {
			panic(errNegativeRead)
		}
		if n == 0 {
			return 0, b.takeErr()
		}
		b.w += n
	}
	n = copy(p, b.buf[b.r:b.w])
	b.r += n
	b.lastByte = int(b.buf[b.r-1])
	b.lastRuneSize = -1
	return n, nil
}

// ReadByte reads one byte.
func (b *Reader) ReadByte() (byte, error) {
	b.lastRuneSize = -1
	for b.r == b.w {
		if b.err != nil {
			return 0, b.takeErr()
		}
		b.fill()
	}
	c := b.buf[b.r]
	b.r++
	b.lastByte = int(c)
	return c, nil
}

// UnreadByte gives back the last byte of the most recent read. Only one
// can be given back, and not after a Peek, a Discard, or a WriteTo.
func (b *Reader) UnreadByte() error {
	if b.lastByte < 0 || b.r == 0 && b.w > 0 {
		return ErrInvalidUnreadByte
	}
	if b.r > 0 {
		b.r--
	} else {
		// The buffer is empty: the byte becomes its content.
		b.w = 1
	}
	b.buf[b.r] = byte(b.lastByte)
	b.forgetLast()
	return nil
}

// ReadRune reads one character in UTF-8 and returns it with the number of
// bytes it took. Bytes that are no character are read one at a time as
// U+FFFD.
func (b *Reader) ReadRune() (r rune, size int, err error) {
	for b.r+utf8.UTFMax > b.w && !fullRune(b.buf[b.r:b.w]) && b.err == nil && b.w-b.r < len(b.buf) {
		b.fill()
	}
	b.lastRuneSize = -1
	if b.r == b.w {
		return 0, 0, b.takeErr()
	}
	r, size = rune(b.buf[b.r]), 1
	if r >= utf8.RuneSelf {
		r, size = decodeRune(b.buf[b.r:b.w])
	}
	b.r += size
	b.lastByte = int(b.buf[b.r-1])
	b.lastRuneSize = size
	return r, size, nil
}

// UnreadRune gives back the rune of a ReadRune that was the most recent
// read.
func (b *Reader) UnreadRune() error {
	if b.lastRuneSize < 0 || b.r < b.lastRuneSize {
		return ErrInvalidUnreadRune
	}
	b.r -= b.lastRuneSize
	b.forgetLast()
	return nil
}

// Buffered is the number of bytes that can be read without asking the
// source.
func (b *Reader) Buffered() int { return b.w - b.r }

// ReadSlice reads up to and including delim and returns the bytes where
// they lie in the buffer, good until the next read. A line longer than the
// buffer comes in parts, each with ErrBufferFull; the end of the data
// before a delim comes with the error.
func (b *Reader) ReadSlice(delim byte) (line []byte, err error) {
	searched := 0 // bytes of the buffered data known to hold no delim
	for {
		if i := native.indexByte(b.buf[b.r+searched:b.w], delim); i >= 0 {
			end := b.r + searched + i + 1
			line = b.buf[b.r:end]
			b.r = end
			break
		}
		if b.err != nil {
			line = b.buf[b.r:b.w]
			b.r = b.w
			err = b.takeErr()
			break
		}
		if b.Buffered() >= len(b.buf) {
			b.r = b.w
			line = b.buf
			err = ErrBufferFull
			break
		}
		searched = b.w - b.r
		b.fill()
	}
	if n := len(line); n > 0 {
		b.lastByte = int(line[n-1])
		b.lastRuneSize = -1
	}
	return line, err
}

// ReadLine reads one line without its end, "\n" or "\r\n". A line longer
// than the buffer comes in parts, each but the last with isPrefix set.
// The bytes are the buffer's own. ReadString and Scanner are easier to
// use.
func (b *Reader) ReadLine() (line []byte, isPrefix bool, err error) {
	line, err = b.ReadSlice('\n')
	if err == ErrBufferFull {
		if len(line) > 0 && line[len(line)-1] == '\r' {
			// The "\n" may be next: leave the "\r" to be read with it.
			if b.r == 0 {
				panic("bufio: tried to rewind past start of buffer")
			}
			b.r--
			line = line[:len(line)-1]
		}
		return line, true, nil
	}
	if len(line) == 0 {
		if err != nil {
			line = nil
		}
		return line, false, err
	}
	// A last line without an end is a line; the error comes next time.
	err = nil
	if n := len(line); line[n-1] == '\n' {
		if n > 1 && line[n-2] == '\r' {
			n--
		}
		line = line[:n-1]
	}
	return line, false, err
}

// ReadBytes reads up to and including delim into a slice of its own. The
// end of the data before a delim returns what was read and the error.
func (b *Reader) ReadBytes(delim byte) ([]byte, error) {
	// The parts that filled the buffer are copied aside, then all are
	// joined in a slice of the exact size.
	var full [][]byte
	var last []byte
	var err error
	size := 0
	for {
		last, err = b.ReadSlice(delim)
		if err != ErrBufferFull {
			break
		}
		part := make([]byte, len(last))
		copy(part, last)
		full = append(full, part)
		size += len(part)
	}
	size += len(last)
	line := make([]byte, size)
	at := 0
	for _, part := range full {
		at += copy(line[at:], part)
	}
	copy(line[at:], last)
	return line, err
}

// ReadString is ReadBytes with the result as a string.
func (b *Reader) ReadString(delim byte) (string, error) {
	line, err := b.ReadBytes(delim)
	return string(line), err
}

// WriteTo writes to w everything b can still read, and returns the number
// of bytes written. The end of the source is not an error.
func (b *Reader) WriteTo(w io.Writer) (n int64, err error) {
	b.forgetLast()
	// What is buffered goes first; the destination is written to even
	// when that is nothing.
	n, err = b.writeBuffered(w)
	if err != nil {
		return n, err
	}
	// With the buffer empty the source and the destination may know a
	// shorter way between them.
	if source, ok := b.rd.(io.WriterTo); ok {
		m, err := source.WriteTo(w)
		return n + m, err
	}
	if destination, ok := w.(io.ReaderFrom); ok {
		m, err := destination.ReadFrom(b.rd)
		return n + m, err
	}
	if b.w-b.r < len(b.buf) {
		b.fill()
	}
	for b.r < b.w {
		m, err := b.writeBuffered(w)
		n += m
		if err != nil {
			return n, err
		}
		b.fill()
	}
	if b.err == io.EOF {
		b.err = nil
	}
	return n, b.takeErr()
}

// writeBuffered writes what is buffered to w.
func (b *Reader) writeBuffered(w io.Writer) (int64, error) {
	n, err := w.Write(b.buf[b.r:b.w])
	if n < 0 {
		panic(errNegativeWrite)
	}
	b.r += n
	return int64(n), err
}

// A Writer writes to an io.Writer through a buffer. After an error it
// accepts nothing more and every write returns that error. What is still
// buffered when the writing is done is sent by Flush.
type Writer struct {
	err error
	buf []byte
	n   int // buf[:n] is waiting to be written
	wr  io.Writer
}

// NewWriterSize returns a Writer to w whose buffer has at least size
// bytes. A Writer that is large enough already is returned as it is.
func NewWriterSize(w io.Writer, size int) *Writer {
	if b, ok := w.(*Writer); ok && len(b.buf) >= size {
		return b
	}
	if size <= 0 {
		size = defaultBufSize
	}
	return &Writer{buf: make([]byte, size), wr: w}
}

// NewWriter returns a Writer to w with a buffer of the default size.
func NewWriter(w io.Writer) *Writer {
	return NewWriterSize(w, defaultBufSize)
}

// Size is the size of the buffer.
func (b *Writer) Size() int { return len(b.buf) }

// Reset drops what is buffered and any error, and makes b write to w. A
// zero Writer gets a buffer of the default size; resetting a Writer to
// itself does nothing.
func (b *Writer) Reset(w io.Writer) {
	if same, ok := w.(*Writer); ok && same == b {
		return
	}
	if b.buf == nil {
		b.buf = make([]byte, defaultBufSize)
	}
	b.err = nil
	b.n = 0
	b.wr = w
}

// Flush writes what is buffered to the destination.
func (b *Writer) Flush() error {
	if b.err != nil {
		return b.err
	}
	if b.n == 0 {
		return nil
	}
	n, err := b.wr.Write(b.buf[0:b.n])
	if n < b.n && err == nil {
		err = io.ErrShortWrite
	}
	if err != nil {
		// What was not taken stays, at the front.
		if n > 0 && n < b.n {
			copy(b.buf[0:b.n-n], b.buf[n:b.n])
		}
		b.n -= n
		b.err = err
		return err
	}
	b.n = 0
	return nil
}

// Available is the room left in the buffer.
func (b *Writer) Available() int { return len(b.buf) - b.n }

// AvailableBuffer is an empty slice over the room left in the buffer, to
// append to and hand to Write at once.
func (b *Writer) AvailableBuffer() []byte { return b.buf[b.n:][:0] }

// Buffered is the number of bytes waiting in the buffer.
func (b *Writer) Buffered() int { return b.n }

// Write writes p. If it takes fewer than len(p) bytes it says why.
func (b *Writer) Write(p []byte) (written int, err error) {
	for len(p) > b.Available() && b.err == nil {
		var n int
		if b.Buffered() == 0 {
			// More than a buffer, and nothing before it: write it past
			// the buffer.
			n, b.err = b.wr.Write(p)
		} else {
			n = copy(b.buf[b.n:], p)
			b.n += n
			b.Flush()
		}
		written += n
		p = p[n:]
	}
	if b.err != nil {
		return written, b.err
	}
	n := copy(b.buf[b.n:], p)
	b.n += n
	return written + n, nil
}

// WriteByte writes one byte.
func (b *Writer) WriteByte(c byte) error {
	if b.err != nil {
		return b.err
	}
	if b.Available() <= 0 && b.Flush() != nil {
		return b.err
	}
	b.buf[b.n] = c
	b.n++
	return nil
}

// WriteRune writes one character in UTF-8 and returns the number of bytes
// it took.
func (b *Writer) WriteRune(r rune) (size int, err error) {
	if uint32(r) < utf8.RuneSelf {
		err = b.WriteByte(byte(r))
		if err != nil {
			return 0, err
		}
		return 1, nil
	}
	if b.err != nil {
		return 0, b.err
	}
	if b.Available() < utf8.UTFMax {
		b.Flush()
		if b.err != nil {
			return 0, b.err
		}
		if b.Available() < utf8.UTFMax {
			// A buffer too small for a rune.
			return b.WriteString(string(r))
		}
	}
	size = utf8.EncodeRune(b.buf[b.n:], r)
	b.n += size
	return size, nil
}

// WriteString writes s. If it takes fewer than len(s) bytes it says why.
func (b *Writer) WriteString(s string) (written int, err error) {
	// The bytes of s; a string cannot be cut inside a character.
	p := []byte(s)
	var direct io.StringWriter
	asked := false
	for len(p) > b.Available() && b.err == nil {
		var n int
		if b.Buffered() == 0 && !asked {
			direct, _ = b.wr.(io.StringWriter)
			asked = true
		}
		if b.Buffered() == 0 && direct != nil {
			// More than a buffer, and nothing before it: write it past
			// the buffer, as a string where the destination takes one.
			rest := s
			if written > 0 {
				rest = string(p)
			}
			n, b.err = direct.WriteString(rest)
		} else {
			n = copy(b.buf[b.n:], p)
			b.n += n
			b.Flush()
		}
		written += n
		p = p[n:]
	}
	if b.err != nil {
		return written, b.err
	}
	n := copy(b.buf[b.n:], p)
	b.n += n
	return written + n, nil
}

// ReadFrom reads r to its end into the Writer and returns the number of
// bytes read. The end of r is not an error.
func (b *Writer) ReadFrom(r io.Reader) (n int64, err error) {
	if b.err != nil {
		return 0, b.err
	}
	direct, isReaderFrom := b.wr.(io.ReaderFrom)
	for {
		if b.Available() == 0 {
			if ferr := b.Flush(); ferr != nil {
				return n, ferr
			}
		}
		if isReaderFrom && b.Buffered() == 0 {
			// Nothing is waiting: the destination reads the rest itself.
			m, rerr := direct.ReadFrom(r)
			b.err = rerr
			return n + m, rerr
		}
		m, empties := 0, 0
		for empties < maxConsecutiveEmptyReads {
			m, err = r.Read(b.buf[b.n:])
			if m != 0 || err != nil {
				break
			}
			empties++
		}
		if empties == maxConsecutiveEmptyReads {
			return n, io.ErrNoProgress
		}
		b.n += m
		n += int64(m)
		if err != nil {
			break
		}
	}
	if err == io.EOF {
		// A buffer that was filled exactly is sent on.
		if b.Available() == 0 {
			err = b.Flush()
		} else {
			err = nil
		}
	}
	return n, err
}

// A ReadWriter is a Reader and a Writer in one value, which is an
// io.ReadWriter.
type ReadWriter struct {
	*Reader
	*Writer
}

// NewReadWriter returns a ReadWriter that reads through r and writes
// through w.
func NewReadWriter(r *Reader, w *Writer) *ReadWriter {
	return &ReadWriter{r, w}
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

// fullRune is utf8.FullRune: whether p begins with a whole character, or
// with bytes that more bytes could not make one.
func fullRune(p []byte) bool {
	if len(p) == 0 {
		return false
	}
	size, lo, hi := runeShape(p[0])
	if len(p) >= size {
		return true
	}
	if len(p) > 1 && (p[1] < lo || hi < p[1]) {
		return true
	}
	if len(p) > 2 && (p[2] < 0x80 || 0xBF < p[2]) {
		return true
	}
	return false
}
