/// `sync/atomic`: the functions on pointers to integers, and the typed
/// values `Int32`, `Int64`, `Uint32`, `Uint64`, `Bool`, and `Value`.
///
/// The package is Go text of the library
/// (`Sources/SwiftixGoLibrary/sync/atomic`). The scheduler may switch
/// goroutines after any instruction, so the text holds a lock where it
/// reads and then writes; the first test would lose counts without it, as
/// the same loops over `x++` do. What each program prints is what Go 1.24.5
/// prints for it, and `Scripts/go-library-harness/run.sh sync/atomic` holds
/// the text to Go's package in real Go.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go sync/atomic")
struct GoSyncAtomicTests: GoTestHarness {

    /// Four goroutines add to one variable, one struct field, and one typed value,
    /// and none of the additions is lost; a compare-and-swap loop counts as well,
    /// and one goroutine alone wins a flag.
    @Test func goroutinesCountTogether() throws {
        #expect(
            try runGoMain(
                """
                var wg sync.WaitGroup
                var s stats
                var typed atomic.Int64
                var flag atomic.Bool
                var winners atomic.Int32
                for g := 0; g < 4; g++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        for i := 0; i < 300; i++ {
                            atomic.AddInt64(&s.hits, 1)
                            atomic.AddInt64(&global, 2)
                            typed.Add(3)
                            for {
                                old := atomic.LoadUint32(&s.u)
                                if atomic.CompareAndSwapUint32(&s.u, old, old+1) {
                                    break
                                }
                            }
                        }
                        if flag.CompareAndSwap(false, true) {
                            winners.Add(1)
                        }
                    }()
                }
                wg.Wait()
                fmt.Println(s.hits, global, typed.Load(), s.u, flag.Load(), winners.Load())
                """,
                imports: ["fmt", "sync", "sync/atomic"],
                declarations: """
                    type stats struct {
                        hits  int64
                        small int32
                        u     uint32
                        big   uint64
                    }

                    var global int64
                    """)
                == "1200 2400 3600 1200 true 1\n")
    }

    /// `Add`, `Load`, `Store`, `Swap`, and `CompareAndSwap` of the four integer
    /// types, on a package variable, a struct field, a local variable, and an
    /// element, wrapping around as the type does.
    @Test func theFunctionsWorkThroughAnyPointer() throws {
        #expect(
            try runGoMain(
                """
                var s stats
                fmt.Println(atomic.AddInt32(&s.small, 2147483647), atomic.AddInt32(&s.small, 1), atomic.LoadInt32(&s.small))
                fmt.Println(atomic.AddUint32(&s.u, ^uint32(0)), atomic.AddUint64(&s.big, ^uint64(0)), atomic.AddUint64(&s.big, 2))
                atomic.StoreInt32(&s.small, -5)
                fmt.Println(atomic.SwapInt32(&s.small, 6), atomic.CompareAndSwapInt32(&s.small, 6, 7), atomic.CompareAndSwapInt32(&s.small, 6, 8), s.small)
                atomic.StoreInt64(&global, 1<<40)
                fmt.Println(atomic.SwapInt64(&global, -1), atomic.LoadInt64(&global), atomic.CompareAndSwapInt64(&global, -1, 4), global)
                atomic.StoreUint32(&s.u, 9)
                atomic.StoreUint64(&s.big, 1<<63)
                fmt.Println(atomic.SwapUint32(&s.u, 1), atomic.SwapUint64(&s.big, 2), atomic.LoadUint64(&s.big), atomic.CompareAndSwapUint64(&s.big, 2, 3), s.big, s.u)
                local := int64(5)
                p := &local
                fmt.Println(atomic.AddInt64(p, -6), local)
                counters := []int32{1, 2}
                atomic.AddInt32(&counters[1], 40)
                fmt.Println(counters)
                add := atomic.AddInt64
                fmt.Println(add(p, 10), atomic.LoadInt64(p))
                """,
                imports: ["fmt", "sync/atomic"],
                declarations: """
                    type stats struct {
                        hits  int64
                        small int32
                        u     uint32
                        big   uint64
                    }

                    var global int64
                    """)
                == """
                2147483647 -2147483648 -2147483648
                4294967295 18446744073709551615 1
                -5 true false 7
                1099511627776 -1 true 4
                9 9223372036854775808 2 true 3 1
                -1 -1
                [1 42]
                9 9

                """)
    }

    /// A typed value is a variable, a field, and an element; its zero value is
    /// zero, and its methods are called through a pointer and as values.
    @Test func theTypedValuesHaveTheSameOperations() throws {
        #expect(
            try runGoMain(
                #"""
                type gauge struct {
                    n    atomic.Int64
                    seen atomic.Bool
                }
                type counter = atomic.Uint32
                var i32 atomic.Int32
                var u32 counter
                var u64 atomic.Uint64
                var typed atomic.Int64
                var flag atomic.Bool
                i32.Store(5)
                fmt.Println(i32.Add(-7), i32.Swap(9), i32.CompareAndSwap(9, 10), i32.CompareAndSwap(9, 11), i32.Load())
                fmt.Println(u32.Add(^uint32(0)), u32.Swap(3), u32.CompareAndSwap(3, 4), u32.Load())
                u64.Store(1 << 63)
                fmt.Println(u64.Add(1<<63), u64.Swap(8), u64.CompareAndSwap(7, 1), u64.Load())
                typed.Store(-1)
                fmt.Println(typed.Swap(2), typed.CompareAndSwap(2, 3), typed.Load())
                fmt.Println(flag.Swap(true), flag.Load(), flag.CompareAndSwap(true, false), flag.Load())
                flag.Store(true)
                fmt.Println(flag.Load())
                g := &gauge{}
                bump := g.n.Add
                bump(4)
                bump(5)
                g.seen.Store(g.n.Load() == 9)
                gauges := make([]gauge, 2)
                gauges[1].n.Add(7)
                total := func() int64 { return g.n.Load() + gauges[0].n.Load() + gauges[1].n.Load() }
                fmt.Println(g.seen.Load(), total())
                fmt.Printf("%T %T %T\n", &g.n, &flag, &u32)
                """#,
                imports: ["fmt", "sync/atomic"])
                == """
                -2 -2 true false 10
                4294967295 4294967295 true 4
                0 0 false 8
                -1 true 3
                false true true false
                true
                true 16
                *atomic.Int64 *atomic.Bool *atomic.Uint32

                """)
    }

    /// An `atomic.Value` is empty until the first `Store`, takes values of the
    /// type of the first only, and never `nil`: Go's panics, with Go's words.
    @Test func aValueHoldsValuesOfOneType() throws {
        #expect(
            try runGoMain(
                """
                var v atomic.Value
                fmt.Println(v.Load() == nil, v.CompareAndSwap(nil, "a"), v.Load())
                v.Store("b")
                fmt.Println(v.Swap("c"), v.CompareAndSwap("b", "d"), v.CompareAndSwap("c", "d"), v.Load())
                var cfg atomic.Value
                fmt.Println(cfg.Swap(map[string]int{"a": 1}), cfg.CompareAndSwap(nil, map[string]int{}))
                cfg.Store(map[string]int{"b": 2})
                fmt.Println(cfg.Load().(map[string]int)["b"])
                var current atomic.Value
                current.Store(&settings{name: "one"})
                current.Store(&settings{name: "two"})
                fmt.Println(current.Load().(*settings).name)
                for _, f := range []func(){
                    func() { v.Store(nil) },
                    func() { v.Store(1) },
                    func() { v.Swap(nil) },
                    func() { v.Swap(1) },
                    func() { v.CompareAndSwap("d", nil) },
                    func() { v.CompareAndSwap(1, "d") },
                    func() { v.CompareAndSwap(1, 2) },
                    func() { v.CompareAndSwap(nil, 2) },
                    func() { current.Store(settings{}) },
                } {
                    func() {
                        defer func() { fmt.Println(recover()) }()
                        f()
                    }()
                }
                fmt.Println(v.Load())
                """,
                imports: ["fmt", "sync/atomic"],
                declarations: "type settings struct{ name string }")
                == """
                true true a
                b false true d
                <nil> false
                2
                two
                sync/atomic: store of nil value into Value
                sync/atomic: store of inconsistently typed value into Value
                sync/atomic: swap of nil value into Value
                sync/atomic: swap of inconsistently typed value into Value
                sync/atomic: compare and swap of nil value into Value
                sync/atomic: compare and swap of inconsistently typed values
                sync/atomic: compare and swap of inconsistently typed value into Value
                sync/atomic: compare and swap of inconsistently typed value into Value
                sync/atomic: store of inconsistently typed value into Value
                d

                """)
    }
}
