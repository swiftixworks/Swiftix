package atomic

import "fmt"

// A Value holds a value of any one type, read and written atomically. The
// zero Value holds nothing, and Load returns nil until the first Store.
// Every value stored must have the type of the first, and none may be nil.
type Value struct {
	v any
}

// sameType says whether a and b, neither nil, have one dynamic type. The
// dialect has no reflection, so the types are compared by the names fmt
// prints for them.
func sameType(a, b any) bool {
	return fmt.Sprintf("%T", a) == fmt.Sprintf("%T", b)
}

// Load returns the value most recently stored, or nil if there is none.
func (v *Value) Load() any { return v.v }

// Store sets the value to val.
func (v *Value) Store(val any) {
	if val == nil {
		panic("sync/atomic: store of nil value into Value")
	}
	lock.Lock()
	if v.v != nil && !sameType(v.v, val) {
		lock.Unlock()
		panic("sync/atomic: store of inconsistently typed value into Value")
	}
	v.v = val
	lock.Unlock()
}

// Swap stores val and returns the value it replaced, nil if there was
// none.
func (v *Value) Swap(val any) any {
	if val == nil {
		panic("sync/atomic: swap of nil value into Value")
	}
	lock.Lock()
	old := v.v
	if old != nil && !sameType(old, val) {
		lock.Unlock()
		panic("sync/atomic: swap of inconsistently typed value into Value")
	}
	v.v = val
	lock.Unlock()
	return old
}

// CompareAndSwap stores val if the value is old, and says whether it did.
// An old of nil stands for a Value nothing was stored in.
func (v *Value) CompareAndSwap(old, val any) bool {
	if val == nil {
		panic("sync/atomic: compare and swap of nil value into Value")
	}
	if old != nil && !sameType(old, val) {
		panic("sync/atomic: compare and swap of inconsistently typed values")
	}
	lock.Lock()
	held := v.v
	if held == nil {
		if old == nil {
			v.v = val
		}
		lock.Unlock()
		return old == nil
	}
	if !sameType(held, val) {
		lock.Unlock()
		panic("sync/atomic: compare and swap of inconsistently typed value into Value")
	}
	// The lock is given back before the comparison, which panics for
	// values that cannot be compared, and taken again for the store.
	lock.Unlock()
	if held != old {
		return false
	}
	lock.Lock()
	swapped := v.v == held
	if swapped {
		v.v = val
	}
	lock.Unlock()
	return swapped
}
