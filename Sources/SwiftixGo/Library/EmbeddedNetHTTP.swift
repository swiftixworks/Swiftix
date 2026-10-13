/// Go source of the package `net/http`. See `GoEmbeddedLibrary`.
///
/// The text is Go as `gofmt` prints it, compiled with every program that
/// uses the package. A path under `$GOROOT/src` names each file in a
/// diagnostic, which only a mistake in this source can produce.
extension GoEmbeddedSources {
    static let netHTTP: [GoSourceFile] = [
        GoSourceFile(
            path: "$GOROOT/src/net/http/client.go",
            text: #"""
package http

import (
	"errors"
	"fmt"
	"io"
	"net"
	nethttp "net/http"
	"net/url"
	"strconv"
	"strings"
)

// A Response is the response to a request a client sent.
type Response struct {
	// Status is the status line without the version: "200 OK".
	Status     string
	StatusCode int
	// Proto is the protocol version: "HTTP/1.1".
	Proto      string
	ProtoMajor int
	ProtoMinor int

	// Header holds the header fields, by canonical key.
	Header Header

	// Body is the body, which is never nil and is read as it arrives. The
	// caller closes it.
	Body io.ReadCloser

	// ContentLength is the length of the body, or -1 when the header
	// does not say.
	ContentLength int64

	// TransferEncoding is ["chunked"] for a body that came in chunks.
	TransferEncoding []string

	// Close says that the header asked for the connection to end after
	// the response.
	Close bool

	// Uncompressed is always false: a response is given as it was sent.
	Uncompressed bool

	// Trailer holds the fields that followed a body in chunks, once the
	// body has been read to its end.
	Trailer Header

	// Request is the request that was sent to get this response.
	Request *Request
}

// A Client sends requests and returns their responses. The zero Client
// follows up to ten redirects.
type Client struct {
	// CheckRedirect is asked before a redirect is followed: req is the
	// request to send next and via the requests sent so far. An error
	// stops there, and ErrUseLastResponse returns the redirect itself.
	CheckRedirect func(req *Request, via []*Request) error
}

// DefaultClient is the Client that Get, Head, and Post use.
var DefaultClient = &Client{}

// ErrUseLastResponse is what a CheckRedirect function returns to get the
// redirect response instead of following it.
var ErrUseLastResponse = errors.New("net/http: use last response")

// Get sends a GET request for the URL and returns the response, following
// redirects. The caller closes the body of the response.
func Get(url string) (resp *Response, err error) {
	return DefaultClient.Get(url)
}

// Head sends a HEAD request for the URL.
func Head(url string) (resp *Response, err error) {
	return DefaultClient.Head(url)
}

// Post sends a POST request to the URL with the body, whose type is
// contentType.
func Post(url, contentType string, body io.Reader) (resp *Response, err error) {
	return DefaultClient.Post(url, contentType, body)
}

// PostForm sends a POST request to the URL with the values as a
// URL-encoded form.
func PostForm(target string, data url.Values) (resp *Response, err error) {
	return DefaultClient.PostForm(target, data)
}

// Get sends a GET request for the URL.
func (c *Client) Get(url string) (resp *Response, err error) {
	req, err := NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	return c.Do(req)
}

// Head sends a HEAD request for the URL.
func (c *Client) Head(url string) (resp *Response, err error) {
	req, err := NewRequest("HEAD", url, nil)
	if err != nil {
		return nil, err
	}
	return c.Do(req)
}

// Post sends a POST request to the URL.
func (c *Client) Post(url, contentType string, body io.Reader) (resp *Response, err error) {
	req, err := NewRequest("POST", url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", contentType)
	return c.Do(req)
}

// PostForm sends a POST request to the URL with a URL-encoded form.
func (c *Client) PostForm(target string, data url.Values) (resp *Response, err error) {
	return c.Post(target, "application/x-www-form-urlencoded", strings.NewReader(data.Encode()))
}

// urlErrorOp is the operation a failed request names: "Get" for GET.
func urlErrorOp(method string) string {
	if method == "" {
		return "Get"
	}
	return method[:1] + strings.ToLower(method[1:])
}

// stripPassword is the URL as text, with a password replaced by "***".
func stripPassword(u *url.URL) string {
	if _, has := u.User.Password(); has {
		return strings.Join(strings.Split(u.String(), u.User.String()+"@"), u.User.Username()+":***@")
	}
	return u.String()
}

// Do sends the request and returns the response. It follows redirects as
// CheckRedirect allows: after 301, 302, and 303 with GET, or HEAD for a
// HEAD, and after 307 and 308 with the method and the body again. An error
// is a *url.Error; a response with a status that is no success is not one.
func (c *Client) Do(req *Request) (*Response, error) {
	if req.URL == nil {
		closeBody(req)
		return nil, &url.Error{Op: urlErrorOp(req.Method), Err: errors.New("http: nil Request.URL")}
	}
	var reqs []*Request
	var resp *Response
	redirectMethod := ""
	includeBody := true
	first := req
	uerr := func(err error) error {
		urlStr := stripPassword(req.URL)
		if resp != nil && resp.Request != nil {
			urlStr = stripPassword(resp.Request.URL)
		}
		return &url.Error{Op: urlErrorOp(first.Method), URL: urlStr, Err: err}
	}
	for {
		// After the first request: where the last response points.
		if len(reqs) > 0 {
			loc := resp.Header.Get("Location")
			if loc == "" {
				// A redirect that does not say where to is the response.
				return resp, nil
			}
			u, err := req.URL.Parse(loc)
			if err != nil {
				resp.Body.Close()
				return nil, uerr(fmt.Errorf("failed to parse Location header %q: %v", loc, err))
			}
			host := ""
			if req.Host != "" && req.Host != req.URL.Host {
				// A Host of the caller's own stays for a relative
				// redirect.
				if lu, _ := url.Parse(loc); lu != nil && !lu.IsAbs() {
					host = req.Host
				}
			}
			ireq := reqs[0]
			req = &Request{
				Method:     redirectMethod,
				URL:        u,
				Header:     Header{},
				Host:       host,
				Proto:      "HTTP/1.1",
				ProtoMajor: 1,
				ProtoMinor: 1,
			}
			if includeBody && ireq.GetBody != nil {
				req.Body, err = ireq.GetBody()
				if err != nil {
					resp.Body.Close()
					return nil, uerr(err)
				}
				req.ContentLength = ireq.ContentLength
			}
			// The caller's header goes along, without what describes a
			// body that is not sent again, and without what authorizes
			// the caller to another host.
			sameHost := ireq.URL.Host == u.Host
			for k, vv := range ireq.Header {
				switch k {
				case "Authorization", "Www-Authenticate", "Cookie", "Cookie2", "Proxy-Authorization", "Proxy-Authenticate":
					if !sameHost {
						continue
					}
				case "Content-Encoding", "Content-Language", "Content-Location", "Content-Type":
					if !includeBody {
						continue
					}
				}
				vv2 := make([]string, len(vv))
				copy(vv2, vv)
				req.Header[k] = vv2
			}
			if ref := refererForURL(reqs[len(reqs)-1].URL, req.URL, req.Header.Get("Referer")); ref != "" {
				req.Header.Set("Referer", ref)
			}
			err = c.checkRedirect(req, reqs)
			if err == ErrUseLastResponse {
				return resp, nil
			}

			// The body of a redirect is read, when it is short, and
			// closed.
			if resp.ContentLength == -1 || resp.ContentLength <= 2<<10 {
				discardBody(resp.Body, 2<<10)
			}
			resp.Body.Close()

			if err != nil {
				return resp, &url.Error{Op: urlErrorOp(first.Method), URL: loc, Err: err}
			}
		}

		reqs = append(reqs, req)
		var err error
		resp, err = send(req)
		if err != nil {
			return nil, uerr(err)
		}

		shouldRedirect := false
		includeBodyOnHop := false
		switch resp.StatusCode {
		case 301, 302, 303:
			redirectMethod = req.Method
			shouldRedirect = true
			if req.Method != "GET" && req.Method != "HEAD" {
				redirectMethod = "GET"
			}
		case 307, 308:
			redirectMethod = req.Method
			shouldRedirect = true
			includeBodyOnHop = true
			if reqs[0].GetBody == nil && outgoingLength(reqs[0]) != 0 {
				// The body cannot be sent again: the redirect is the
				// response.
				shouldRedirect = false
			}
		}
		if !shouldRedirect {
			return resp, nil
		}
		if !includeBodyOnHop {
			includeBody = false
		}
		closeBody(req)
	}
}

func (c *Client) checkRedirect(req *Request, via []*Request) error {
	if c.CheckRedirect != nil {
		check := c.CheckRedirect
		return check(req, via)
	}
	if len(via) >= 10 {
		return errors.New("stopped after 10 redirects")
	}
	return nil
}

// refererForURL is the Referer of a request that follows a redirect: the
// URL it came from, without user information.
func refererForURL(lastReq, newReq *url.URL, explicitRef string) string {
	// Not from a secure page to one that is not.
	if lastReq.Scheme == "https" && newReq.Scheme == "http" {
		return ""
	}
	if explicitRef != "" {
		return explicitRef
	}
	referer := lastReq.String()
	if lastReq.User != nil {
		// What the URL has before the host is not for others to see.
		auth := lastReq.User.String() + "@"
		referer = strings.Join(strings.Split(referer, auth), "")
	}
	return referer
}

func closeBody(r *Request) {
	if r.Body != nil {
		r.Body.Close()
	}
}

// outgoingLength is the length of the body a request sends: -1 when it is
// not known.
func outgoingLength(r *Request) int {
	if r.Body == nil {
		return 0
	}
	if _, ok := r.Body.(noBody); ok {
		return 0
	}
	if r.ContentLength != 0 {
		return int(r.ContentLength)
	}
	return -1
}

var errMissingHost = errors.New("http: Request.Write on Request with no Host or URL set")

// send sends one request on a connection of its own and reads the header
// of the response. The connection is closed when the body of the response
// has been read to its end, or is closed.
func send(req *Request) (*Response, error) {
	if req.URL == nil {
		closeBody(req)
		return nil, errors.New("http: nil Request.URL")
	}
	if req.Header == nil {
		closeBody(req)
		return nil, errors.New("http: nil Request.Header")
	}
	scheme := req.URL.Scheme
	if scheme != "http" {
		closeBody(req)
		return nil, badStringError("unsupported protocol scheme", scheme)
	}
	if req.URL.Host == "" {
		closeBody(req)
		return nil, errors.New("http: no Host in request URL")
	}
	if req.Method != "" && !nethttp.validToken(req.Method) {
		closeBody(req)
		return nil, fmt.Errorf("net/http: invalid method %q", req.Method)
	}
	for k, vv := range req.Header {
		if !nethttp.validToken(k) {
			closeBody(req)
			return nil, fmt.Errorf("net/http: invalid header field name %q", k)
		}
		for _, v := range vv {
			if !nethttp.validHeaderValue(v) {
				closeBody(req)
				// The value is not shown: it may be a secret.
				return nil, fmt.Errorf("net/http: invalid header field value for %q", k)
			}
		}
	}

	// The address to connect to: the host, and port 80 when none is
	// given. The name "localhost" is this host.
	hostname := req.URL.Hostname()
	port := req.URL.Port()
	if port == "" {
		port = "80"
	}
	if hostname == "localhost" {
		hostname = "127.0.0.1"
	}
	conn, err := net.Dial("tcp", hostname+":"+port)
	if err != nil {
		closeBody(req)
		return nil, err
	}

	if err := writeRequest(conn, req); err != nil {
		conn.Close()
		return nil, err
	}

	r := newConnReader(conn)
	resp, err := readResponse(r, req)
	// An interim response is not the answer: the next one is.
	for n := 0; err == nil && resp.StatusCode >= 100 && resp.StatusCode <= 199 && resp.StatusCode != StatusSwitchingProtocols; n++ {
		if n >= 5 {
			err = errors.New("net/http: too many 1xx informational responses")
			break
		}
		resp, err = readResponse(r, req)
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	if b, ok := resp.Body.(*body); ok {
		resp.Body = &bodyEOFSignal{body: b, conn: conn}
	} else {
		conn.Close()
	}
	return resp, nil
}

// A bodyEOFSignal is the body of a response, which gives the connection
// back when it has been read to its end or is closed.
type bodyEOFSignal struct {
	body   *body
	conn   net.Conn
	closed bool
	done   bool
}

func (es *bodyEOFSignal) Read(p []byte) (n int, err error) {
	if es.closed {
		return 0, errors.New("http: read on closed response body")
	}
	n, err = es.body.Read(p)
	if err != nil {
		es.finish()
	}
	return n, err
}

func (es *bodyEOFSignal) Close() error {
	if es.closed {
		return nil
	}
	es.closed = true
	es.finish()
	return nil
}

func (es *bodyEOFSignal) finish() {
	if !es.done {
		es.done = true
		es.conn.Close()
	}
}

// writeRequest sends the request line, the header, and the body.
func writeRequest(conn net.Conn, req *Request) error {
	host := req.Host
	if host == "" {
		host = req.URL.Host
	}
	if !validHostHeader(host) {
		host = ""
	}
	ruri := req.URL.RequestURI()
	if req.Method == "CONNECT" && req.URL.Path == "" {
		ruri = host
		if req.URL.Opaque != "" {
			ruri = req.URL.Opaque
		}
	}
	method := req.Method
	if method == "" {
		method = "GET"
	}
	text := method + " " + ruri + " HTTP/1.1\r\nHost: " + host + "\r\n"

	// The agent is named unless the caller set the field, and left out
	// when the caller set it to nothing.
	userAgent := "Go-http-client/1.1"
	if req.Header.has("User-Agent") {
		userAgent = req.Header.Get("User-Agent")
	}
	if userAgent != "" {
		text += "User-Agent: " + trimString(strings.Join(strings.Split(userAgent, "\n"), " ")) + "\r\n"
	}

	// How the body is framed: a length that is known, or chunks.
	length := outgoingLength(req)
	var first []byte
	if length < 0 {
		// A body of unknown length may be empty: its first bytes tell.
		buf := make([]byte, 4096)
		n, err := req.Body.Read(buf)
		if n == 0 && err == io.EOF {
			length = 0
		} else if err != nil && err != io.EOF {
			closeBody(req)
			return err
		} else {
			first = buf[:n]
		}
	}
	if req.Close && !hasToken(req.Header.get("Connection"), "close") {
		text += "Connection: close\r\n"
	}
	chunked := false
	switch {
	case length > 0:
		text += "Content-Length: " + strconv.Itoa(length) + "\r\n"
	case length < 0:
		chunked = true
		text += "Transfer-Encoding: chunked\r\n"
	case method == "POST" || method == "PUT" || method == "PATCH":
		// These say that they have no body.
		text += "Content-Length: 0\r\n"
	}

	// The caller's fields, without those written above.
	rest := Header{}
	for k, vv := range req.Header {
		switch k {
		case "Host", "User-Agent", "Content-Length", "Transfer-Encoding", "Trailer":
		default:
			rest[k] = vv
		}
	}
	text += rest.text() + "\r\n"
	if _, err := conn.Write([]byte(text)); err != nil {
		closeBody(req)
		return err
	}

	if length == 0 {
		closeBody(req)
		return nil
	}
	buf := make([]byte, 4096)
	sent := 0
	for {
		var p []byte
		var err error
		if first != nil {
			p = first
			first = nil
		} else {
			n := 0
			n, err = req.Body.Read(buf)
			p = buf[:n]
		}
		if len(p) > 0 {
			if length > 0 && sent+len(p) > length {
				closeBody(req)
				return errors.New("http: ContentLength=" + strconv.Itoa(length) + " with Body length " + strconv.Itoa(sent+len(p)))
			}
			sent += len(p)
			var werr error
			if chunked {
				_, werr = conn.Write([]byte(fmt.Sprintf("%x", len(p)) + "\r\n"))
				if werr == nil {
					_, werr = conn.Write(p)
				}
				if werr == nil {
					_, werr = conn.Write([]byte("\r\n"))
				}
			} else {
				_, werr = conn.Write(p)
			}
			if werr != nil {
				closeBody(req)
				return werr
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			closeBody(req)
			return err
		}
		if !chunked && sent == length {
			break
		}
	}
	closeBody(req)
	if chunked {
		_, err := conn.Write([]byte("0\r\n\r\n"))
		return err
	}
	if sent != length {
		return errors.New("http: ContentLength=" + strconv.Itoa(length) + " with Body length " + strconv.Itoa(sent))
	}
	return nil
}

// A transportError is a response that is not what the protocol says.
func transportError(err error) error {
	return fmt.Errorf("net/http: HTTP/1.x transport connection broken: %w", err)
}

// readResponse reads a status line and a header, and prepares the body.
func readResponse(r *connReader, req *Request) (*Response, error) {
	resp := &Response{Request: req}

	line, err := r.readLine()
	if err != nil {
		// A server that closes without a word.
		return nil, err
	}
	sp := strings.Index(line, " ")
	if sp < 0 {
		return nil, transportError(badStringError("malformed HTTP response", line))
	}
	resp.Proto = line[:sp]
	status := line[sp+1:]
	for len(status) > 0 && status[0] == ' ' {
		status = status[1:]
	}
	resp.Status = status

	statusCode := status
	if i := strings.Index(status, " "); i >= 0 {
		statusCode = status[:i]
	}
	if len(statusCode) != 3 {
		return nil, transportError(badStringError("malformed HTTP status code", statusCode))
	}
	for i := 0; i < 3; i++ {
		if statusCode[i] < '0' || statusCode[i] > '9' {
			return nil, transportError(badStringError("malformed HTTP status code", statusCode))
		}
	}
	resp.StatusCode, _ = strconv.Atoi(statusCode)
	var ok bool
	if resp.ProtoMajor, resp.ProtoMinor, ok = parseHTTPVersion(resp.Proto); !ok {
		return nil, transportError(badStringError("malformed HTTP version", resp.Proto))
	}

	resp.Header, err = r.readHeader()
	if err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return nil, transportError(err)
	}
	if _, ok := resp.Header["Cache-Control"]; !ok {
		if pragma := resp.Header["Pragma"]; len(pragma) > 0 && pragma[0] == "no-cache" {
			resp.Header["Cache-Control"] = []string{"no-cache"}
		}
	}

	t := &transfer{
		header:        resp.Header,
		isResponse:    true,
		status:        resp.StatusCode,
		requestMethod: "GET",
		protoMajor:    resp.ProtoMajor,
		protoMinor:    resp.ProtoMinor,
	}
	if req != nil && req.Method != "" {
		t.requestMethod = req.Method
	}
	t.closing = shouldClose(t.protoMajor, t.protoMinor, t.header, true)
	if err := t.prepare(); err != nil {
		return nil, transportError(err)
	}
	resp.Trailer, err = t.trailerKeys()
	if err != nil {
		return nil, transportError(err)
	}
	resp.ContentLength = int64(t.contentLength)
	resp.Close = t.closing
	noBodyExpected := t.requestMethod == "HEAD" || !bodyAllowedForStatus(resp.StatusCode)
	switch {
	case t.chunked:
		resp.TransferEncoding = []string{"chunked"}
		if noBodyExpected {
			resp.Body = NoBody
		} else {
			resp.Body = &body{src: r, res: resp, chunked: true, remaining: -1, closing: t.closing}
		}
	case noBodyExpected || t.contentLength == 0:
		resp.Body = NoBody
	case t.contentLength > 0:
		resp.Body = &body{src: r, remaining: t.contentLength, closing: t.closing}
	default:
		// The end of the connection ends the body.
		resp.Body = &body{src: r, remaining: -1, closing: true}
	}
	return resp, nil
}
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/header.go",
            text: #"""
package http

import (
	nethttp "net/http"
	"sort"
	"strings"
)

// A Header holds the fields of an HTTP header. Keys are in canonical form:
// the first letter and each letter after a hyphen in upper case.
type Header map[string][]string

// Add adds value to the values of key.
func (h Header) Add(key, value string) {
	key = nethttp.CanonicalHeaderKey(key)
	h[key] = append(h[key], value)
}

// Set makes value the only value of key.
func (h Header) Set(key, value string) {
	h[nethttp.CanonicalHeaderKey(key)] = []string{value}
}

// Get returns the first value of key, or "". The key may be in any case.
func (h Header) Get(key string) string {
	if h == nil {
		return ""
	}
	v := h[nethttp.CanonicalHeaderKey(key)]
	if len(v) == 0 {
		return ""
	}
	return v[0]
}

// Values returns every value of key. The slice is the header's own.
func (h Header) Values(key string) []string {
	if h == nil {
		return nil
	}
	return h[nethttp.CanonicalHeaderKey(key)]
}

// get is Get for a key that is canonical already.
func (h Header) get(key string) string {
	if v := h[key]; len(v) > 0 {
		return v[0]
	}
	return ""
}

// has reports whether the header has the canonical key.
func (h Header) has(key string) bool {
	_, ok := h[key]
	return ok
}

// Del removes key.
func (h Header) Del(key string) {
	delete(h, nethttp.CanonicalHeaderKey(key))
}

// Clone returns a copy of h that shares nothing with it.
func (h Header) Clone() Header {
	if h == nil {
		return nil
	}
	h2 := Header{}
	for k, vv := range h {
		vv2 := make([]string, len(vv))
		copy(vv2, vv)
		h2[k] = vv2
	}
	return h2
}

// text returns the fields as they are written in a message, one per line
// and sorted by key. A line break inside a value becomes a space, and a
// key that is no token is left out.
func (h Header) text() string {
	if len(h) == 0 {
		return ""
	}
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	if len(keys) > 1 {
		sort.Strings(keys)
	}
	text := ""
	for _, k := range keys {
		if !nethttp.validToken(k) {
			continue
		}
		for _, v := range h[k] {
			if strings.Contains(v, "\n") {
				v = strings.Join(strings.Split(v, "\n"), " ")
			}
			if strings.Contains(v, "\r") {
				v = strings.Join(strings.Split(v, "\r"), " ")
			}
			text += k + ": " + trimString(v) + "\r\n"
		}
	}
	return text
}

// CanonicalHeaderKey returns the canonical form of a header key:
// "accept-encoding" becomes "Accept-Encoding". A key with a space or a byte
// no key has is returned as it is.
func CanonicalHeaderKey(s string) string { return nethttp.CanonicalHeaderKey(s) }

// isSpace reports whether b is white space of a header: a space, a tab, or
// a line break.
func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// trimString returns s without leading and trailing white space.
func trimString(s string) string {
	for len(s) > 0 && isSpace(s[0]) {
		s = s[1:]
	}
	for len(s) > 0 && isSpace(s[len(s)-1]) {
		s = s[:len(s)-1]
	}
	return s
}

// hasToken reports whether token is one of the elements of the header
// value v, which commas and spaces separate. The token is in lower case;
// the value may be in any case.
func hasToken(v, token string) bool {
	if v == "" {
		return false
	}
	if v == token {
		return true
	}
	v = strings.ToLower(v)
	if !strings.Contains(v, token) {
		return false
	}
	for start := 0; start+len(token) <= len(v); start++ {
		if v[start:start+len(token)] != token {
			continue
		}
		if start > 0 && !isTokenBoundary(v[start-1]) {
			continue
		}
		if end := start + len(token); end != len(v) && !isTokenBoundary(v[end]) {
			continue
		}
		return true
	}
	return false
}

func isTokenBoundary(b byte) bool {
	return b == ' ' || b == ',' || b == '\t'
}

// valuesContainToken reports whether a comma-separated element of any of
// the values is token, in any case.
func valuesContainToken(values []string, token string) bool {
	for _, v := range values {
		if !strings.Contains(strings.ToLower(v), token) {
			continue
		}
		for _, element := range strings.Split(v, ",") {
			if strings.ToLower(trimOWS(element)) == token {
				return true
			}
		}
	}
	return false
}

// trimOWS returns s without the spaces and tabs around it.
func trimOWS(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

// DetectContentType returns the content type of data that begins with
// these bytes, from at most the first 512 of them, by the algorithm of
// https://mimesniff.spec.whatwg.org/. Data it does not recognize is
// "application/octet-stream".
func DetectContentType(data []byte) string { return nethttp.DetectContentType(data) }
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/method.go",
            text: #"""
package http

// The methods of HTTP.
const (
	MethodGet     = "GET"
	MethodHead    = "HEAD"
	MethodPost    = "POST"
	MethodPut     = "PUT"
	MethodPatch   = "PATCH"
	MethodDelete  = "DELETE"
	MethodConnect = "CONNECT"
	MethodOptions = "OPTIONS"
	MethodTrace   = "TRACE"
)
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/request.go",
            text: #"""
package http

import (
	"errors"
	"fmt"
	"io"
	nethttp "net/http"
	"net/url"
	"strconv"
	"strings"
)

// ErrBodyReadAfterClose is returned when a body is read after it was
// closed, which a handler does when it reads the request after it has
// returned.
var ErrBodyReadAfterClose = errors.New("http: invalid Read on closed Body")

// A Request is an HTTP request: one a server received, or one a client is
// to send.
type Request struct {
	// Method is the method: "GET", "POST". An empty Method of a request
	// to send means "GET".
	Method string

	// URL is what is requested. A server has it from the request line,
	// where most requests have a path and a query alone.
	URL *url.URL

	// Proto is the protocol version: "HTTP/1.1".
	Proto      string
	ProtoMajor int
	ProtoMinor int

	// Header holds the header fields, without Host, which is in Host.
	Header Header

	// Body is the body. A request a server received always has one, which
	// ends at once when the request has none, and the server closes it.
	Body io.ReadCloser

	// GetBody returns the body again, for a request a client sends once
	// more after a redirect. NewRequest sets it for a *strings.Reader.
	GetBody func() (io.ReadCloser, error)

	// ContentLength is the length of the body, -1 when it is not known,
	// and 0 when there is none.
	ContentLength int64

	// TransferEncoding is ["chunked"] for a body in chunks.
	TransferEncoding []string

	// Close says that the connection ends with this request's response.
	Close bool

	// Host is the host the request is for: the Host header, or the host
	// of an absolute URL in the request line.
	Host string

	// Form holds the query and the form of the body after ParseForm, and
	// PostForm the form of the body alone.
	Form     url.Values
	PostForm url.Values

	// Trailer holds the fields that follow a body in chunks.
	Trailer Header

	// RemoteAddr is the address the request came from, as "IP:port".
	RemoteAddr string

	// RequestURI is the target of the request line as the client sent it.
	RequestURI string

	// Pattern is the pattern of the ServeMux that matched the request.
	Pattern string

	// What the wildcards of the pattern matched, in the pattern's order,
	// and values a handler set by name.
	pat         *pattern
	matches     []string
	otherValues map[string]string
}

// ProtoAtLeast reports whether the request's protocol is at least
// major.minor.
func (r *Request) ProtoAtLeast(major, minor int) bool {
	return r.ProtoMajor > major || r.ProtoMajor == major && r.ProtoMinor >= minor
}

// UserAgent returns the User-Agent header of the request.
func (r *Request) UserAgent() string {
	return r.Header.Get("User-Agent")
}

// Referer returns the Referer header of the request.
func (r *Request) Referer() string {
	return r.Header.Get("Referer")
}

// PathValue returns what the wildcard name of the matched pattern stands
// for in the request's path, or "" when the pattern has no such wildcard.
func (r *Request) PathValue(name string) string {
	if i := r.patIndex(name); i >= 0 {
		return r.matches[i]
	}
	return r.otherValues[name]
}

// SetPathValue sets what PathValue returns for name.
func (r *Request) SetPathValue(name, value string) {
	if i := r.patIndex(name); i >= 0 {
		r.matches[i] = value
		return
	}
	if r.otherValues == nil {
		r.otherValues = map[string]string{}
	}
	r.otherValues[name] = value
}

// patIndex returns the place of the wildcard name among the pattern's
// wildcards, or -1.
func (r *Request) patIndex(name string) int {
	if r.pat == nil {
		return -1
	}
	i := 0
	for _, seg := range r.pat.segments {
		if seg.wild && seg.s != "" {
			if name == seg.s {
				return i
			}
			i++
		}
	}
	return -1
}

// ParseForm fills Form with the query of the URL and, for a POST, PUT, or
// PATCH with a URL-encoded body, the fields of the body, which come first
// and are also PostForm. The first call does the work.
func (r *Request) ParseForm() error {
	var err error
	if r.PostForm == nil {
		if r.Method == "POST" || r.Method == "PUT" || r.Method == "PATCH" {
			r.PostForm, err = parsePostForm(r)
		}
		if r.PostForm == nil {
			r.PostForm = url.Values{}
		}
	}
	if r.Form == nil {
		r.Form = url.Values{}
		for k, vs := range r.PostForm {
			r.Form[k] = append(r.Form[k], vs...)
		}
		var newValues url.Values
		if r.URL != nil {
			var e error
			newValues, e = url.ParseQuery(r.URL.RawQuery)
			if err == nil {
				err = e
			}
		}
		for k, vs := range newValues {
			r.Form[k] = append(r.Form[k], vs...)
		}
	}
	return err
}

// The most a form in a body may hold.
const maxFormSize = 10 << 20

func parsePostForm(r *Request) (url.Values, error) {
	if r.Body == nil {
		return nil, errors.New("missing form body")
	}
	ct := r.Header.Get("Content-Type")
	// A body without a type is a stream of octets, which is no form.
	if ct == "" {
		return nil, nil
	}
	if i := strings.Index(ct, ";"); i >= 0 {
		ct = ct[:i]
	}
	if strings.ToLower(strings.TrimSpace(ct)) != "application/x-www-form-urlencoded" {
		return nil, nil
	}
	b, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err
	}
	if len(b) > maxFormSize {
		return nil, errors.New("http: POST too large")
	}
	return url.ParseQuery(string(b))
}

// FormValue returns the first value of key in the form, which the body's
// fields precede. It parses the form when that has not been done, and
// ignores what is malformed.
func (r *Request) FormValue(key string) string {
	if r.Form == nil {
		r.ParseForm()
	}
	if vs := r.Form[key]; len(vs) > 0 {
		return vs[0]
	}
	return ""
}

// PostFormValue is FormValue for the fields of the body alone.
func (r *Request) PostFormValue(key string) string {
	if r.PostForm == nil {
		r.ParseForm()
	}
	if vs := r.PostForm[key]; len(vs) > 0 {
		return vs[0]
	}
	return ""
}

func (r *Request) expectsContinue() bool {
	return hasToken(r.Header.get("Expect"), "100-continue")
}

func (r *Request) wantsHttp10KeepAlive() bool {
	if r.ProtoMajor != 1 || r.ProtoMinor != 0 {
		return false
	}
	return hasToken(r.Header.get("Connection"), "keep-alive")
}

func (r *Request) wantsClose() bool {
	if r.Close {
		return true
	}
	return hasToken(r.Header.get("Connection"), "close")
}

// NewRequest returns a request to send: the method, the URL, and a body,
// which may be nil. A body that is a *strings.Reader gives the request its
// length.
func NewRequest(method, target string, body io.Reader) (*Request, error) {
	if method == "" {
		method = "GET"
	}
	if !nethttp.validToken(method) {
		return nil, fmt.Errorf("net/http: invalid method %q", method)
	}
	u, err := url.Parse(target)
	if err != nil {
		return nil, err
	}
	// "host:" is the host without a port.
	if strings.HasSuffix(u.Host, ":") && !strings.HasSuffix(u.Host, "]:") {
		u.Host = u.Host[:len(u.Host)-1]
	}
	req := &Request{
		Method:     method,
		URL:        u,
		Proto:      "HTTP/1.1",
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     Header{},
		Host:       u.Host,
	}
	if body != nil {
		if rc, ok := body.(io.ReadCloser); ok {
			req.Body = rc
		} else {
			req.Body = io.NopCloser(body)
		}
		req.ContentLength = -1
		if sr, ok := body.(*strings.Reader); ok {
			req.ContentLength = int64(sr.Len())
			snapshot := *sr
			req.GetBody = func() (io.ReadCloser, error) {
				r := snapshot
				return io.NopCloser(&r), nil
			}
			if req.ContentLength == 0 {
				req.Body = NoBody
				req.GetBody = func() (io.ReadCloser, error) { return NoBody, nil }
			}
		}
	}
	return req, nil
}

// noBody is the body of a message that has none.
type noBody struct{}

func (b noBody) Read(p []byte) (int, error) { return 0, io.EOF }

func (b noBody) Close() error { return nil }

// NoBody is a body without bytes: Read returns io.EOF at once.
var NoBody = noBody{}

// A badStringError says what is wrong and quotes the text that is.
func badStringError(what, val string) error {
	return fmt.Errorf("%s %q", what, val)
}

// parseHTTPVersion reads "HTTP/1.0" as (1, 0, true).
func parseHTTPVersion(vers string) (major, minor int, ok bool) {
	switch vers {
	case "HTTP/1.1":
		return 1, 1, true
	case "HTTP/1.0":
		return 1, 0, true
	}
	if !strings.HasPrefix(vers, "HTTP/") || len(vers) != len("HTTP/X.Y") || vers[6] != '.' {
		return 0, 0, false
	}
	if vers[5] < '0' || vers[5] > '9' || vers[7] < '0' || vers[7] > '9' {
		return 0, 0, false
	}
	return int(vers[5] - '0'), int(vers[7] - '0'), true
}

// ParseHTTPVersion parses a protocol version: "HTTP/1.0" is (1, 0, true).
func ParseHTTPVersion(vers string) (major, minor int, ok bool) {
	return parseHTTPVersion(vers)
}

// parseContentLength reads the value of a Content-Length field: -1 when
// there is none.
func parseContentLength(values []string) (int, error) {
	if len(values) == 0 {
		return -1, nil
	}
	cl := trimString(values[0])
	if cl == "" {
		return 0, badStringError("invalid empty Content-Length", cl)
	}
	// Digits and nothing else, and no more of them than a length has.
	if len(cl) > 18 {
		return 0, badStringError("bad Content-Length", cl)
	}
	for i := 0; i < len(cl); i++ {
		if cl[i] < '0' || cl[i] > '9' {
			return 0, badStringError("bad Content-Length", cl)
		}
	}
	n, err := strconv.Atoi(cl)
	if err != nil {
		return 0, badStringError("bad Content-Length", cl)
	}
	return n, nil
}
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/servemux.go",
            text: #"""
package http

import (
	"errors"
	"fmt"
	nethttp "net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
)

// A ServeMux routes a request to the handler of the pattern that matches
// it. A pattern is
//
//	[METHOD ][HOST]/[PATH]
//
// where a path that ends in a slash matches every path below it, a segment
// "{name}" matches any one segment, "{name...}" at the end matches the
// rest of the path, and "{$}" at the end matches the slash alone. Of the
// patterns that match, the most specific one handles the request: one that
// names a host before one that does not, one that names the method before
// one that does not, and a literal segment before a wildcard. Two patterns
// of which neither is more specific cannot both be registered.
//
// A request for a path without the final slash of a registered subtree is
// redirected to the path with it, and so is one whose path has "." or ".."
// elements or doubled slashes, to the clean path.
type ServeMux struct {
	mu sync.Mutex
	// The patterns, by host and then by method, each list with a more
	// specific pattern before a more general one that it overlaps.
	hosts map[string]map[string][]*muxEntry
	all   []*muxEntry
}

type muxEntry struct {
	pat     *pattern
	handler Handler
}

// NewServeMux returns a ServeMux without patterns.
func NewServeMux() *ServeMux {
	return &ServeMux{hosts: map[string]map[string][]*muxEntry{}}
}

// DefaultServeMux is the ServeMux that Handle and HandleFunc register with
// and that a server without a handler serves.
var DefaultServeMux = NewServeMux()

// A pattern is a parsed ServeMux pattern.
type pattern struct {
	str      string
	method   string
	host     string
	segments []segment
}

func (p *pattern) lastSegment() segment {
	return p.segments[len(p.segments)-1]
}

// A segment is one element of a pattern's path: literal text, the name of
// a wildcard, or "/" for the "{$}" that ends a pattern.
type segment struct {
	s     string
	wild  bool
	multi bool
}

// parsePattern parses a pattern. An error says where in the pattern it is.
func parsePattern(s string) (*pattern, error) {
	if len(s) == 0 {
		return nil, errors.New("empty pattern")
	}
	off := 0
	fail := func(err error) (*pattern, error) {
		return nil, fmt.Errorf("at offset %d: %w", off, err)
	}

	method := ""
	rest := s
	found := false
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' || s[i] == '\t' {
			method = s[:i]
			rest = s[i+1:]
			for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
				rest = rest[1:]
			}
			found = true
			break
		}
	}
	if method != "" && !nethttp.validToken(method) {
		return fail(fmt.Errorf("invalid method %q", method))
	}
	p := &pattern{str: s, method: method}

	if found {
		off = len(method) + 1
	}
	i := strings.Index(rest, "/")
	if i < 0 {
		return fail(errors.New("host/path missing /"))
	}
	p.host = rest[:i]
	rest = rest[i:]
	if j := strings.Index(p.host, "{"); j >= 0 {
		off += j
		return fail(errors.New("host contains '{' (missing initial '/'?)"))
	}
	off += i

	if method != "" && method != "CONNECT" && rest != cleanPath(rest) {
		return fail(errors.New("non-CONNECT pattern with unclean path can never match"))
	}

	seenNames := map[string]bool{}
	for len(rest) > 0 {
		// rest begins with the slash before the next segment.
		rest = rest[1:]
		off = len(s) - len(rest)
		if len(rest) == 0 {
			// A final slash matches everything below it.
			p.segments = append(p.segments, segment{s: "", wild: true, multi: true})
			break
		}
		i := strings.Index(rest, "/")
		if i < 0 {
			i = len(rest)
		}
		seg := rest[:i]
		rest = rest[i:]
		brace := strings.Index(seg, "{")
		if brace < 0 {
			p.segments = append(p.segments, segment{s: pathUnescape(seg), wild: false, multi: false})
			continue
		}
		if brace != 0 {
			return fail(errors.New("bad wildcard segment (must start with '{')"))
		}
		if seg[len(seg)-1] != '}' {
			return fail(errors.New("bad wildcard segment (must end with '}')"))
		}
		name := seg[1 : len(seg)-1]
		if name == "$" {
			if len(rest) != 0 {
				return fail(errors.New("{$} not at end"))
			}
			p.segments = append(p.segments, segment{s: "/", wild: false, multi: false})
			break
		}
		multi := strings.HasSuffix(name, "...")
		if multi {
			name = name[:len(name)-3]
		}
		if multi && len(rest) != 0 {
			return fail(errors.New("{...} wildcard not at end"))
		}
		if name == "" {
			return fail(errors.New("empty wildcard"))
		}
		if !isValidWildcardName(name) {
			return fail(fmt.Errorf("bad wildcard name %q", name))
		}
		if seenNames[name] {
			return fail(fmt.Errorf("duplicate wildcard name %q", name))
		}
		seenNames[name] = true
		p.segments = append(p.segments, segment{s: name, wild: true, multi: multi})
	}
	return p, nil
}

// isValidWildcardName reports whether s is an identifier of ASCII letters,
// digits, and underscores. Go also takes letters and digits beyond ASCII.
func isValidWildcardName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		isLetter := 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || c >= 0x80
		isDigit := '0' <= c && c <= '9'
		if !isLetter && c != '_' && (i == 0 || !isDigit) {
			return false
		}
	}
	return true
}

