package strings

// A Builder collects text piece by piece and gives it as one string. Its
// zero value is empty and ready. Once written to it must not be copied:
// the copy would share its bytes, so a write through one panics.
type Builder struct {
	self *Builder // the Builder that was written to; nil until then
	buf  []byte
}

// written notes that b is being written to, and panics when what was
// written to before is another Builder that b was copied from.
func (b *Builder) written() {
	if b.self == nil {
		b.self = b
		return
	}
	if b.self != b {
		panic("strings: illegal use of non-zero Builder copied by value")
	}
}

// String is the text collected so far.
func (b *Builder) String() string { return string(b.buf) }

// Len is the number of bytes collected so far.
func (b *Builder) Len() int { return len(b.buf) }

// Cap is the number of bytes b has room for, those it holds included.
func (b *Builder) Cap() int { return cap(b.buf) }

// Reset makes b empty, and free to be copied again.
func (b *Builder) Reset() {
	b.self = nil
	b.buf = nil
}

// Grow makes room for n more bytes, so that writing them allocates
// nothing. A negative n panics.
func (b *Builder) Grow(n int) {
	b.written()
	if n < 0 {
		panic("strings.Builder.Grow: negative count")
	}
	if cap(b.buf)-len(b.buf) >= n {
		return
	}
	roomy := make([]byte, len(b.buf), 2*cap(b.buf)+n)
	copy(roomy, b.buf)
	b.buf = roomy
}

// Write adds the bytes of p. The error is always nil.
func (b *Builder) Write(p []byte) (int, error) {
	b.written()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

// WriteByte adds the byte c. The error is always nil.
func (b *Builder) WriteByte(c byte) error {
	b.written()
	b.buf = append(b.buf, c)
	return nil
}

// WriteRune adds the UTF-8 encoding of r and returns its length. A value
// that is no code point is written as U+FFFD. The error is always nil.
func (b *Builder) WriteRune(r rune) (int, error) {
	b.written()
	before := len(b.buf)
	b.buf = append(b.buf, string(r)...)
	return len(b.buf) - before, nil
}

// WriteString adds s. The error is always nil.
func (b *Builder) WriteString(s string) (int, error) {
	b.written()
	b.buf = append(b.buf, s...)
	return len(s), nil
}
