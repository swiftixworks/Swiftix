// Drives the Go text of bytes and Go's own bytes with the same random
// inputs and compares what they return, down to whether a result is nil,
// and for a Buffer its capacity after every operation.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"unicode"

	text "example/harness/bytes"
)

var errBroken = errors.New("broken")

var alphabets = []string{
	"ab", "abc ,", "aAbB kK\u212a sS\u017f", "aé世😀 \t\n", "a\xff\xe4\xb8\xf0\x9f \u2003\u0085\xc2",
	"\u0130\u0131iI", "\u03b8\u03d1\u0398\u03f4\u00b5\u039c\u03bc\u01c4\u01c5\u01c6", "x",
}

func randomBytes(rng *rand.Rand) []byte {
	alphabet := []byte(alphabets[rng.Intn(len(alphabets))])
	sizes := []int{0, 0, 1, 2, 3, 5, 9, 30}
	n := rng.Intn(sizes[rng.Intn(len(sizes))] + 1)
	if n == 0 && rng.Intn(2) == 0 {
		return nil
	}
	data := make([]byte, n)
	for i := range data {
		data[i] = alphabet[rng.Intn(len(alphabet))]
	}
	return data
}

func show(b []byte) string { return fmt.Sprintf("%q/%v", b, b == nil) }

func showAll(parts [][]byte) string {
	s := fmt.Sprintf("%d/%v:", len(parts), parts == nil)
	for _, p := range parts {
		s += show(p) + ","
	}
	return s
}

// guarded is what f returns, or what it panicked with.
func guarded(f func() string) (result string) {
	defer func() {
		if r := recover(); r != nil {
			result = fmt.Sprint("panic: ", r)
		}
	}()
	return f()
}

