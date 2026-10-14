package http

import (
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"
)

// ErrLineTooLong is returned for a chunk header or a trailer line that is
// longer than a line of a message may be.
var ErrLineTooLong = errors.New("header line too long")

var errTrailerEOF = errors.New("http: unexpected EOF reading trailer")

// errTooLarge is a request header that is larger than the server reads.
var errTooLarge = errors.New("http: request too large")

// A connReader is the incoming side of a connection: what has been read
// from it and not yet used. A server and a client both read messages
// through one, a line at a time for the header and by the byte for a body.
type connReader struct {
	conn net.Conn
	// The bytes read and not used, and where a read from the connection
	// lands before it is added to them.
	buf     []byte
	scratch []byte
	// What ended reading from the connection.
	err error
	// How many more bytes of a header may be used, when limited.
	limited bool
	remain  int
	// A read under way in a goroutine of its own, and the read deadline
	// (deadline.go).
	pending     chan pendingRead
	hasDeadline bool
	expired     bool
	deadline    *time.Timer
}

func newConnReader(conn net.Conn) *connReader {
	return &connReader{conn: conn, scratch: make([]byte, 4096)}
}

// fill reads once from the connection, waiting for it.
func (r *connReader) fill() error {
	if r.err != nil {
		return r.err
	}
	if r.pending != nil || r.hasDeadline {
		return r.fillPending()
	}
	n, err := r.conn.Read(r.scratch)
	if n > 0 {
		r.buf = append(r.buf, r.scratch[:n]...)
		return nil
	}
	if err == nil {
		err = io.ErrUnexpectedEOF
	}
	r.err = err
	return err
}

// peek waits until n bytes are there to use, and reports whether they are.
func (r *connReader) peek(n int) bool {
	for len(r.buf) < n {
		if r.fill() != nil {
			return false
		}
	}
	return true
}

// consume uses up the first n bytes.
func (r *connReader) consume(n int) {
	if n >= len(r.buf) {
		r.buf = r.buf[:0]
		return
	}
	r.buf = r.buf[n:]
}

// Read gives the bytes there are, and waits for some when there are none.
func (r *connReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if len(r.buf) == 0 {
		if err := r.fill(); err != nil {
			return 0, err
		}
	}
	n := copy(p, r.buf)
	r.consume(n)
	return n, nil
}

// readSlice returns the next line with its line feed. When the connection
// ends first it returns what there was, and the error.
func (r *connReader) readSlice() (string, error) {
	from := 0
	for {
		end := native.lineEnd(r.buf, from)
		if end >= 0 {
			if r.limited {
				r.remain -= end
				if r.remain < 0 {
					return "", errTooLarge
				}
			}
			line := string(r.buf[:end])
			r.consume(end)
			return line, nil
		}
		from = len(r.buf)
		if r.limited && from > r.remain {
			return "", errTooLarge
		}
		if err := r.fill(); err != nil {
			line := string(r.buf)
			r.consume(len(r.buf))
			return line, err
		}
	}
}

// readLine returns the next line without its end, which is a line feed
// with or without a carriage return before it. The last line of a
// connection that ends without a line feed is a line too.
func (r *connReader) readLine() (string, error) {
	line, err := r.readSlice()
	if err != nil {
		if line != "" && err != errTooLarge {
			return line, nil
		}
		return "", err
	}
	line = line[:len(line)-1]
	if strings.HasSuffix(line, "\r") {
		line = line[:len(line)-1]
	}
	return line, nil
}

// A protocolError is a header that is not what the protocol says.
type protocolError string

func (e protocolError) Error() string { return string(e) }

// readHeader reads header fields up to the empty line that ends them. A
// line that begins with a space or a tab continues the field before it.
func (r *connReader) readHeader() (Header, error) {
	h := Header{}
	if r.peek(1) && (r.buf[0] == ' ' || r.buf[0] == '\t') {
		line, err := r.readLine()
		if err != nil {
			return h, err
		}
		return h, protocolError("malformed MIME header initial line: " + line)
	}
	for {
		line, err := r.readLine()
		if err != nil {
			return h, err
		}
		if line == "" {
			return h, nil
		}
		colon := strings.Index(line, ":")
		if colon < 0 {
			return h, protocolError(fmt.Sprintf("malformed MIME header: missing colon: %q", line))
		}
		line = trimOWS(line)
		// The lines that continue this one, each after a single space.
		for r.peek(1) && (r.buf[0] == ' ' || r.buf[0] == '\t') {
			more, err := r.readLine()
			if err != nil {
				break
			}
			line += " " + trimOWS(more)
		}
		key := line[:colon]
		value := line[colon+1:]
		if key == "" || !validHeaderKey(key) || !native.validHeaderValue(value) {
			return h, protocolError("malformed MIME header line: " + line)
		}
		key = native.CanonicalHeaderKey(key)
		for len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
			value = value[1:]
		}
		h[key] = append(h[key], value)
	}
}

