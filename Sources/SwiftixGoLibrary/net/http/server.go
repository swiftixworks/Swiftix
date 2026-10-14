// Package http is an HTTP/1.1 server and client.
//
// It is written in Go and compiled with the program that imports it, so a
// handler is an ordinary function of the program: each connection is served
// by a goroutine of its own, a handler shares the program's variables like
// any goroutine does, and a handler that panics ends its own connection.
// What a server sends and accepts follows Go's net/http, message for
// message. The work that goes over a message byte by byte belongs to the
// run-time library, which the package reaches by importing its own path.
package http

import (
	"errors"
	"fmt"
	"io"
	"net"
	urlpkg "net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Errors a handler can meet when it writes a response.
var (
	// ErrBodyNotAllowed is returned by Write when the status of the
	// response says that it has no body.
	ErrBodyNotAllowed = errors.New("http: request method or response status code does not allow body")

	// ErrContentLength is returned by Write when the handler declared a
	// Content-Length and writes more than that.
	ErrContentLength = errors.New("http: wrote more than the declared Content-Length")
)

// ErrAbortHandler is a value to panic with to end a handler without the
// server logging the panic.
var ErrAbortHandler = errors.New("net/http: abort Handler")

// ErrServerClosed is what Go's Serve and ListenAndServe return after a
// server was closed.
var ErrServerClosed = errors.New("http: Server closed")

// A Handler answers an HTTP request: it writes the header and the body of
// the response to the ResponseWriter, and returns when it is done.
type Handler interface {
	ServeHTTP(ResponseWriter, *Request)
}

// A ResponseWriter is what a handler writes its response to.
type ResponseWriter interface {
	// Header returns the header that WriteHeader will send. Changing it
	// after the header was sent changes nothing.
	Header() Header

	// Write writes part of the body. Before the first byte it sends the
	// header with the status 200, when WriteHeader has not been called,
	// and a Content-Type found from the first bytes, when none is set.
	Write([]byte) (int, error)

	// WriteHeader sends the header with the status code. Only the first
	// call does.
	WriteHeader(statusCode int)
}

// A Flusher is a ResponseWriter that can send what was written so far.
type Flusher interface {
	Flush()
}

// HandlerFunc makes a function a Handler: f(w, r) is the handling.
type HandlerFunc func(ResponseWriter, *Request)

// ServeHTTP calls f(w, r).
func (f HandlerFunc) ServeHTTP(w ResponseWriter, r *Request) {
	f(w, r)
}

// How much of a response body is kept before the header is sent, so that a
// small response can say its length and a larger one is sent in chunks.
const bufferBeforeChunkingSize = 2048

// How much of the outgoing side of a connection is kept before it is sent.
const connWriteBufferSize = 4096

// The most header a server reads of one request.
const defaultMaxHeaderBytes = 1 << 20

// DefaultMaxHeaderBytes is the most header a server reads of one request.
const DefaultMaxHeaderBytes = defaultMaxHeaderBytes

// The time format of HTTP, for a time in GMT.
const TimeFormat = "Mon, 02 Jan 2006 15:04:05 GMT"

// A conn is the server's side of one connection.
type conn struct {
	server     *Server
	rwc        net.Conn
	remoteAddr string
	r          *connReader
	// What was written and not yet sent, and the error of a send.
	out  []byte
	werr error
	// The method of the request before this one.
	lastMethod string
}

// write adds p to what is to be sent, and sends when that is a buffer full.
func (c *conn) write(p []byte) {
	c.out = append(c.out, p...)
	if len(c.out) >= connWriteBufferSize {
		c.flush()
	}
}

func (c *conn) writeString(s string) {
	c.out = append(c.out, s...)
	if len(c.out) >= connWriteBufferSize {
		c.flush()
	}
}

// flush sends what was written.
func (c *conn) flush() error {
	if len(c.out) == 0 {
		return c.werr
	}
	if c.werr == nil {
		_, err := c.rwc.Write(c.out)
		if err != nil {
			c.werr = err
		}
	}
	c.out = c.out[:0]
	return c.werr
}

// A statusError is a request the server refuses with a status of its own.
type statusError struct {
	code int
	text string
}

func (e statusError) Error() string { return StatusText(e.code) + ": " + e.text }

func badRequestError(e string) error { return statusError{code: StatusBadRequest, text: e} }

// readRequest reads the next request of the connection and makes the
// response its handler writes to.
func (c *conn) readRequest() (*response, error) {
	c.r.limited = true
	c.r.remain = c.server.maxHeaderBytes() + 4096
	if c.lastMethod == "POST" {
		// Some clients send a line break after the body of a POST.
		c.r.peek(4)
		n := 0
		for n < 4 && n < len(c.r.buf) && (c.r.buf[n] == '\r' || c.r.buf[n] == '\n') {
			n++
		}
		c.r.consume(n)
	}
	req, err := readRequest(c.r)
	c.r.limited = false
	if err != nil {
		return nil, err
	}

	if req.ProtoMajor != 1 && !(req.ProtoMajor == 2 && req.ProtoMinor == 0 && req.Method == "PRI" && req.RequestURI == "*") {
		return nil, statusError{code: StatusHTTPVersionNotSupported, text: "unsupported protocol version"}
	}

	c.lastMethod = req.Method

	hosts, haveHost := req.Header["Host"]
	if req.ProtoAtLeast(1, 1) && (!haveHost || len(hosts) == 0) && req.Method != "CONNECT" {
		return nil, badRequestError("missing required Host header")
	}
	if len(hosts) == 1 && !validHostHeader(hosts[0]) {
		return nil, badRequestError("malformed Host header")
	}
	for k := range req.Header {
		if !native.validToken(k) {
			return nil, badRequestError("invalid header name")
		}
	}
	delete(req.Header, "Host")

	req.RemoteAddr = c.remoteAddr
	if b, ok := req.Body.(*body); ok {
		b.doEarlyClose = true
	}

	w := &response{
		conn:          c,
		req:           req,
		reqBody:       req.Body,
		handlerHeader: Header{},
		contentLength: -1,

		// Read now: a handler may change the request's header.
		wants10KeepAlive: req.wantsHttp10KeepAlive(),
		wantsClose:       req.wantsClose(),
	}
	return w, nil
}

// validHostHeader reports whether h may be the value of a Host header.
func validHostHeader(h string) bool {
	for i := 0; i < len(h); i++ {
		c := h[i]
		switch {
		case 'a' <= c && c <= 'z', 'A' <= c && c <= 'Z', '0' <= c && c <= '9':
		case c >= 0x80:
		default:
			if !strings.Contains("!$&'()*+,;=:[]-._~%/", string(c)) {
				return false
			}
		}
	}
	return true
}

// readRequest reads a request line and a header, and prepares the body.
func readRequest(r *connReader) (*Request, error) {
	line, err := r.readLine()
	if err != nil {
		return nil, err
	}
	req, err := parseRequest(line, r)
	if err == io.EOF {
		// The connection ended inside the request.
		err = io.ErrUnexpectedEOF
	}
	return req, err
}

func parseRequest(line string, r *connReader) (*Request, error) {
	req := &Request{}
	// The request line: a method, a target, and a version.
	sp1 := strings.Index(line, " ")
	sp2 := -1
	if sp1 >= 0 {
		sp2 = strings.Index(line[sp1+1:], " ")
	}
	if sp1 < 0 || sp2 < 0 {
		return nil, badStringError("malformed HTTP request", line)
	}
	req.Method = line[:sp1]
	req.RequestURI = line[sp1+1 : sp1+1+sp2]
	req.Proto = line[sp1+sp2+2:]
	if !native.validToken(req.Method) {
		return nil, badStringError("invalid method", req.Method)
	}
	var ok bool
	if req.ProtoMajor, req.ProtoMinor, ok = parseHTTPVersion(req.Proto); !ok {
		return nil, badStringError("malformed HTTP version", req.Proto)
	}

	// The target of CONNECT is a host and a port, and no URL.
	rawurl := req.RequestURI
	justAuthority := req.Method == "CONNECT" && !strings.HasPrefix(rawurl, "/")
	if justAuthority {
		rawurl = "http://" + rawurl
	}
	var err error
	if req.URL, err = urlpkg.ParseRequestURI(rawurl); err != nil {
		return nil, err
	}
	if justAuthority {
		req.URL.Scheme = ""
	}

	req.Header, err = r.readHeader()
	if err != nil {
		return nil, err
	}
	if len(req.Header["Host"]) > 1 {
		return nil, fmt.Errorf("too many Host headers")
	}

	// An absolute target names the host, and a Host line is then ignored.
	req.Host = req.URL.Host
	if req.Host == "" {
		req.Host = req.Header.get("Host")
	}

	if _, ok := req.Header["Cache-Control"]; !ok {
		if pragma := req.Header["Pragma"]; len(pragma) > 0 && pragma[0] == "no-cache" {
			req.Header["Cache-Control"] = []string{"no-cache"}
		}
	}

	req.Close = shouldClose(req.ProtoMajor, req.ProtoMinor, req.Header, false)

	t := &transfer{
		header:        req.Header,
		requestMethod: req.Method,
		protoMajor:    req.ProtoMajor,
		protoMinor:    req.ProtoMinor,
		status:        200,
		closing:       req.Close,
	}
	if err := t.prepare(); err != nil {
		return nil, err
	}
	req.Trailer, err = t.trailerKeys()
	if err != nil {
		return nil, err
	}
	req.ContentLength = int64(t.contentLength)
	req.Close = t.closing
	switch {
	case t.chunked:
		req.TransferEncoding = []string{"chunked"}
		req.Body = &body{src: r, req: req, chunked: true, remaining: -1, closing: t.closing}
	case t.contentLength > 0:
		req.Body = &body{src: r, remaining: t.contentLength, closing: t.closing}
	default:
		req.Body = NoBody
	}
	return req, nil
}

// A response is the ResponseWriter of one request. What a handler writes
// goes through two stages: the first bufferBeforeChunkingSize bytes are
// kept, so that a handler that returns before writing more gets a
// Content-Length, and from there on the body is sent in chunks.
type response struct {
	conn    *conn
	req     *Request
	reqBody io.ReadCloser

	// Whether WriteHeader was called with a final status, and the status.
	wroteHeader bool
	status      int

	wants10KeepAlive bool
	wantsClose       bool
	// Whether the body of the request waits for "100 Continue".
	canWriteContinue bool

	// The body bytes kept back from the chunk stage.
	buf []byte

	// The header the handler changes, and the copy that is sent, taken
	// when the status was set.
	handlerHeader Header
	calledHeader  bool
	header        Header

	// The chunk stage: whether the header has been sent, and whether the
	// body goes in chunks.
	sentHeader bool
	chunking   bool

	// The bytes the handler wrote, and the Content-Length it declared.
	written       int
	contentLength int

	closeAfterReply     bool
	requestBodyLimitHit bool
	handlerDone         bool
	trailers            []string
}

func (w *response) Header() Header {
	if w.header == nil && w.wroteHeader && !w.sentHeader {
		// The status is set and the header not yet sent: what is sent is
		// what the header was then.
		w.header = w.handlerHeader.Clone()
	}
	w.calledHeader = true
	return w.handlerHeader
}

func (w *response) WriteHeader(code int) {
	if w.wroteHeader {
		w.conn.server.logf("http: superfluous response.WriteHeader call")
		return
	}
	if code < 100 || code > 999 {
		panic(fmt.Sprintf("invalid WriteHeader code %v", code))
	}
	if code < 101 || code > 199 {
		// Any header but an interim one answers the request, and the
		// client is not told to continue after that.
		w.canWriteContinue = false
	}
	// An interim response: it is sent at once, and the final one follows.
	if code >= 100 && code <= 199 && code != StatusSwitchingProtocols {
		w.conn.writeString(statusLine(w.req.ProtoAtLeast(1, 1), code))
		interim := w.handlerHeader.Clone()
		interim.Del("Content-Length")
		interim.Del("Transfer-Encoding")
		w.conn.writeString(interim.text() + "\r\n")
		w.conn.flush()
		return
	}

	w.wroteHeader = true
	w.status = code

	if w.calledHeader && w.header == nil {
		w.header = w.handlerHeader.Clone()
	}

	if cl := w.handlerHeader.get("Content-Length"); cl != "" {
		v, err := parseContentLength([]string{cl})
		if err == nil && v >= 0 && cl == trimString(cl) {
			w.contentLength = v
		} else {
			w.conn.server.logf("http: invalid Content-Length of %q", cl)
			w.handlerHeader.Del("Content-Length")
		}
	}
}

func (w *response) Write(data []byte) (n int, err error) {
	if err := w.beforeWrite(len(data)); err != nil || len(data) == 0 {
		return 0, err
	}
	// The keeping stage, as a buffered writer does it: a write that does
	// not fit fills the buffer and sends it, and a write into an empty
	// buffer that is larger than the buffer is sent as it is.
	p := data
	for len(p) > bufferBeforeChunkingSize-len(w.buf) {
		if len(w.buf) == 0 {
			w.sendBody(p)
			return len(data), nil
		}
		room := bufferBeforeChunkingSize - len(w.buf)
		w.buf = append(w.buf, p[:room]...)
		p = p[room:]
		w.flushBuffer()
	}
	w.buf = append(w.buf, p...)
	return len(data), nil
}

// WriteString is Write for a string.
func (w *response) WriteString(data string) (n int, err error) {
	if err := w.beforeWrite(len(data)); err != nil || len(data) == 0 {
		return 0, err
	}
	// A string is copied into the buffer, a buffer at a time.
	s := data
	for len(s) > bufferBeforeChunkingSize-len(w.buf) {
		room := bufferBeforeChunkingSize - len(w.buf)
		w.buf = append(w.buf, s[:room]...)
		s = s[room:]
		w.flushBuffer()
	}
	w.buf = append(w.buf, s...)
	return len(data), nil
}

// beforeWrite does what every write of n bytes begins with: the header
// gets its status, and a write the response cannot have is refused.
func (w *response) beforeWrite(n int) error {
	w.canWriteContinue = false
	if !w.wroteHeader {
		w.WriteHeader(StatusOK)
	}
	if n == 0 {
		return nil
	}
	if !bodyAllowedForStatus(w.status) {
		return ErrBodyNotAllowed
	}
	w.written += n
	if w.contentLength != -1 && w.written > w.contentLength {
		return ErrContentLength
	}
	return nil
}

// flushBuffer passes the kept bytes on to the chunk stage.
func (w *response) flushBuffer() {
	if len(w.buf) == 0 {
		return
	}
	w.sendBody(w.buf)
	w.buf = w.buf[:0]
}

// sendBody is the chunk stage: p goes to the connection, after the header
// when this is the first of the body, and as a chunk when the body is sent
// in chunks.
func (w *response) sendBody(p []byte) {
	if !w.sentHeader {
		w.sendHeader(p)
	}
	if w.req.Method == "HEAD" {
		// The answer to HEAD is the header alone.
		return
	}
	if w.chunking {
		w.conn.writeString(fmt.Sprintf("%x", len(p)) + "\r\n")
	}
	w.conn.write(p)
	if w.chunking {
		w.conn.writeString("\r\n")
	}
}

// Flush sends what was written so far to the client.
func (w *response) Flush() {
	if !w.wroteHeader {
		w.WriteHeader(StatusOK)
	}
	w.flushBuffer()
	if !w.sentHeader {
		w.sendHeader(nil)
	}
	w.conn.flush()
}

// statusLine returns the first line of a response.
func statusLine(is11 bool, code int) string {
	proto := "HTTP/1.0 "
	if is11 {
		proto = "HTTP/1.1 "
	}
	if text := StatusText(code); text != "" {
		return proto + strconv.Itoa(code) + " " + text + "\r\n"
	}
	return proto + fmt.Sprintf("%03d status code %d\r\n", code, code)
}

// sendHeader decides how the response is framed and sends its header. p is
// the first of the body: when the handler is done it is all of it, and its
// length is the Content-Length; otherwise an HTTP/1.1 response is sent in
// chunks, and an HTTP/1.0 one ends with the connection.
func (w *response) sendHeader(p []byte) {
	if w.sentHeader {
		return
	}
	w.sentHeader = true

	keepAlivesEnabled := w.conn.server.doKeepAlives()
	isHEAD := w.req.Method == "HEAD"

	header := w.header
	if header == nil {
		header = Header{}
	}
	// What the server adds, each written after the handler's fields.
	date := ""
	contentLength := ""
	contentType := ""
	connection := ""
	transferEncoding := ""

	// A key with the trailer prefix is a trailer, not a field.
	trailers := false
	for k := range header {
		if strings.HasPrefix(k, TrailerPrefix) {
			trailers = true
		}
	}
	if trailers {
		for _, k := range w.trailerKeys(header) {
			delete(header, k)
		}
	}
	for _, v := range header["Trailer"] {
		trailers = true
		for _, key := range strings.Split(v, ",") {
			if key = trimString(key); key != "" {
				w.declareTrailer(key)
			}
		}
	}

	te := header.get("Transfer-Encoding")
	hasTE := te != ""

	// A handler that is done and declared no length wrote all there is.
	// HEAD is the exception when nothing was written: the handler may
	// have known that the body would not be sent.
	if w.handlerDone && !trailers && !hasTE && bodyAllowedForStatus(w.status) && !header.has("Content-Length") && (!isHEAD || len(p) > 0) {
		w.contentLength = len(p)
		contentLength = strconv.Itoa(len(p))
	}

	// An HTTP/1.0 client that asked to keep the connection gets that when
	// the response says how long it is.
	if w.wants10KeepAlive && keepAlivesEnabled {
		sentLength := header.get("Content-Length") != ""
		if sentLength && header.get("Connection") == "keep-alive" {
			w.closeAfterReply = false
		}
	}

	hasCL := w.contentLength != -1

	if w.wants10KeepAlive && (isHEAD || hasCL || !bodyAllowedForStatus(w.status)) {
		if !header.has("Connection") {
			connection = "keep-alive"
		}
	} else if !w.req.ProtoAtLeast(1, 1) || w.wantsClose {
		w.closeAfterReply = true
	}

	if header.get("Connection") == "close" || !keepAlivesEnabled {
		w.closeAfterReply = true
	}

	// A client that waits for "100 Continue" and was not told to has a
	// body it may or may not send: the connection is not used again.
	if ecr, ok := w.req.Body.(*expectContinueReader); ok && !ecr.sawEOF {
		w.closeAfterReply = true
	}

	// What is left of the request's body is read and dropped now, when
	// the connection stays open: a client that sends its whole request
	// before it reads the response would wait forever otherwise.
	if w.req.ContentLength != 0 && !w.closeAfterReply {
		discard := false
		tooBig := false
		if _, ok := w.req.Body.(*expectContinueReader); ok {
			// The body was read to its end, or the connection closes.
		} else if bdy, ok := w.req.Body.(*body); ok {
			bdy.mu.Lock()
			switch {
			case bdy.closed:
				if !bdy.sawEOF {
					// Closed by the handler before its end.
					w.closeAfterReply = true
				}
			case bdy.unreadSize() >= maxPostHandlerReadBytes:
				tooBig = true
			default:
				discard = true
			}
			bdy.mu.Unlock()
		} else {
			discard = true
		}

		if discard {
			_, err := discardBody(w.reqBody, maxPostHandlerReadBytes+1)
			switch {
			case err == nil:
				// There is more than is worth reading.
				tooBig = true
			case err == ErrBodyReadAfterClose:
				// Read and closed already.
			case err == io.EOF:
				if w.reqBody.Close() != nil {
					w.closeAfterReply = true
				}
			default:
				// What is on the wire is not a request: stop there.
				w.closeAfterReply = true
			}
		}

		if tooBig {
			w.requestTooLarge()
			header.Del("Connection")
			connection = "close"
		}
	}

	code := w.status
	if bodyAllowedForStatus(code) {
		// A body without a type gets the one its first bytes show, unless
		// it is encoded, which hides them.
		_, haveType := header["Content-Type"]
		hasCE := len(header.Get("Content-Encoding")) > 0
		if !hasCE && !haveType && !hasTE && len(p) > 0 {
			contentType = native.DetectContentType(p)
		}
	} else {
		// A response without a body has no field that frames one, and
		// "304 Not Modified" none that describes one either.
		if code == StatusNotModified {
			header.Del("Content-Type")
		}
		header.Del("Content-Length")
		header.Del("Transfer-Encoding")
	}

	if !header.has("Date") {
		date = native.formatTime(int(time.Now().Unix()), 0)
	}

	if hasCL && hasTE && te != "identity" {
		w.conn.server.logf("http: WriteHeader called with both Transfer-Encoding of %q and a Content-Length of %d", te, w.contentLength)
		header.Del("Content-Length")
		hasCL = false
	}

	if w.req.Method == "HEAD" || !bodyAllowedForStatus(code) || code == StatusNoContent {
		// No body.
		header.Del("Transfer-Encoding")
	} else if hasCL {
		// The length is known: no chunks.
		header.Del("Transfer-Encoding")
	} else if w.req.ProtoAtLeast(1, 1) {
		if hasTE && te == "identity" {
			// The handler asked for the body as it is, which only the
			// end of the connection can end.
			w.chunking = false
			w.closeAfterReply = true
			header.Del("Transfer-Encoding")
		} else {
			// Chunks, so that the connection can stay open.
			w.chunking = true
			transferEncoding = "chunked"
			if hasTE && te == "chunked" {
				header.Del("Transfer-Encoding")
			}
		}
	} else {
		// HTTP/1.0 has no chunks: the end of the connection ends the body.
		w.closeAfterReply = true
		header.Del("Transfer-Encoding")
	}

	if w.chunking {
		header.Del("Content-Length")
	}
	if !w.req.ProtoAtLeast(1, 0) {
		return
	}

	// "Connection: close" is the server's to say, unless the response
	// switches protocols.
	delConnectionHeader := w.closeAfterReply && (!keepAlivesEnabled || !hasToken(header.get("Connection"), "close")) && !isProtocolSwitchResponse(w.status, header)
	if delConnectionHeader {
		header.Del("Connection")
		if w.req.ProtoAtLeast(1, 1) {
			connection = "close"
		}
	}

	text := statusLine(w.req.ProtoAtLeast(1, 1), code) + header.text()
	if date != "" {
		text += "Date: " + date + "\r\n"
	}
	if contentLength != "" {
		text += "Content-Length: " + contentLength + "\r\n"
	}
	if contentType != "" {
		text += "Content-Type: " + contentType + "\r\n"
	}
	if connection != "" {
		text += "Connection: " + connection + "\r\n"
	}
	if transferEncoding != "" {
		text += "Transfer-Encoding: " + transferEncoding + "\r\n"
	}
	w.conn.writeString(text + "\r\n")
}

// TrailerPrefix marks a key of the response header as a trailer: the field
// is sent after the body, without the prefix.
const TrailerPrefix = "Trailer:"

// trailerKeys returns the keys of header that have the trailer prefix.
func (w *response) trailerKeys(header Header) []string {
	var keys []string
	for k := range header {
		if strings.HasPrefix(k, TrailerPrefix) {
			keys = append(keys, k)
		}
	}
	return keys
}

// declareTrailer notes a key the handler announced in a Trailer field.
func (w *response) declareTrailer(k string) {
	k = CanonicalHeaderKey(k)
	switch k {
	case "Transfer-Encoding", "Content-Length", "Trailer":
		// A trailer cannot change the framing.
		return
	}
	w.trailers = append(w.trailers, k)
}

// finalTrailers returns the trailer to send after the body: the fields
// with the trailer prefix, and the announced ones the handler has set.
func (w *response) finalTrailers() Header {
	var t Header
	for k, vv := range w.handlerHeader {
		if strings.HasPrefix(k, TrailerPrefix) {
			if t == nil {
				t = Header{}
			}
			t[k[len(TrailerPrefix):]] = vv
		}
	}
	for _, k := range w.trailers {
		if t == nil {
			t = Header{}
		}
		for _, v := range w.handlerHeader[k] {
			t.Add(k, v)
		}
	}
	return t
}

// isProtocolSwitchResponse reports whether the response moves the
// connection to another protocol.
func isProtocolSwitchResponse(code int, h Header) bool {
	return code == StatusSwitchingProtocols && h.get("Upgrade") != "" && valuesContainToken(h["Connection"], "upgrade")
}

func (w *response) requestTooLarge() {
	w.closeAfterReply = true
	w.requestBodyLimitHit = true
	if !w.wroteHeader {
		w.Header().Set("Connection", "close")
	}
}

// discardBody reads and drops up to limit bytes of body.
func discardBody(body io.Reader, limit int) (int, error) {
	buf := make([]byte, 4096)
	total := 0
	for total < limit {
		p := buf
		if len(p) > limit-total {
			p = p[:limit-total]
		}
		n, err := body.Read(p)
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// finishRequest sends what the handler left unsent and ends the response.
func (w *response) finishRequest() {
	w.handlerDone = true

	if !w.wroteHeader {
		w.WriteHeader(StatusOK)
	}

	w.flushBuffer()
	if !w.sentHeader {
		w.sendHeader(nil)
	}
	if w.chunking {
		// An empty chunk ends the body, and the trailer follows it.
		end := "0\r\n"
		if trailers := w.finalTrailers(); trailers != nil {
			end += trailers.text()
		}
		w.conn.writeString(end + "\r\n")
	}
	w.conn.flush()

	// Closed whether or not the connection stays open.
	w.reqBody.Close()
}

// shouldReuseConnection reports whether the connection can carry another
// request after this response.
func (w *response) shouldReuseConnection() bool {
	if w.closeAfterReply {
		return false
	}
	if w.req.Method != "HEAD" && w.contentLength != -1 && bodyAllowedForStatus(w.status) && w.contentLength != w.written {
		// Fewer bytes than were declared: the client cannot tell where
		// the next response begins.
		return false
	}
	if w.conn.werr != nil {
		return false
	}
	if w.closedRequestBodyEarly() {
		return false
	}
	return true
}

func (w *response) closedRequestBodyEarly() bool {
	b, ok := w.req.Body.(*body)
	return ok && b.earlyClose
}

// An expectContinueReader is the body of a request whose client waits for
// "100 Continue" before it sends it: the first read tells it to.
type expectContinueReader struct {
	resp       *response
	readCloser io.ReadCloser
	closed     bool
	sawEOF     bool
}

func (ecr *expectContinueReader) Read(p []byte) (n int, err error) {
	if ecr.closed {
		return 0, ErrBodyReadAfterClose
	}
	w := ecr.resp
	if w.canWriteContinue {
		w.canWriteContinue = false
		w.conn.writeString("HTTP/1.1 100 Continue\r\n\r\n")
		w.conn.flush()
	}
	n, err = ecr.readCloser.Read(p)
	if err == io.EOF {
		ecr.sawEOF = true
	}
	return n, err
}

func (ecr *expectContinueReader) Close() error {
	ecr.closed = true
	return ecr.readCloser.Close()
}

// The header of the response to a request the server could not read.
const errorHeaders = "\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"

// serve reads the requests of a connection and runs the handler for each,
// until the client or the response ends the connection.
func (c *conn) serve() {
	c.remoteAddr = native.remoteAddr(c.rwc)
	defer func() {
		if err := recover(); err != nil && !isAbortHandler(err) {
			c.server.logf("http: panic serving %v: %v", c.remoteAddr, err)
		}
		c.close()
	}()

	c.r = newConnReader(c.rwc)

	for {
		w, err := c.readRequest()
		if err != nil {
			switch {
			case err == errTooLarge:
				const publicErr = "431 Request Header Fields Too Large"
				c.rwc.Write([]byte("HTTP/1.1 " + publicErr + errorHeaders + publicErr))
				return
			case isUnsupportedTEError(err):
				c.rwc.Write([]byte("HTTP/1.1 501 Not Implemented" + errorHeaders + "Unsupported transfer encoding"))
				return
			case err == io.EOF:
				// The client went away between requests.
				return
			default:
				if v, ok := err.(statusError); ok {
					text := strconv.Itoa(v.code) + " " + StatusText(v.code) + ": " + v.text
					c.rwc.Write([]byte("HTTP/1.1 " + text + errorHeaders + text))
					return
				}
				const publicErr = "400 Bad Request"
				c.rwc.Write([]byte("HTTP/1.1 " + publicErr + errorHeaders + publicErr))
				return
			}
		}

		req := w.req
		if req.expectsContinue() {
			if req.ProtoAtLeast(1, 1) && req.ContentLength != 0 {
				// The first read of the body tells the client to send it.
				req.Body = &expectContinueReader{readCloser: req.Body, resp: w}
				w.canWriteContinue = true
			}
		} else if req.Header.get("Expect") != "" {
			w.Header().Set("Connection", "close")
			w.WriteHeader(StatusExpectationFailed)
			w.finishRequest()
			return
		}

		handler := c.server.Handler
		if handler == nil {
			handler = DefaultServeMux
		}
		if req.RequestURI == "*" && req.Method == "OPTIONS" {
			handler = globalOptionsHandler{}
		}
		handler.ServeHTTP(w, w.req)
		w.finishRequest()
		if !w.shouldReuseConnection() {
			return
		}
		if !c.server.doKeepAlives() {
			return
		}
		// The next request, when the client sends one.
		if !c.r.peek(4) {
			return
		}
	}
}

// isAbortHandler reports whether a handler panicked with ErrAbortHandler,
// which ends the handler without a word in the log.
func isAbortHandler(v any) bool {
	err, ok := v.(error)
	return ok && err == ErrAbortHandler
}

func isUnsupportedTEError(err error) bool {
	_, ok := err.(*unsupportedTEError)
	return ok
}

func (c *conn) close() {
	c.flush()
	c.rwc.Close()
}

// globalOptionsHandler answers "OPTIONS *", which asks about the server
// and not about a resource.
type globalOptionsHandler struct{}

func (h globalOptionsHandler) ServeHTTP(w ResponseWriter, r *Request) {
	w.Header().Set("Content-Length", "0")
	if r.ContentLength != 0 {
		// Read what the client sent, within reason, so the connection can
		// be used again.
		mb := MaxBytesReader(w, r.Body, 4<<10)
		io.Copy(io.Discard, mb)
	}
}

// A Server is an HTTP server: an address to listen on and a handler.
type Server struct {
	// Addr is the address to listen on, "host:port" or ":port". An empty
	// Addr is ":http", port 80.
	Addr string

	// Handler answers the requests. A nil Handler is DefaultServeMux.
	Handler Handler

	// MaxHeaderBytes is the most header the server reads of a request.
	// Zero is DefaultMaxHeaderBytes.
	MaxHeaderBytes int

	noKeepAlives bool
}

func (srv *Server) maxHeaderBytes() int {
	if srv.MaxHeaderBytes > 0 {
		return srv.MaxHeaderBytes
	}
	return DefaultMaxHeaderBytes
}

func (srv *Server) doKeepAlives() bool {
	return !srv.noKeepAlives
}

// SetKeepAlivesEnabled says whether a connection carries more than one
// request. It does by default.
func (srv *Server) SetKeepAlivesEnabled(v bool) {
	srv.noKeepAlives = !v
}

// logf reports what the server cannot tell a client, on standard error
// after the time, as Go's log package writes it.
func (srv *Server) logf(format string, args ...any) {
	fmt.Fprintln(os.Stderr, native.formatTime(int(time.Now().Unix()), 1)+" "+fmt.Sprintf(format, args...))
}

// ListenAndServe listens on srv.Addr and serves the connections it
// accepts. It returns when the server cannot listen or accept.
func (srv *Server) ListenAndServe() error {
	addr := srv.Addr
	if addr == "" {
		addr = ":80"
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	return srv.Serve(ln)
}

// Serve accepts connections on l and serves each in a goroutine of its
// own, which reads requests and calls srv.Handler for them. It returns
// when l fails.
func (srv *Server) Serve(l net.Listener) error {
	for {
		rw, err := l.Accept()
		if err != nil {
			return err
		}
		c := &conn{server: srv, rwc: rw}
		go c.serve()
	}
}

// ListenAndServe listens on addr and serves requests with handler, or
// with DefaultServeMux when handler is nil. It returns only an error.
func ListenAndServe(addr string, handler Handler) error {
	server := &Server{Addr: addr, Handler: handler}
	return server.ListenAndServe()
}

// Serve serves the connections l accepts with handler, or with
// DefaultServeMux when handler is nil. It returns only an error.
func Serve(l net.Listener, handler Handler) error {
	srv := &Server{Handler: handler}
	return srv.Serve(l)
}

// Error answers a request with the error message as plain text and the
// status code. The caller writes nothing after it.
func Error(w ResponseWriter, error string, code int) {
	h := w.Header()
	// The length and the type are the message's, not those of what the
	// handler meant to send.
	h.Del("Content-Length")
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	fmt.Fprintln(w, error)
}

// NotFound answers a request with "404 page not found".
func NotFound(w ResponseWriter, r *Request) { Error(w, "404 page not found", StatusNotFound) }

// NotFoundHandler returns a handler that answers every request with
// "404 page not found".
func NotFoundHandler() Handler { return HandlerFunc(NotFound) }

// StripPrefix returns a handler that takes prefix off the path of a
// request and passes it to h, and answers a request whose path does not
// begin with prefix with "404 page not found".
func StripPrefix(prefix string, h Handler) Handler {
	if prefix == "" {
		return h
	}
	return HandlerFunc(func(w ResponseWriter, r *Request) {
		p := strings.TrimPrefix(r.URL.Path, prefix)
		rp := strings.TrimPrefix(r.URL.RawPath, prefix)
		if len(p) < len(r.URL.Path) && (r.URL.RawPath == "" || len(rp) < len(r.URL.RawPath)) {
			r2 := *r
			u2 := *r.URL
			u2.Path = p
			u2.RawPath = rp
			r2.URL = &u2
			h.ServeHTTP(w, &r2)
		} else {
			NotFound(w, r)
		}
	})
}

// Redirect answers a request by sending the client to url, which may be
// relative to the request's path. The code is one of the 3xx statuses,
// such as StatusMovedPermanently, StatusFound, or StatusSeeOther. For GET
// the body is a short HTML page with a link.
func Redirect(w ResponseWriter, r *Request, url string, code int) {
	if u, err := urlpkg.Parse(url); err == nil {
		// A URL without a scheme and a host is relative to the request's
		// path, which a client may not resolve the way the server would.
		if u.Scheme == "" && u.Host == "" {
			oldpath := r.URL.Path
			if oldpath == "" {
				oldpath = "/"
			}
			if url == "" || url[0] != '/' {
				// Relative to the directory of the request's path.
				olddir := oldpath[:strings.LastIndex(oldpath, "/")+1]
				url = olddir + url
			}
			query := ""
			if i := strings.Index(url, "?"); i != -1 {
				query = url[i:]
				url = url[:i]
			}
			trailing := strings.HasSuffix(url, "/")
			url = pathClean(url)
			if trailing && !strings.HasSuffix(url, "/") {
				url += "/"
			}
			url += query
		}
	}

	h := w.Header()
	// A handler that set a type sends a body of its own.
	_, hadCT := h["Content-Type"]

	h.Set("Location", hexEscapeNonASCII(url))
	if !hadCT && (r.Method == "GET" || r.Method == "HEAD") {
		h.Set("Content-Type", "text/html; charset=utf-8")
	}
	w.WriteHeader(code)

	if !hadCT && r.Method == "GET" {
		body := "<a href=\"" + htmlEscape(url) + "\">" + StatusText(code) + "</a>.\n"
		fmt.Fprintln(w, body)
	}
}

// htmlEscape replaces the characters that mean something in HTML.
func htmlEscape(s string) string {
	if !strings.Contains(s, "&") && !strings.Contains(s, "<") && !strings.Contains(s, ">") && !strings.Contains(s, "\"") && !strings.Contains(s, "'") {
		return s
	}
	out := ""
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '&':
			out += "&amp;"
		case '<':
			out += "&lt;"
		case '>':
			out += "&gt;"
		case '"':
			out += "&#34;"
		case '\'':
			out += "&#39;"
		default:
			out += s[i : i+1]
		}
	}
	return out
}

// hexEscapeNonASCII writes the bytes of s that are not ASCII as %XX.
func hexEscapeNonASCII(s string) string {
	plain := true
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			plain = false
			break
		}
	}
	if plain {
		return s
	}
	out := ""
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			out += "%" + strings.ToUpper(fmt.Sprintf("%02x", s[i]))
		} else {
			out += s[i : i+1]
		}
	}
	return out
}

