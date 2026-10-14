// The sorting functions for an Interface: an unstable sort that is a
// pattern-defeating quicksort, as Go's is, and a stable one that merges
// sorted blocks in place. What a program can see of either is the order of
// the calls of Less and Swap, and with it the order equal elements end in,
// so each function compares and exchanges exactly where Go's does.
//
// zsortfunc.go is this file for a slice with a less function, and is
// generated from it: change this one and run Scripts/generate-go-library.py.

package sort

// insertionSort sorts data[a:b] by sinking each element to its place.
func insertionSort(data Interface, a, b int) {
	for i := a + 1; i < b; i++ {
		for j := i; j > a && data.Less(j, j-1); j-- {
			data.Swap(j, j-1)
		}
	}
}

// siftDown restores the heap of count elements that begins at first,
// below the element at root.
func siftDown(data Interface, root, count, first int) {
	for {
		child := 2*root + 1
		if child >= count {
			return
		}
		if child+1 < count && data.Less(first+child, first+child+1) {
			child++
		}
		if !data.Less(first+root, first+child) {
			return
		}
		data.Swap(first+root, first+child)
		root = child
	}
}

// heapSort sorts data[a:b]: what the quicksort falls back to when its
// pivots keep being bad.
func heapSort(data Interface, a, b int) {
	count := b - a
	for i := (count - 1) / 2; i >= 0; i-- {
		siftDown(data, i, count, a)
	}
	for i := count - 1; i >= 0; i-- {
		data.Swap(a, a+i)
		siftDown(data, 0, i, a)
	}
}

// quickSort sorts data[a:b]. limit is how many badly balanced
// partitions it accepts before it gives the range to heapSort.
func quickSort(data Interface, a, b, limit int) {
	balanced, partitioned := true, true
	for {
		length := b - a
		if length <= 12 {
			insertionSort(data, a, b)
			return
		}
		if limit == 0 {
			heapSort(data, a, b)
			return
		}
		if !balanced {
			scatter(data, a, b)
			limit--
		}
		pivot, order := choosePivot(data, a, b)
		if order < 0 {
			reverseRange(data, a, b)
			pivot = (b - 1) - (pivot - a)
			order = 1
		}
		if balanced && partitioned && order > 0 {
			if finishSorted(data, a, b) {
				return
			}
		}
		// Nothing in the range is less than what precedes it, so what
		// is not greater than the pivot is equal to it.
		if a > 0 && !data.Less(a-1, pivot) {
			a = partitionEqual(data, a, b, pivot)
			continue
		}
		middle, already := partition(data, a, b, pivot)
		partitioned = already
		left, right := middle-a, b-middle
		if left < right {
			balanced = left >= length/8
			quickSort(data, a, middle, limit)
			a = middle + 1
		} else {
			balanced = right >= length/8
			quickSort(data, middle+1, b, limit)
			b = middle
		}
	}
}

// partition puts the element at pivot where it belongs in data[a:b],
// with the lesser ones before it, and says where that is and whether
// the range was partitioned already.
func partition(data Interface, a, b, pivot int) (int, bool) {
	data.Swap(a, pivot)
	i, j := a+1, b-1
	for i <= j && data.Less(i, a) {
		i++
	}
	for i <= j && !data.Less(j, a) {
		j--
	}
	if i > j {
		data.Swap(j, a)
		return j, true
	}
	data.Swap(i, j)
	i++
	j--
	for {
		for i <= j && data.Less(i, a) {
			i++
		}
		for i <= j && !data.Less(j, a) {
			j--
		}
		if i > j {
			break
		}
		data.Swap(i, j)
		i++
		j--
	}
	data.Swap(j, a)
	return j, false
}

// partitionEqual puts the elements of data[a:b] that equal the one
// at pivot first, where none is less than it, and says where the
// greater ones begin.
func partitionEqual(data Interface, a, b, pivot int) int {
	data.Swap(a, pivot)
	i, j := a+1, b-1
	for {
		for i <= j && !data.Less(a, i) {
			i++
		}
		for i <= j && data.Less(a, j) {
			j--
		}
		if i > j {
			return i
		}
		data.Swap(i, j)
		i++
		j--
	}
}

// finishSorted moves up to five elements of data[a:b] that are out
// of order to their places, and says whether that sorted the range.
func finishSorted(data Interface, a, b int) bool {
	i := a + 1
	for step := 0; step < 5; step++ {
		for i < b && !data.Less(i, i-1) {
			i++
		}
		if i == b {
			return true
		}
		if b-a < 50 {
			return false
		}
		data.Swap(i, i-1)
		if i-a >= 2 {
			for j := i - 1; j >= 1; j-- {
				if !data.Less(j, j-1) {
					break
				}
				data.Swap(j, j-1)
			}
		}
		if b-i >= 2 {
			for j := i + 1; j < b; j++ {
				if !data.Less(j, j-1) {
					break
				}
				data.Swap(j, j-1)
			}
		}
	}
	return false
}

