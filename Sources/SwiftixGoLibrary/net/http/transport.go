package http

import (
	"context"
	"net"
	"net/url"
	"time"
)

// RoundTripper is an interface representing the ability to execute a
// single HTTP transaction, obtaining the [Response] for a given [Request].
//
// A RoundTripper must be safe for concurrent use by multiple
// goroutines.
type RoundTripper interface {
	// RoundTrip executes a single HTTP transaction, returning
	// a Response for the provided Request.
	//
	// RoundTrip should not attempt to interpret the response. In
	// particular, RoundTrip must return err == nil if it obtained
	// a response, regardless of the response's HTTP status code.
	// A non-nil err should be reserved for failure to obtain a
	// response. Similarly, RoundTrip should not attempt to
	// handle higher-level protocol details such as redirects,
	// authentication, or cookies.
	RoundTrip(*Request) (*Response, error)
}

// DefaultTransport is the default implementation of [Transport] and is
// used by [DefaultClient].
var DefaultTransport RoundTripper = &Transport{
	Proxy:                 ProxyFromEnvironment,
	ForceAttemptHTTP2:     true,
	MaxIdleConns:          100,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   10 * time.Second,
	ExpectContinueTimeout: 1 * time.Second,
}

// Transport is an implementation of [RoundTripper] that sends a request on
// a connection of its own and reads the response. It has Go's fields; this
// library uses DialContext and keeps no idle connections, and the others
// change nothing: there is no proxy, TLS, or HTTP/2.
type Transport struct {
	// Proxy specifies a function to return a proxy for a given
	// Request. This library connects to the host of the request.
	Proxy func(*Request) (*url.URL, error)

	// DialContext specifies the dial function for creating unencrypted TCP
	// connections. If DialContext is nil, the transport dials using
	// package net.
	DialContext func(ctx context.Context, network, addr string) (net.Conn, error)

	TLSHandshakeTimeout    time.Duration
	DisableKeepAlives      bool
	DisableCompression     bool
	MaxIdleConns           int
	MaxIdleConnsPerHost    int
	MaxConnsPerHost        int
	IdleConnTimeout        time.Duration
	ResponseHeaderTimeout  time.Duration
	ExpectContinueTimeout  time.Duration
	MaxResponseHeaderBytes int64
	WriteBufferSize        int
	ReadBufferSize         int
	ForceAttemptHTTP2      bool
}

// RoundTrip implements the [RoundTripper] interface.
func (t *Transport) RoundTrip(req *Request) (*Response, error) {
	rc := newRequestCanceler(req.ctx, 0)
	resp, err := send(req, rc, t)
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

// CloseIdleConnections closes any connections which were previously
// connected from previous requests but are now sitting idle in a
// "keep-alive" state. It does not interrupt any connections currently in
// use. This transport keeps none.
func (t *Transport) CloseIdleConnections() {}

// ProxyFromEnvironment returns the URL of the proxy to use for a given
// request. This library uses no proxy: it returns nil.
func ProxyFromEnvironment(req *Request) (*url.URL, error) {
	return nil, nil
}