type redirectHandler struct {
	url  string
	code int
}

func (rh *redirectHandler) ServeHTTP(w ResponseWriter, r *Request) {
	Redirect(w, r, rh.url, rh.code)
}

// RedirectHandler returns a handler that sends every request to url with
// the status code.
func RedirectHandler(url string, code int) Handler {
	return &redirectHandler{url: url, code: code}
}

// A MaxBytesError is a body that is longer than MaxBytesReader allows.
type MaxBytesError struct {
	Limit int
}

func (e *MaxBytesError) Error() string {
	return "http: request body too large"
}

// MaxBytesReader returns a body that fails with a *MaxBytesError once more
// than n bytes of r have been read, and tells the server to close the
// connection then. It bounds what a client can make a handler read.
func MaxBytesReader(w ResponseWriter, r io.ReadCloser, n int) io.ReadCloser {
	if n < 0 {
		n = 0
	}
	return &maxBytesReader{w: w, r: r, i: n, n: n}
}

type maxBytesReader struct {
	w   ResponseWriter
	r   io.ReadCloser
	i   int   // the limit
	n   int   // the bytes still allowed
	err error // the error that stays
}

func (l *maxBytesReader) Read(p []byte) (n int, err error) {
	if l.err != nil {
		return 0, l.err
	}
	if len(p) == 0 {
		return 0, nil
	}
	// One byte more than is allowed tells the limit from the end.
	if len(p)-1 > l.n {
		p = p[:l.n+1]
	}
	n, err = l.r.Read(p)

	if n <= l.n {
		l.n -= n
		l.err = err
		return n, err
	}

	n = l.n
	l.n = 0

	// The server closes the connection after the response: the client
	// sent more than the handler will read.
	if res, ok := l.w.(*response); ok {
		res.requestTooLarge()
	}
	l.err = &MaxBytesError{Limit: l.i}
	return n, l.err
}

func (l *maxBytesReader) Close() error {
	return l.r.Close()
}