func functions(seed int64) (want, got []string) {
	rng := rand.New(rand.NewSource(seed))
	a, b, c := randomBytes(rng), randomBytes(rng), randomBytes(rng)
	if rng.Intn(3) == 0 && len(a) > 0 {
		lo := rng.Intn(len(a))
		b = a[lo : lo+rng.Intn(len(a)-lo+1)]
	}
	if rng.Intn(4) == 0 {
		// The same text in another case.
		b = bytes.ToUpper(a)
		if rng.Intn(2) == 0 {
			b = bytes.ToLower(a)
		}
	}
	n := rng.Intn(6) - 2
	cutset := string(bytes.ToValidUTF8(c, []byte("\uFFFD")))
	parts := [][]byte{a, b, c}[:rng.Intn(4)]
	if rng.Intn(8) == 0 {
		parts = nil
	}
	var delim byte = ' '
	if len(c) > 0 {
		delim = c[0]
	}
	add := func(list *[]string, name string, f func() string) {
		*list = append(*list, name+" "+guarded(f))
	}
	both := func(name string, real, mine func() string) {
		add(&want, name, real)
		add(&got, name, mine)
	}
	both("Equal", func() string { return fmt.Sprint(bytes.Equal(a, b)) }, func() string { return fmt.Sprint(text.Equal(a, b)) })
	both("Compare", func() string { return fmt.Sprint(bytes.Compare(a, b)) }, func() string { return fmt.Sprint(text.Compare(a, b)) })
	both("Contains", func() string { return fmt.Sprint(bytes.Contains(a, b)) }, func() string { return fmt.Sprint(text.Contains(a, b)) })
	both("Index", func() string { return fmt.Sprint(bytes.Index(a, b)) }, func() string { return fmt.Sprint(text.Index(a, b)) })
	both("IndexByte", func() string { return fmt.Sprint(bytes.IndexByte(a, delim)) }, func() string { return fmt.Sprint(text.IndexByte(a, delim)) })
	both("LastIndex", func() string { return fmt.Sprint(bytes.LastIndex(a, b)) }, func() string { return fmt.Sprint(text.LastIndex(a, b)) })
	both("LastIndexByte", func() string { return fmt.Sprint(bytes.LastIndexByte(a, delim)) }, func() string { return fmt.Sprint(text.LastIndexByte(a, delim)) })
	both("HasPrefix", func() string { return fmt.Sprint(bytes.HasPrefix(a, b)) }, func() string { return fmt.Sprint(text.HasPrefix(a, b)) })
	both("HasSuffix", func() string { return fmt.Sprint(bytes.HasSuffix(a, b)) }, func() string { return fmt.Sprint(text.HasSuffix(a, b)) })
	both("Count", func() string { return fmt.Sprint(bytes.Count(a, b)) }, func() string { return fmt.Sprint(text.Count(a, b)) })
	both("EqualFold", func() string { return fmt.Sprint(bytes.EqualFold(a, b)) }, func() string { return fmt.Sprint(text.EqualFold(a, b)) })
	both("Split", func() string { return showAll(bytes.Split(a, b)) }, func() string { return showAll(text.Split(a, b)) })
	both("SplitN", func() string { return showAll(bytes.SplitN(a, b, n)) }, func() string { return showAll(text.SplitN(a, b, n)) })
	both("Join", func() string { return show(bytes.Join(parts, c)) }, func() string { return show(text.Join(parts, c)) })
	both("Fields", func() string { return showAll(bytes.Fields(a)) }, func() string { return showAll(text.Fields(a)) })
	both("TrimSpace", func() string { return show(bytes.TrimSpace(a)) }, func() string { return show(text.TrimSpace(a)) })
	both("Trim", func() string { return show(bytes.Trim(a, cutset)) }, func() string { return show(text.Trim(a, cutset)) })
	both("TrimLeft", func() string { return show(bytes.TrimLeft(a, cutset)) }, func() string { return show(text.TrimLeft(a, cutset)) })
	both("TrimRight", func() string { return show(bytes.TrimRight(a, cutset)) }, func() string { return show(text.TrimRight(a, cutset)) })
	both("TrimPrefix", func() string { return show(bytes.TrimPrefix(a, b)) }, func() string { return show(text.TrimPrefix(a, b)) })
	both("TrimSuffix", func() string { return show(bytes.TrimSuffix(a, b)) }, func() string { return show(text.TrimSuffix(a, b)) })
	both("ToUpper", func() string { return show(bytes.ToUpper(a)) }, func() string { return show(text.ToUpper(a)) })
	both("ToLower", func() string { return show(bytes.ToLower(a)) }, func() string { return show(text.ToLower(a)) })
	both("Repeat", func() string { return show(bytes.Repeat(a, n*3)) }, func() string { return show(text.Repeat(a, n*3)) })
	both("Replace", func() string { return show(bytes.Replace(a, b, c, n)) }, func() string { return show(text.Replace(a, b, c, n)) })
	both("ReplaceAll", func() string { return show(bytes.ReplaceAll(a, b, c)) }, func() string { return show(text.ReplaceAll(a, b, c)) })
	both("Clone", func() string { return show(bytes.Clone(a)) }, func() string { return show(text.Clone(a)) })
	both("Cut", func() string {
		x, y, ok := bytes.Cut(a, b)
		return show(x) + show(y) + fmt.Sprint(ok)
	}, func() string {
		x, y, ok := text.Cut(a, b)
		return show(x) + show(y) + fmt.Sprint(ok)
	})
	return want, got
}

type buffer interface {
	io.ReadWriter
	io.ReaderFrom
	io.WriterTo
	WriteString(s string) (int, error)
	WriteByte(c byte) error
	WriteRune(r rune) (int, error)
	ReadByte() (byte, error)
	UnreadByte() error
	ReadRune() (rune, int, error)
	UnreadRune() error
	ReadBytes(delim byte) ([]byte, error)
	ReadString(delim byte) (string, error)
	Next(n int) []byte
	Bytes() []byte
	AvailableBuffer() []byte
	String() string
	Len() int
	Cap() int
	Available() int
	Reset()
	Truncate(n int)
	Grow(n int)
}

