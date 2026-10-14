// Package context carries deadlines, cancellation, and request-scoped
// values across the functions and goroutines that serve one request. It is
// Go's package of that name written for this run-time library: the same
// types, values, and behavior, over channels, a mutex, and timers.
package context

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// A Context carries a deadline, a cancellation signal, and values. Its
// methods may be called by several goroutines at once.
type Context interface {
	// Deadline returns the time at which work done for this context should
	// be cancelled, and ok false when no deadline is set.
	Deadline() (deadline time.Time, ok bool)
	// Done returns a channel that is closed when work done for this context
	// should be cancelled, and nil when it can never be.
	Done() <-chan struct{}
	// Err returns nil while Done is open, and afterwards why it was closed:
	// Canceled, or DeadlineExceeded.
	Err() error
	// Value returns the value this context has for key, or nil.
	Value(key any) any
}

// Canceled is the error Err returns when the context was cancelled for a
// reason other than its deadline passing.
var Canceled = errors.New("context canceled")

// DeadlineExceeded is the error Err returns when the context was cancelled
// because its deadline passed.
var DeadlineExceeded error = deadlineExceededError{}

type deadlineExceededError struct{}

func (deadlineExceededError) Error() string   { return "context deadline exceeded" }
func (deadlineExceededError) Timeout() bool   { return true }
func (deadlineExceededError) Temporary() bool { return true }

// An emptyCtx is never cancelled, has no values, and has no deadline.
type emptyCtx struct{}

func (emptyCtx) Deadline() (deadline time.Time, ok bool) { return }
func (emptyCtx) Done() <-chan struct{}                   { return nil }
func (emptyCtx) Err() error                              { return nil }
func (emptyCtx) Value(key any) any                       { return nil }

type backgroundCtx struct{ emptyCtx }

func (backgroundCtx) String() string { return "context.Background" }

type todoCtx struct{ emptyCtx }

func (todoCtx) String() string { return "context.TODO" }

// Background returns a context that is never cancelled, has no values, and
// has no deadline: the root of the contexts of a program.
func Background() Context { return backgroundCtx{} }

// TODO returns a context like Background, for code that does not know yet
// which context to use.
func TODO() Context { return todoCtx{} }

// A CancelFunc tells an operation to abandon its work. It does not wait for
// the work to stop, may be called by several goroutines at once, and does
// nothing after the first call.
type CancelFunc func()

// WithCancel returns a context derived from parent whose Done channel is
// closed when cancel is called or when parent's is closed, whichever
// happens first.
func WithCancel(parent Context) (ctx Context, cancel CancelFunc) {
	c := withCancel(parent)
	return c, func() { c.cancel(true, Canceled, nil) }
}

// A CancelCauseFunc is a CancelFunc that also records why: the cause, which
// Cause returns for the cancelled context and those derived from it.
type CancelCauseFunc func(cause error)

// WithCancelCause is WithCancel with a cause. Calling cancel with nil
// records Canceled.
func WithCancelCause(parent Context) (ctx Context, cancel CancelCauseFunc) {
	c := withCancel(parent)
	return c, func(cause error) { c.cancel(true, Canceled, cause) }
}

func withCancel(parent Context) *cancelCtx {
	if parent == nil {
		panic("cannot create context from nil parent")
	}
	c := &cancelCtx{done: make(chan struct{})}
	c.propagateCancel(parent, c)
	return c
}

// Cause returns why c was cancelled: the cause its cancel function was
// given, or else what c.Err returns. It is nil until c is cancelled.
func Cause(c Context) error {
	if cc, ok := c.Value(cancelCtxKey).(*cancelCtx); ok {
		cc.mu.Lock()
		cause := cc.cause
		cc.mu.Unlock()
		return cause
	}
	// No cancelCtx is under c: it is a context of the program's own, or one
	// that is never cancelled.
	return c.Err()
}

// AfterFunc arranges for f to run in a goroutine of its own once ctx is
// cancelled, at once if it already is. Calling stop ends that arrangement
// and reports whether it kept f from running.
func AfterFunc(ctx Context, f func()) (stop func() bool) {
	a := &afterFuncCtx{f: f}
	a.done = make(chan struct{})
	a.propagateCancel(ctx, a)
	return func() bool {
		a.mu.Lock()
		stopped := !a.started
		a.started = true
		a.mu.Unlock()
		if stopped {
			a.cancel(true, Canceled, nil)
		}
		return stopped
	}
}

type afterFuncCtx struct {
	cancelCtx
	started bool // under cancelCtx.mu: f ran, or stop was called
	f       func()
}

func (a *afterFuncCtx) cancel(removeFromParent bool, err, cause error) {
	a.cancelCtx.cancel(false, err, cause)
	if removeFromParent {
		removeChild(a.Context, a)
	}
	a.mu.Lock()
	run := !a.started
	a.started = true
	a.mu.Unlock()
	if run {
		go a.f()
	}
}

