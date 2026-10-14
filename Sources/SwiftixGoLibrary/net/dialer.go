package net

import (
	"context"
	"errors"
	"time"
)

// A Dialer contains options for connecting to an address. It has Go's
// fields; this library dials TCP over IPv4 at once, so Timeout, Deadline,
// LocalAddr, DualStack, FallbackDelay, KeepAlive, and Control change
// nothing.
//
// The zero value for each field is equivalent to dialing
// without that option. Dialing with the zero value of Dialer
// is therefore equivalent to just calling the [Dial] function.
//
// It is safe to call Dialer's methods concurrently.
type Dialer struct {
	Timeout       time.Duration
	Deadline      time.Time
	LocalAddr     Addr
	DualStack     bool
	FallbackDelay time.Duration
	KeepAlive     time.Duration
}

// errCanceled is Go's error of a dial whose context was canceled.
var errCanceled = errors.New("operation was canceled")

// mapErr maps from the context errors to the historical internal net
// error values.
func mapErr(err error) error {
	switch err {
	case context.Canceled:
		return errCanceled
	case context.DeadlineExceeded:
		return errTimeout
	default:
		return err
	}
}

// Dial connects to the address on the named network.
func (d *Dialer) Dial(network, address string) (Conn, error) {
	return d.DialContext(context.Background(), network, address)
}

// DialContext connects to the address on the named network using
// the provided context. A context that is done before the connection is
// made ends the dial with Go's error for it.
func (d *Dialer) DialContext(ctx context.Context, network, address string) (Conn, error) {
	if ctx == nil {
		panic("nil context")
	}
	if err := ctx.Err(); err != nil {
		return nil, &OpError{Op: "dial", Net: network, Source: nil, Addr: nil, Err: mapErr(err)}
	}
	return Dial(network, address)
}

// errTimeout exists to return the historical "i/o timeout" string
// for context.DeadlineExceeded. See mapErr.
// It is also used when Dialer.Deadline is exceeded.
// error.Is(errTimeout, context.DeadlineExceeded) returns true.
var errTimeout error = &timeoutError{}

type timeoutError struct{}

func (e *timeoutError) Error() string   { return "i/o timeout" }
func (e *timeoutError) Timeout() bool   { return true }
func (e *timeoutError) Temporary() bool { return true }

func (e *timeoutError) Is(err error) bool {
	return err == context.DeadlineExceeded
}
