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
