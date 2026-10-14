/// `container/list`, `container/heap`, and `container/ring`, Go's text:
/// an LRU cache on a list, a heap of timers that `Fix` and `Remove` reorder,
/// and a ring. A method may be named `init`, which `ring` has.
///
/// What each program prints is what Go 1.24.5 printed for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go container packages")
struct GoContainerTests {
    private func run(_ source: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    @Test func listsHeapsAndRingsAreGos() throws {
        #expect(try run(containersSource) == containersExpected)
    }

    /// Only a function of the package named `init` runs before `main` and
    /// takes nothing.
    @Test func aMethodMayBeNamedInit() throws {
        #expect(try run(initMethodSource) == initMethodExpected)
    }
}

private let containersSource = #"""
package main

import (
	"container/heap"
	"container/list"
	"container/ring"
	"fmt"
	"strings"
	"time"
)

// An LRU cache of a fixed size, as a key-value server keeps one.
type lru struct {
	size  int
	order *list.List
	items map[string]*list.Element
}

type entry struct {
	key, value string
}

func newLRU(size int) *lru {
	return &lru{size: size, order: list.New(), items: map[string]*list.Element{}}
}

func (c *lru) get(key string) (string, bool) {
	e, ok := c.items[key]
	if !ok {
		return "", false
	}
	c.order.MoveToFront(e)
	return e.Value.(*entry).value, true
}

func (c *lru) put(key, value string) {
	if e, ok := c.items[key]; ok {
		e.Value.(*entry).value = value
		c.order.MoveToFront(e)
		return
	}
	c.items[key] = c.order.PushFront(&entry{key, value})
	if c.order.Len() > c.size {
		last := c.order.Back()
		c.order.Remove(last)
		delete(c.items, last.Value.(*entry).key)
	}
}

func (c *lru) keys() string {
	var b strings.Builder
	for e := c.order.Front(); e != nil; e = e.Next() {
		b.WriteString(e.Value.(*entry).key)
	}
	return b.String()
}

// A timer heap: the soonest deadline on top.
type timer struct {
	name     string
	deadline time.Duration
	index    int
}

type timers []*timer

func (t timers) Len() int           { return len(t) }
func (t timers) Less(i, j int) bool { return t[i].deadline < t[j].deadline }
func (t timers) Swap(i, j int) {
	t[i], t[j] = t[j], t[i]
	t[i].index = i
	t[j].index = j
}
func (t *timers) Push(x any) {
	item := x.(*timer)
	item.index = len(*t)
	*t = append(*t, item)
}
func (t *timers) Pop() any {
	old := *t
	n := len(old)
	item := old[n-1]
	old[n-1] = nil
	item.index = -1
	*t = old[:n-1]
	return item
}

type ints []int

func (h ints) Len() int           { return len(h) }
func (h ints) Less(i, j int) bool { return h[i] < h[j] }
func (h ints) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *ints) Push(x any)        { *h = append(*h, x.(int)) }
func (h *ints) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

func main() {
	c := newLRU(3)
	for _, k := range []string{"a", "b", "c"} {
		c.put(k, strings.ToUpper(k))
	}
	c.get("a")
	c.put("d", "D")
	_, ok := c.get("b")
	fmt.Println(c.keys(), ok, c.order.Len())

	l := list.New()
	e4 := l.PushBack(4)
	e1 := l.PushFront(1)
	l.InsertBefore(3, e4)
	l.InsertAfter(2, e1)
	l.MoveToBack(e1)
	other := list.New()
	other.PushBack(9)
	l.PushBackList(other)
	l.PushFrontList(other)
	for e := l.Front(); e != nil; e = e.Next() {
		fmt.Print(e.Value, " ")
	}
	fmt.Println(l.Len(), l.Remove(e4), l.Len())
	var zero list.List
	zero.PushBack("z")
	fmt.Println(zero.Front().Value, zero.Len(), zero.Back().Prev())

	h := &timers{}
	heap.Init(h)
	for i, d := range []int{50, 10, 30, 20, 40} {
		heap.Push(h, &timer{name: fmt.Sprint("t", i), deadline: time.Duration(d) * time.Millisecond})
	}
	(*h)[2].deadline = time.Millisecond
	heap.Fix(h, 2)
	removed := heap.Remove(h, 1).(*timer)
	fmt.Print(removed.name, ":")
	for h.Len() > 0 {
		t := heap.Pop(h).(*timer)
		fmt.Print(" ", t.name, "=", t.deadline)
	}
	fmt.Println()
	ih := &ints{5, 2, 8, 1, 9, 3}
	heap.Init(ih)
	heap.Push(ih, 0)
	var out []int
	for ih.Len() > 0 {
		out = append(out, heap.Pop(ih).(int))
	}
	fmt.Println(out)

	r := ring.New(5)
	for i := 0; i < r.Len(); i++ {
		r.Value = i * i
		r = r.Next()
	}
	r.Do(func(v any) { fmt.Print(v, " ") })
	removedRing := r.Unlink(2)
	fmt.Println(r.Len(), removedRing.Len(), r.Move(2).Value, r.Prev().Value)
}
"""#

private let containersExpected = #"""
dac false 3
9 2 3 4 1 9 6 4 5
z 1 <nil>
t3: t2=1ms t1=10ms t4=40ms t0=50ms
[0 1 2 3 5 8 9]
0 1 4 9 16 3 2 16 16

"""#

private let initMethodSource = #"""
package main

import "fmt"

type T struct{ n int }

func (t *T) init() *T { t.n = 7; return t }

func init() { fmt.Println("pkg init") }

func main() { fmt.Println(new(T).init().n) }
"""#

private let initMethodExpected = #"""
pkg init
7

"""#
