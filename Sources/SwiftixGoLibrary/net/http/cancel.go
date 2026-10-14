package http

import (
	"context"
	"net"
	"sync"
	"time"
)

// A requestCanceler gives up on a request a client sends when the
// request's context is done or the client's Timeout passes: it closes the
// connection, which wakes whatever waits on it, and keeps the reason, which
// the error of the request then is.
type requestCanceler struct {
	mu       sync.Mutex
	conn     net.Conn
	err      error // why the request was given up; nil while it runs
	timedOut bool  // whether that was the Timeout of the client
	closed   bool  // whether the connection was closed
	stopped  bool
	stop     chan struct{}
	timer    *time.Timer
}

// newRequestCanceler watches ctx, and gives the request timeout to finish
// when it is more than zero. It returns nil when there is nothing to watch.
func newRequestCanceler(ctx context.Context, timeout time.Duration) *requestCanceler {
	var done <-chan struct{}
	if ctx != nil {
		done = ctx.Done()
	}
	if done == nil && timeout <= 0 {
		return nil
	}
	rc := &requestCanceler{stop: make(chan struct{})}
	if timeout > 0 {
		rc.timer = time.AfterFunc(timeout, func() {
			rc.cancel(context.DeadlineExceeded, true)
		})
	}
	if done != nil {
		select {
		case <-done:
			// Done already: the request is not sent at all.
			rc.cancel(context.Cause(ctx), false)
			return rc
		default:
		}
		go func() {
			select {
			case <-done:
				rc.cancel(context.Cause(ctx), false)
			case <-rc.stop:
			}
		}()
	}
	return rc
}

// cancel gives up on the request for err. Only the first call does.
func (rc *requestCanceler) cancel(err error, timedOut bool) {
	rc.mu.Lock()
	if rc.err != nil || rc.stopped {
		rc.mu.Unlock()
		return
	}
	rc.err = err
	rc.timedOut = timedOut
	conn := rc.conn
	rc.mu.Unlock()
	if conn != nil {
		rc.closeConn(conn)
	}
}

// reason returns why the request was given up, or nil.
func (rc *requestCanceler) reason() error {
	if rc == nil {
		return nil
	}
	rc.mu.Lock()
	defer rc.mu.Unlock()
	return rc.err
}

// attach makes conn the connection a cancel closes, and reports false,
// without attaching it, when the request was given up already.
func (rc *requestCanceler) attach(conn net.Conn) bool {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	if rc.err != nil {
		return false
	}
	rc.conn = conn
	rc.closed = false
	return true
}

// closeConn closes conn once, whether the request or a cancel asks first.
func (rc *requestCanceler) closeConn(conn net.Conn) {
	rc.mu.Lock()
	closed := rc.closed && rc.conn == conn
	if rc.conn == conn {
		rc.closed = true
	}
	rc.mu.Unlock()
	if !closed {
		conn.Close()
	}
}

// finish ends the watch: the response has been read, or the request
// failed.
func (rc *requestCanceler) finish() {
	if rc == nil {
		return
	}
	rc.mu.Lock()
	stopped := rc.stopped
	rc.stopped = true
	rc.mu.Unlock()
	if stopped {
		return
	}
	if rc.timer != nil {
		rc.timer.Stop()
	}
	close(rc.stop)
}

// requestError is the error of a request that failed with err: the reason
// it was given up, when it was, as Go words it for a client's Timeout.
func (rc *requestCanceler) requestError(err error, during string) error {
	reason := rc.reason()
	if reason == nil {
		return err
	}
	rc.mu.Lock()
	timedOut := rc.timedOut
	rc.mu.Unlock()
	if timedOut {
		return &timeoutError{reason.Error() + " (Client.Timeout " + during + ")"}
	}
	return reason
}
