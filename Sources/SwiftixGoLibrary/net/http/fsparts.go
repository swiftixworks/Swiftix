// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package http

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"sort"
	"strings"
	"time"
)

// What fs.go takes from other packages: Go's ParseTime, and the parts of
// mime/multipart's Writer and net/textproto's MIMEHeader that a response
// of several ranges is written with.

var timeFormats = []string{
	TimeFormat,
	time.RFC850,
	time.ANSIC,
}

// ParseTime parses a time header (such as the Date: header),
// trying each of the three formats allowed by HTTP/1.1:
// [TimeFormat], [time.RFC850], and [time.ANSIC].
func ParseTime(text string) (t time.Time, err error) {
	for _, layout := range timeFormats {
		t, err = time.Parse(layout, text)
		if err == nil {
			return
		}
	}
	return
}

// mimeHeader is textproto.MIMEHeader.
type mimeHeader map[string][]string

// multipartWriter is mime/multipart's Writer.
type multipartWriter struct {
	w        io.Writer
	boundary string
	lastpart *multipartPart
}

func newMultipartWriter(w io.Writer) *multipartWriter {
	return &multipartWriter{
		w:        w,
		boundary: randomBoundary(),
	}
}

// Boundary returns the [Writer]'s boundary.
func (w *multipartWriter) Boundary() string {
	return w.boundary
}

// randomBoundary is 30 random bytes in hexadecimal, as Go's: those of
// math/rand here, where Go reads crypto/rand.
func randomBoundary() string {
	var buf [30]byte
	rand.Read(buf[:])
	return fmt.Sprintf("%x", buf[:])
}

// CreatePart creates a new multipart section with the provided
// header. The body of the part should be written to the returned
// [Writer]. After calling CreatePart, any previous part may no longer
// be written to.
func (w *multipartWriter) CreatePart(header mimeHeader) (io.Writer, error) {
	if w.lastpart != nil {
		if err := w.lastpart.close(); err != nil {
			return nil, err
		}
	}
	var b bytes.Buffer
	if w.lastpart != nil {
		fmt.Fprintf(&b, "\r\n--%s\r\n", w.boundary)
	} else {
		fmt.Fprintf(&b, "--%s\r\n", w.boundary)
	}

	keys := make([]string, 0, len(header))
	for k := range header {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		for _, v := range header[k] {
			fmt.Fprintf(&b, "%s: %s\r\n", k, v)
		}
	}
	fmt.Fprintf(&b, "\r\n")
	_, err := io.Copy(w.w, &b)
	if err != nil {
		return nil, err
	}
	p := &multipartPart{
		mw: w,
	}
	w.lastpart = p
	return p, nil
}

// Close finishes the multipart message and writes the trailing
// boundary end line to the output.
func (w *multipartWriter) Close() error {
	if w.lastpart != nil {
		if err := w.lastpart.close(); err != nil {
			return err
		}
		w.lastpart = nil
	}
	_, err := fmt.Fprintf(w.w, "\r\n--%s--\r\n", w.boundary)
	return err
}

type multipartPart struct {
	mw     *multipartWriter
	closed bool
	we     error // last error that occurred writing
}

func (p *multipartPart) close() error {
	p.closed = true
	return p.we
}

func (p *multipartPart) Write(d []byte) (n int, err error) {
	if p.closed {
		return 0, errors.New("multipart: can't write to finished part")
	}
	n, err = p.mw.w.Write(d)
	if err != nil {
		p.we = err
	}
	return
}

// The algorithm uses at most sniffLen bytes to make its decision.
const sniffLen = 512

var htmlReplacer = strings.NewReplacer(
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	// "&#34;" is shorter than "&quot;".
	`"`, "&#34;",
	// "&#39;" is shorter than "&apos;" and apos was not in HTML until HTML5.
	"'", "&#39;",
)