type source struct {
	data []byte
	rng  *rand.Rand
	end  error
}

func (s *source) Read(p []byte) (int, error) {
	if len(s.data) == 0 {
		return 0, s.end
	}
	n := min(1+s.rng.Intn(len(p)+1), len(p), len(s.data))
	copy(p, s.data[:n])
	s.data = s.data[n:]
	return n, nil
}

type sink struct {
	rng *rand.Rand
	log *[]string
}

func (s *sink) Write(p []byte) (int, error) {
	n := len(p)
	var err error
	switch s.rng.Intn(6) {
	case 0:
		n = s.rng.Intn(len(p) + 1)
	case 1:
		n = s.rng.Intn(len(p) + 1)
		err = errBroken
	}
	*s.log = append(*s.log, fmt.Sprintf("dst.Write(%q)=%d,%v", p, n, err))
	return n, err
}

var amounts = []int{-1, 0, 1, 2, 3, 5, 8, 31, 32, 33, 63, 64, 65, 100, 500, 513, 2000, 40000}

func driveBuffer(seed int64, open func(kind int, initial []byte) buffer) []string {
	rng := rand.New(rand.NewSource(seed))
	var log []string
	say := func(format string, a ...any) { log = append(log, fmt.Sprintf(format, a...)) }
	initial := make([]byte, rng.Intn(40), 40+rng.Intn(40))
	for i := range initial {
		initial[i] = byte('a' + i%26)
	}
	b := open(rng.Intn(3), initial)
	runes := []rune{'a', 'é', '世', '😀', 0xD800, -1, 0x110000, '\n'}
	amount := func() int { return amounts[rng.Intn(len(amounts))] }
	long := func() []byte {
		p := make([]byte, max(amount(), 0)%3000)
		alphabet := alphabets[rng.Intn(len(alphabets))]
		for i := range p {
			p[i] = alphabet[rng.Intn(len(alphabet))]
		}
		return p
	}
	for step := 0; step < 60; step++ {
		log = append(log, guarded(func() string {
			switch rng.Intn(21) {
			case 0, 1, 2:
				p := long()
				n, err := b.Write(p)
				return fmt.Sprintf("Write(%d)=%d,%v", len(p), n, err)
			case 3, 4:
				p := string(bytes.ToValidUTF8(long(), []byte("?")))
				n, err := b.WriteString(p)
				return fmt.Sprintf("WriteString(%d)=%d,%v", len(p), n, err)
			case 5:
				return fmt.Sprintf("WriteByte=%v", b.WriteByte(byte(rng.Intn(256))))
			case 6:
				r := runes[rng.Intn(len(runes))]
				n, err := b.WriteRune(r)
				return fmt.Sprintf("WriteRune(%d)=%d,%v", r, n, err)
			case 7, 8:
				p := make([]byte, max(amount(), 0)%600)
				n, err := b.Read(p)
				return fmt.Sprintf("Read(%d)=%d,%v %q", len(p), n, err, p[:n])
			case 9:
				c, err := b.ReadByte()
				return fmt.Sprintf("ReadByte=%d,%v", c, err)
			case 10:
				return fmt.Sprintf("UnreadByte=%v", b.UnreadByte())
			case 11:
				r, n, err := b.ReadRune()
				return fmt.Sprintf("ReadRune=%d,%d,%v", r, n, err)
			case 12:
				return fmt.Sprintf("UnreadRune=%v", b.UnreadRune())
			case 13:
				p, err := b.ReadBytes("\n a\xff"[rng.Intn(4)])
				return fmt.Sprintf("ReadBytes=%s,%v", show(p), err)
			case 14:
				s, err := b.ReadString("\n a\xff"[rng.Intn(4)])
				return fmt.Sprintf("ReadString=%q,%v", s, err)
			case 15:
				n := amount()
				return fmt.Sprintf("Next(%d)=%s", n, show(b.Next(n)))
			case 16:
				n := amount()
				if rng.Intn(2) == 0 && b.Len() > 0 {
					n = rng.Intn(b.Len() + 1)
				}
				b.Truncate(n)
				return fmt.Sprintf("Truncate(%d)", n)
			case 17:
				n := amount()
				b.Grow(n)
				return fmt.Sprintf("Grow(%d)", n)
			case 18:
				if rng.Intn(3) == 0 {
					b.Reset()
					return "Reset"
				}
				// What is written into Bytes is read later.
				if p := b.Bytes(); len(p) > 0 {
					p[rng.Intn(len(p))] = 'Z'
				}
				return "Bytes"
			case 19:
				src := &source{data: long(), rng: rand.New(rand.NewSource(rng.Int63())), end: io.EOF}
				if rng.Intn(5) == 0 {
					src.end = errBroken
				}
				n, err := b.ReadFrom(src)
				return fmt.Sprintf("ReadFrom=%d,%v", n, err)
			default:
				if rng.Intn(3) != 0 {
					return "-"
				}
				n, err := b.WriteTo(&sink{rng: rand.New(rand.NewSource(rng.Int63())), log: &log})
				return fmt.Sprintf("WriteTo=%d,%v", n, err)
			}
		}))
		a := b.AvailableBuffer()
		say("  len=%d cap=%d available=%d %d/%d %s %q", b.Len(), b.Cap(), b.Available(), len(a), cap(a), show(b.Bytes()), b.String())
	}
	return log
}

