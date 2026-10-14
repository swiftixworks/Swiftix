// Drives the sort of the run-time library's Go text and Go's own sort with
// the same inputs and compares what a program can see of them: the result,
// and every call of Less and Swap, or of a less function, in order.
//
// Run by ../run.sh, which puts the library's files beside this one.
package main

import (
	"fmt"
	"math/rand"
	"sort"

	library "example/harness/sort"
)

type item struct{ key, tag int }

// recorder is a sort.Interface that writes down every call.
type recorder struct {
	items []item
	log   []int
	bad   bool
}

func (r *recorder) Len() int { return len(r.items) }
func (r *recorder) Less(i, j int) bool {
	r.log = append(r.log, 1, i, j)
	if r.bad {
		return (r.items[i].key*31+r.items[j].tag)%3 == 0
	}
	return r.items[i].key < r.items[j].key
}
func (r *recorder) Swap(i, j int) {
	r.log = append(r.log, 2, i, j)
	r.items[i], r.items[j] = r.items[j], r.items[i]
}

func same(a, b []int) bool {
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

func sameItems(a, b []item) bool {
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

func input(rng *rand.Rand, n, shape int) []item {
	items := make([]item, n)
	distinct := []int{1, 2, 3, 5, 10, 100, 1 << 30}[rng.Intn(7)]
	for i := range items {
		var key int
		switch shape {
		case 0:
			key = rng.Intn(distinct)
		case 1:
			key = i
		case 2:
			key = n - i
		case 3:
			key = i % (distinct + 1)
		case 4:
			key = 7
		case 5: // organ pipe
			if i < n/2 {
				key = i
			} else {
				key = n - i
			}
		case 6: // sorted with a few elements out of place
			key = i
			if rng.Intn(50) == 0 {
				key = rng.Intn(n + 1)
			}
		case 7: // reversed with duplicates
			key = (n - i) / (1 + rng.Intn(3))
		case 8: // blocks
			key = (i / 7) % 5
		}
		items[i] = item{key, i}
	}
	return items
}

func main() {
	rng := rand.New(rand.NewSource(1))
	checked, failures := 0, 0
	maxLog := 0
	check := func(n, shape int) {
		base := input(rng, n, shape)
		clone := func() []item { return append([]item(nil), base...) }
		// Sort
		a, b := &recorder{items: clone()}, &recorder{items: clone()}
		sort.Sort(a)
		library.Sort(b)
		if len(a.log) > maxLog {
			maxLog = len(a.log)
		}
		if !same(a.log, b.log) || !sameItems(a.items, b.items) {
			failures++
			fmt.Println("Sort differs", n, shape)
		}
		// Stable
		a, b = &recorder{items: clone()}, &recorder{items: clone()}
		sort.Stable(a)
		library.Stable(b)
		if !same(a.log, b.log) || !sameItems(a.items, b.items) {
			failures++
			fmt.Println("Stable differs", n, shape)
		}
		// A Less that is no order at all.
		a, b = &recorder{items: clone(), bad: true}, &recorder{items: clone(), bad: true}
		sort.Sort(a)
		library.Sort(b)
		if !same(a.log, b.log) || !sameItems(a.items, b.items) {
			failures++
			fmt.Println("Sort with a bad Less differs", n, shape)
		}
		a, b = &recorder{items: clone(), bad: true}, &recorder{items: clone(), bad: true}
		sort.Stable(a)
		library.Stable(b)
		if !same(a.log, b.log) || !sameItems(a.items, b.items) {
			failures++
			fmt.Println("Stable with a bad Less differs", n, shape)
		}
		// Reverse
		a, b = &recorder{items: clone()}, &recorder{items: clone()}
		sort.Sort(sort.Reverse(a))
		library.Sort(library.Reverse(b))
		if !same(a.log, b.log) || !sameItems(a.items, b.items) {
			failures++
			fmt.Println("Reverse differs", n, shape)
		}
		// IsSorted
		if sort.IsSorted(a) != library.IsSorted(b) {
			failures++
			fmt.Println("IsSorted differs", n, shape)
		}
		// Slice
		xs, ys := clone(), clone()
		var lx, ly []int
		sort.Slice(xs, func(i, j int) bool { lx = append(lx, i, j); return xs[i].key < xs[j].key })
		library.Slice(ys, func(i, j int) bool { ly = append(ly, i, j); return ys[i].key < ys[j].key })
		if !same(lx, ly) || !sameItems(xs, ys) {
			failures++
			fmt.Println("Slice differs", n, shape)
		}
		if sort.SliceIsSorted(xs, func(i, j int) bool { return xs[i].key < xs[j].key }) != library.SliceIsSorted(ys, func(i, j int) bool { return ys[i].key < ys[j].key }) {
			failures++
			fmt.Println("SliceIsSorted differs", n, shape)
		}
		// SliceStable
		xs, ys = clone(), clone()
		lx, ly = nil, nil
		sort.SliceStable(xs, func(i, j int) bool { lx = append(lx, i, j); return xs[i].key < xs[j].key })
		library.SliceStable(ys, func(i, j int) bool { ly = append(ly, i, j); return ys[i].key < ys[j].key })
		if !same(lx, ly) || !sameItems(xs, ys) {
			failures++
			fmt.Println("SliceStable differs", n, shape)
		}
		// A less that is no order at all: the sequence of calls must still agree.
		xs, ys = clone(), clone()
		lx, ly = nil, nil
		sort.Slice(xs, func(i, j int) bool { lx = append(lx, i, j); return (xs[i].key*31+xs[j].tag)%3 == 0 })
		library.Slice(ys, func(i, j int) bool { ly = append(ly, i, j); return (ys[i].key*31+ys[j].tag)%3 == 0 })
		if !same(lx, ly) || !sameItems(xs, ys) {
			failures++
			fmt.Println("Slice with a bad less differs", n, shape)
		}
		// Search
		keys := make([]int, n)
		for i := range keys {
			keys[i] = xs[i].key
		}
		sort.Ints(keys)
		for _, want := range []int{-1, 0, 3, n / 2, n + 5} {
			if sort.SearchInts(keys, want) != library.SearchInts(keys, want) {
				failures++
				fmt.Println("SearchInts differs", n, shape)
			}
			i1, f1 := sort.Find(n, func(i int) int { return want - keys[i] })
			i2, f2 := library.Find(n, func(i int) int { return want - keys[i] })
			if i1 != i2 || f1 != f2 {
				failures++
				fmt.Println("Find differs", n, shape)
			}
		}
		checked++
	}
	for n := 0; n <= 400; n++ {
		for shape := 0; shape < 9; shape++ {
			check(n, shape)
		}
	}
	for round := 0; round < 600; round++ {
		check(400+rng.Intn(5000), rng.Intn(9))
	}
	for _, n := range []int{8191, 8192, 8193, 20000, 65536, 100003} {
		for shape := 0; shape < 9; shape++ {
			check(n, shape)
		}
	}
	fmt.Println("checked", checked, "inputs,", failures, "failures, longest log", maxLog)
}
