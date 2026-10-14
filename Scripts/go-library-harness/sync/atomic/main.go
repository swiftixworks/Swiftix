// Holds the text of sync/atomic to Go's own: the same random operations on
// a variable of each kind in both, with every result compared; the panics
// of a Value; and goroutines that count together.
package main

import (
	"fmt"
	"math/rand"
	"os"
	"sync"
	goatomic "sync/atomic"

	"example/harness/sync/atomic"
)

var failures int

func fail(format string, args ...any) {
	failures++
	if failures <= 20 {
		fmt.Printf(format+"\n", args...)
	}
}

func recovered(f func() any) (r any) {
	defer func() {
		if p := recover(); p != nil {
			r = fmt.Sprint("panic: ", p)
		}
	}()
	return f()
}

func checkInt32(random *rand.Rand) {
	edges := []int32{0, 1, 2, ^int32(0), ^int32(0) >> 1, ^int32(0)>>1 + 1}
	var a, b int32
	var ta atomic.Int32
	var tb goatomic.Int32
	for step := 0; step < 20000; step++ {
		x, y := edges[random.Intn(len(edges))], edges[random.Intn(len(edges))]
		if random.Intn(2) == 0 {
			x = a
		}
		var ra, rb, rta, rtb any
		switch random.Intn(5) {
		case 0:
			ra, rb = atomic.AddInt32(&a, y), goatomic.AddInt32(&b, y)
			rta, rtb = ta.Add(y), tb.Add(y)
		case 1:
			ra, rb = atomic.LoadInt32(&a), goatomic.LoadInt32(&b)
			rta, rtb = ta.Load(), tb.Load()
		case 2:
			atomic.StoreInt32(&a, y)
			goatomic.StoreInt32(&b, y)
			ta.Store(y)
			tb.Store(y)
		case 3:
			ra, rb = atomic.SwapInt32(&a, y), goatomic.SwapInt32(&b, y)
			rta, rtb = ta.Swap(y), tb.Swap(y)
		case 4:
			ra, rb = atomic.CompareAndSwapInt32(&a, x, y), goatomic.CompareAndSwapInt32(&b, x, y)
			rta, rtb = ta.CompareAndSwap(x, y), tb.CompareAndSwap(x, y)
		}
		if ra != rb || rta != rtb || a != b || ta.Load() != tb.Load() || ra != rta || a != ta.Load() {
			fail("Int32 step %d: %v %v %v %v, Go %v %v %v %v", step, ra, rta, a, ta.Load(), rb, rtb, b, tb.Load())
		}
	}
}

func checkInt64(random *rand.Rand) {
	edges := []int64{0, 1, 2, ^int64(0), ^int64(0) >> 1, ^int64(0)>>1 + 1}
	var a, b int64
	var ta atomic.Int64
	var tb goatomic.Int64
	for step := 0; step < 20000; step++ {
		x, y := edges[random.Intn(len(edges))], edges[random.Intn(len(edges))]
		if random.Intn(2) == 0 {
			x = a
		}
		var ra, rb, rta, rtb any
		switch random.Intn(5) {
		case 0:
			ra, rb = atomic.AddInt64(&a, y), goatomic.AddInt64(&b, y)
			rta, rtb = ta.Add(y), tb.Add(y)
		case 1:
			ra, rb = atomic.LoadInt64(&a), goatomic.LoadInt64(&b)
			rta, rtb = ta.Load(), tb.Load()
		case 2:
			atomic.StoreInt64(&a, y)
			goatomic.StoreInt64(&b, y)
			ta.Store(y)
			tb.Store(y)
		case 3:
			ra, rb = atomic.SwapInt64(&a, y), goatomic.SwapInt64(&b, y)
			rta, rtb = ta.Swap(y), tb.Swap(y)
		case 4:
			ra, rb = atomic.CompareAndSwapInt64(&a, x, y), goatomic.CompareAndSwapInt64(&b, x, y)
			rta, rtb = ta.CompareAndSwap(x, y), tb.CompareAndSwap(x, y)
		}
		if ra != rb || rta != rtb || a != b || ta.Load() != tb.Load() || ra != rta || a != ta.Load() {
			fail("Int64 step %d: %v %v %v %v, Go %v %v %v %v", step, ra, rta, a, ta.Load(), rb, rtb, b, tb.Load())
		}
	}
}

func checkUint32(random *rand.Rand) {
	edges := []uint32{0, 1, 2, ^uint32(0), ^uint32(0) >> 1, ^uint32(0)>>1 + 1}
	var a, b uint32
	var ta atomic.Uint32
	var tb goatomic.Uint32
	for step := 0; step < 20000; step++ {
		x, y := edges[random.Intn(len(edges))], edges[random.Intn(len(edges))]
		if random.Intn(2) == 0 {
			x = a
		}
		var ra, rb, rta, rtb any
		switch random.Intn(5) {
		case 0:
			ra, rb = atomic.AddUint32(&a, y), goatomic.AddUint32(&b, y)
			rta, rtb = ta.Add(y), tb.Add(y)
		case 1:
			ra, rb = atomic.LoadUint32(&a), goatomic.LoadUint32(&b)
			rta, rtb = ta.Load(), tb.Load()
		case 2:
			atomic.StoreUint32(&a, y)
			goatomic.StoreUint32(&b, y)
			ta.Store(y)
			tb.Store(y)
		case 3:
			ra, rb = atomic.SwapUint32(&a, y), goatomic.SwapUint32(&b, y)
			rta, rtb = ta.Swap(y), tb.Swap(y)
		case 4:
			ra, rb = atomic.CompareAndSwapUint32(&a, x, y), goatomic.CompareAndSwapUint32(&b, x, y)
			rta, rtb = ta.CompareAndSwap(x, y), tb.CompareAndSwap(x, y)
		}
		if ra != rb || rta != rtb || a != b || ta.Load() != tb.Load() || ra != rta || a != ta.Load() {
			fail("Uint32 step %d: %v %v %v %v, Go %v %v %v %v", step, ra, rta, a, ta.Load(), rb, rtb, b, tb.Load())
		}
	}
}

