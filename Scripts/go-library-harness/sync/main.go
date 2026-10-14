// Holds the Map, the Pool, and the Once of the run-time library's Go text
// to Go's own: random sequences of every method of a Map on both, with the
// results compared after each step; Range with a function that changes the
// map; and goroutines that use one Map together.
package main

import (
	"fmt"
	"math/rand"
	"os"
	"sort"
	gosync "sync"

	"example/harness/sync"
)

var failures int

func fail(format string, args ...any) {
	failures++
	if failures <= 20 {
		fmt.Printf(format+"\n", args...)
	}
}

type point struct{ x, y int }

// The keys and values: of several types, some equal as numbers and not as
// values, so that a key is its type as well.
var keys = []any{0, 1, 2, 3, int8(1), int64(1), uint(1), "1", "a", "", 1.5, true, false, point{1, 2}, point{2, 1}, [2]int{1, 2}, nil, 'a', struct{}{}}

type entry struct{ key, value any }

func entries(rangeOver func(func(key, value any) bool)) []string {
	var out []string
	seen := map[any]bool{}
	rangeOver(func(key, value any) bool {
		if seen[key] {
			fail("Range visited %#v twice", key)
		}
		seen[key] = true
		out = append(out, fmt.Sprintf("%#v=%#v", key, value))
		return true
	})
	sort.Strings(out)
	return out
}

func same(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func randomSequences(random *rand.Rand) {
	for round := 0; round < 3000; round++ {
		var mine sync.Map
		var gos gosync.Map
		span := 1 + random.Intn(len(keys))
		for step := 0; step < 60; step++ {
			key := keys[random.Intn(span)]
			value, other := any(random.Intn(3)), any(random.Intn(3))
			if random.Intn(8) == 0 {
				value = keys[random.Intn(len(keys))]
			}
			var a, b [2]any
			op := random.Intn(22)
			switch op {
			case 0, 1, 2:
				a[0], a[1] = mine.Load(key)
				b[0], b[1] = gos.Load(key)
			case 3, 4, 5, 6:
				mine.Store(key, value)
				gos.Store(key, value)
			case 7, 8:
				a[0], a[1] = mine.LoadOrStore(key, value)
				b[0], b[1] = gos.LoadOrStore(key, value)
			case 9, 10:
				a[0], a[1] = mine.LoadAndDelete(key)
				b[0], b[1] = gos.LoadAndDelete(key)
			case 11:
				mine.Delete(key)
				gos.Delete(key)
			case 12, 13:
				a[0], a[1] = mine.Swap(key, value)
				b[0], b[1] = gos.Swap(key, value)
			case 14, 15, 16:
				a[0] = mine.CompareAndSwap(key, other, value)
				b[0] = gos.CompareAndSwap(key, other, value)
			case 17, 18:
				a[0] = mine.CompareAndDelete(key, other)
				b[0] = gos.CompareAndDelete(key, other)
			case 19:
				if random.Intn(6) == 0 {
					mine.Clear()
					gos.Clear()
				}
			case 20:
				// Range that stops early visits that many entries.
				limit, n, m := random.Intn(4), 0, 0
				mine.Range(func(_, _ any) bool { n++; return n < limit })
				gos.Range(func(_, _ any) bool { m++; return m < limit })
				a[0], b[0] = n, m
			case 21:
				// A function that changes the entry it is given, in a way
				// that does not depend on the order of the visits.
				change := random.Intn(5)
				visit := func(store func(key, value any), remove func(key any), swap func(key, old, new any) bool) func(key, value any) bool {
					return func(key, value any) bool {
						switch change {
						case 0:
							remove(key)
						case 1:
							store(key, fmt.Sprint(value, "!"))
						case 2:
							swap(key, value, entry{key, value})
						case 3:
							remove(key)
							store(key, 7)
						}
						return true
					}
				}
				var seenMine, seenGos []string
				mine.Range(func(key, value any) bool {
					seenMine = append(seenMine, fmt.Sprintf("%#v=%#v", key, value))
					return visit(mine.Store, mine.Delete, mine.CompareAndSwap)(key, value)
				})
				gos.Range(func(key, value any) bool {
					seenGos = append(seenGos, fmt.Sprintf("%#v=%#v", key, value))
					return visit(gos.Store, gos.Delete, gos.CompareAndSwap)(key, value)
				})
				sort.Strings(seenMine)
				sort.Strings(seenGos)
				if !same(seenMine, seenGos) {
					fail("round %d step %d: changing Range visited %v, Go %v", round, step, seenMine, seenGos)
				}
			}
			if a != b {
				fail("round %d step %d op %d key %#v: %v, Go %v", round, step, op, key, a, b)
			}
			if x, y := entries(mine.Range), entries(gos.Range); !same(x, y) {
				fail("round %d step %d op %d: holds %v, Go %v", round, step, op, x, y)
			}
		}
	}
}

// What Go promises of a Range whose function changes other keys: no key
// twice, a key that stays is visited with a value it had, and one that was
// never there is not.
func changingRange(random *rand.Rand) {
	for round := 0; round < 2000; round++ {
		var m sync.Map
		n := random.Intn(12)
		for i := 0; i < n; i++ {
			m.Store(i, 0)
		}
		touched := map[int]bool{}
		visited := map[int]bool{}
		m.Range(func(key, value any) bool {
			k := key.(int)
			if visited[k] {
				fail("changing Range visited %d twice", k)
			}
			visited[k] = true
			if k >= 100 && !touched[k] {
				fail("changing Range visited %d, which was never stored", k)
			}
			if _, ok := m.Load(key); !ok && !touched[k] {
				fail("changing Range visited %d, which is not there", k)
			}
			other := random.Intn(n + 2)
			if random.Intn(3) == 0 {
				other += 100
			}
			touched[other] = true
			switch random.Intn(4) {
			case 0:
				m.Delete(other)
			case 1:
				m.Store(other, k)
			case 2:
				m.LoadOrStore(other, k)
			case 3:
				m.Swap(other, k)
			}
			return true
		})
		for i := 0; i < n; i++ {
			if !visited[i] && !touched[i] {
				fail("changing Range of %d keys left out %d, which nothing touched", n, i)
			}
		}
	}
}

func together() {
	var m sync.Map
	var wg gosync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 2000; i++ {
				for {
					old, loaded := m.LoadOrStore(i%50, 1)
					if !loaded || m.CompareAndSwap(i%50, old, old.(int)+1) {
						break
					}
				}
				m.Store(1000+g, i)
				m.Range(func(key, value any) bool { return key != 3 })
				if i%100 == 0 {
					m.LoadAndDelete(1000 + g)
				}
			}
		}()
	}
	wg.Wait()
	total := 0
	for i := 0; i < 50; i++ {
		v, _ := m.Load(i)
		total += v.(int)
	}
	if total != 16000 {
		fail("goroutines counted %d in a Map together, want 16000", total)
	}
}