// WithoutCancel returns a context with parent's values that is not
// cancelled when parent is: it has no deadline, no error, and a nil Done.
func WithoutCancel(parent Context) Context {
	if parent == nil {
		panic("cannot create context from nil parent")
	}
	return withoutCancelCtx{parent}
}

type withoutCancelCtx struct {
	c Context
}

func (withoutCancelCtx) Deadline() (deadline time.Time, ok bool) { return }
func (withoutCancelCtx) Done() <-chan struct{}                   { return nil }
func (withoutCancelCtx) Err() error                              { return nil }
func (c withoutCancelCtx) Value(key any) any                     { return value(c, key) }
func (c withoutCancelCtx) String() string                        { return contextName(c.c) + ".WithoutCancel" }

// cancelCtxKey is the key a cancelCtx returns itself for. Go's is the
// address of a variable; the dialect compares an interface value with
// another, so the key is one, of a type nothing else has.
var cancelCtxKey any = cancelCtxKeyType{}

type cancelCtxKeyType struct{}

// parentCancelCtx returns the cancelCtx parent is or derives from, when the
// Done channel of parent is that one's: a context of the program's own
// wrapped around one has another channel, and is watched instead.
func parentCancelCtx(parent Context) (*cancelCtx, bool) {
	done := parent.Done()
	if done == nil {
		return nil, false
	}
	p, ok := parent.Value(cancelCtxKey).(*cancelCtx)
	if !ok {
		return nil, false
	}
	// The dialect compares two channels of one type only, so p's channel is
	// read as the receive-only one Done returns.
	var pdone <-chan struct{} = p.done
	if pdone != done {
		return nil, false
	}
	return p, true
}

// removeChild takes child out of the children of its parent.
func removeChild(parent Context, child canceler) {
	p, ok := parentCancelCtx(parent)
	if !ok {
		return
	}
	p.mu.Lock()
	for i, c := range p.children {
		if c == child {
			p.children = append(p.children[:i], p.children[i+1:]...)
			break
		}
	}
	p.mu.Unlock()
}

// A canceler is a context that can be cancelled directly.
type canceler interface {
	cancel(removeFromParent bool, err, cause error)
	Done() <-chan struct{}
}

// A cancelCtx can be cancelled, and cancels the children it has when it is.
type cancelCtx struct {
	Context

	mu       sync.Mutex
	done     chan struct{} // closed by the first cancel call
	children []canceler    // emptied by the first cancel call
	err      error         // set by the first cancel call
	cause    error         // set by the first cancel call
}

func (c *cancelCtx) Value(key any) any {
	if key == cancelCtxKey {
		return c
	}
	return value(c.Context, key)
}

func (c *cancelCtx) Done() <-chan struct{} { return c.done }

func (c *cancelCtx) Err() error {
	c.mu.Lock()
	err := c.err
	c.mu.Unlock()
	return err
}

// propagateCancel arranges for child to be cancelled when parent is, and
// makes parent the context child derives from.
func (c *cancelCtx) propagateCancel(parent Context, child canceler) {
	c.Context = parent

	done := parent.Done()
	if done == nil {
		return // parent is never cancelled
	}

	select {
	case <-done:
		// parent is already cancelled
		child.cancel(false, parent.Err(), Cause(parent))
		return
	default:
	}

	if p, ok := parentCancelCtx(parent); ok {
		// parent is a cancelCtx, or derives from one.
		p.mu.Lock()
		err := p.err
		if err == nil {
			p.children = append(p.children, child)
		}
		p.mu.Unlock()
		if err != nil {
			// parent was cancelled meanwhile
			child.cancel(false, err, p.cause)
		}
		return
	}

	// A context of the program's own: watch its channel.
	go func() {
		select {
		case <-parent.Done():
			child.cancel(false, parent.Err(), Cause(parent))
		case <-child.Done():
		}
	}()
}

type stringer interface {
	String() string
}

func contextName(c Context) string {
	if s, ok := c.(stringer); ok {
		return s.String()
	}
	return fmt.Sprintf("%T", c)
}

func (c *cancelCtx) String() string {
	return contextName(c.Context) + ".WithCancel"
}

// cancel closes c.done, cancels each of c's children, and, when
// removeFromParent is true, takes c out of its parent's children. The
// first call sets the cause.
func (c *cancelCtx) cancel(removeFromParent bool, err, cause error) {
	if err == nil {
		panic("context: internal error: missing cancel error")
	}
	if cause == nil {
		cause = err
	}
	c.mu.Lock()
	if c.err != nil {
		c.mu.Unlock()
		return // already cancelled
	}
	c.err = err
	c.cause = cause
	close(c.done)
	children := c.children
	c.children = nil
	c.mu.Unlock()
	for _, child := range children {
		child.cancel(false, err, cause)
	}

	if removeFromParent {
		removeChild(c.Context, c)
	}
}

