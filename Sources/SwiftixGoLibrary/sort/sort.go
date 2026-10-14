// Package sort is the part of sort that is written in Go: everything that
// calls a function or a method of the program. Strings and Ints belong to
// the run-time library.
//
// native.length is the length of the slice an `any` holds, and takes the
// name of the function of Go's reflect that refuses anything else;
// native.swap exchanges two elements of such a slice.
package sort

type Interface interface {
	Len() int
	Less(i, j int) bool
	Swap(i, j int)
}

type IntSlice []int

func (x IntSlice) Len() int           { return len(x) }
func (x IntSlice) Less(i, j int) bool { return x[i] < x[j] }
func (x IntSlice) Swap(i, j int)      { x[i], x[j] = x[j], x[i] }
func (x IntSlice) Sort()              { Sort(x) }
func (x IntSlice) Search(v int) int   { return SearchInts(x, v) }

type StringSlice []string

func (x StringSlice) Len() int            { return len(x) }
func (x StringSlice) Less(i, j int) bool  { return x[i] < x[j] }
func (x StringSlice) Swap(i, j int)       { x[i], x[j] = x[j], x[i] }
func (x StringSlice) Sort()               { Sort(x) }
func (x StringSlice) Search(v string) int { return SearchStrings(x, v) }

type reverse struct {
	Interface Interface
}

func (r reverse) Len() int           { return r.Interface.Len() }
func (r reverse) Less(i, j int) bool { return r.Interface.Less(j, i) }
func (r reverse) Swap(i, j int)      { r.Interface.Swap(i, j) }

func Reverse(data Interface) Interface {
	return &reverse{data}
}

func Sort(data Interface) {
	n := data.Len()
	if n <= 1 {
		return
	}
	quickSort(data, 0, n, bitLength(n))
}

func Stable(data Interface) {
	stableSort(data, data.Len())
}

func IsSorted(data Interface) bool {
	for i := data.Len() - 1; i > 0; i-- {
		if data.Less(i, i-1) {
			return false
		}
	}
	return true
}

func Slice(x any, less func(i, j int) bool) {
	n := native.length(x, "Swapper")
	quickSortFunc(x, less, 0, n, bitLength(n))
}

func SliceStable(x any, less func(i, j int) bool) {
	stableSortFunc(x, less, native.length(x, "Swapper"))
}

func SliceIsSorted(x any, less func(i, j int) bool) bool {
	for i := native.length(x, "reflect.Value.Len") - 1; i > 0; i-- {
		if less(i, i-1) {
			return false
		}
	}
	return true
}

func IntsAreSorted(x []int) bool {
	for i := len(x) - 1; i > 0; i-- {
		if x[i] < x[i-1] {
			return false
		}
	}
	return true
}

func StringsAreSorted(x []string) bool {
	for i := len(x) - 1; i > 0; i-- {
		if x[i] < x[i-1] {
			return false
		}
	}
	return true
}

func Search(n int, f func(int) bool) int {
	low, high := 0, n
	for low < high {
		middle := (low + high) >> 1
		if f(middle) {
			high = middle
		} else {
			low = middle + 1
		}
	}
	return low
}

func Find(n int, cmp func(int) int) (int, bool) {
	low, high := 0, n
	for low < high {
		middle := (low + high) >> 1
		if cmp(middle) > 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low, low < n && cmp(low) == 0
}

func SearchInts(a []int, x int) int {
	return Search(len(a), func(i int) bool { return a[i] >= x })
}

func SearchStrings(a []string, x string) int {
	return Search(len(a), func(i int) bool { return a[i] >= x })
}

// bitLength is the number of bits it takes to write n, which is not
// negative.
func bitLength(n int) int {
	bits := 0
	for n > 0 {
		bits++
		n >>= 1
	}
	return bits
}

// xorshift is the next number after r of the sequence Go scatters
// elements by. Go computes it on a uint64, whose shift to the right
// brings in zeros: the mask takes out the copies of the sign.
func xorshift(r int) int {
	r ^= r << 13
	r ^= (r >> 7) & 0x1ffffffffffffff
	r ^= r << 17
	return r
}