func pool() {
	var empty sync.Pool
	if x := empty.Get(); x != nil {
		fail("Get of an empty Pool without New: %v", x)
	}
	made := 0
	p := sync.Pool{New: func() any { made++; return made }}
	gos := gosync.Pool{New: func() any { return 0 }}
	p.Put(nil)
	gos.Put(nil)
	if a, b := p.Get(), gos.Get(); a != 1 || b != 0 {
		fail("Get after Put(nil): %v, and Go's New gave %v", a, b)
	}
	// What is taken out was put in or made, and nothing comes out twice.
	in := map[any]bool{}
	for i := 0; i < 100; i++ {
		x := &point{i, i}
		in[x] = true
		p.Put(x)
	}
	for i := 0; i < 150; i++ {
		x := p.Get()
		if _, isNew := x.(int); isNew {
			continue
		}
		if !in[x] {
			fail("Get returned %v, which is not in the Pool", x)
		}
		delete(in, x)
	}
	if len(in) != 0 || made != 51 {
		fail("the Pool kept %d of 100 and made %d", len(in), made)
	}
	var wg gosync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				p.Put(p.Get())
			}
		}()
	}
	wg.Wait()
}

func once() {
	var o sync.Once
	n := 0
	for i := 0; i < 3; i++ {
		o.Do(func() { n++ })
	}
	if n != 1 {
		fail("Once called its function %d times", n)
	}
}

func main() {
	random := rand.New(rand.NewSource(1))
	randomSequences(random)
	changingRange(random)
	together()
	pool()
	once()
	if failures > 0 {
		fmt.Println(failures, "differences")
		os.Exit(1)
	}
	fmt.Println("sync: the text and Go agree")
}
