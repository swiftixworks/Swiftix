// Drives the Go text of bufio and Go's own bufio with the same random
// operations over the same sources and destinations, and compares what
// every call returns and every call the two make of the io.Reader and the
// io.Writer they were given: the sizes they ask for, in order.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"strings"

	text "example/harness/bufio"
)

var errBroken = errors.New("broken")

// A source gives its data in pieces of random sizes, at times nothing, at
// times an error with the last bytes, and logs every call.
type source struct {
	data  []byte
	rng   *rand.Rand
	log   *[]string
	end   error
	stall bool // returns nothing for ever at the end
}

func (s *source) Read(p []byte) (int, error) {
	n := 0
	var err error
	switch {
	case len(s.data) == 0 && s.stall:
	case len(s.data) == 0:
		err = s.end
	case s.rng.Intn(8) == 0:
	default:
		n = 1 + s.rng.Intn(len(p)+1)
		if s.rng.Intn(3) == 0 {
			n = len(p)
		}
		n = min(n, len(p), len(s.data))
		copy(p, s.data[:n])
		s.data = s.data[n:]
		if len(s.data) == 0 && !s.stall && s.rng.Intn(2) == 0 {
			err = s.end
		}
	}
	*s.log = append(*s.log, fmt.Sprintf("src.Read(%d)=%d,%v", len(p), n, err))
	return n, err
}

// A source that also writes itself out.
type sourceTo struct{ *source }

func (s sourceTo) WriteTo(w io.Writer) (int64, error) {
	*s.log = append(*s.log, "src.WriteTo")
	n, err := w.Write(s.data)
	s.data = s.data[n:]
	return int64(n), err
}

// A sink logs what it is given, and at times takes less or fails.
type sink struct {
	rng    *rand.Rand
	log    *[]string
	faulty bool
}

func (s *sink) Write(p []byte) (int, error) {
	n := len(p)
	var err error
	if s.faulty && s.rng.Intn(6) == 0 {
		n = s.rng.Intn(len(p) + 1)
		if s.rng.Intn(2) == 0 {
			err = errBroken
		}
	}
	*s.log = append(*s.log, fmt.Sprintf("dst.Write(%q)=%d,%v", p, n, err))
	return n, err
}

type sinkString struct{ *sink }

func (s sinkString) WriteString(x string) (int, error) {
	*s.log = append(*s.log, "dst.WriteString")
	return s.Write([]byte(x))
}

type sinkFrom struct{ *sink }