// validHeaderKey reports whether key is a token, or one with spaces, which
// is kept as it is so that the request can be refused for it.
func validHeaderKey(key string) bool {
	if native.validToken(key) {
		return true
	}
	if !strings.Contains(key, " ") {
		return false
	}
	return native.validToken(strings.Join(strings.Split(key, " "), ""))
}

// The most of a request body that is read and thrown away after a handler
// that did not read it, so that the next request can follow on the same
// connection.
const maxPostHandlerReadBytes = 256 << 10

// A body is the body of a message on a connection: so many bytes, chunks
// up to an empty one, or everything until the connection ends.
type body struct {
	src *connReader
	// The message whose trailer follows the chunks.
	req *Request
	res *Response

	chunked bool
	// The bytes left of a body with a length, or -1 for one without.
	remaining int
	// The bytes left of the chunk being read, and whether the line break
	// after it is still to come.
	chunkLeft int
	checkEnd  bool
	chunkErr  error
	// Bytes of chunk headers beyond what the data accounts for.
	excess int

	// Whether the connection closes after this message, and whether Close
	// gives up on a long remainder instead of reading it.
	closing      bool
	doEarlyClose bool

	mu         sync.Mutex
	sawEOF     bool
	closed     bool
	earlyClose bool
	// Called when the body is closed or read to its end.
	onDone func()
}

func (b *body) Read(p []byte) (n int, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return 0, ErrBodyReadAfterClose
	}
	return b.readLocked(p)
}

func (b *body) readLocked(p []byte) (n int, err error) {
	if b.sawEOF {
		return 0, io.EOF
	}
	if b.chunked {
		n, err = b.readChunked(p)
		if err == io.EOF {
			b.sawEOF = true
			if e := b.readTrailer(); e != nil {
				err = e
				b.sawEOF = false
				b.closed = true
			}
		}
	} else if b.remaining >= 0 {
		if len(p) > b.remaining {
			p = p[:b.remaining]
		}
		n, err = b.src.Read(p)
		b.remaining -= n
		if err == io.EOF {
			// The connection ended before the body did.
			b.sawEOF = true
			if b.remaining > 0 {
				err = io.ErrUnexpectedEOF
			}
		} else if err == nil && n > 0 && b.remaining == 0 {
			err = io.EOF
			b.sawEOF = true
		}
	} else {
		n, err = b.src.Read(p)
		if err == io.EOF {
			b.sawEOF = true
		}
	}
	if b.sawEOF && b.onDone != nil {
		done := b.onDone
		b.onDone = nil
		done()
	}
	return n, err
}

// readChunked reads the data of the chunks. It waits for the first byte
// and then gives what is there, so a reader sees a chunk when it arrives.
func (b *body) readChunked(p []byte) (n int, err error) {
	for b.chunkErr == nil {
		if b.checkEnd {
			if n > 0 && len(b.src.buf) < 2 {
				// Something was read: do not wait for the line break.
				break
			}
			if !b.src.peek(2) {
				b.chunkErr = io.ErrUnexpectedEOF
				break
			}
			if b.src.buf[0] != '\r' || b.src.buf[1] != '\n' {
				b.chunkErr = errors.New("malformed chunked encoding")
				break
			}
			b.src.consume(2)
			b.checkEnd = false
		}
		if b.chunkLeft == 0 {
			if n > 0 && native.lineEnd(b.src.buf, 0) < 0 {
				// The header of the next chunk is yet to arrive.
				break
			}
			b.beginChunk()
			continue
		}
		if len(p) == 0 {
			break
		}
		rbuf := p
		if len(rbuf) > b.chunkLeft {
			rbuf = rbuf[:b.chunkLeft]
		}
		n0, rerr := b.src.Read(rbuf)
		n += n0
		p = p[n0:]
		b.chunkLeft -= n0
		if rerr != nil {
			b.chunkErr = rerr
			if rerr == io.EOF {
				b.chunkErr = io.ErrUnexpectedEOF
			}
		} else if b.chunkLeft == 0 {
			b.checkEnd = true
		}
	}
	return n, b.chunkErr
}

