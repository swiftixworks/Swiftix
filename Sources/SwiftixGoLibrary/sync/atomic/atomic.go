// Package atomic is sync/atomic written in Go.
//
// The scheduler of the run-time may give another goroutine its turn after
// any instruction, so a statement of Go is not atomic by itself: `x++` in
// two goroutines loses counts. One store through a pointer is a single
// instruction, and so is one read. Whatever reads a variable and then
// writes it (Add, Swap, CompareAndSwap) therefore holds a lock that every
// writer of this package takes, Store among them, since a store that fell
// between the read and the write of an Add would be lost. Load takes none:
// it sees the variable as some writer left it.
//
// The lock is one for the whole package, which costs nothing on the single
// thread goroutines share, and lets the functions work on any variable or
// struct field a program has the address of.
package atomic

import "sync"

// lock is held by every operation of the package that writes.
var lock sync.Mutex

// AddInt32 adds delta to *addr and returns the new value.
func AddInt32(addr *int32, delta int32) int32 {
	lock.Lock()
	sum := *addr + delta
	*addr = sum
	lock.Unlock()
	return sum
}

// LoadInt32 returns *addr.
func LoadInt32(addr *int32) int32 {
	return *addr
}

// StoreInt32 stores val in *addr.
func StoreInt32(addr *int32, val int32) {
	lock.Lock()
	*addr = val
	lock.Unlock()
}

// SwapInt32 stores val in *addr and returns what was there.
func SwapInt32(addr *int32, val int32) int32 {
	lock.Lock()
	old := *addr
	*addr = val
	lock.Unlock()
	return old
}

// CompareAndSwapInt32 stores val in *addr if it holds old, and says whether
// it did.
func CompareAndSwapInt32(addr *int32, old, val int32) bool {
	lock.Lock()
	swapped := *addr == old
	if swapped {
		*addr = val
	}
	lock.Unlock()
	return swapped
}

// AddInt64 adds delta to *addr and returns the new value.
func AddInt64(addr *int64, delta int64) int64 {
	lock.Lock()
	sum := *addr + delta
	*addr = sum
	lock.Unlock()
	return sum
}

// LoadInt64 returns *addr.
func LoadInt64(addr *int64) int64 {
	return *addr
}

// StoreInt64 stores val in *addr.
func StoreInt64(addr *int64, val int64) {
	lock.Lock()
	*addr = val
	lock.Unlock()
}

// SwapInt64 stores val in *addr and returns what was there.
func SwapInt64(addr *int64, val int64) int64 {
	lock.Lock()
	old := *addr
	*addr = val
	lock.Unlock()
	return old
}

// CompareAndSwapInt64 stores val in *addr if it holds old, and says whether
// it did.
func CompareAndSwapInt64(addr *int64, old, val int64) bool {
	lock.Lock()
	swapped := *addr == old
	if swapped {
		*addr = val
	}
	lock.Unlock()
	return swapped
}

// AddUint32 adds delta to *addr and returns the new value.
func AddUint32(addr *uint32, delta uint32) uint32 {
	lock.Lock()
	sum := *addr + delta
	*addr = sum
	lock.Unlock()
	return sum
}

// LoadUint32 returns *addr.
func LoadUint32(addr *uint32) uint32 {
	return *addr
}

// StoreUint32 stores val in *addr.
func StoreUint32(addr *uint32, val uint32) {
	lock.Lock()
	*addr = val
	lock.Unlock()
}

// SwapUint32 stores val in *addr and returns what was there.
func SwapUint32(addr *uint32, val uint32) uint32 {
	lock.Lock()
	old := *addr
	*addr = val
	lock.Unlock()
	return old
}

// CompareAndSwapUint32 stores val in *addr if it holds old, and says whether
// it did.
func CompareAndSwapUint32(addr *uint32, old, val uint32) bool {
	lock.Lock()
	swapped := *addr == old
	if swapped {
		*addr = val
	}
	lock.Unlock()
	return swapped
}

// AddUint64 adds delta to *addr and returns the new value.
func AddUint64(addr *uint64, delta uint64) uint64 {
	lock.Lock()
	sum := *addr + delta
	*addr = sum
	lock.Unlock()
	return sum
}

// LoadUint64 returns *addr.
func LoadUint64(addr *uint64) uint64 {
	return *addr
}

// StoreUint64 stores val in *addr.
func StoreUint64(addr *uint64, val uint64) {
	lock.Lock()
	*addr = val
	lock.Unlock()
}

// SwapUint64 stores val in *addr and returns what was there.
func SwapUint64(addr *uint64, val uint64) uint64 {
	lock.Lock()
	old := *addr
	*addr = val
	lock.Unlock()
	return old
}

// CompareAndSwapUint64 stores val in *addr if it holds old, and says whether
// it did.
func CompareAndSwapUint64(addr *uint64, old, val uint64) bool {
	lock.Lock()
	swapped := *addr == old
	if swapped {
		*addr = val
	}
	lock.Unlock()
	return swapped
}