func pathUnescape(path string) string {
	if !strings.Contains(path, "%") {
		return path
	}
	u, err := url.PathUnescape(path)
	if err != nil {
		// What is no escape stands for itself.
		return path
	}
	return u
}

// How the requests two patterns match relate.
type relationship int

const (
	equivalent   relationship = iota // both match the same requests
	moreGeneral                      // the first matches all the second does, and more
	moreSpecific                     // the second matches all the first does, and more
	disjoint                         // no request matches both
	overlaps                         // some request matches both, and neither is more specific
)

// conflictsWith reports whether p1 and p2 cannot both be registered: some
// request matches both and neither is the more specific.
func (p1 *pattern) conflictsWith(p2 *pattern) bool {
	if p1.host != p2.host {
		// A pattern with a host comes before one without, and two hosts
		// share no request.
		return false
	}
	rel := p1.comparePathsAndMethods(p2)
	return rel == equivalent || rel == overlaps
}

func (p1 *pattern) comparePathsAndMethods(p2 *pattern) relationship {
	mrel := p1.compareMethods(p2)
	if mrel == disjoint {
		return disjoint
	}
	return combineRelationships(mrel, p1.comparePaths(p2))
}

// compareMethods relates the methods of two patterns. No method is every
// method, and GET is HEAD as well.
func (p1 *pattern) compareMethods(p2 *pattern) relationship {
	if p1.method == p2.method {
		return equivalent
	}
	if p1.method == "" {
		return moreGeneral
	}
	if p2.method == "" {
		return moreSpecific
	}
	if p1.method == "GET" && p2.method == "HEAD" {
		return moreGeneral
	}
	if p2.method == "GET" && p1.method == "HEAD" {
		return moreSpecific
	}
	return disjoint
}