// WithDeadline returns a context derived from parent that is also cancelled
// when the time d comes, unless parent's deadline is earlier already.
func WithDeadline(parent Context, d time.Time) (Context, CancelFunc) {
	return WithDeadlineCause(parent, d, nil)
}

// WithDeadlineCause is WithDeadline with the cause the context has when the
// deadline is what cancels it.
func WithDeadlineCause(parent Context, d time.Time, cause error) (Context, CancelFunc) {
	if parent == nil {
		panic("cannot create context from nil parent")
	}
	if cur, ok := parent.Deadline(); ok && cur.Before(d) {
		// The deadline parent has is sooner than the new one.
		return WithCancel(parent)
	}
	c := &timerCtx{deadline: d}
	c.done = make(chan struct{})
	c.propagateCancel(parent, c)
	dur := time.Until(d)
	if dur <= 0 {
		c.cancel(true, DeadlineExceeded, cause) // the deadline has passed
		return c, func() { c.cancel(false, Canceled, nil) }
	}
	if c.Err() == nil {
		// The timer: it ends with the context, whichever comes first.
		go func() {
			select {
			case <-time.After(dur):
				c.cancel(true, DeadlineExceeded, cause)
			case <-c.done:
			}
		}()
	}
	return c, func() { c.cancel(true, Canceled, nil) }
}

// A timerCtx is a cancelCtx with a deadline, which a timer enforces.
type timerCtx struct {
	cancelCtx

	deadline time.Time
}

func (c *timerCtx) Deadline() (deadline time.Time, ok bool) {
	return c.deadline, true
}

func (c *timerCtx) String() string {
	return contextName(c.cancelCtx.Context) + ".WithDeadline(" +
		fmt.Sprint(c.deadline) + " [" +
		time.Until(c.deadline).String() + "])"
}

func (c *timerCtx) cancel(removeFromParent bool, err, cause error) {
	c.cancelCtx.cancel(false, err, cause)
	if removeFromParent {
		// Take this timerCtx out of the children of its parent.
		removeChild(c.cancelCtx.Context, c)
	}
}

// WithTimeout returns WithDeadline(parent, time.Now().Add(timeout)).
func WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc) {
	return WithDeadline(parent, time.Now().Add(timeout))
}

// WithTimeoutCause is WithTimeout with the cause the context has when the
// timeout is what cancels it.
func WithTimeoutCause(parent Context, timeout time.Duration, cause error) (Context, CancelFunc) {
	return WithDeadlineCause(parent, time.Now().Add(timeout), cause)
}

// WithValue returns a context derived from parent in which key has the
// value val. A key should be of a type of the package that uses it, so that
// packages do not collide.
func WithValue(parent Context, key, val any) Context {
	if parent == nil {
		panic("cannot create context from nil parent")
	}
	if key == nil {
		panic("nil key")
	}
	return &valueCtx{parent, key, val}
}

// A valueCtx carries one key and its value, and asks the context it is
// derived from for every other key.
type valueCtx struct {
	Context
	key, val any
}

// stringify says what a key or a value is without using its fmt verbs: its
// String, itself when it is a string, and its type otherwise.
func stringify(v any) string {
	switch s := v.(type) {
	case stringer:
		return s.String()
	case string:
		return s
	case nil:
		return "<nil>"
	}
	return fmt.Sprintf("%T", v)
}

func (c *valueCtx) String() string {
	return contextName(c.Context) + ".WithValue(" +
		stringify(c.key) + ", " +
		stringify(c.val) + ")"
}

func (c *valueCtx) Value(key any) any {
	if c.key == key {
		return c.val
	}
	return value(c.Context, key)
}

func value(c Context, key any) any {
	for {
		switch ctx := c.(type) {
		case *valueCtx:
			if key == ctx.key {
				return ctx.val
			}
			c = ctx.Context
		case *cancelCtx:
			if key == cancelCtxKey {
				return c
			}
			c = ctx.Context
		case withoutCancelCtx:
			if key == cancelCtxKey {
				// A cancelCtx under this one does not cancel it.
				return nil
			}
			c = ctx.c
		case *timerCtx:
			if key == cancelCtxKey {
				return &ctx.cancelCtx
			}
			c = ctx.Context
		case *afterFuncCtx:
			if key == cancelCtxKey {
				return &ctx.cancelCtx
			}
			c = ctx.Context
		case backgroundCtx, todoCtx:
			return nil
		default:
			return c.Value(key)
		}
	}
}
