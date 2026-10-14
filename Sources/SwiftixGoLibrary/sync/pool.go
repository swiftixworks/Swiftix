package sync

import "sync"

// A Pool keeps values that are not in use so that they can be used again
// instead of made anew. Any value in it may be dropped at any time, so a
// program must not count on getting back what it put.
//
// This one keeps everything it is given and hands back the value put most
// recently, which Go permits and does not promise: Go's pool is emptied by
// the garbage collector and prefers the values of the calling thread.
type Pool struct {
	mu    sync.Mutex
	items []any

	// New, when it is not nil, makes the value Get returns from an empty
	// pool.
	New func() any
}

// Put adds x to the pool. A nil x is not kept.
func (p *Pool) Put(x any) {
	if x == nil {
		return
	}
	p.mu.Lock()
	p.items = append(p.items, x)
	p.mu.Unlock()
}

// Get takes a value out of the pool and returns it. From an empty pool it
// returns what New returns, or nil when there is no New.
func (p *Pool) Get() any {
	p.mu.Lock()
	if n := len(p.items); n > 0 {
		x := p.items[n-1]
		p.items[n-1] = nil
		p.items = p.items[:n-1]
		p.mu.Unlock()
		return x
	}
	p.mu.Unlock()
	if p.New != nil {
		return p.New()
	}
	return nil
}
