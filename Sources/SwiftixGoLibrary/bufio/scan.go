package bufio

import (
	"errors"
	"io"
	"unicode/utf8"
)

// A Scanner reads a source token by token: by default line by line, each
// without its end. Scan steps to the next token, Bytes and Text give it,
// and when Scan returns false Err says whether the source failed.
//
// A token that does not fit the buffer stops the scan; a program that must
// go on, or wants the error where it happens, uses a Reader.
type Scanner struct {
	r            io.Reader
	split        SplitFunc
	maxTokenSize int
	token        []byte
	buf          []byte
	// buf[start:end] is what has been read and not yet split.
	start, end int
	err        error
	// Empty tokens in a row that advanced nothing.
	empties    int
	scanCalled bool
	done       bool
}

// A SplitFunc finds the next token in data, the bytes not yet split, and
// says how many of them the Scanner is to step over. atEOF is set when the
// source has no more. No token and no error asks for more data; an error
// stops the scan, ErrFinalToken after delivering the token returned with
// it.
type SplitFunc func(data []byte, atEOF bool) (advance int, token []byte, err error)

var (
	ErrTooLong         = errors.New("bufio.Scanner: token too long")
	ErrNegativeAdvance = errors.New("bufio.Scanner: SplitFunc returns negative advance count")
	ErrAdvanceTooFar   = errors.New("bufio.Scanner: SplitFunc returns advance count beyond input")
	ErrBadReadCount    = errors.New("bufio.Scanner: Read returned impossible count")
)

// ErrFinalToken is what a SplitFunc returns with the last token to end the
// scan there, without an error.
var ErrFinalToken = errors.New("final token")

const (
	// MaxScanTokenSize is the longest token a Scanner takes unless Buffer
	// gave it another limit.
	MaxScanTokenSize = 64 * 1024

	startBufSize = 4096
)

// NewScanner returns a Scanner of r that splits lines.
func NewScanner(r io.Reader) *Scanner {
	return &Scanner{r: r, split: ScanLines, maxTokenSize: MaxScanTokenSize}
}

// Err is the error that ended the scan; the end of the source is none.
func (s *Scanner) Err() error {
	if s.err == io.EOF {
		return nil
	}
	return s.err
}

// Bytes is the token of the last Scan, where it lies in the buffer: the
// next Scan may overwrite it.
func (s *Scanner) Bytes() []byte { return s.token }

// Text is the token of the last Scan as a string.
func (s *Scanner) Text() string { return string(s.token) }

// Scan steps to the next token and says whether there is one.
func (s *Scanner) Scan() bool {
	if s.done {
		return false
	}
	s.scanCalled = true
	for {
		// Split what is there, if anything is, or if the source has
		// ended and the split function may have a last word.
		if s.end > s.start || s.err != nil {
			advance, token, err := s.split(s.buf[s.start:s.end], s.err != nil)
			if err != nil {
				if err == ErrFinalToken {
					s.token = token
					s.done = true
					// A nil token with it only ends the scan.
					return token != nil
				}
				s.setErr(err)
				return false
			}
			if !s.advance(advance) {
				return false
			}
			s.token = token
			if token != nil {
				if s.err == nil || advance > 0 {
					s.empties = 0
				} else {
					// An empty token at the end that steps over
					// nothing could be returned for ever.
					s.empties++
					if s.empties > maxConsecutiveEmptyReads {
						panic("bufio.Scan: too many empty tokens without progressing")
					}
				}
				return true
			}
		}
		// No token in what is there, and nothing more to come.
		if s.err != nil {
			s.start = 0
			s.end = 0
			return false
		}
		// Make room: move the data to the front when much of the buffer
		// lies before it, and grow the buffer when it is full.
		if s.start > 0 && (s.end == len(s.buf) || s.start > len(s.buf)/2) {
			copy(s.buf, s.buf[s.start:s.end])
			s.end -= s.start
			s.start = 0
		}
		if s.end == len(s.buf) {
			const maxInt = int(^uint(0) >> 1)
			if len(s.buf) >= s.maxTokenSize || len(s.buf) > maxInt/2 {
				s.setErr(ErrTooLong)
				return false
			}
			size := len(s.buf) * 2
			if size == 0 {
				size = startBufSize
			}
			if size > s.maxTokenSize {
				size = s.maxTokenSize
			}
			grown := make([]byte, size)
			copy(grown, s.buf[s.start:s.end])
			s.buf = grown
			s.end -= s.start
			s.start = 0
		}
		// Read until something comes: a source may return nothing a few
		// times without having ended.
		empty := 0
		for {
			n, err := s.r.Read(s.buf[s.end:len(s.buf)])
			if n < 0 || len(s.buf)-s.end < n {
				s.setErr(ErrBadReadCount)
				break
			}
			s.end += n
			if err != nil {
				s.setErr(err)
				break
			}
			if n > 0 {
				s.empties = 0
				break
			}
			empty++
			if empty > maxConsecutiveEmptyReads {
				s.setErr(io.ErrNoProgress)
				break
			}
		}
	}
}