type reader interface {
	io.Reader
	io.ReaderAt
	io.Seeker
	io.WriterTo
	ReadByte() (byte, error)
	UnreadByte() error
	ReadRune() (rune, int, error)
	UnreadRune() error
	Len() int
	Size() int64
	Reset(b []byte)
}

func driveReader(seed int64, open func([]byte) reader) []string {
	rng := rand.New(rand.NewSource(seed))
	var log []string
	say := func(format string, a ...any) { log = append(log, fmt.Sprintf(format, a...)) }
	r := open(randomBytes(rng))
	for step := 0; step < 40; step++ {
		log = append(log, guarded(func() string {
			switch rng.Intn(10) {
			case 0, 1:
				p := make([]byte, rng.Intn(6))
				n, err := r.Read(p)
				return fmt.Sprintf("Read(%d)=%d,%v %q", len(p), n, err, p[:n])
			case 2:
				p := make([]byte, rng.Intn(6))
				off := int64(rng.Intn(12) - 2)
				n, err := r.ReadAt(p, off)
				return fmt.Sprintf("ReadAt(%d,%d)=%d,%v %q", len(p), off, n, err, p[:n])
			case 3:
				c, err := r.ReadByte()
				return fmt.Sprintf("ReadByte=%d,%v", c, err)
			case 4:
				return fmt.Sprintf("UnreadByte=%v", r.UnreadByte())
			case 5, 6:
				c, n, err := r.ReadRune()
				return fmt.Sprintf("ReadRune=%d,%d,%v", c, n, err)
			case 7:
				return fmt.Sprintf("UnreadRune=%v", r.UnreadRune())
			case 8:
				off, whence := int64(rng.Intn(14)-6), rng.Intn(4)
				n, err := r.Seek(off, whence)
				return fmt.Sprintf("Seek(%d,%d)=%d,%v", off, whence, n, err)
			default:
				switch rng.Intn(6) {
				case 0:
					r.Reset(randomBytes(rng))
					return "Reset"
				case 1:
					n, err := r.WriteTo(&sink{rng: rand.New(rand.NewSource(rng.Int63())), log: &log})
					return fmt.Sprintf("WriteTo=%d,%v", n, err)
				}
				return "-"
			}
		}))
		say("  len=%d size=%d", r.Len(), r.Size())
	}
	return log
}

// sameFold is the rule of the text for two characters, through EqualFold.
func sameFold(a, b rune) bool {
	return text.EqualFold([]byte(string(a)), []byte(string(b)))
}