// comparePaths relates the paths of two patterns, segment by segment.
func (p1 *pattern) comparePaths(p2 *pattern) relationship {
	// Paths of different lengths share a path only when the shorter one
	// ends in a wildcard for the rest.
	if len(p1.segments) != len(p2.segments) && !p1.lastSegment().multi && !p2.lastSegment().multi {
		return disjoint
	}
	segs1 := p1.segments
	segs2 := p2.segments
	rel := equivalent
	for len(segs1) > 0 && len(segs2) > 0 {
		rel = combineRelationships(rel, compareSegments(segs1[0], segs2[0]))
		if rel == disjoint {
			return rel
		}
		segs1 = segs1[1:]
		segs2 = segs2[1:]
	}
	if len(segs1) == 0 && len(segs2) == 0 {
		return rel
	}
	// One pattern has segments left, which the other's final wildcard
	// takes in.
	if len(segs1) < len(segs2) && p1.lastSegment().multi {
		return combineRelationships(rel, moreGeneral)
	}
	if len(segs2) < len(segs1) && p2.lastSegment().multi {
		return combineRelationships(rel, moreSpecific)
	}
	return disjoint
}

func compareSegments(s1, s2 segment) relationship {
	if s1.multi && s2.multi {
		return equivalent
	}
	if s1.multi {
		return moreGeneral
	}
	if s2.multi {
		return moreSpecific
	}
	if s1.wild && s2.wild {
		return equivalent
	}
	if s1.wild {
		if s2.s == "/" {
			// A wildcard matches a segment, and "{$}" the lack of one.
			return disjoint
		}
		return moreGeneral
	}
	if s2.wild {
		if s1.s == "/" {
			return disjoint
		}
		return moreSpecific
	}
	if s1.s == s2.s {
		return equivalent
	}
	return disjoint
}

