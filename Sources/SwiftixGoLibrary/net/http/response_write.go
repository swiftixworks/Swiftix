// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package http

import (
	"bytes"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// Write writes a header in wire format.
func (h Header) Write(w io.Writer) error {
	return h.writeSubset(w, nil)
}

// WriteSubset writes a header in wire format.
// If exclude is not nil, keys where exclude[key] == true are not written.
// Keys are not canonicalized before checking the exclude map.
func (h Header) WriteSubset(w io.Writer, exclude map[string]bool) error {
	return h.writeSubset(w, exclude)
}

var headerNewlineToSpace = strings.NewReplacer("\n", " ", "\r", " ")

func (h Header) writeSubset(w io.Writer, exclude map[string]bool) error {
	keys := make([]string, 0, len(h))
	for k := range h {
		if !exclude[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		if !validHeaderKey(key) {
			// This could be an error. In the common case of
			// writing response headers, however, we have no good
			// way to provide the error back to the server
			// handler, so just drop invalid headers instead.
			continue
		}
		for _, v := range h[key] {
			v = headerNewlineToSpace.Replace(v)
			v = strings.Trim(v, " \t\n\r")
			if _, err := io.WriteString(w, key+": "+v+"\r\n"); err != nil {
				return err
			}
		}
	}
	return nil
}

var respExcludeHeader = map[string]bool{
	"Content-Length":    true,
	"Transfer-Encoding": true,
	"Trailer":           true,
}

// ProtoAtLeast reports whether the HTTP protocol used
// in the response is at least major.minor.
func (r *Response) ProtoAtLeast(major, minor int) bool {
	return r.ProtoMajor > major ||
		r.ProtoMajor == major && r.ProtoMinor >= minor
}

// Write writes r to w in the HTTP/1.x server response format,
// including the status line, headers, body, and optional trailer.
//
// This method consults the following fields of the response r:
//
//	StatusCode
//	ProtoMajor
//	ProtoMinor
//	Request.Method
//	TransferEncoding
//	Trailer
//	Body
//	ContentLength
//	Header, values for non-canonical keys will have unpredictable behavior
//
// The Response Body is closed after it is sent.
func (r *Response) Write(w io.Writer) error {
	// Status line
	text := r.Status
	if text == "" {
		text = StatusText(r.StatusCode)
		if text == "" {
			text = "status code " + strconv.Itoa(r.StatusCode)
		}
	} else {
		// Just to reduce stutter, if user set r.Status to "200 OK" and StatusCode to 200.
		// Not important.
		text = strings.TrimPrefix(text, strconv.Itoa(r.StatusCode)+" ")
	}

	if _, err := fmt.Fprintf(w, "HTTP/%d.%d %03d %s\r\n", r.ProtoMajor, r.ProtoMinor, r.StatusCode, text); err != nil {
		return err
	}

	// Clone it, so we can modify r1 as needed.
	r1 := new(Response)
	*r1 = *r
	if r1.ContentLength == 0 && r1.Body != nil {
		// Is it actually 0 length? Or just unknown?
		var buf [1]byte
		n, err := r1.Body.Read(buf[:])
		if err != nil && err != io.EOF {
			return err
		}
		if n == 0 {
			// Reset it to a known zero reader, in case underlying one
			// is unhappy being read repeatedly.
			r1.Body = NoBody
		} else {
			r1.ContentLength = -1
			// Go writes struct{ io.Reader; io.Closer } in place here.
			r1.Body = readCloser{
				io.MultiReader(bytes.NewReader(buf[:1]), r.Body),
				r.Body,
			}
		}
	}
	// If we're sending a non-chunked HTTP/1.1 response without a
	// content-length, the only way to do that is the old HTTP/1.0
	// way, by noting the EOF with a connection close, so we need
	// to set Close.
	if r1.ContentLength == -1 && !r1.Close && r1.ProtoAtLeast(1, 1) && !isChunked(r1.TransferEncoding) && !r1.Uncompressed {
		r1.Close = true
	}

	// Process Body,ContentLength,Close,Trailer
	tw := newResponseTransferWriter(r1)
	if err := tw.writeHeader(w); err != nil {
		return err
	}

	// Rest of header
	if err := r.Header.WriteSubset(w, respExcludeHeader); err != nil {
		return err
	}

	// contentLengthAlreadySent may have been already sent for
	// POST/PUT requests, even if zero length. See Issue 8180.
	contentLengthAlreadySent := tw.shouldSendContentLength()
	if r1.ContentLength == 0 && !isChunked(r1.TransferEncoding) && !contentLengthAlreadySent && bodyAllowedForStatus(r.StatusCode) {
		if _, err := io.WriteString(w, "Content-Length: 0\r\n"); err != nil {
			return err
		}
	}

	// End-of-header
	if _, err := io.WriteString(w, "\r\n"); err != nil {
		return err
	}

	// Write body and trailer
	return tw.writeBody(w)
}

// responseTransferWriter is the part of Go's transferWriter that writes a
// response.
type responseTransferWriter struct {
	method           string
	body             io.Reader
	bodyCloser       io.Closer
	responseToHEAD   bool
	contentLength    int64
	close            bool
	transferEncoding []string
	header           Header
	trailer          Header
}

func newResponseTransferWriter(rr *Response) *responseTransferWriter {
	t := &responseTransferWriter{}
	if rr.Request != nil {
		t.method = rr.Request.Method
	}
	t.body = rr.Body
	t.bodyCloser = rr.Body
	t.contentLength = rr.ContentLength
	t.close = rr.Close
	t.transferEncoding = rr.TransferEncoding
	t.header = rr.Header
	t.trailer = rr.Trailer
	t.responseToHEAD = t.method == "HEAD"
	if rr.Body == nil {
		t.body = nil
		t.bodyCloser = nil
	}

	// Sanitize Body,ContentLength,TransferEncoding
	if t.responseToHEAD {
		t.body = nil
		if isChunked(t.transferEncoding) {
			t.contentLength = -1
		}
	} else {
		if !rr.ProtoAtLeast(1, 1) || t.body == nil {
			t.transferEncoding = nil
		}
		if isChunked(t.transferEncoding) {
			t.contentLength = -1
		} else if t.body == nil { // no chunking, no body
			t.contentLength = 0
		}
	}

	// Sanitize Trailer
	if !isChunked(t.transferEncoding) {
		t.trailer = nil
	}
	return t
}

func (t *responseTransferWriter) shouldSendContentLength() bool {
	if isChunked(t.transferEncoding) {
		return false
	}
	if t.contentLength > 0 {
		return true
	}
	if t.contentLength < 0 {
		return false
	}
	// Many servers expect a Content-Length for these methods
	if t.method == "POST" || t.method == "PUT" || t.method == "PATCH" {
		return true
	}
	if t.contentLength == 0 && isIdentity(t.transferEncoding) {
		if t.method == "GET" || t.method == "HEAD" {
			return false
		}
		return true
	}
	return false
}

func (t *responseTransferWriter) writeHeader(w io.Writer) error {
	if t.close && !hasToken(t.header.get("Connection"), "close") {
		if _, err := io.WriteString(w, "Connection: close\r\n"); err != nil {
			return err
		}
	}

	// Write Content-Length and/or Transfer-Encoding whose values are a
	// function of the sanitized field triple (Body, ContentLength,
	// TransferEncoding).
	if t.shouldSendContentLength() {
		if _, err := io.WriteString(w, "Content-Length: "+strconv.FormatInt(t.contentLength, 10)+"\r\n"); err != nil {
			return err
		}
	} else if isChunked(t.transferEncoding) {
		if _, err := io.WriteString(w, "Transfer-Encoding: chunked\r\n"); err != nil {
			return err
		}
	}
	if t.trailer != nil {
		keys := make([]string, 0, len(t.trailer))
		for k := range t.trailer {
			k = CanonicalHeaderKey(k)
			switch k {
			case "Transfer-Encoding", "Trailer", "Content-Length":
				return badStringError("invalid Trailer key", k)
			}
			keys = append(keys, k)
		}
		if len(keys) > 0 {
			sort.Strings(keys)
			// TODO: could do better allocation-wise here, but trailers are rare,
			// so being lazy for now.
			if _, err := io.WriteString(w, "Trailer: "+strings.Join(keys, ",")+"\r\n"); err != nil {
				return err
			}
		}
	}
	return nil
}

func (t *responseTransferWriter) writeBody(w io.Writer) (err error) {
	var ncopy int64
	closed := false
	defer func() {
		if closed || t.bodyCloser == nil {
			return
		}
		if closeErr := t.bodyCloser.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
	}()

	if !t.responseToHEAD && t.body != nil {
		if isChunked(t.transferEncoding) {
			cw := &chunkedWriter{w}
			_, err = io.Copy(cw, t.body)
			if err == nil {
				err = cw.Close()
			}
		} else if t.contentLength == -1 {
			ncopy, err = io.Copy(w, t.body)
		} else {
			ncopy, err = io.Copy(w, io.LimitReader(t.body, t.contentLength))
			if err != nil {
				return err
			}
			var nextra int64
			nextra, err = io.Copy(io.Discard, t.body)
			ncopy += nextra
		}
		if err != nil {
			return err
		}
	}
	if t.bodyCloser != nil {
		closed = true
		if err := t.bodyCloser.Close(); err != nil {
			return err
		}
	}

	if !t.responseToHEAD && t.contentLength != -1 && t.contentLength != ncopy {
		return fmt.Errorf("http: ContentLength=%d with Body length %d",
			t.contentLength, ncopy)
	}

	if isChunked(t.transferEncoding) {
		// Write Trailer header
		if t.trailer != nil {
			if err := t.trailer.Write(w); err != nil {
				return err
			}
		}
		// Last chunk, empty trailer
		_, err = io.WriteString(w, "\r\n")
	}
	return err
}

// isChunked checks whether chunked is part of the encodings stack.
func isChunked(te []string) bool { return len(te) > 0 && te[0] == "chunked" }

// isIdentity checks whether the encoding stack is a single "identity".
func isIdentity(te []string) bool { return len(te) == 1 && te[0] == "identity" }

// chunkedWriter writes in the chunked transfer encoding of HTTP/1.1.
type chunkedWriter struct {
	w io.Writer
}

func (cw *chunkedWriter) Write(data []byte) (n int, err error) {
	// Don't send 0-length data. It looks like EOF for chunked encoding.
	if len(data) == 0 {
		return 0, nil
	}
	if _, err = fmt.Fprintf(cw.w, "%x\r\n", len(data)); err != nil {
		return 0, err
	}
	if n, err = cw.w.Write(data); err != nil {
		return
	}
	if n != len(data) {
		err = io.ErrShortWrite
		return
	}
	if _, err = io.WriteString(cw.w, "\r\n"); err != nil {
		return
	}
	return
}

func (cw *chunkedWriter) Close() error {
	_, err := io.WriteString(cw.w, "0\r\n")
	return err
}

// readCloser is a reader and the closer that goes with it.
type readCloser struct {
	io.Reader
	io.Closer
}
