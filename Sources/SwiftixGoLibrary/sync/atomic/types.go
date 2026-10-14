package atomic

// An Int32 is an int32 that is read and written atomically. The zero value
// is zero.
type Int32 struct {
	v int32
}

// Load returns the value.
func (x *Int32) Load() int32 { return x.v }

// Store stores val.
func (x *Int32) Store(val int32) { StoreInt32(&x.v, val) }

// Swap stores val and returns the value it replaced.
func (x *Int32) Swap(val int32) int32 { return SwapInt32(&x.v, val) }

// CompareAndSwap stores val if the value is old, and says whether it did.
func (x *Int32) CompareAndSwap(old, val int32) bool {
	return CompareAndSwapInt32(&x.v, old, val)
}

// Add adds delta and returns the new value.
func (x *Int32) Add(delta int32) int32 { return AddInt32(&x.v, delta) }

// An Int64 is an int64 that is read and written atomically. The zero value
// is zero.
type Int64 struct {
	v int64
}

// Load returns the value.
func (x *Int64) Load() int64 { return x.v }

// Store stores val.
func (x *Int64) Store(val int64) { StoreInt64(&x.v, val) }

// Swap stores val and returns the value it replaced.
func (x *Int64) Swap(val int64) int64 { return SwapInt64(&x.v, val) }

// CompareAndSwap stores val if the value is old, and says whether it did.
func (x *Int64) CompareAndSwap(old, val int64) bool {
	return CompareAndSwapInt64(&x.v, old, val)
}

// Add adds delta and returns the new value.
func (x *Int64) Add(delta int64) int64 { return AddInt64(&x.v, delta) }

// A Uint32 is a uint32 that is read and written atomically. The zero value
// is zero.
type Uint32 struct {
	v uint32
}

// Load returns the value.
func (x *Uint32) Load() uint32 { return x.v }

// Store stores val.
func (x *Uint32) Store(val uint32) { StoreUint32(&x.v, val) }

// Swap stores val and returns the value it replaced.
func (x *Uint32) Swap(val uint32) uint32 { return SwapUint32(&x.v, val) }

// CompareAndSwap stores val if the value is old, and says whether it did.
func (x *Uint32) CompareAndSwap(old, val uint32) bool {
	return CompareAndSwapUint32(&x.v, old, val)
}

// Add adds delta and returns the new value.
func (x *Uint32) Add(delta uint32) uint32 { return AddUint32(&x.v, delta) }

// A Uint64 is a uint64 that is read and written atomically. The zero value
// is zero.
type Uint64 struct {
	v uint64
}

// Load returns the value.
func (x *Uint64) Load() uint64 { return x.v }

// Store stores val.
func (x *Uint64) Store(val uint64) { StoreUint64(&x.v, val) }

// Swap stores val and returns the value it replaced.
func (x *Uint64) Swap(val uint64) uint64 { return SwapUint64(&x.v, val) }

// CompareAndSwap stores val if the value is old, and says whether it did.
func (x *Uint64) CompareAndSwap(old, val uint64) bool {
	return CompareAndSwapUint64(&x.v, old, val)
}

// Add adds delta and returns the new value.
func (x *Uint64) Add(delta uint64) uint64 { return AddUint64(&x.v, delta) }

// A Bool is a boolean that is read and written atomically. The zero value
// is false.
type Bool struct {
	v bool
}

// Load returns the value.
func (x *Bool) Load() bool { return x.v }

// Store stores val.
func (x *Bool) Store(val bool) {
	lock.Lock()
	x.v = val
	lock.Unlock()
}

// Swap stores val and returns the value it replaced.
func (x *Bool) Swap(val bool) bool {
	lock.Lock()
	old := x.v
	x.v = val
	lock.Unlock()
	return old
}

// CompareAndSwap stores val if the value is old, and says whether it did.
func (x *Bool) CompareAndSwap(old, val bool) bool {
	lock.Lock()
	swapped := x.v == old
	if swapped {
		x.v = val
	}
	lock.Unlock()
	return swapped
}