// combineRelationships relates two patterns of which one part relates as
// r1 and another as r2.
func combineRelationships(r1, r2 relationship) relationship {
	switch r1 {
	case equivalent:
		return r2
	case disjoint:
		return disjoint
	case overlaps:
		if r2 == disjoint {
			return disjoint
		}
		return overlaps
	}
	// r1 is moreGeneral or moreSpecific.
	switch r2 {
	case equivalent:
		return r1
	case inverseRelationship(r1):
		return overlaps
	}
	return r2
}

func inverseRelationship(r relationship) relationship {
	switch r {
	case moreSpecific:
		return moreGeneral
	case moreGeneral:
		return moreSpecific
	}
	return r
}

// describeConflict says why two patterns cannot both be registered.
func describeConflict(p1, p2 *pattern) string {
	mrel := p1.compareMethods(p2)
	prel := p1.comparePaths(p2)
	rel := combineRelationships(mrel, prel)
	if rel == equivalent {
		return fmt.Sprintf("%s matches the same requests as %s", p1.str, p2.str)
	}
	if rel != overlaps {
		panic("describeConflict called with non-conflicting patterns")
	}
	if prel == overlaps {
		return fmt.Sprintf("%[1]s and %[2]s both match some paths, like %[3]q.\nBut neither is more specific than the other.\n%[1]s matches %[4]q, but %[2]s doesn't.\n%[2]s matches %[5]q, but %[1]s doesn't.",
			p1.str, p2.str, commonPath(p1, p2), differencePath(p1, p2), differencePath(p2, p1))
	}
	if mrel == moreGeneral && prel == moreSpecific {
		return fmt.Sprintf("%s matches more methods than %s, but has a more specific path pattern", p1.str, p2.str)
	}
	if mrel == moreSpecific && prel == moreGeneral {
		return fmt.Sprintf("%s matches fewer methods than %s, but has a more general path pattern", p1.str, p2.str)
	}
	return fmt.Sprintf("bug: unexpected way for two patterns %s and %s to conflict", p1.str, p2.str)
}

