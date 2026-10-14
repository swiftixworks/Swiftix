package http

import (
	"context"
	"sync"
	"time"
)

// A connection's read deadline, and the read that watches for a client to
// go away, as a server has them.
//
// A read of the connection waits until the peer sends something or goes
// away; nothing else wakes it but closing the connection. So when a read
// has to be given up on, it runs in a goroutine of its own: the reader
// waits for its result or for the deadline, whichever comes first, and a
// result that comes later is the result of the next read. Nothing read is
// lost, and a connection without a deadline or a watching read is read
// directly.

// A pendingRead is what a read in a goroutine of its own read.
type pendingRead struct {
	p   []byte
	err error
}

// A timeoutError is a read or a write whose deadline passed.
type timeoutError struct {
	err string
}

func (e *timeoutError) Error() string { return e.err }

// Timeout reports that the error is a time that ran out.
func (e *timeoutError) Timeout() bool { return true }

// Temporary reports that the operation may succeed when tried again.
func (e *timeoutError) Temporary() bool { return true }

// Is reports that the error is, as Go's is, context.DeadlineExceeded.
func (e *timeoutError) Is(err error) bool { return err == context.DeadlineExceeded }

// A deadlineError is a read or a write of a connection after its deadline.
type deadlineError struct{}

func (deadlineError) Error() string   { return "i/o timeout" }
func (deadlineError) Timeout() bool   { return true }
func (deadlineError) Temporary() bool { return true }

var errDeadline error = deadlineError{}

// startRead reads the connection in a goroutine of its own. gone, when not
// nil, is called when the read ends without a byte: the client went away,
// or the connection was closed.
func (r *connReader) startRead(gone func()) {
	ch := make(chan pendingRead, 1)
	r.pending = ch
	conn := r.conn
	go func() {
		p := make([]byte, 4096)
		n, err := conn.Read(p)
		if n == 0 && gone != nil {
			gone()
		}
		ch <- pendingRead{p[:n], err}
	}()
}

// startBackgroundRead watches for the client to go away while a handler
// runs, with a read whose bytes, if the client sends any, are the start of
// the next request. It has no deadline.
func (r *connReader) startBackgroundRead(gone func()) {
	r.clearReadDeadline()
	if r.pending == nil && r.err == nil {
		r.startRead(gone)
	}
}

// setReadDeadline gives the reads from now on until at to complete.
func (r *connReader) setReadDeadline(at time.Time) {
	r.clearReadDeadline()
	r.hasDeadline = true
	if d := time.Until(at); d > 0 {
		r.deadline = time.NewTimer(d)
	} else {
		r.expired = true
	}
}

// clearReadDeadline lets reads wait as long as they take.
func (r *connReader) clearReadDeadline() {
	if r.deadline != nil {
		r.deadline.Stop()
		r.deadline = nil
	}
	r.hasDeadline = false
	r.expired = false
}

// fillPending is fill for a connection with a read under way or a read
// deadline. A deadline that passes is an error of this read, not of the
// connection.
func (r *connReader) fillPending() error {
	if r.expired {
		return errDeadline
	}
	if r.pending == nil {
		r.startRead(nil)
	}
	var res pendingRead
	if r.deadline == nil {
		res = <-r.pending
	} else {
		select {
		case res = <-r.pending:
		case <-r.deadline.C:
			r.expired = true
			return errDeadline
		}
	}
	r.pending = nil
	if len(res.p) > 0 {
		r.buf = append(r.buf, res.p...)
		return nil
	}
	err := res.err
	if err == nil {
		return nil
	}
	r.err = err
	return err
}

// A serverCtx is the context of a request a server serves: it is done when
// the handler returns, when the client goes away, and when the server
// closes the connection.
type serverCtx struct {
	srv  *Server
	mu   sync.Mutex
	done chan struct{}
	err  error
}

// A contextKey is the key of a value the server puts in the context of a
// request.
type contextKey struct {
	name string
}

func (k *contextKey) String() string { return "net/http context value " + k.name }

// ServerContextKey is the key of the *Server in the context of a request
// it serves.
var ServerContextKey = &contextKey{"http-server"}

func (c *serverCtx) Deadline() (deadline time.Time, ok bool) { return }

func (c *serverCtx) Done() <-chan struct{} { return c.done }

func (c *serverCtx) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

func (c *serverCtx) Value(key any) any {
	if k, ok := key.(*contextKey); ok && k == ServerContextKey {
		return c.srv
	}
	return nil
}

// cancel ends the context. Only the first call does anything.
func (c *serverCtx) cancel() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err == nil {
		c.err = context.Canceled
		close(c.done)
	}
}
