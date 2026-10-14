// Package sync is the part of sync that is written in Go. Mutex and
// WaitGroup belong to the run-time library, which this file imports under
// the same path.
package sync

import "sync"

// Once calls a function once. The first call of Do holds the lock while its
// function runs, so a call from another goroutine waits for it to end, and
// the function counts as called once it has returned or panicked.
type Once struct {
	done bool
	m    sync.Mutex
}

func (o *Once) Do(f func()) {
	if !o.done {
		o.doSlow(f)
	}
}

func (o *Once) doSlow(f func()) {
	o.m.Lock()
	defer o.m.Unlock()
	if !o.done {
		defer o.finish()
		f()
	}
}

func (o *Once) finish() {
	o.done = true
}

// OnceFunc returns a function that invokes f only once. The returned function
// may be called concurrently.
//
// If f panics, the returned function will panic with the same value on every call.
func OnceFunc(f func()) func() {
	var (
		once  Once
		valid bool
		p     any
	)
	// Construct the inner closure just once to reduce costs on the fast path.
	g := func() {
		defer func() {
			p = recover()
			if !valid {
				// Re-panic immediately so on the first call the user gets a
				// complete stack trace into f.
				panic(p)
			}
		}()
		f()
		f = nil      // Do not keep f alive after invoking it.
		valid = true // Set only if f does not panic.
	}
	return func() {
		once.Do(g)
		if !valid {
			panic(p)
		}
	}
}
