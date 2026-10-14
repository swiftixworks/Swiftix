package http

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
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

	// Timeout is how long a request may take, redirects and the reading of
	// the response's body included; zero is no limit. A request that takes
	// longer fails with an error whose Timeout method reports true.
	Timeout time.Duration

	// Transport sends each request; nil is DefaultTransport.
	Transport RoundTripper
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
// It gives up when the request's context is done or c.Timeout passes.
func (c *Client) Do(req *Request) (*Response, error) {
	rc := newRequestCanceler(req.ctx, c.Timeout)
	resp, err := c.do(req, rc)
	if rc != nil {
		if es, ok := bodySignal(resp); ok && err == nil {
			// The body is read under the same watch.
			es.cancel = rc
		} else {
			rc.finish()
		}
	}
	return resp, err
}

// bodySignal returns the body of resp that closes its connection.
func bodySignal(resp *Response) (*bodyEOFSignal, bool) {
	if resp == nil {
		return nil, false
	}
	es, ok := resp.Body.(*bodyEOFSignal)
	return es, ok
}

func (c *Client) do(req *Request, rc *requestCanceler) (*Response, error) {
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
		resp, err = c.send(req, rc)
		if err != nil {
			if rc != nil {
				err = rc.requestError(err, "exceeded while awaiting headers")
			}
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
// send sends req through the client's transport: Transport's own path
// watched by rc, or another RoundTripper's RoundTrip.
func (c *Client) send(req *Request, rc *requestCanceler) (*Response, error) {
	switch t := c.Transport.(type) {
	case nil:
		return send(req, rc, nil)
	case *Transport:
		return send(req, rc, t)
	default:
		resp, err := t.RoundTrip(req)
		if resp == nil && err == nil {
			return nil, errors.New("http: RoundTripper implementation (" + fmt.Sprintf("%T", t) + ") returned a nil *Response with a nil error")
		}
		return resp, err
	}
}

func send(req *Request, rc *requestCanceler, t *Transport) (*Response, error) {
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
	if req.Method != "" && !native.validToken(req.Method) {
		closeBody(req)
		return nil, fmt.Errorf("net/http: invalid method %q", req.Method)
	}
	for k, vv := range req.Header {
		if !native.validToken(k) {
			closeBody(req)
			return nil, fmt.Errorf("net/http: invalid header field name %q", k)
		}
		for _, v := range vv {
			if !native.validHeaderValue(v) {
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
	if err := rc.reason(); err != nil {
		// Given up on before it was sent.
		closeBody(req)
		return nil, err
	}
	var conn net.Conn
	var err error
	if t != nil && t.DialContext != nil {
		conn, err = t.DialContext(req.Context(), "tcp", hostname+":"+port)
	} else {
		conn, err = net.Dial("tcp", hostname+":"+port)
	}
	if err != nil {
		closeBody(req)
		return nil, err
	}
	if rc != nil && !rc.attach(conn) {
		conn.Close()
		closeBody(req)
		return nil, rc.reason()
	}

	if err := writeRequest(conn, req); err != nil {
		closeConn(conn, rc)
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
		closeConn(conn, rc)
		return nil, err
	}
	if b, ok := resp.Body.(*body); ok {
		resp.Body = &bodyEOFSignal{body: b, conn: conn, rc: rc}
	} else {
		closeConn(conn, rc)
	}
	return resp, nil
}

// closeConn closes the connection of a request, once.
func closeConn(conn net.Conn, rc *requestCanceler) {
	if rc != nil {
		rc.closeConn(conn)
	} else {
		conn.Close()
	}
}

// A bodyEOFSignal is the body of a response, which gives the connection
// back when it has been read to its end or is closed.
type bodyEOFSignal struct {
	body   *body
	conn   net.Conn
	closed bool
	done   bool
	// What closes the connection when the request is given up, and, for
	// the response Do returns, the watch that ends with the body.
	rc     *requestCanceler
	cancel *requestCanceler
}

func (es *bodyEOFSignal) Read(p []byte) (n int, err error) {
	if es.closed {
		return 0, errors.New("http: read on closed response body")
	}
	n, err = es.body.Read(p)
	if err != nil {
		if err != io.EOF && es.cancel != nil {
			err = es.cancel.requestError(err, "or context cancellation while reading body")
		}
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
		closeConn(es.conn, es.rc)
		es.cancel.finish()
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