// advance steps over n bytes, if the split function may ask for that.
func (s *Scanner) advance(n int) bool {
	if n < 0 {
		s.setErr(ErrNegativeAdvance)
		return false
	}
	if n > s.end-s.start {
		s.setErr(ErrAdvanceTooFar)
		return false
	}
	s.start += n
	return true
}

// setErr keeps the first error; the end of the source gives way to one.
func (s *Scanner) setErr(err error) {
	if s.err == nil || s.err == io.EOF {
		s.err = err
	}
}

// Buffer gives the Scanner the buffer to start with and the size it may
// grow it to, which is the longest token: max, or cap(buf) if that is
// more. It is called before the first Scan.
func (s *Scanner) Buffer(buf []byte, max int) {
	if s.scanCalled {
		panic("Buffer called after Scan")
	}
	s.buf = buf[0:cap(buf)]
	s.maxTokenSize = max
}

// Split sets the function that finds the tokens. It is called before the
// first Scan.
func (s *Scanner) Split(split SplitFunc) {
	if s.scanCalled {
		panic("Split called after Scan")
	}
	s.split = split
}

// ScanBytes is a split function whose tokens are the bytes.
func ScanBytes(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}
	return 1, data[0:1], nil
}

// ScanRunes is a split function whose tokens are the characters in UTF-8.
// A byte that begins none is the token U+FFFD, as it is for a range over a
// string.
func ScanRunes(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}
	if data[0] < utf8.RuneSelf {
		return 1, data[0:1], nil
	}
	if _, width := decodeRune(data); width > 1 {
		return width, data[0:width], nil
	}
	// One byte of something: an error, unless more bytes may complete it.
	if !atEOF && !fullRune(data) {
		return 0, nil, nil
	}
	return 1, []byte(string(utf8.RuneError)), nil
}

// ScanLines is a split function whose tokens are the lines, each without
// its end: "\n", with a "\r" before it or not. An empty line is a token;
// the last line needs no end.
func ScanLines(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}
	if i := native.indexByte(data, '\n'); i >= 0 {
		return i + 1, withoutCR(data[0:i]), nil
	}
	if atEOF {
		return len(data), withoutCR(data), nil
	}
	return 0, nil, nil
}

func withoutCR(line []byte) []byte {
	if n := len(line); n > 0 && line[n-1] == '\r' {
		return line[0 : n-1]
	}
	return line
}

// isSpace is unicode.IsSpace, which this package has as a list of its own
// as Go's has.
func isSpace(r rune) bool {
	if r <= 0xFF {
		switch r {
		case ' ', '\t', '\n', '\v', '\f', '\r', 0x85, 0xA0:
			return true
		}
		return false
	}
	if 0x2000 <= r && r <= 0x200a {
		return true
	}
	switch r {
	case 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
		return true
	}
	return false
}

// ScanWords is a split function whose tokens are the words between white
// space. No token is empty.
func ScanWords(data []byte, atEOF bool) (advance int, token []byte, err error) {
	// Over the space before the word.
	start := 0
	for start < len(data) {
		r, width := decodeRune(data[start:])
		if !isSpace(r) {
			break
		}
		start += width
	}
	// To the space after it.
	for i := start; i < len(data); {
		r, width := decodeRune(data[i:])
		if isSpace(r) {
			return i + width, data[start:i], nil
		}
		i += width
	}
	if atEOF && len(data) > start {
		return len(data), data[start:], nil
	}
	// The word may go on.
	return start, nil, nil
}
