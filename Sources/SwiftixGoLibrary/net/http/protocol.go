package http

import (
	"bufio"
	"errors"
	"net"
	"time"
)

// ProtocolError represents an HTTP protocol error.
//
// Deprecated: Not all errors in the http package related to protocol errors
// are of type ProtocolError.
type ProtocolError struct {
	ErrorString string
}

func (pe *ProtocolError) Error() string { return pe.ErrorString }

// Is lets http.ErrNotSupported match errors.ErrUnsupported.
func (pe *ProtocolError) Is(err error) bool {
	return pe == ErrNotSupported && err == errors.ErrUnsupported
}

// ErrNotSupported indicates that a feature is not supported.
//
// It is returned by ResponseController methods to indicate that
// the handler does not support the method, and by the Push method
// of Pusher implementations to indicate that HTTP/2 Push support
// is not available.
var ErrNotSupported = &ProtocolError{"feature not supported"}

// The Hijacker interface is implemented by ResponseWriters that allow
// an HTTP handler to take over the connection. The server of this library
// does not: its ResponseController's Hijack is ErrNotSupported.
type Hijacker interface {
	// Hijack lets the caller take over the connection.
	Hijack() (net.Conn, *bufio.ReadWriter, error)
}

// The CloseNotifier interface is implemented by ResponseWriters which
// allow detecting when the underlying connection has gone away.
//
// Deprecated: the CloseNotifier interface predates Go's context package.
// New code should use [Request.Context] instead.
type CloseNotifier interface {
	// CloseNotify returns a channel that receives at most a
	// single value (true) when the client connection has gone
	// away.
	CloseNotify() <-chan bool
}

// FlushError is Flush that reports what stopped the response being sent.
func (w *response) FlushError() error {
	w.Flush()
	return w.conn.werr
}

// SetReadDeadline sets the deadline for reading the request's body.
func (w *response) SetReadDeadline(deadline time.Time) error {
	return w.conn.rwc.SetReadDeadline(deadline)
}

// SetWriteDeadline sets the deadline for sending the response; the zero
// time is none.
func (w *response) SetWriteDeadline(deadline time.Time) error {
	w.conn.hasWriteDeadline = !deadline.IsZero()
	w.conn.writeDeadline = deadline
	return nil
}

// EnableFullDuplex lets the handler read the request body while writing
// the response, which this server does anyway.
func (w *response) EnableFullDuplex() error {
	return nil
}