// matchingSegment is a path segment that s matches.
func matchingSegment(s segment) string {
	if !s.multi && s.s != "/" {
		return "/" + s.s
	}
	return "/"
}

func matchingPath(segs []segment) string {
	path := ""
	for _, s := range segs {
		path += matchingSegment(s)
	}
	return path
}

// commonPath is a path that both of two overlapping patterns match.
func commonPath(p1, p2 *pattern) string {
	path := ""
	segs1 := p1.segments
	segs2 := p2.segments
	for len(segs1) > 0 && len(segs2) > 0 {
		if s1 := segs1[0]; s1.wild {
			path += matchingSegment(segs2[0])
		} else {
			path += matchingSegment(s1)
		}
		segs1 = segs1[1:]
		segs2 = segs2[1:]
	}
	if len(segs1) > 0 {
		path += matchingPath(segs1)
	} else if len(segs2) > 0 {
		path += matchingPath(segs2)
	}
	return path
}

// differencePath is a path that p1 matches and p2, which overlaps it,
// does not.
func differencePath(p1, p2 *pattern) string {
	path := ""
	segs1 := p1.segments
	segs2 := p2.segments
	for len(segs1) > 0 && len(segs2) > 0 {
		s1 := segs1[0]
		s2 := segs2[0]
		if s1.multi && s2.multi {
			// Both end here, so the difference lies before.
			return path + "/"
		}
		if s1.multi && !s2.multi {
			// s1 takes the rest, where s2 takes one segment or the lack
			// of one: the other of the two is the difference.
			path += "/"
			if s2.s == "/" {
				if s1.s != "" {
					path += s1.s
				} else {
					path += "x"
				}
			}
			return path
		}
		if !s1.multi && s2.multi {
			path += matchingSegment(s1)
		} else if s1.wild && s2.wild {
			path += matchingSegment(s1)
		} else if s1.wild && !s2.wild {
			// Any segment but the literal of s2.
			if s1.s != s2.s {
				path += matchingSegment(s1)
			} else {
				path += "/" + s2.s + "x"
			}
		} else if !s1.wild && s2.wild {
			path += matchingSegment(s1)
		} else {
			if s1.s != s2.s {
				panic(fmt.Sprintf("literals differ: %q and %q", s1.s, s2.s))
			}
			path += matchingSegment(s1)
		}
		segs1 = segs1[1:]
		segs2 = segs2[1:]
	}
	if len(segs1) > 0 {
		path += matchingPath(segs1)
	} else if len(segs2) > 0 {
		path += matchingPath(segs2)
	}
	return path
}

