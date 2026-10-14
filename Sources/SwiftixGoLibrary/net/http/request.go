package http

import (
	"context"
	"errors"
	"fmt"
	"io"
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

	// The context of the request: the client's, or the one the server
	// cancels. Nil is context.Background.
	ctx context.Context
}

// Context returns the context of the request. A server cancels it when
// the client goes away or the handler returns; a client gives up on a
// request when it is done. It is context.Background when none was given.
func (r *Request) Context() context.Context {
	if r.ctx != nil {
		return r.ctx
	}
	return context.Background()
}

// WithContext returns a shallow copy of r whose context is ctx.
func (r *Request) WithContext(ctx context.Context) *Request {
	if ctx == nil {
		panic("nil context")
	}
	r2 := new(Request)
	*r2 = *r
	r2.ctx = ctx
	return r2
}

// Clone returns a deep copy of r whose context is ctx. The body is shared.
func (r *Request) Clone(ctx context.Context) *Request {
	if ctx == nil {
		panic("nil context")
	}
	r2 := new(Request)
	*r2 = *r
	r2.ctx = ctx
	if r.URL != nil {
		u2 := new(url.URL)
		*u2 = *r.URL
		if r.URL.User != nil {
			u2.User = new(url.Userinfo)
			*u2.User = *r.URL.User
		}
		r2.URL = u2
	}
	r2.Header = r.Header.Clone()
	r2.Trailer = r.Trailer.Clone()
	if s := r.TransferEncoding; s != nil {
		s2 := make([]string, len(s))
		copy(s2, s)
		r2.TransferEncoding = s2
	}
	r2.Form = cloneValues(r.Form)
	r2.PostForm = cloneValues(r.PostForm)
	if s := r.matches; s != nil {
		s2 := make([]string, len(s))
		copy(s2, s)
		r2.matches = s2
	}
	if r.otherValues != nil {
		r2.otherValues = map[string]string{}
		for k, v := range r.otherValues {
			r2.otherValues[k] = v
		}
	}
	return r2
}

func cloneValues(v url.Values) url.Values {
	if v == nil {
		return nil
	}
	v2 := url.Values{}
	for k, vv := range v {
		vv2 := make([]string, len(vv))
		copy(vv2, vv)
		v2[k] = vv2
	}
	return v2
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
	return newRequest(nil, method, target, body)
}

// NewRequestWithContext is NewRequest with the context the request is sent
// under: a client gives up on it when ctx is done.
func NewRequestWithContext(ctx context.Context, method, target string, body io.Reader) (*Request, error) {
	if method == "" {
		method = "GET"
	}
	if native.validToken(method) && ctx == nil {
		return nil, errors.New("net/http: nil Context")
	}
	return newRequest(ctx, method, target, body)
}

// newRequest makes the request of NewRequest. A nil ctx is Background,
// which a program that never asks for a context does not link.
func newRequest(ctx context.Context, method, target string, body io.Reader) (*Request, error) {
	if method == "" {
		method = "GET"
	}
	if !native.validToken(method) {
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
		ctx:        ctx,
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
