package http

import (
	"context"
	"net"
	"time"
)

// A ConnState is a state of a connection a server serves, which the
// server's ConnState hook is told of.
type ConnState int

const (
	// StateNew is a connection that has been accepted and has sent nothing
	// yet.
	StateNew ConnState = iota

	// StateActive is a connection that has sent a request and is being
	// answered.
	StateActive

	// StateIdle is a connection between requests.
	StateIdle

	// StateHijacked is a connection the server gave to a handler.
	StateHijacked

	// StateClosed is a connection that is closed.
	StateClosed
)

func (c ConnState) String() string {
	switch c {
	case StateNew:
		return "new"
	case StateActive:
		return "active"
	case StateIdle:
		return "idle"
	case StateHijacked:
		return "hijacked"
	case StateClosed:
		return "closed"
	}
	return ""
}

// A trackedListener is a listener a server accepts on, which Close and
// Shutdown close once.
type trackedListener struct {
	l      net.Listener
	closed bool
}

// shuttingDown reports whether Shutdown or Close has been called.
func (srv *Server) shuttingDown() bool {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	return srv.inShutdown
}

// trackListener adds a listener to those Close and Shutdown close, and
// returns nil when the server is shutting down already.
func (srv *Server) trackListener(l net.Listener) *trackedListener {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if srv.inShutdown {
		return nil
	}
	t := &trackedListener{l: l}
	srv.listeners = append(srv.listeners, t)
	return t
}

// untrackListener closes a listener Serve is done with, unless Close or
// Shutdown did, and forgets it.
func (srv *Server) untrackListener(t *trackedListener) {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if !t.closed {
		t.closed = true
		t.l.Close()
	}
	for i, x := range srv.listeners {
		if x == t {
			srv.listeners = append(srv.listeners[:i], srv.listeners[i+1:]...)
			break
		}
	}
}

// closeListenersLocked closes the listeners, which ends their Serve with
// ErrServerClosed.
func (srv *Server) closeListenersLocked() error {
	var err error
	for _, t := range srv.listeners {
		if !t.closed {
			t.closed = true
			if cerr := t.l.Close(); cerr != nil && err == nil {
				err = cerr
			}
		}
	}
	return err
}

// setState records the state of a connection, and tells the ConnState
// hook. A new connection is tracked, a closed one is not.
func (c *conn) setState(state ConnState) {
	srv := c.server
	srv.mu.Lock()
	switch state {
	case StateNew:
		srv.conns = append(srv.conns, c)
	case StateHijacked, StateClosed:
		for i, x := range srv.conns {
			if x == c {
				srv.conns = append(srv.conns[:i], srv.conns[i+1:]...)
				break
			}
		}
	}
	c.state = state
	c.stateUnix = time.Now().Unix()
	srv.mu.Unlock()
	if hook := srv.ConnState; hook != nil {
		hook(c.rwc, state)
	}
}

// closeConn closes the connection once, whoever asks first: its own
// goroutine, Close, Shutdown, or a deadline.
func (c *conn) closeConn() {
	c.server.mu.Lock()
	closed := c.closed
	c.closed = true
	c.server.mu.Unlock()
	if !closed {
		c.rwc.Close()
	}
}

// RegisterOnShutdown arranges for f to be called, in a goroutine of its
// own, when Shutdown is.
func (srv *Server) RegisterOnShutdown(f func()) {
	srv.mu.Lock()
	srv.onShutdown = append(srv.onShutdown, f)
	srv.mu.Unlock()
}

// Close closes the listeners and every connection at once, whether or not
// a request is being answered on it. Serve and ListenAndServe then return
// ErrServerClosed. It returns what closing the listeners returned.
func (srv *Server) Close() error {
	srv.mu.Lock()
	srv.inShutdown = true
	err := srv.closeListenersLocked()
	conns := srv.conns
	srv.conns = nil
	srv.mu.Unlock()
	for _, c := range conns {
		c.closeConn()
	}
	return err
}

// The longest Shutdown waits between two looks at the connections.
const shutdownPollIntervalMax = 500 * time.Millisecond

// Shutdown stops the server without interrupting a request: it closes the
// listeners, then the idle connections, and waits for each active one to
// become idle to close it, looking again after 1ms, 2ms, 4ms, and so on up
// to 500ms. When ctx is done first, it returns ctx's error and leaves the
// rest open. Serve and ListenAndServe return ErrServerClosed at once.
func (srv *Server) Shutdown(ctx context.Context) error {
	srv.mu.Lock()
	srv.inShutdown = true
	lnerr := srv.closeListenersLocked()
	for _, f := range srv.onShutdown {
		go f()
	}
	srv.mu.Unlock()

	pollInterval := time.Millisecond
	timer := time.NewTimer(pollInterval)
	defer timer.Stop()
	for {
		if srv.closeIdleConns() {
			return lnerr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			pollInterval *= 2
			if pollInterval > shutdownPollIntervalMax {
				pollInterval = shutdownPollIntervalMax
			}
			timer.Reset(pollInterval)
		}
	}
}

// closeIdleConns closes the connections that wait for a request, and a new
// one that has said nothing for five seconds, and reports whether every
// connection is closed.
func (srv *Server) closeIdleConns() bool {
	srv.mu.Lock()
	quiescent := true
	var idle []*conn
	var rest []*conn
	for _, c := range srv.conns {
		st := c.state
		if st == StateNew && c.stateUnix < time.Now().Unix()-5 {
			st = StateIdle
		}
		if st != StateIdle {
			quiescent = false
			rest = append(rest, c)
			continue
		}
		idle = append(idle, c)
	}
	srv.conns = rest
	srv.mu.Unlock()
	for _, c := range idle {
		c.closeConn()
	}
	return quiescent
}