// beginChunk reads the line that says how long the next chunk is.
func (b *body) beginChunk() {
	line, err := b.src.readSlice()
	if err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		b.chunkErr = err
		return
	}
	cr := strings.Index(line, "\r")
	if cr < 0 {
		b.chunkErr = errors.New("chunked line ends with bare LF")
		return
	}
	if cr != len(line)-2 {
		b.chunkErr = errors.New("invalid CR in chunked line")
		return
	}
	line = line[:len(line)-2]
	if len(line) >= 4096 {
		b.chunkErr = ErrLineTooLong
		return
	}
	b.excess += len(line) + 2
	for len(line) > 0 && (line[len(line)-1] == ' ' || line[len(line)-1] == '\t') {
		line = line[:len(line)-1]
	}
	// What follows a semicolon is an extension, which is not looked at.
	if semi := strings.Index(line, ";"); semi >= 0 {
		line = line[:semi]
	}
	size, err := parseHexUint(line)
	if err != nil {
		b.chunkErr = err
		return
	}
	b.chunkLeft = size
	b.excess -= 16 + 2*size
	if b.excess < 0 {
		b.excess = 0
	}
	if b.excess > 16*1024 {
		b.chunkErr = errors.New("chunked encoding contains too much non-data")
		return
	}
	if size == 0 {
		b.chunkErr = io.EOF
	}
}

func parseHexUint(v string) (int, error) {
	if len(v) == 0 {
		return 0, errors.New("empty hex number for chunk length")
	}
	n := 0
	for i := 0; i < len(v); i++ {
		c := v[i]
		d := 0
		switch {
		case '0' <= c && c <= '9':
			d = int(c - '0')
		case 'a' <= c && c <= 'f':
			d = int(c-'a') + 10
		case 'A' <= c && c <= 'F':
			d = int(c-'A') + 10
		default:
			return 0, errors.New("invalid byte in chunk length")
		}
		// Sixteen digits are a length, and no length is as long as they
		// could say.
		if i == 16 || n >= 1<<59 {
			return 0, errors.New("http chunk length too large")
		}
		n = n*16 + d
	}
	return n, nil
}

// readTrailer reads what follows the last chunk: an empty line, or header
// fields and then one, which become the message's Trailer.
func (b *body) readTrailer() error {
	if !b.src.peek(2) {
		return errTrailerEOF
	}
	if b.src.buf[0] == '\r' && b.src.buf[1] == '\n' {
		b.src.consume(2)
		return nil
	}
	hdr, err := b.src.readHeader()
	if err != nil {
		if err == io.EOF {
			return errTrailerEOF
		}
		return err
	}
	if b.req != nil {
		if b.req.Trailer == nil {
			b.req.Trailer = Header{}
		}
		for k, vv := range hdr {
			b.req.Trailer[k] = vv
		}
	}
	if b.res != nil {
		if b.res.Trailer == nil {
			b.res.Trailer = Header{}
		}
		for k, vv := range hdr {
			b.res.Trailer[k] = vv
		}
	}
	return nil
}

func (b *body) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil
	}
	var err error
	switch {
	case b.sawEOF:
		// Read to the end already.
	case !b.chunked && b.closing:
		// The connection closes next: nothing has to be read.
	case b.doEarlyClose:
		if !b.chunked && b.remaining > maxPostHandlerReadBytes {
			b.earlyClose = true
		} else {
			n := 0
			n, err = b.discard(maxPostHandlerReadBytes)
			if err == io.EOF {
				err = nil
			}
			if n == maxPostHandlerReadBytes {
				b.earlyClose = true
			}
		}
	default:
		_, err = b.discard(-1)
		if err == io.EOF {
			err = nil
		}
	}
	b.closed = true
	if b.onDone != nil {
		done := b.onDone
		b.onDone = nil
		done()
	}
	return err
}

