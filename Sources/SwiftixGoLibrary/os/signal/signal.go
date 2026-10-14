// Copyright 2012 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Package signal implements access to incoming signals.
//
// This is Go's os/signal, written for this run-time library: the VM installs
// a handler with the kernel for each signal a program asks for and hands
// what arrives to the goroutine that loop runs, which delivers it to the
// channels as Go's does, never blocking on one.
package signal

import (
	"context"
	"os"
	"sync"
	"syscall"
)

// numSig is the number of signals a mask has room for.
const numSig = 65 // max across all systems

var (
	handlersMu sync.Mutex
	// Map a channel to the signals that should be sent to it.
	handlersM map[chan<- os.Signal]*handler
	// Map a signal to the number of channels receiving it.
	handlersRef [numSig]int64
	// Which signals are ignored.
	ignored [numSig]bool
)

type handler struct {
	mask [(numSig + 31) / 32]uint32
}

func (h *handler) want(sig int) bool {
	return (h.mask[sig/32]>>uint(sig&31))&1 != 0
}

func (h *handler) set(sig int) {
	h.mask[sig/32] |= 1 << uint(sig&31)
}

func (h *handler) clear(sig int) {
	h.mask[sig/32] &^= 1 << uint(sig&31)
}

// Stop relaying the signals, sigs, to any channels previously registered to
// receive them and either reset the signal handlers to their original values
// (action=disableSignal) or ignore the signals (action=ignoreSignal).
func cancel(sigs []os.Signal, action func(int)) {
	handlersMu.Lock()
	defer handlersMu.Unlock()

	remove := func(n int) {
		var zerohandler handler

		for c, h := range handlersM {
			if h.want(n) {
				handlersRef[n]--
				h.clear(n)
				if h.mask == zerohandler.mask {
					delete(handlersM, c)
				}
			}
		}

		action(n)
	}

	if len(sigs) == 0 {
		for n := 0; n < numSig; n++ {
			remove(n)
		}
	} else {
		for _, s := range sigs {
			n := signum(s)
			if n >= 0 {
				remove(n)
			}
		}
	}
}

// Ignore causes the provided signals to be ignored. If they are received by
// the program, nothing will happen. Ignore undoes the effect of any prior
// calls to [Notify] for the provided signals.
// If no signals are provided, all incoming signals will be ignored.
func Ignore(sig ...os.Signal) {
	cancel(sig, ignoreSignal)
}

// Ignored reports whether sig is currently ignored.
func Ignored(sig os.Signal) bool {
	sn := signum(sig)
	return sn >= 0 && signalIgnored(sn)
}

var watchSignalLoopOnce sync.Once

// Notify causes package signal to relay incoming signals to c.
// If no signals are provided, all incoming signals will be relayed to c.
// Otherwise, just the provided signals will.
//
// Package signal will not block sending to c: the caller must ensure
// that c has sufficient buffer space to keep up with the expected
// signal rate. For a channel used for notification of just one signal value,
// a buffer of size 1 is sufficient.
//
// It is allowed to call Notify multiple times with the same channel:
// each call expands the set of signals sent to that channel.
// The only way to remove signals from the set is to call [Stop].
//
// It is allowed to call Notify multiple times with different channels
// and the same signals: each channel receives copies of incoming
// signals independently.
func Notify(c chan<- os.Signal, sig ...os.Signal) {
	if c == nil {
		panic("os/signal: Notify using nil channel")
	}

	handlersMu.Lock()
	defer handlersMu.Unlock()

	h := handlersM[c]
	if h == nil {
		if handlersM == nil {
			handlersM = make(map[chan<- os.Signal]*handler)
		}
		h = new(handler)
		handlersM[c] = h
	}

	add := func(n int) {
		if n < 0 {
			return
		}
		if !h.want(n) {
			h.set(n)
			if handlersRef[n] == 0 {
				enableSignal(n)

				// The runtime requires that we enable a
				// signal before starting the watcher.
				watchSignalLoopOnce.Do(func() {
					go loop()
				})
			}
			handlersRef[n]++
		}
	}

	if len(sig) == 0 {
		for n := 0; n < numSig; n++ {
			add(n)
		}
	} else {
		for _, s := range sig {
			add(signum(s))
		}
	}
}