// Handle registers the handler for the pattern. It panics when the pattern
// is malformed or conflicts with one that is registered.
func (mux *ServeMux) Handle(pattern string, handler Handler) {
	if err := mux.register(pattern, handler); err != nil {
		panic(err)
	}
}

// HandleFunc registers the function as the handler for the pattern.
func (mux *ServeMux) HandleFunc(pattern string, handler func(ResponseWriter, *Request)) {
	if handler == nil {
		panic(errors.New("http: nil handler"))
	}
	if err := mux.register(pattern, HandlerFunc(handler)); err != nil {
		panic(err)
	}
}

// Handle registers the handler for the pattern in DefaultServeMux.
func Handle(pattern string, handler Handler) {
	DefaultServeMux.Handle(pattern, handler)
}

// HandleFunc registers the function as the handler for the pattern in
// DefaultServeMux.
func HandleFunc(pattern string, handler func(ResponseWriter, *Request)) {
	DefaultServeMux.HandleFunc(pattern, handler)
}

func (mux *ServeMux) register(patstr string, handler Handler) error {
	if patstr == "" {
		return errors.New("http: invalid pattern")
	}
	if handler == nil {
		return errors.New("http: nil handler")
	}
	if f, ok := handler.(HandlerFunc); ok && f == nil {
		return errors.New("http: nil handler")
	}

	pat, err := parsePattern(patstr)
	if err != nil {
		return fmt.Errorf("parsing %q: %w", patstr, err)
	}

	mux.mu.Lock()
	defer mux.mu.Unlock()
	if mux.hosts == nil {
		mux.hosts = map[string]map[string][]*muxEntry{}
	}
	for _, e := range mux.all {
		if pat.conflictsWith(e.pat) {
			// Go names the lines of the two registrations here, which a
			// program of this toolchain cannot ask for.
			return fmt.Errorf("pattern %q (registered at %s) conflicts with pattern %q (registered at %s):\n%s",
				pat.str, "unknown location", e.pat.str, "unknown location", describeConflict(pat, e.pat))
		}
	}
	entry := &muxEntry{pat: pat, handler: handler}
	mux.all = append(mux.all, entry)
	methods := mux.hosts[pat.host]
	if methods == nil {
		methods = map[string][]*muxEntry{}
		mux.hosts[pat.host] = methods
	}
	// Before the first pattern it is more specific than: every pattern
	// more specific than this one is more specific than that one too, and
	// so stands before it already.
	list := methods[pat.method]
	at := len(list)
	for i, e := range list {
		if pat.comparePaths(e.pat) == moreSpecific {
			at = i
			break
		}
	}
	list = append(list, entry)
	copy(list[at+1:], list[at:len(list)-1])
	list[at] = entry
	methods[pat.method] = list
	return nil
}

// requestPath is the path of a request in the pieces patterns match: its
// segments unescaped, with "/" last for a path that ends in a slash, and
// where each segment begins in the path.
type requestPath struct {
	path     string
	segments []string
	starts   []int
}

func splitPath(path string) *requestPath {
	rp := &requestPath{path: path}
	parts := strings.Split(path[1:], "/")
	offset := 0
	for i, part := range parts {
		rp.starts = append(rp.starts, offset)
		if i == len(parts)-1 && part == "" {
			rp.segments = append(rp.segments, "/")
		} else {
			rp.segments = append(rp.segments, pathUnescape(part))
		}
		offset += len(part) + 1
	}
	return rp
}

// match reports whether the pattern's path matches rp, and what its
// wildcards stand for.
func (p *pattern) match(rp *requestPath) (bool, []string) {
	var matches []string
	n := len(rp.segments)
	for i, seg := range p.segments {
		if seg.multi {
			// The rest of the path, which is at least a slash.
			if i >= n {
				return false, nil
			}
			if seg.s != "" {
				matches = append(matches, pathUnescape(rp.path[rp.starts[i]+1:]))
			}
			return true, matches
		}
		if i >= n {
			return false, nil
		}
		if seg.wild {
			if rp.segments[i] == "/" {
				return false, nil
			}
			matches = append(matches, rp.segments[i])
		} else if seg.s != rp.segments[i] {
			return false, nil
		}
	}
	return len(p.segments) == n, matches
}