// discard reads and drops up to limit bytes of the body, all of it when
// limit is negative, and returns how many and what stopped it.
func (b *body) discard(limit int) (int, error) {
	buf := make([]byte, 4096)
	total := 0
	for limit < 0 || total < limit {
		p := buf
		if limit >= 0 && len(p) > limit-total {
			p = p[:limit-total]
		}
		n, err := b.readLocked(p)
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// unreadSize returns how many bytes of the body are still to be read, or
// -1 when that is not known.
func (b *body) unreadSize() int {
	if b.chunked {
		return -1
	}
	return b.remaining
}

// A transfer says how the body of a message being read is delimited.
type transfer struct {
	header        Header
	isResponse    bool
	status        int
	requestMethod string
	protoMajor    int
	protoMinor    int

	chunked       bool
	contentLength int
	closing       bool
}

// An unsupportedTEError is a transfer coding this package cannot read.
type unsupportedTEError struct {
	err string
}

func (e *unsupportedTEError) Error() string { return e.err }

// bodyAllowedForStatus reports whether a response with the status may have
// a body.
func bodyAllowedForStatus(status int) bool {
	switch {
	case status >= 100 && status <= 199:
		return false
	case status == 204:
		return false
	case status == 304:
		return false
	}
	return true
}

// shouldClose reports whether the header of a message asks for the
// connection to end with it.
func shouldClose(major, minor int, header Header, removeCloseHeader bool) bool {
	if major < 1 {
		return true
	}
	conv := header["Connection"]
	hasClose := valuesContainToken(conv, "close")
	if major == 1 && minor == 0 {
		return hasClose || !valuesContainToken(conv, "keep-alive")
	}
	if hasClose && removeCloseHeader {
		header.Del("Connection")
	}
	return hasClose
}

// prepare works out the framing of the message from its header, and takes
// the fields that describe it out of the header as Go does.
func (t *transfer) prepare() error {
	if t.protoMajor == 0 && t.protoMinor == 0 {
		t.protoMajor = 1
		t.protoMinor = 1
	}
	// The transfer coding. Only "chunked" is one a message may have.
	if raw, present := t.header["Transfer-Encoding"]; present {
		delete(t.header, "Transfer-Encoding")
		if t.protoMajor > 1 || t.protoMajor == 1 && t.protoMinor >= 1 {
			if len(raw) != 1 {
				return &unsupportedTEError{err: fmt.Sprintf("too many transfer encodings: %q", raw)}
			}
			if strings.ToLower(raw[0]) != "chunked" {
				return &unsupportedTEError{err: fmt.Sprintf("unsupported transfer encoding: %q", raw[0])}
			}
			t.chunked = true
		}
	}
	realLength, err := t.fixLength()
	if err != nil {
		return err
	}
	if t.isResponse && t.requestMethod == "HEAD" {
		n, err := parseContentLength(t.header["Content-Length"])
		if err != nil {
			return err
		}
		t.contentLength = n
	} else {
		t.contentLength = realLength
	}
	if t.isResponse && realLength == -1 && !t.chunked && bodyAllowedForStatus(t.status) {
		// Nothing says where the body ends but the end of the connection.
		t.closing = true
	}
	return nil
}

// fixLength returns the length of the body the header declares: -1 for a
// body in chunks or one that the end of the connection ends.
func (t *transfer) fixLength() (int, error) {
	contentLens := t.header["Content-Length"]
	// Several fields that say the same are one.
	if len(contentLens) > 1 {
		first := trimString(contentLens[0])
		for _, ct := range contentLens[1:] {
			if first != trimString(ct) {
				return 0, fmt.Errorf("http: message cannot contain multiple Content-Length headers; got %q", contentLens)
			}
		}
		t.header.Del("Content-Length")
		t.header.Add("Content-Length", first)
		contentLens = t.header["Content-Length"]
	}
	n := 0
	if len(contentLens) > 0 {
		var err error
		n, err = parseContentLength(contentLens)
		if err != nil {
			return -1, err
		}
	}
	if t.isResponse && t.requestMethod == "HEAD" {
		return 0, nil
	}
	if t.status/100 == 1 {
		return 0, nil
	}
	if t.status == 204 || t.status == 304 {
		return 0, nil
	}
	if t.chunked {
		t.header.Del("Content-Length")
		return -1, nil
	}
	if len(contentLens) > 0 {
		return n, nil
	}
	t.header.Del("Content-Length")
	if !t.isResponse {
		// A request without a length has no body.
		return 0, nil
	}
	return -1, nil
}

// trailerKeys returns the header a Trailer field announces: its keys,
// each without a value yet.
func (t *transfer) trailerKeys() (Header, error) {
	vv, ok := t.header["Trailer"]
	if !ok {
		return nil, nil
	}
	if !t.chunked {
		// A trailer needs chunks to follow.
		return nil, nil
	}
	t.header.Del("Trailer")
	trailer := Header{}
	for _, v := range vv {
		for _, key := range strings.Split(v, ",") {
			key = CanonicalHeaderKey(trimString(key))
			if key == "" {
				continue
			}
			switch key {
			case "Transfer-Encoding", "Trailer", "Content-Length":
				return nil, badStringError("bad trailer key", key)
			}
			trailer[key] = nil
		}
	}
	if len(trailer) == 0 {
		return nil, nil
	}
	return trailer, nil
}
