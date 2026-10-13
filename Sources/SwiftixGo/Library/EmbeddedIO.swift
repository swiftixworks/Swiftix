/// Go source of the members of `io` that are written in Go. See `GoEmbeddedLibrary`.
///
/// The text is Go as `gofmt` prints it, compiled with every program that
/// uses the package. A path under `$GOROOT/src` names each file in a
/// diagnostic, which only a mistake in this source can produce.
extension GoEmbeddedSources {
    static let io: [GoSourceFile] = [
        GoSourceFile(
            path: "$GOROOT/src/io/io.go",
            text: #"""
// Package io is the part of io that is written in Go: the interfaces, and
// the functions that call their methods. EOF and the Seek constants belong
// to the run-time library, which this file imports under the same path.
package io

import (
	"errors"
	"io"
)

// Reader is what bytes are read from. Read fills p from the start and says
// how many bytes it stored; at the end of the data it returns EOF.
type Reader interface {
	Read(p []byte) (n int, err error)
}

// Writer is what bytes are written to. Write takes all of p or returns the
// error that stopped it.
type Writer interface {
	Write(p []byte) (n int, err error)
}

// Closer is something that is given back when it is no longer used.
type Closer interface {
	Close() error
}

// ReadCloser is a Reader that is closed after use, such as the body of an
// HTTP message.
type ReadCloser interface {
	Read(p []byte) (n int, err error)
	Close() error
}

// WriteCloser is a Writer that is closed after use.
type WriteCloser interface {
	Write(p []byte) (n int, err error)
	Close() error
}

// ReadWriter is both a Reader and a Writer.
type ReadWriter interface {
	Read(p []byte) (n int, err error)
	Write(p []byte) (n int, err error)
}

// ReadWriteCloser is a Reader, a Writer, and a Closer.
type ReadWriteCloser interface {
	Read(p []byte) (n int, err error)
	Write(p []byte) (n int, err error)
	Close() error
}

// StringWriter is a writer that takes a string as it is.
type StringWriter interface {
	WriteString(s string) (n int, err error)
}

// ErrUnexpectedEOF is the end of the data where more was promised.
var ErrUnexpectedEOF = errors.New("unexpected EOF")

// ErrShortWrite is a Write that took fewer bytes than it was given and
// reported no error.
var ErrShortWrite = errors.New("short write")

// WriteString writes s to w, through w's own WriteString when it has one.
func WriteString(w Writer, s string) (n int, err error) {
	if sw, ok := w.(StringWriter); ok {
		return sw.WriteString(s)
	}
	return w.Write([]byte(s))
}

// ReadAll reads r to its end and returns everything it read. Reaching the
// end is not an error: only a failure to read is returned.
func ReadAll(r Reader) ([]byte, error) {
	b := make([]byte, 0, 512)
	for {
		n, err := r.Read(b[len(b):cap(b)])
		b = b[:len(b)+n]
		if err != nil {
			if err == io.EOF {
				err = nil
			}
			return b, err
		}
		if len(b) == cap(b) {
			// Full: have append make room, and keep the length.
			b = append(b, 0)[:len(b)]
		}
	}
}

// Copy writes to dst what it reads from src until src ends, and returns
// the number of bytes written. The end of src is not an error.
func Copy(dst Writer, src Reader) (written int, err error) {
	buf := make([]byte, 4096)
	for {
		nr, rerr := src.Read(buf)
		if nr > 0 {
			nw, werr := dst.Write(buf[:nr])
			if nw < 0 || nw > nr {
				nw = 0
				if werr == nil {
					werr = errors.New("invalid write result")
				}
			}
			written += nw
			if werr != nil {
				return written, werr
			}
			if nw != nr {
				return written, ErrShortWrite
			}
		}
		if rerr == io.EOF {
			return written, nil
		}
		if rerr != nil {
			return written, rerr
		}
	}
}

type nopCloser struct {
	r Reader
}

func (c nopCloser) Read(p []byte) (n int, err error) { return c.r.Read(p) }

func (c nopCloser) Close() error { return nil }

// NopCloser gives r a Close that does nothing.
func NopCloser(r Reader) ReadCloser {
	return nopCloser{r: r}
}

type discard struct{}

func (d discard) Write(p []byte) (int, error) { return len(p), nil }

func (d discard) WriteString(s string) (int, error) { return len(s), nil }

// Discard accepts every write and keeps nothing.
var Discard Writer = discard{}
"""#),
    ]
}