// match finds the entry for a host, a method, and a path: among the
// patterns for the host before those for any host, and among those for the
// method before those for any method, the first that matches the path.
func (mux *ServeMux) match(host, method, path string) (*muxEntry, []string) {
	if len(path) == 0 || path[0] != '/' {
		return nil, nil
	}
	rp := splitPath(path)
	if host != "" {
		if e, m := matchMethodAndPath(mux.hosts[host], method, rp); e != nil {
			return e, m
		}
	}
	return matchMethodAndPath(mux.hosts[""], method, rp)
}

func matchMethodAndPath(methods map[string][]*muxEntry, method string, rp *requestPath) (*muxEntry, []string) {
	if methods == nil {
		return nil, nil
	}
	if e, m := matchPath(methods[method], rp); e != nil {
		return e, m
	}
	if method == "HEAD" {
		// A pattern for GET takes HEAD as well.
		if e, m := matchPath(methods["GET"], rp); e != nil {
			return e, m
		}
	}
	if method == "" {
		return nil, nil
	}
	return matchPath(methods[""], rp)
}

func matchPath(entries []*muxEntry, rp *requestPath) (*muxEntry, []string) {
	for _, e := range entries {
		if ok, m := e.pat.match(rp); ok {
			return e, m
		}
	}
	return nil, nil
}

// exactMatch reports whether the entry matches the path as such, and not
// as a path below the slash its pattern ends in.
func exactMatch(e *muxEntry, path string) bool {
	if e == nil {
		return false
	}
	if !e.pat.lastSegment().multi {
		return true
	}
	// A pattern that ends in a slash matches the path exactly when the
	// path ends there too.
	if len(path) > 0 && path[len(path)-1] != '/' {
		return false
	}
	return len(e.pat.segments) == strings.Count(path, "/")
}

// matchOrRedirect matches the path, and when nothing matches it exactly
// and a pattern does match it with a slash added, says to redirect there.
func (mux *ServeMux) matchOrRedirect(host, method, path string, u *url.URL) (*muxEntry, []string, *url.URL) {
	mux.mu.Lock()
	defer mux.mu.Unlock()

	e, matches := mux.match(host, method, path)
	if !exactMatch(e, path) && u != nil && !strings.HasSuffix(path, "/") {
		path += "/"
		e2, _ := mux.match(host, method, path)
		if exactMatch(e2, path) {
			return nil, nil, &url.URL{Path: cleanPath(u.Path) + "/", RawQuery: u.RawQuery}
		}
	}
	return e, matches, nil
}

// matchingMethods returns the methods of the patterns that match the host
// and the path, or the path with a slash added, sorted.
func (mux *ServeMux) matchingMethods(host, path string) []string {
	mux.mu.Lock()
	defer mux.mu.Unlock()
	set := map[string]bool{}
	paths := []string{path}
	if !strings.HasSuffix(path, "/") {
		paths = append(paths, path+"/")
	}
	hosts := []string{""}
	if host != "" {
		hosts = []string{host, ""}
	}
	for _, p := range paths {
		if len(p) == 0 || p[0] != '/' {
			continue
		}
		rp := splitPath(p)
		for _, h := range hosts {
			for method, entries := range mux.hosts[h] {
				if method == "" {
					continue
				}
				if e, _ := matchPath(entries, rp); e != nil {
					set[method] = true
				}
			}
		}
		if set["GET"] {
			set["HEAD"] = true
		}
	}
	methods := make([]string, 0, len(set))
	for m := range set {
		methods = append(methods, m)
	}
	sort.Strings(methods)
	return methods
}

// Handler returns the handler for the request and the pattern that
// matched: a redirect for a path that is not clean or lacks the slash of a
// subtree, and a "page not found" handler with the pattern "" when nothing
// matches.
func (mux *ServeMux) Handler(r *Request) (h Handler, pattern string) {
	h, p, _, _ := mux.findHandler(r)
	return h, p
}

func (mux *ServeMux) findHandler(r *Request) (h Handler, patStr string, pat *pattern, matches []string) {
	var e *muxEntry
	host := r.URL.Host
	escapedPath := r.URL.EscapedPath()
	path := escapedPath
	// The path of CONNECT is taken as it is.
	if r.Method == "CONNECT" {
		_, _, u := mux.matchOrRedirect(host, r.Method, path, r.URL)
		if u != nil {
			return RedirectHandler(u.String(), StatusMovedPermanently), u.Path, nil, nil
		}
		// With the request's host this time, and no redirect.
		e, matches, _ = mux.matchOrRedirect(r.Host, r.Method, path, nil)
	} else {
		// The host without its port, and the path clean.
		host = stripHostPort(r.Host)
		path = cleanPath(path)

		var u *url.URL
		e, matches, u = mux.matchOrRedirect(host, r.Method, path, r.URL)
		if u != nil {
			return RedirectHandler(u.String(), StatusMovedPermanently), u.Path, nil, nil
		}
		if path != escapedPath {
			// To the clean path.
			patStr := ""
			if e != nil {
				patStr = e.pat.str
			}
			u := &url.URL{Path: path, RawQuery: r.URL.RawQuery}
			return RedirectHandler(u.String(), StatusMovedPermanently), patStr, nil, nil
		}
	}
	if e == nil {
		// Nothing for the method: when a pattern matches but for the
		// method, the answer is that the method is not allowed.
		allowedMethods := mux.matchingMethods(host, path)
		if len(allowedMethods) > 0 {
			return HandlerFunc(func(w ResponseWriter, r *Request) {
				w.Header().Set("Allow", strings.Join(allowedMethods, ", "))
				Error(w, StatusText(StatusMethodNotAllowed), StatusMethodNotAllowed)
			}), "", nil, nil
		}
		return NotFoundHandler(), "", nil, nil
	}
	return e.handler, e.pat.str, e.pat, matches
}

// ServeHTTP passes the request to the handler whose pattern matches it.
func (mux *ServeMux) ServeHTTP(w ResponseWriter, r *Request) {
	if r.RequestURI == "*" {
		if r.ProtoAtLeast(1, 1) {
			w.Header().Set("Connection", "close")
		}
		w.WriteHeader(StatusBadRequest)
		return
	}
	var h Handler
	h, r.Pattern, r.pat, r.matches = mux.findHandler(r)
	h.ServeHTTP(w, r)
}

// cleanPath returns the canonical form of a path: rooted, without "." and
// ".." elements and doubled slashes, and with the final slash it had.
func cleanPath(p string) string {
	if p == "" {
		return "/"
	}
	if p[0] != '/' {
		p = "/" + p
	}
	if !strings.Contains(p, "//") && !strings.Contains(p, "/.") {
		// Clean already.
		return p
	}
	np := pathClean(p)
	// Cleaning takes the final slash away, except from the root.
	if p[len(p)-1] == '/' && np != "/" {
		if len(p) == len(np)+1 && strings.HasPrefix(p, np) {
			np = p
		} else {
			np += "/"
		}
	}
	return np
}

// pathClean returns the shortest path that names what p names, as Go's
// path.Clean does: no doubled slash, no "." element, and no ".." element
// that an element before it cancels.
func pathClean(p string) string {
	if p == "" {
		return "."
	}
	rooted := p[0] == '/'
	var out []string
	for _, element := range strings.Split(p, "/") {
		switch element {
		case "", ".":
		case "..":
			if len(out) > 0 && out[len(out)-1] != ".." {
				out = out[:len(out)-1]
			} else if !rooted {
				out = append(out, "..")
			}
		default:
			out = append(out, element)
		}
	}
	cleaned := strings.Join(out, "/")
	if rooted {
		return "/" + cleaned
	}
	if cleaned == "" {
		return "."
	}
	return cleaned
}

// stripHostPort returns h without a port.
func stripHostPort(h string) string {
	if !strings.Contains(h, ":") {
		return h
	}
	host, _, ok := splitHostPort(h)
	if !ok {
		// What cannot be split is left as it is.
		return h
	}
	return host
}

