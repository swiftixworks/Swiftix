package sync

import "sync"

// Map is a map from any key to any value that goroutines may use together
// without a lock of their own. The zero Map is empty and ready.
//
// It is a Go map behind a Mutex. Another goroutine may get its turn after
// any instruction, so each method holds the lock for the whole of what it
// does to the map, and gives it back before it compares values a program
// supplied or calls a function of the program.
type Map struct {
	mu sync.Mutex
	m  map[any]any
}

// Load returns the value stored for key, and whether there is one.
func (m *Map) Load(key any) (value any, ok bool) {
	m.mu.Lock()
	value, ok = m.m[key]
	m.mu.Unlock()
	return value, ok
}

// Store sets the value for key.
func (m *Map) Store(key, value any) {
	m.mu.Lock()
	if m.m == nil {
		m.m = map[any]any{}
	}
	m.m[key] = value
	m.mu.Unlock()
}

// Clear deletes every entry.
func (m *Map) Clear() {
	m.mu.Lock()
	m.m = nil
	m.mu.Unlock()
}

// LoadOrStore returns the value stored for key if there is one, and stores
// and returns value otherwise. loaded says which.
func (m *Map) LoadOrStore(key, value any) (actual any, loaded bool) {
	m.mu.Lock()
	actual, loaded = m.m[key]
	if !loaded {
		if m.m == nil {
			m.m = map[any]any{}
		}
		m.m[key] = value
		actual = value
	}
	m.mu.Unlock()
	return actual, loaded
}

// LoadAndDelete deletes the value for key and returns what it was, if
// there was one.
func (m *Map) LoadAndDelete(key any) (value any, loaded bool) {
	m.mu.Lock()
	value, loaded = m.m[key]
	if loaded {
		delete(m.m, key)
	}
	m.mu.Unlock()
	return value, loaded
}

// Delete deletes the value for key.
func (m *Map) Delete(key any) {
	m.LoadAndDelete(key)
}

// Swap stores value for key and returns what it replaced, if anything.
func (m *Map) Swap(key, value any) (previous any, loaded bool) {
	m.mu.Lock()
	previous, loaded = m.m[key]
	if m.m == nil {
		m.m = map[any]any{}
	}
	m.m[key] = value
	m.mu.Unlock()
	return previous, loaded
}

// CompareAndSwap stores new for key if the value stored for it is old, and
// says whether it did. old must be comparable.
func (m *Map) CompareAndSwap(key, old, new any) (swapped bool) {
	for {
		held, ok := m.Load(key)
		// Compared without the lock: values that cannot be compared panic.
		if !ok || held != old {
			return false
		}
		m.mu.Lock()
		now, ok := m.m[key]
		if ok && now == held {
			m.m[key] = new
			m.mu.Unlock()
			return true
		}
		m.mu.Unlock()
		// Another goroutine wrote in between: look again.
	}
}

// CompareAndDelete deletes the entry for key if its value is old, and says
// whether it did. old must be comparable.
func (m *Map) CompareAndDelete(key, old any) (deleted bool) {
	for {
		held, ok := m.Load(key)
		if !ok || held != old {
			return false
		}
		m.mu.Lock()
		now, ok := m.m[key]
		if ok && now == held {
			delete(m.m, key)
			m.mu.Unlock()
			return true
		}
		m.mu.Unlock()
	}
}

// Range calls f for each key and value of the map, one after another, and
// stops when f returns false.
//
// f may call any method of the map, and so may other goroutines meanwhile.
// The keys are those the map had when Range was called, in the order they
// were first stored. No key is visited twice; one that was deleted before
// its turn is passed over; the value f is given is the one stored when the
// key's turn comes; and a key stored after Range began is not visited. Go
// promises no more than that of a Range whose map changes.
func (m *Map) Range(f func(key, value any) bool) {
	m.mu.Lock()
	keys := make([]any, 0, len(m.m))
	for key := range m.m {
		keys = append(keys, key)
	}
	m.mu.Unlock()
	for _, key := range keys {
		value, ok := m.Load(key)
		if !ok {
			continue
		}
		if !f(key, value) {
			break
		}
	}
}