func main() {
	failures := 0
	compare := func(what string, seed int64, want, got []string) {
		for i := 0; i < len(want) || i < len(got); i++ {
			w, g := "(nothing)", "(nothing)"
			if i < len(want) {
				w = want[i]
			}
			if i < len(got) {
				g = got[i]
			}
			if w != g {
				failures++
				if failures <= 10 {
					fmt.Printf("%s seed %d differs at step %d:\n  go:   %.300s\n  text: %.300s\n", what, seed, i, w, g)
					for j := max(0, i-6); j < i; j++ {
						fmt.Printf("    before: %.200s\n", want[j])
					}
				}
				return
			}
		}
	}
	goBuffer := func(kind int, initial []byte) buffer {
		switch kind {
		case 0:
			return new(bytes.Buffer)
		case 1:
			return bytes.NewBuffer(append(make([]byte, 0, len(initial)), initial...))
		}
		return bytes.NewBuffer(append(make([]byte, 0, cap(initial)), initial...))
	}
	textBuffer := func(kind int, initial []byte) buffer {
		switch kind {
		case 0:
			return new(text.Buffer)
		case 1:
			return text.NewBuffer(append(make([]byte, 0, len(initial)), initial...))
		}
		return text.NewBuffer(append(make([]byte, 0, cap(initial)), initial...))
	}
	const rounds = 200000
	for seed := int64(0); seed < rounds; seed++ {
		want, got := functions(seed)
		compare("functions", seed, want, got)
		if seed%10 == 0 {
			compare("Buffer", seed, driveBuffer(seed, goBuffer), driveBuffer(seed, textBuffer))
			compare("Reader", seed, driveReader(seed, func(b []byte) reader { return bytes.NewReader(b) }),
				driveReader(seed, func(b []byte) reader { return text.NewReader(b) }))
		}
	}
	// Two characters fold together exactly when Go's table says so: each
	// with all of its orbit, and with nothing outside it among the
	// characters that have a case at all.
	var cased []rune
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if r >= 0xD800 && r <= 0xDFFF {
			continue
		}
		if unicode.SimpleFold(r) != r {
			cased = append(cased, r)
		}
		for x := unicode.SimpleFold(r); x != r; x = unicode.SimpleFold(x) {
			if !sameFold(r, x) {
				failures++
				fmt.Printf("%U and %U do not fold together\n", r, x)
			}
		}
		for _, x := range []rune{unicode.ToUpper(r), unicode.ToLower(r), 'k', 's', 'i', 'I', 0x130, 0x131} {
			if sameFold(r, x) != bytes.EqualFold([]byte(string(r)), []byte(string(x))) {
				failures++
				fmt.Printf("%U and %U fold differently\n", r, x)
			}
		}
	}
	for _, a := range cased {
		for _, b := range cased {
			if a < b && sameFold(a, b) != bytes.EqualFold([]byte(string(a)), []byte(string(b))) {
				failures++
				fmt.Printf("%U and %U fold differently\n", a, b)
			}
		}
	}
	// A NewBufferString begins with the content, whatever its capacity.
	for _, s := range []string{"", "a", "héllo", "a string longer than the small buffer of sixty-four bytes, to be sure"} {
		if a, b := bytes.NewBufferString(s), text.NewBufferString(s); a.String() != b.String() || a.Len() != b.Len() {
			failures++
			fmt.Printf("NewBufferString(%q) differs\n", s)
		}
	}
	var none *text.Buffer
	if none.String() != "<nil>" || text.MinRead != bytes.MinRead || text.ErrTooLarge.Error() != bytes.ErrTooLarge.Error() {
		failures++
		fmt.Println("a constant, an error, or the nil Buffer differs")
	}
	if failures > 0 {
		fmt.Printf("%d differences\n", failures)
		os.Exit(1)
	}
	fmt.Printf("bytes: %d random inputs of every function, %d sequences each of Buffer and Reader, and the folding of %d cased characters are Go's\n", rounds, rounds/10, len(cased))
}