func (s sinkFrom) ReadFrom(r io.Reader) (int64, error) {
	*s.log = append(*s.log, "dst.ReadFrom")
	var total int64
	buf := make([]byte, 7)
	for empty := 0; ; {
		n, err := r.Read(buf)
		total += int64(n)
		if n == 0 && err == nil {
			if empty++; empty > 20 {
				return total, errBroken
			}
		}
		if err == io.EOF {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}

var alphabets = []string{
	"ab\n", "abc \r\n\t", "aé世😀\n ", "a\xff\xe4\xb8\xf0\x9f\n \u2003\u0085", "x",
}

func randomData(rng *rand.Rand) []byte {
	alphabet := []byte(alphabets[rng.Intn(len(alphabets))])
	sizes := []int{0, 1, 5, 17, 40, 100, 300, 5000, 9000}
	n := rng.Intn(sizes[rng.Intn(len(sizes))] + 1)
	data := make([]byte, n)
	for i := range data {
		data[i] = alphabet[rng.Intn(len(alphabet))]
	}
	if rng.Intn(4) == 0 {
		// Long runs without a delimiter.
		for i := range data {
			if data[i] == '\n' && rng.Intn(50) != 0 {
				data[i] = 'q'
			}
		}
	}
	return data
}

func newSource(rng *rand.Rand, log *[]string) io.Reader {
	s := &source{data: randomData(rng), rng: rand.New(rand.NewSource(rng.Int63())), log: log, end: io.EOF}
	switch rng.Intn(12) {
	case 0:
		s.end = errBroken
	case 1:
		s.stall = true
	case 2:
		return sourceTo{s}
	}
	return s
}

func newSink(rng *rand.Rand, log *[]string) io.Writer {
	s := &sink{rng: rand.New(rand.NewSource(rng.Int63())), log: log, faulty: rng.Intn(4) == 0}
	switch rng.Intn(6) {
	case 0:
		return sinkString{s}
	case 1:
		return sinkFrom{s}
	}
	return s
}

type reader interface {
	io.Reader
	io.WriterTo
	ReadByte() (byte, error)
	UnreadByte() error
	ReadRune() (rune, int, error)
	UnreadRune() error
	Peek(n int) ([]byte, error)
	Discard(n int) (int, error)
	ReadSlice(delim byte) ([]byte, error)
	ReadLine() ([]byte, bool, error)
	ReadBytes(delim byte) ([]byte, error)
	ReadString(delim byte) (string, error)
	Buffered() int
	Size() int
	Reset(r io.Reader)
}

type writer interface {
	io.Writer
	io.ReaderFrom
	WriteString(s string) (int, error)
	WriteByte(c byte) error
	WriteRune(r rune) (int, error)
	Flush() error
	Available() int
	AvailableBuffer() []byte
	Buffered() int
	Size() int
	Reset(w io.Writer)
}

var sizes = []int{-1, 0, 1, 2, 3, 4, 5, 7, 15, 16, 17, 31, 32, 33, 64, 100, 4096}

func size(rng *rand.Rand) int { return sizes[rng.Intn(len(sizes))] }

// guarded runs f and adds what it panicked with to the log.
func guarded(log *[]string, f func()) (panicked bool) {
	defer func() {
		if r := recover(); r != nil {
			*log = append(*log, fmt.Sprint("panic: ", r))
			panicked = true
		}
	}()
	f()
	return false
}

func driveReader(seed int64, open func(io.Reader, int) reader) []string {
	rng := rand.New(rand.NewSource(seed))
	var log []string
	b := open(newSource(rng, &log), size(rng))
	say := func(format string, a ...any) { log = append(log, fmt.Sprintf(format, a...)) }
	delims := []byte{'\n', ' ', 'a', 0xff}
	for step := 0; step < 60; step++ {
		stop := guarded(&log, func() {
			switch rng.Intn(17) {
			case 0, 1:
				p := make([]byte, max(size(rng), 0))
				n, err := b.Read(p)
				say("Read(%d)=%d,%v %q", len(p), n, err, p[:max(n, 0)])
			case 2, 3:
				c, err := b.ReadByte()
				say("ReadByte=%d,%v", c, err)
			case 4:
				say("UnreadByte=%v", b.UnreadByte())
			case 5, 6:
				r, n, err := b.ReadRune()
				say("ReadRune=%d,%d,%v", r, n, err)
			case 7:
				say("UnreadRune=%v", b.UnreadRune())
			case 8:
				n := size(rng)
				p, err := b.Peek(n)
				say("Peek(%d)=%q,%v,%v", n, p, p == nil, err)
			case 9:
				n := size(rng)
				d, err := b.Discard(n)
				say("Discard(%d)=%d,%v", n, d, err)
			case 10:
				p, err := b.ReadSlice(delims[rng.Intn(len(delims))])
				say("ReadSlice=%q,%v,%v", p, p == nil, err)
			case 11:
				p, more, err := b.ReadLine()
				say("ReadLine=%q,%v,%v,%v", p, p == nil, more, err)
			case 12:
				p, err := b.ReadBytes(delims[rng.Intn(len(delims))])
				say("ReadBytes=%q,%v,%v", p, p == nil, err)
			case 13:
				s, err := b.ReadString(delims[rng.Intn(len(delims))])
				say("ReadString=%q,%v", s, err)
			case 14:
				say("Buffered=%d Size=%d", b.Buffered(), b.Size())
			case 15:
				if rng.Intn(4) == 0 {
					if rng.Intn(3) == 0 {
						b.Reset(b)
					} else {
						b.Reset(newSource(rng, &log))
					}
					say("Reset")
				}
			case 16:
				if rng.Intn(4) == 0 {
					n, err := b.WriteTo(newSink(rng, &log))
					say("WriteTo=%d,%v", n, err)
				}
			}
		})
		if stop {
			break
		}
	}
	return log
}

func driveWriter(seed int64, open func(io.Writer, int) writer, reader func(io.Reader, int) reader) []string {
	rng := rand.New(rand.NewSource(seed))
	var log []string
	b := open(newSink(rng, &log), size(rng))
	say := func(format string, a ...any) { log = append(log, fmt.Sprintf(format, a...)) }
	runes := []rune{'a', 'é', '世', '😀', 0xD800, -1, 0x110000, 0x7f, 0x80}
	for step := 0; step < 50; step++ {
		stop := guarded(&log, func() {
			switch rng.Intn(12) {
			case 0, 1:
				p := randomData(rng)
				n, err := b.Write(p)
				say("Write(%d)=%d,%v", len(p), n, err)
			case 2, 3:
				// Text only: a string of this dialect is valid UTF-8.
				p := strings.ToValidUTF8(string(randomData(rng)), "?")
				n, err := b.WriteString(p)
				say("WriteString(%d)=%d,%v", len(p), n, err)
			case 4, 5:
				say("WriteByte=%v", b.WriteByte(byte(rng.Intn(256))))
			case 6, 7:
				r := runes[rng.Intn(len(runes))]
				n, err := b.WriteRune(r)
				say("WriteRune(%d)=%d,%v", r, n, err)
			case 8:
				say("Flush=%v", b.Flush())
			case 9:
				a := b.AvailableBuffer()
				say("Available=%d Buffered=%d Size=%d %d/%d", b.Available(), b.Buffered(), b.Size(), len(a), cap(a))
			case 10:
				if rng.Intn(4) == 0 {
					if rng.Intn(3) == 0 {
						b.Reset(b)
					} else {
						b.Reset(newSink(rng, &log))
					}
					say("Reset")
				}
			case 11:
				if rng.Intn(3) == 0 {
					var from io.Reader = newSource(rng, &log)
					if rng.Intn(4) == 0 {
						from = reader(from, size(rng))
					}
					n, err := b.ReadFrom(from)
					say("ReadFrom=%d,%v", n, err)
				}
			}
		})
		if stop {
			break
		}
	}
	say("Flush=%v", b.Flush())
	return log
}

// The same split function for both packages: at times it ends the scan,
// and at times it asks for what it may not.
func oddSplit(rng *rand.Rand, final, negative, far error) func([]byte, bool) (int, []byte, error) {
	kind := rng.Intn(6)
	calls := 0
	return func(data []byte, atEOF bool) (int, []byte, error) {
		calls++
		switch {
		case kind == 0 && calls == 5:
			return 0, []byte("last"), final
		case kind == 1 && calls == 5:
			return 0, nil, final
		case kind == 2 && calls == 4:
			return -1, nil, nil
		case kind == 3 && calls == 4:
			return len(data) + 1, nil, nil
		case kind == 4 && atEOF:
			return 0, []byte{}, nil
		case kind == 5 && calls == 3:
			return 0, nil, errBroken
		}
		if len(data) < 3 && !atEOF {
			return 0, nil, nil
		}
		if len(data) == 0 {
			return 0, nil, nil
		}
		n := min(3, len(data))
		return n, data[:n], nil
	}
}

type scanner interface {
	Scan() bool
	Bytes() []byte
	Text() string
	Err() error
	Buffer(buf []byte, max int)
}

func driveScanner(seed int64, open func(r io.Reader, split int, rng *rand.Rand) scanner) []string {
	rng := rand.New(rand.NewSource(seed))
	var log []string
	say := func(format string, a ...any) { log = append(log, fmt.Sprintf(format, a...)) }
	split := rng.Intn(6)
	s := open(newSource(rng, &log), split, rand.New(rand.NewSource(seed*7+1)))
	if rng.Intn(2) == 0 {
		limits := []int{0, 1, 2, 5, 16, 100, 4096, 70000}
		length := rng.Intn(3) * rng.Intn(40)
		s.Buffer(make([]byte, length, length+rng.Intn(3)*rng.Intn(60)), limits[rng.Intn(len(limits))])
	}
	guarded(&log, func() {
		for i := 0; i < 400 && s.Scan(); i++ {
			say("%q %q %v", s.Bytes(), s.Text(), s.Bytes() == nil)
		}
		say("end %q %v %v", s.Bytes(), s.Err(), s.Scan())
		if rng.Intn(2) == 0 {
			s.Buffer(nil, 5)
		}
	})
	return log
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
	goReader := func(r io.Reader, n int) reader {
		if n == 4096 {
			return bufio.NewReader(r)
		}
		return bufio.NewReaderSize(r, n)
	}
	textReader := func(r io.Reader, n int) reader {
		if n == 4096 {
			return text.NewReader(r)
		}
		return text.NewReaderSize(r, n)
	}
	goWriter := func(w io.Writer, n int) writer {
		if n == 4096 {
			return bufio.NewWriter(w)
		}
		return bufio.NewWriterSize(w, n)
	}
	textWriter := func(w io.Writer, n int) writer {
		if n == 4096 {
			return text.NewWriter(w)
		}
		return text.NewWriterSize(w, n)
	}
	goScanner := func(r io.Reader, split int, rng *rand.Rand) scanner {
		s := bufio.NewScanner(r)
		switch split {
		case 0:
			s.Split(bufio.ScanBytes)
		case 1:
			s.Split(bufio.ScanRunes)
		case 2:
			s.Split(bufio.ScanWords)
		case 3:
			s.Split(bufio.ScanLines)
		case 4:
			s.Split(oddSplit(rng, bufio.ErrFinalToken, bufio.ErrNegativeAdvance, bufio.ErrAdvanceTooFar))
		}
		return s
	}
	textScanner := func(r io.Reader, split int, rng *rand.Rand) scanner {
		s := text.NewScanner(r)
		switch split {
		case 0:
			s.Split(text.ScanBytes)
		case 1:
			s.Split(text.ScanRunes)
		case 2:
			s.Split(text.ScanWords)
		case 3:
			s.Split(text.ScanLines)
		case 4:
			s.Split(oddSplit(rng, text.ErrFinalToken, text.ErrNegativeAdvance, text.ErrAdvanceTooFar))
		}
		return s
	}
	const rounds = 20000
	for seed := int64(0); seed < rounds; seed++ {
		compare("Reader", seed, driveReader(seed, goReader), driveReader(seed, textReader))
		compare("Writer", seed, driveWriter(seed, goWriter, goReader), driveWriter(seed, textWriter, textReader))
		compare("Scanner", seed, driveScanner(seed, goScanner), driveScanner(seed, textScanner))
	}
	// The errors are worded as Go's.
	pairs := [][2]error{
		{bufio.ErrInvalidUnreadByte, text.ErrInvalidUnreadByte}, {bufio.ErrInvalidUnreadRune, text.ErrInvalidUnreadRune},
		{bufio.ErrBufferFull, text.ErrBufferFull}, {bufio.ErrNegativeCount, text.ErrNegativeCount},
		{bufio.ErrTooLong, text.ErrTooLong}, {bufio.ErrNegativeAdvance, text.ErrNegativeAdvance},
		{bufio.ErrAdvanceTooFar, text.ErrAdvanceTooFar}, {bufio.ErrBadReadCount, text.ErrBadReadCount},
		{bufio.ErrFinalToken, text.ErrFinalToken},
	}
	for _, pair := range pairs {
		if pair[0].Error() != pair[1].Error() {
			failures++
			fmt.Printf("error text differs: %q, %q\n", pair[0], pair[1])
		}
	}
	if text.MaxScanTokenSize != bufio.MaxScanTokenSize {
		failures++
		fmt.Println("MaxScanTokenSize differs")
	}
	if failures > 0 {
		fmt.Printf("%d sequences differ\n", failures)
		os.Exit(1)
	}
	fmt.Printf("bufio: %d random sequences each of Reader, Writer, and Scanner are Go's\n", rounds)
}