// Reset undoes the effect of any prior calls to [Notify] for the provided
// signals.
// If no signals are provided, all signal handlers will be reset.
func Reset(sig ...os.Signal) {
	cancel(sig, disableSignal)
}

// Stop causes package signal to stop relaying incoming signals to c.
// It undoes the effect of all prior calls to [Notify] using c.
// When Stop returns, it is guaranteed that c will receive no more signals.
func Stop(c chan<- os.Signal) {
	handlersMu.Lock()
	defer handlersMu.Unlock()

	h := handlersM[c]
	if h == nil {
		return
	}
	delete(handlersM, c)

	for n := 0; n < numSig; n++ {
		if h.want(n) {
			handlersRef[n]--
			if handlersRef[n] == 0 {
				disableSignal(n)
			}
		}
	}
}

func process(sig os.Signal) {
	n := signum(sig)
	if n < 0 {
		return
	}

	handlersMu.Lock()
	defer handlersMu.Unlock()

	for c, h := range handlersM {
		if h.want(n) {
			// send but do not block for it
			select {
			case c <- sig:
			default:
			}
		}
	}
}

// NotifyContext returns a copy of the parent context that is marked done
// (its Done channel is closed) when one of the listed signals arrives,
// when the returned stop function is called, or when the parent context's
// Done channel is closed, whichever happens first.
//
// The stop function unregisters the signal behavior, which, like
// [signal.Reset], may restore the default behavior for a given signal.
func NotifyContext(parent context.Context, signals ...os.Signal) (ctx context.Context, stop context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	c := &signalCtx{
		Context: ctx,
		cancel:  cancel,
		signals: signals,
	}
	c.ch = make(chan os.Signal, 1)
	Notify(c.ch, c.signals...)
	if ctx.Err() == nil {
		go func() {
			select {
			case <-c.ch:
				c.cancel()
			case <-c.Done():
			}
		}()
	}
	return c, c.stop
}

type signalCtx struct {
	context.Context

	cancel  context.CancelFunc
	signals []os.Signal
	ch      chan os.Signal
}

func (c *signalCtx) stop() {
	c.cancel()
	Stop(c.ch)
}

type stringer interface {
	String() string
}

func (c *signalCtx) String() string {
	var buf []byte
	// We know that the type of c.Context is context.cancelCtx, and we know that the
	// String method of cancelCtx returns a string that ends with ".WithCancel".
	name := c.Context.(stringer).String()
	name = name[:len(name)-len(".WithCancel")]
	buf = append(buf, "signal.NotifyContext("+name...)
	if len(c.signals) != 0 {
		buf = append(buf, ", ["...)
		for i, s := range c.signals {
			buf = append(buf, s.String()...)
			if i != len(c.signals)-1 {
				buf = append(buf, ' ')
			}
		}
		buf = append(buf, ']')
	}
	buf = append(buf, ')')
	return string(buf)
}

// loop hands each signal the VM receives to process.
func loop() {
	for {
		process(syscall.Signal(native.wait()))
	}
}

func signum(sig os.Signal) int {
	switch sig := sig.(type) {
	case syscall.Signal:
		i := int(sig)
		if i < 0 || i >= numSig {
			return -1
		}
		return i
	default:
		return -1
	}
}

func enableSignal(sig int) {
	ignored[sig] = false
	native.enable(sig)
}

func disableSignal(sig int) {
	ignored[sig] = false
	native.reset(sig)
}

func ignoreSignal(sig int) {
	ignored[sig] = true
	native.ignore(sig)
}

func signalIgnored(sig int) bool {
	return ignored[sig]
}