// scatter exchanges three elements in the middle of data[a:b] with
// others, chosen by a sequence that depends on the length alone.
func scatter(data Interface, a, b int) {
	length := b - a
	if length < 8 {
		return
	}
	random := length
	mask := (1 << bitLength(length)) - 1
	middle := a + length/4*2
	for at := middle - 1; at <= middle+1; at++ {
		random = xorshift(random)
		other := random & mask
		if other >= length {
			other -= length
		}
		data.Swap(at, a+other)
	}
}

// choosePivot picks a pivot for data[a:b]: the middle element of a
// short range, the median of three, or of three medians of three for
// a long one. The comparisons that came out the wrong way round say
// whether the range looks sorted already (1), sorted backwards (-1),
// or neither (0).
func choosePivot(data Interface, a, b int) (int, int) {
	length := b - a
	exchanges := 0
	i := a + length/4
	j := a + length/4*2
	k := a + length/4*3
	if length >= 8 {
		if length >= 50 {
			i, exchanges = median(data, i-1, i, i+1, exchanges)
			j, exchanges = median(data, j-1, j, j+1, exchanges)
			k, exchanges = median(data, k-1, k, k+1, exchanges)
		}
		j, exchanges = median(data, i, j, k, exchanges)
	}
	if exchanges == 0 {
		return j, 1
	}
	if exchanges == 12 {
		return j, -1
	}
	return j, 0
}

// inOrder gives a and b so that the element at the first is not
// after the one at the second, and counts one more exchange when
// that turned them round.
func inOrder(data Interface, a, b, exchanges int) (int, int, int) {
	if data.Less(b, a) {
		return b, a, exchanges + 1
	}
	return a, b, exchanges
}

// median is the index among a, b, and c of the element between the
// other two.
func median(data Interface, a, b, c, exchanges int) (int, int) {
	a, b, exchanges = inOrder(data, a, b, exchanges)
	b, _, exchanges = inOrder(data, b, c, exchanges)
	_, b, exchanges = inOrder(data, a, b, exchanges)
	return b, exchanges
}

func reverseRange(data Interface, a, b int) {
	i, j := a, b-1
	for i < j {
		data.Swap(i, j)
		i++
		j--
	}
}

func swapRange(data Interface, a, b, n int) {
	for i := 0; i < n; i++ {
		data.Swap(a+i, b+i)
	}
}

// stableSort sorts the first n elements and keeps equal ones in the
// order they had: blocks of twenty by insertion, then merged in place,
// two at a time, until one block is left.
func stableSort(data Interface, n int) {
	block := 20
	a, b := 0, block
	for b <= n {
		insertionSort(data, a, b)
		a = b
		b += block
	}
	insertionSort(data, a, n)
	for block < n {
		a, b = 0, 2*block
		for b <= n {
			merge(data, a, a+block, b)
			a = b
			b += 2 * block
		}
		if m := a + block; m < n {
			merge(data, a, m, n)
		}
		block *= 2
	}
}

// merge merges the sorted data[a:m] and data[m:b], neither empty,
// without other storage (SymMerge, by Kim and Kutzner): it finds by
// binary search where the two halves must exchange a block, rotates
// that block into place, and merges each side of the middle likewise.
func merge(data Interface, a, m, b int) {
	if m-a == 1 {
		// One element on the left: to before the first on the right
		// that is not less than it.
		low, high := m, b
		for low < high {
			h := (low + high) >> 1
			if data.Less(h, a) {
				low = h + 1
			} else {
				high = h
			}
		}
		for k := a; k < low-1; k++ {
			data.Swap(k, k+1)
		}
		return
	}
	if b-m == 1 {
		// One element on the right: to after the last on the left
		// that it is not less than.
		low, high := a, m
		for low < high {
			h := (low + high) >> 1
			if !data.Less(m, h) {
				low = h + 1
			} else {
				high = h
			}
		}
		for k := m; k > low; k-- {
			data.Swap(k, k-1)
		}
		return
	}
	middle := (a + b) >> 1
	n := middle + m
	start, r := a, m
	if m > middle {
		start, r = n-b, middle
	}
	p := n - 1
	for start < r {
		c := (start + r) >> 1
		if !data.Less(p-c, c) {
			start = c + 1
		} else {
			r = c
		}
	}
	end := n - start
	if start < m && m < end {
		rotate(data, start, m, end)
	}
	if a < start && start < middle {
		merge(data, a, start, middle)
	}
	if middle < end && end < b {
		merge(data, middle, end, b)
	}
}

// rotate exchanges the adjacent blocks data[a:m] and data[m:b].
func rotate(data Interface, a, m, b int) {
	i, j := m-a, b-m
	for i != j {
		if i > j {
			swapRange(data, m-i, m, j)
			i -= j
		} else {
			swapRange(data, m-i, m+j-i, i)
			j -= i
		}
	}
	swapRange(data, m-i, m, i)
}
