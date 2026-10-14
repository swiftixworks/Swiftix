/// `sync.Map`, a map from any key to any value for goroutines to share, and
/// `sync.Pool`, which keeps values to use again.
///
/// Both are Go text of the library (`Sources/SwiftixGoLibrary/sync`), beside
/// the native `sync.Mutex` they lock. What each program prints is what Go
/// 1.24.5 prints for it; the programs sort what `Range` gives them, since
/// Go's order is not this one's, and ask of a `Pool` only what Go promises.
/// `Scripts/go-library-harness/run.sh sync` runs the text in real Go against
/// Go's own `Map` on random sequences of every method.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go sync.Map and sync.Pool")
struct GoSyncMapTests: GoTestHarness {

    /// Keys of any comparable type are kept apart by type as well as value: `1`,
    /// `int8(1)`, and `int64(1)` are three keys, a struct and an array are keys by
    /// their contents, and a pointer by what it points to.
    @Test func aKeyIsAValueOfItsType() throws {
        #expect(
            try runGoMain(
                """
                var m sync.Map
                v, ok := m.Load("missing")
                fmt.Println(v, ok)
                m.Store("a", 1)
                m.Store(1, "int")
                m.Store(int8(1), "int8")
                m.Store(int64(1), "int64")
                m.Store(point{1, 2}, "point")
                m.Store(1.5, nil)
                m.Store(true, []int{1})
                m.Store([2]string{"x", "y"}, "array")
                p := &point{3, 4}
                m.Store(p, "pointer")
                show(&m)
                fmt.Println(m.Load(1))
                fmt.Println(m.Load(int8(1)))
                fmt.Println(m.Load(int32(1)))
                fmt.Println(m.Load(point{1, 2}))
                fmt.Println(m.Load(point{2, 1}))
                fmt.Println(m.Load(1.5))
                fmt.Println(m.Load([2]string{"x", "y"}))
                fmt.Println(m.Load(p))
                fmt.Println(m.Load(&point{3, 4}))
                k := 1
                var boxed any = "a"
                fmt.Println(m.Load(k))
                fmt.Println(m.Load(boxed))
                """,
                imports: ["fmt", "sort", "sync"],
                declarations: """
                    type point struct{ x, y int }

                    func show(m *sync.Map) {
                        var out []string
                        m.Range(func(key, value any) bool {
                            out = append(out, fmt.Sprintf("%v(%T)=%v", key, key, value))
                            return true
                        })
                        sort.Strings(out)
                        fmt.Println(len(out), out)
                    }
                    """)
                == """
                <nil> false
                9 [&{3 4}(*main.point)=pointer 1(int)=int 1(int64)=int64 1(int8)=int8 1.5(float64)=<nil> [x y]([2]string)=array a(string)=1 true(bool)=[1] {1 2}(main.point)=point]
                int true
                int8 true
                <nil> false
                point true
                <nil> false
                <nil> true
                array true
                pointer true
                <nil> false
                int true
                1 true

                """)
    }

    /// `LoadOrStore`, `LoadAndDelete`, `Delete`, `Swap`, `CompareAndSwap`,
    /// `CompareAndDelete`, `Clear`, and a `Range` that stops.
    @Test func everyMethodDoesWhatGosDoes() throws {
        #expect(
            try runGoMain(
                """
                var m sync.Map
                m.Store("a", 1)
                m.Store(point{1, 2}, "point")
                fmt.Println(m.LoadOrStore("a", 2))
                fmt.Println(m.LoadOrStore("b", 2))
                fmt.Println(m.LoadAndDelete("b"))
                fmt.Println(m.LoadAndDelete("b"))
                fmt.Println(m.Swap("a", 10))
                fmt.Println(m.Swap("c", 11))
                fmt.Println(m.CompareAndSwap("a", 1, 2), m.CompareAndSwap("a", 10, 20), m.CompareAndSwap("zz", nil, 1))
                fmt.Println(m.CompareAndDelete("c", 12), m.CompareAndDelete("c", 11), m.CompareAndDelete("c", 11))
                fmt.Println(m.CompareAndSwap(point{1, 2}, "point", point{9, 9}))
                fmt.Println(m.Load(point{1, 2}))
                m.Delete("a")
                m.Delete("never there")
                show(&m)
                for i := 0; i < 5; i++ {
                    m.Store(i, i)
                }
                n := 0
                m.Range(func(key, value any) bool {
                    n++
                    return n < 3
                })
                fmt.Println(n)
                m.Clear()
                show(&m)
                m.Store("again", 1)
                show(&m)
                """,
                imports: ["fmt", "sort", "sync"],
                declarations: """
                    type point struct{ x, y int }

                    func show(m *sync.Map) {
                        var out []string
                        m.Range(func(key, value any) bool {
                            out = append(out, fmt.Sprintf("%v(%T)=%v", key, key, value))
                            return true
                        })
                        sort.Strings(out)
                        fmt.Println(len(out), out)
                    }
                    """)
                == """
                1 true
                2 false
                2 true
                <nil> false
                1 true
                <nil> false
                false true false
                false true false
                true
                {9 9} true
                1 [{1 2}(main.point)={9 9}]
                3
                0 []
                1 [again(string)=1]

                """)
    }

    /// The function `Range` calls may store and delete: every key that was there
    /// is visited once, with its value.
    @Test func rangeLetsItsFunctionChangeTheMap() throws {
        #expect(
            try runGoMain(
                """
                var r sync.Map
                for i := 0; i < 6; i++ {
                    r.Store(i, i*i)
                }
                sum, visits := 0, 0
                r.Range(func(key, value any) bool {
                    visits++
                    sum += value.(int)
                    r.Store(key, value.(int)+1)
                    r.Delete(key.(int) + 100)
                    return true
                })
                fmt.Println(sum, visits)
                show(&r)
                r.Range(func(key, value any) bool {
                    r.Delete(key)
                    return true
                })
                show(&r)
                """,
                imports: ["fmt", "sort", "sync"],
                declarations: """
                    type point struct{ x, y int }

                    func show(m *sync.Map) {
                        var out []string
                        m.Range(func(key, value any) bool {
                            out = append(out, fmt.Sprintf("%v(%T)=%v", key, key, value))
                            return true
                        })
                        sort.Strings(out)
                        fmt.Println(len(out), out)
                    }
                    """)
                == """
                55 6
                6 [0(int)=1 1(int)=2 2(int)=5 3(int)=10 4(int)=17 5(int)=26]
                0 []

                """)
    }

    /// Four goroutines count in one map of a package with `LoadOrStore` and
    /// `CompareAndSwap`; a map embedded in a struct lends it its methods.
    @Test func goroutinesShareAMap() throws {
        #expect(
            try runGoMain(
                #"""
                var wg sync.WaitGroup
                for g := 0; g < 4; g++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        for i := 0; i < 50; i++ {
                            for {
                                old, loaded := registry.LoadOrStore(i%5, 1)
                                if !loaded || registry.CompareAndSwap(i%5, old, old.(int)+1) {
                                    break
                                }
                            }
                        }
                    }()
                }
                wg.Wait()
                show(&registry)
                c := &cache{}
                c.Store("k", "v")
                if _, ok := c.Load("k"); ok {
                    c.hits++
                }
                load := c.Load
                fmt.Println(load("k"))
                fmt.Printf("%d %T\n", c.hits, &registry)
                """#,
                imports: ["fmt", "sort", "sync"],
                declarations: """
                    type point struct{ x, y int }

                    func show(m *sync.Map) {
                        var out []string
                        m.Range(func(key, value any) bool {
                            out = append(out, fmt.Sprintf("%v(%T)=%v", key, key, value))
                            return true
                        })
                        sort.Strings(out)
                        fmt.Println(len(out), out)
                    }

                    type cache struct {
                        sync.Map
                        hits int
                    }

                    var registry sync.Map
                    """)
                == """
                5 [0(int)=40 1(int)=40 2(int)=40 3(int)=40 4(int)=40]
                v true
                1 *sync.Map

                """)
    }

    /// `Get` of an empty pool calls `New`, or returns `nil` without one; `Put(nil)`
    /// keeps nothing. That a value put comes back is what this pool does and Go's
    /// does here too, though Go does not promise it.
    @Test func aPoolGivesBackWhatItWasGivenOrMakesNew() throws {
        #expect(
            try runGoMain(
                #"""
                made := 0
                pool := sync.Pool{New: func() any { made++; return &point{made, 0} }}
                a := pool.Get().(*point)
                b := pool.Get().(*point)
                fmt.Println(a.x, b.x, made)
                pool.Put(a)
                pool.Put(nil)
                got := pool.Get().(*point)
                fmt.Println(got == a, made)
                var bare sync.Pool
                fmt.Println(bare.Get())
                bare.Put("x")
                fmt.Println(bare.Get(), bare.Get())
                buffers := &sync.Pool{New: func() any { return make([]byte, 0, 8) }}
                buf := buffers.Get().([]byte)
                buf = append(buf, 'h', 'i')
                buffers.Put(buf[:0])
                fmt.Println(len(buf), cap(buffers.Get().([]byte)))
                var wg sync.WaitGroup
                for g := 0; g < 3; g++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        for i := 0; i < 20; i++ {
                            p := pool.Get().(*point)
                            p.y++
                            pool.Put(p)
                        }
                    }()
                }
                wg.Wait()
                fmt.Printf("%T\n", buffers)
                """#,
                imports: ["fmt", "sort", "sync"],
                declarations: """
                    type point struct{ x, y int }

                    func show(m *sync.Map) {
                        var out []string
                        m.Range(func(key, value any) bool {
                            out = append(out, fmt.Sprintf("%v(%T)=%v", key, key, value))
                            return true
                        })
                        sort.Strings(out)
                        fmt.Println(len(out), out)
                    }
                    """)
                == "1 2 2\ntrue 2\n<nil>\nx <nil>\n2 8\n*sync.Pool\n")
    }
}