// splitHostPort splits "host:port" and "[host]:port", as net.SplitHostPort
// does, and reports whether the address has that form.
func splitHostPort(hostport string) (host, port string, ok bool) {
	i := strings.LastIndex(hostport, ":")
	if i < 0 {
		return "", "", false
	}
	if len(hostport) > 0 && hostport[0] == '[' {
		end := strings.Index(hostport, "]")
		if end < 0 || end+1 != i {
			return "", "", false
		}
		host = hostport[1:end]
		if strings.Contains(host, "[") || strings.Contains(host, "]") {
			return "", "", false
		}
	} else {
		host = hostport[:i]
		if strings.Contains(host, ":") || strings.Contains(host, "[") || strings.Contains(host, "]") {
			return "", "", false
		}
	}
	port = hostport[i+1:]
	if strings.Contains(port, "[") || strings.Contains(port, "]") {
		return "", "", false
	}
	return host, port, true
}
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/server.go",
            text: #"""
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
	nethttp "net/http"
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
		if !nethttp.validToken(k) {
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
	if !nethttp.validToken(req.Method) {
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
			contentType = nethttp.DetectContentType(p)
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
		date = nethttp.formatTime(int(time.Now().Unix()), 0)
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
	c.remoteAddr = nethttp.remoteAddr(c.rwc)
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
	fmt.Fprintln(os.Stderr, nethttp.formatTime(int(time.Now().Unix()), 1)+" "+fmt.Sprintf(format, args...))
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
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/status.go",
            text: #"""
package http

// The status codes of HTTP, as IANA registers them.
const (
	StatusContinue           = 100
	StatusSwitchingProtocols = 101
	StatusProcessing         = 102
	StatusEarlyHints         = 103

	StatusOK                   = 200
	StatusCreated              = 201
	StatusAccepted             = 202
	StatusNonAuthoritativeInfo = 203
	StatusNoContent            = 204
	StatusResetContent         = 205
	StatusPartialContent       = 206
	StatusMultiStatus          = 207
	StatusAlreadyReported      = 208
	StatusIMUsed               = 226

	StatusMultipleChoices   = 300
	StatusMovedPermanently  = 301
	StatusFound             = 302
	StatusSeeOther          = 303
	StatusNotModified       = 304
	StatusUseProxy          = 305
	StatusTemporaryRedirect = 307
	StatusPermanentRedirect = 308

	StatusBadRequest                   = 400
	StatusUnauthorized                 = 401
	StatusPaymentRequired              = 402
	StatusForbidden                    = 403
	StatusNotFound                     = 404
	StatusMethodNotAllowed             = 405
	StatusNotAcceptable                = 406
	StatusProxyAuthRequired            = 407
	StatusRequestTimeout               = 408
	StatusConflict                     = 409
	StatusGone                         = 410
	StatusLengthRequired               = 411
	StatusPreconditionFailed           = 412
	StatusRequestEntityTooLarge        = 413
	StatusRequestURITooLong            = 414
	StatusUnsupportedMediaType         = 415
	StatusRequestedRangeNotSatisfiable = 416
	StatusExpectationFailed            = 417
	StatusTeapot                       = 418
	StatusMisdirectedRequest           = 421
	StatusUnprocessableEntity          = 422
	StatusLocked                       = 423
	StatusFailedDependency             = 424
	StatusTooEarly                     = 425
	StatusUpgradeRequired              = 426
	StatusPreconditionRequired         = 428
	StatusTooManyRequests              = 429
	StatusRequestHeaderFieldsTooLarge  = 431
	StatusUnavailableForLegalReasons   = 451

	StatusInternalServerError           = 500
	StatusNotImplemented                = 501
	StatusBadGateway                    = 502
	StatusServiceUnavailable            = 503
	StatusGatewayTimeout                = 504
	StatusHTTPVersionNotSupported       = 505
	StatusVariantAlsoNegotiates         = 506
	StatusInsufficientStorage           = 507
	StatusLoopDetected                  = 508
	StatusNotExtended                   = 510
	StatusNetworkAuthenticationRequired = 511
)

// StatusText returns the text for a status code, or "" for a code that has
// none.
func StatusText(code int) string {
	switch code {
	case StatusContinue:
		return "Continue"
	case StatusSwitchingProtocols:
		return "Switching Protocols"
	case StatusProcessing:
		return "Processing"
	case StatusEarlyHints:
		return "Early Hints"
	case StatusOK:
		return "OK"
	case StatusCreated:
		return "Created"
	case StatusAccepted:
		return "Accepted"
	case StatusNonAuthoritativeInfo:
		return "Non-Authoritative Information"
	case StatusNoContent:
		return "No Content"
	case StatusResetContent:
		return "Reset Content"
	case StatusPartialContent:
		return "Partial Content"
	case StatusMultiStatus:
		return "Multi-Status"
	case StatusAlreadyReported:
		return "Already Reported"
	case StatusIMUsed:
		return "IM Used"
	case StatusMultipleChoices:
		return "Multiple Choices"
	case StatusMovedPermanently:
		return "Moved Permanently"
	case StatusFound:
		return "Found"
	case StatusSeeOther:
		return "See Other"
	case StatusNotModified:
		return "Not Modified"
	case StatusUseProxy:
		return "Use Proxy"
	case StatusTemporaryRedirect:
		return "Temporary Redirect"
	case StatusPermanentRedirect:
		return "Permanent Redirect"
	case StatusBadRequest:
		return "Bad Request"
	case StatusUnauthorized:
		return "Unauthorized"
	case StatusPaymentRequired:
		return "Payment Required"
	case StatusForbidden:
		return "Forbidden"
	case StatusNotFound:
		return "Not Found"
	case StatusMethodNotAllowed:
		return "Method Not Allowed"
	case StatusNotAcceptable:
		return "Not Acceptable"
	case StatusProxyAuthRequired:
		return "Proxy Authentication Required"
	case StatusRequestTimeout:
		return "Request Timeout"
	case StatusConflict:
		return "Conflict"
	case StatusGone:
		return "Gone"
	case StatusLengthRequired:
		return "Length Required"
	case StatusPreconditionFailed:
		return "Precondition Failed"
	case StatusRequestEntityTooLarge:
		return "Request Entity Too Large"
	case StatusRequestURITooLong:
		return "Request URI Too Long"
	case StatusUnsupportedMediaType:
		return "Unsupported Media Type"
	case StatusRequestedRangeNotSatisfiable:
		return "Requested Range Not Satisfiable"
	case StatusExpectationFailed:
		return "Expectation Failed"
	case StatusTeapot:
		return "I'm a teapot"
	case StatusMisdirectedRequest:
		return "Misdirected Request"
	case StatusUnprocessableEntity:
		return "Unprocessable Entity"
	case StatusLocked:
		return "Locked"
	case StatusFailedDependency:
		return "Failed Dependency"
	case StatusTooEarly:
		return "Too Early"
	case StatusUpgradeRequired:
		return "Upgrade Required"
	case StatusPreconditionRequired:
		return "Precondition Required"
	case StatusTooManyRequests:
		return "Too Many Requests"
	case StatusRequestHeaderFieldsTooLarge:
		return "Request Header Fields Too Large"
	case StatusUnavailableForLegalReasons:
		return "Unavailable For Legal Reasons"
	case StatusInternalServerError:
		return "Internal Server Error"
	case StatusNotImplemented:
		return "Not Implemented"
	case StatusBadGateway:
		return "Bad Gateway"
	case StatusServiceUnavailable:
		return "Service Unavailable"
	case StatusGatewayTimeout:
		return "Gateway Timeout"
	case StatusHTTPVersionNotSupported:
		return "HTTP Version Not Supported"
	case StatusVariantAlsoNegotiates:
		return "Variant Also Negotiates"
	case StatusInsufficientStorage:
		return "Insufficient Storage"
	case StatusLoopDetected:
		return "Loop Detected"
	case StatusNotExtended:
		return "Not Extended"
	case StatusNetworkAuthenticationRequired:
		return "Network Authentication Required"
	}
	return ""
}
"""#),
        GoSourceFile(
            path: "$GOROOT/src/net/http/transfer.go",
            text: #"""
package http

import (
	"errors"
	"fmt"
	"io"
	"net"
	nethttp "net/http"
	"strings"
	"sync"
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
}

func newConnReader(conn net.Conn) *connReader {
	return &connReader{conn: conn, scratch: make([]byte, 4096)}
}

// fill reads once from the connection, waiting for it.
func (r *connReader) fill() error {
	if r.err != nil {
		return r.err
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
		end := nethttp.lineEnd(r.buf, from)
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
		if key == "" || !validHeaderKey(key) || !nethttp.validHeaderValue(value) {
			return h, protocolError("malformed MIME header line: " + line)
		}
		key = nethttp.CanonicalHeaderKey(key)
		for len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
			value = value[1:]
		}
		h[key] = append(h[key], value)
	}
}

// validHeaderKey reports whether key is a token, or one with spaces, which
// is kept as it is so that the request can be refused for it.
func validHeaderKey(key string) bool {
	if nethttp.validToken(key) {
		return true
	}
	if !strings.Contains(key, " ") {
		return false
	}
	return nethttp.validToken(strings.Join(strings.Split(key, " "), ""))
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
			if n > 0 && nethttp.lineEnd(b.src.buf, 0) < 0 {
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
"""#),
    ]
}