func checkUint64(random *rand.Rand) {
	edges := []uint64{0, 1, 2, ^uint64(0), ^uint64(0) >> 1, ^uint64(0)>>1 + 1}
	var a, b uint64
	var ta atomic.Uint64
	var tb goatomic.Uint64
	for step := 0; step < 20000; step++ {
		x, y := edges[random.Intn(len(edges))], edges[random.Intn(len(edges))]
		if random.Intn(2) == 0 {
			x = a
		}
		var ra, rb, rta, rtb any
		switch random.Intn(5) {
		case 0:
			ra, rb = atomic.AddUint64(&a, y), goatomic.AddUint64(&b, y)
			rta, rtb = ta.Add(y), tb.Add(y)
		case 1:
			ra, rb = atomic.LoadUint64(&a), goatomic.LoadUint64(&b)
			rta, rtb = ta.Load(), tb.Load()
		case 2:
			atomic.StoreUint64(&a, y)
			goatomic.StoreUint64(&b, y)
			ta.Store(y)
			tb.Store(y)
		case 3:
			ra, rb = atomic.SwapUint64(&a, y), goatomic.SwapUint64(&b, y)
			rta, rtb = ta.Swap(y), tb.Swap(y)
		case 4:
			ra, rb = atomic.CompareAndSwapUint64(&a, x, y), goatomic.CompareAndSwapUint64(&b, x, y)
			rta, rtb = ta.CompareAndSwap(x, y), tb.CompareAndSwap(x, y)
		}
		if ra != rb || rta != rtb || a != b || ta.Load() != tb.Load() || ra != rta || a != ta.Load() {
			fail("Uint64 step %d: %v %v %v %v, Go %v %v %v %v", step, ra, rta, a, ta.Load(), rb, rtb, b, tb.Load())
		}
	}
}

func checkBool(random *rand.Rand) {
	var a atomic.Bool
	var b goatomic.Bool
	for step := 0; step < 2000; step++ {
		x, y := random.Intn(2) == 0, random.Intn(2) == 0
		var ra, rb any
		switch random.Intn(4) {
		case 0:
			ra, rb = a.Load(), b.Load()
		case 1:
			a.Store(y)
			b.Store(y)
		case 2:
			ra, rb = a.Swap(y), b.Swap(y)
		case 3:
			ra, rb = a.CompareAndSwap(x, y), b.CompareAndSwap(x, y)
		}
		if ra != rb || a.Load() != b.Load() {
			fail("Bool step %d: %v %v, Go %v %v", step, ra, a.Load(), rb, b.Load())
		}
	}
}

type named int

func checkValue(random *rand.Rand) {
	values := []any{nil, 1, 2, "a", "b", named(1), 1.5, []int{1}, []int{2}, struct{ x int }{1}, struct{ x int }{2}}
	for round := 0; round < 3000; round++ {
		var a atomic.Value
		var b goatomic.Value
		for step := 0; step < 12; step++ {
			x, y := values[random.Intn(len(values))], values[random.Intn(len(values))]
			if random.Intn(3) > 0 {
				// Mostly of the type that is there, so that not every step panics.
				y = values[1+random.Intn(2)]
				x = values[random.Intn(3)]
			}
			var ra, rb any
			op := random.Intn(4)
			switch op {
			case 0:
				ra, rb = a.Load(), b.Load()
			case 1:
				ra, rb = recovered(func() any { a.Store(y); return nil }), recovered(func() any { b.Store(y); return nil })
			case 2:
				ra, rb = recovered(func() any { return a.Swap(y) }), recovered(func() any { return b.Swap(y) })
			case 3:
				ra, rb = recovered(func() any { return a.CompareAndSwap(x, y) }), recovered(func() any { return b.CompareAndSwap(x, y) })
			}
			if fmt.Sprintf("%#v %#v", ra, a.Load()) != fmt.Sprintf("%#v %#v", rb, b.Load()) {
				fail("Value round %d step %d op %d (%#v, %#v): %#v %#v, Go %#v %#v", round, step, op, x, y, ra, a.Load(), rb, b.Load())
			}
		}
	}
}

func together() {
	var wg sync.WaitGroup
	var n int64
	var typed atomic.Uint32
	var v atomic.Value
	v.Store(0)
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 5000; i++ {
				atomic.AddInt64(&n, 1)
				for {
					old := typed.Load()
					if typed.CompareAndSwap(old, old+1) {
						break
					}
				}
				for {
					old := v.Load()
					if v.CompareAndSwap(old, old.(int)+1) {
						break
					}
				}
			}
		}()
	}
	wg.Wait()
	if n != 40000 || typed.Load() != 40000 || v.Load() != 40000 {
		fail("goroutines counted %d, %d, %v together, want 40000", n, typed.Load(), v.Load())
	}
}

func main() {
	random := rand.New(rand.NewSource(1))
	checkInt32(random)
	checkInt64(random)
	checkUint32(random)
	checkUint64(random)
	checkBool(random)
	checkValue(random)
	together()
	if failures > 0 {
		fmt.Println(failures, "differences")
		os.Exit(1)
	}
	fmt.Println("sync/atomic: the text and Go agree")
}
