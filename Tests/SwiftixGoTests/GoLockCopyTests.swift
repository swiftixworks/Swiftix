/// Locks inside values: `make([]shard, n)`, zero values, and copies.
///
/// A `sync.Mutex` and a `sync.WaitGroup` are handles in the VM, and each value
/// that holds one has its own, as each Go value has its own lock: see
/// `LockCopies.swift`. Every expected output is what Go 1.24.5 printed for the
/// same program.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go locks inside made and copied values")
struct GoLockCopyTests {
    private func run(_ text: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// A slice made with `make`, an array, `new`, a literal, a map entry, `append`, a result, a
    /// package variable, a struct nested in a struct, and a closed channel's zero value: each lock
    /// is its own, at any depth, so locking one shard leaves the next free.
    @Test func everyZeroValueHasLocksOfItsOwn() throws {
        let source = #"""
            package main

            import (
                "fmt"
                "sync"
            )

            type shard struct {
                sync.Mutex
                m map[string]int
            }

            type named struct {
                mu sync.Mutex
                n  int
            }

            type deep struct {
                inner struct{ a [2]named }
                wg    sync.WaitGroup
            }

            func zero() shard { return shard{} }

            var global [3]named

            func main() {
                shards := make([]shard, 4)
                shards[0].Lock()
                fmt.Println("make", shards[1].TryLock())
                var a [4]shard
                a[0].Lock()
                fmt.Println("array", a[1].TryLock())
                p, q := new(shard), new(shard)
                p.Lock()
                fmt.Println("new", q.TryLock())
                l := []named{{n: 1}, {n: 2}}
                l[0].mu.Lock()
                fmt.Println("literal", l[1].mu.TryLock())
                m := map[int]named{}
                m[1] = named{}
                m[2] = named{}
                x := m[1]
                x.mu.Lock()
                y := m[2]
                fmt.Println("map", y.mu.TryLock())
                mp := map[int]*named{}
                mp[1] = &named{}
                mp[2] = &named{}
                mp[1].mu.Lock()
                fmt.Println("mapptr", mp[2].mu.TryLock())
                var s []shard
                s = append(s, shard{})
                s = append(s, shard{})
                s[0].Lock()
                fmt.Println("append", s[1].TryLock())
                z1, z2 := zero(), zero()
                z1.Lock()
                fmt.Println("func", z2.TryLock())
                global[0].mu.Lock()
                fmt.Println("global", global[1].mu.TryLock())
                ds := make([]deep, 2)
                ds[0].inner.a[0].mu.Lock()
                fmt.Println("deep", ds[0].inner.a[1].mu.TryLock(), ds[1].inner.a[0].mu.TryLock())
                ds[0].wg.Add(1)
                ds[1].wg.Wait()
                fmt.Println("wg ok")
                arr := make([][2]sync.Mutex, 2)
                arr[0][0].Lock()
                fmt.Println("arr", arr[0][1].TryLock(), arr[1][0].TryLock())
                ms := make(map[string]shard)
                e := ms["a"]
                e.Lock()
                f := ms["b"]
                fmt.Println("missing", f.TryLock())
                ch := make(chan shard, 2)
                ch <- shard{}
                var r1 shard
                close(ch)
                r1 = <-ch
                r2 := <-ch
                r1.Lock()
                fmt.Println("chan", r2.TryLock())
            }
            """#
        #expect(
            try run(source + "\n")
                == """
                make true
                array true
                new true
                literal true
                map true
                mapptr true
                append true
                func true
                global true
                deep true true
                wg ok
                arr true true
                missing true
                chan true

                """)
    }

    /// A copy of a struct that holds a lock is a second lock in the state the first was in:
    /// an assignment, an argument, `copy`, an array, a dereference. What the program does, not
    /// what `go vet` says of it.
    @Test func aCopyIsTheLockAsItWas() throws {
        let source = #"""
            package main

            import (
                "fmt"
                "sync"
            )

            type box struct {
                mu sync.Mutex
                n  int
            }

            func byValue(b box) bool { return b.mu.TryLock() }

            func main() {
                var a box
                b := a // copy of unlocked
                a.mu.Lock()
                fmt.Println("copy unlocked then lock orig", b.mu.TryLock())
                c := a // copy of locked
                fmt.Println("copy of locked", c.mu.TryLock())
                a.mu.Unlock()
                fmt.Println("after orig unlock, copy", c.mu.TryLock())
                var d box
                fmt.Println("param", byValue(d), d.mu.TryLock())
                s := []box{{}, {}}
                t := make([]box, 2)
                copy(t, s)
                s[0].mu.Lock()
                fmt.Println("copy()", t[0].mu.TryLock())
                arr := [2]box{}
                arr2 := arr
                arr[0].mu.Lock()
                fmt.Println("array copy", arr2[0].mu.TryLock())
                var m1, m2 sync.Mutex
                m1.Lock()
                m2 = m1
                fmt.Println("assign locked", m2.TryLock())
                m1.Unlock()
                fmt.Println("orig unlock, assigned", m2.TryLock())
                var wg sync.WaitGroup
                wg.Add(1)
                wg2 := wg
                wg.Done()
                _ = wg2
                fmt.Println("done")
                for _, v := range []box{{}, {}} {
                    fmt.Println("range", v.mu.TryLock())
                }
                p := &box{}
                p.mu.Lock()
                q := *p
                fmt.Println("deref copy", q.mu.TryLock())
            }
            """#
        #expect(
            try run(source + "\n")
                == """
                copy unlocked then lock orig true
                copy of locked false
                after orig unlock, copy false
                param true true
                copy() true
                array copy true
                assign locked false
                orig unlock, assigned false
                done
                range true
                range true
                deref copy false

                """)
    }

    /// An aliased import, a type alias, a type declared in a function, `sync.Once` inside a
    /// made value, a value receiver, an interface, a closure, a conversion, `range`, `clear`,
    /// a slice that grows, and goroutines that wait on the groups of a made slice.
    @Test func everyPassSeesTheCopies() throws {
        let source = #"""
            package main

            import (
                "fmt"
                s "sync"
            )

            type counter struct {
                mu s.Mutex
                n  int
            }

            func (c counter) peek() bool { return c.mu.TryLock() }

            type pair = counter

            type wrap struct {
                inner counter
                once  s.Once
            }

            func main() {
                type local struct {
                    s.Mutex
                    wg s.WaitGroup
                }
                ls := make([]local, 3)
                ls[0].Lock()
                fmt.Println(ls[1].TryLock(), ls[2].TryLock(), ls[0].TryLock())
                var c counter
                c.mu.Lock()
                fmt.Println("value receiver", c.peek(), c.peek())
                pc := &c
                fmt.Println("ptr value receiver", pc.peek())
                ps := make([]pair, 2)
                ps[0].mu.Lock()
                fmt.Println("alias", ps[1].mu.TryLock())
                ws := make([]wrap, 2)
                ws[0].once.Do(func() { fmt.Println("once 0") })
                ws[1].once.Do(func() { fmt.Println("once 1") })
                ws[0].once.Do(func() { fmt.Println("once 0 again") })
                var i any = c
                d := i.(counter)
                e := i.(counter)
                d.mu.Unlock()
                fmt.Println("assert", e.mu.TryLock())
                a, b := c, c
                a.mu.Unlock()
                fmt.Println("multi", b.mu.TryLock())
                f := func() bool { return c.mu.TryLock() }
                fmt.Println("closure", f())
                c.mu.Unlock()
                fmt.Println("closure after", f())
                type conv counter
                g := conv(c)
                fmt.Println("conv", g.mu.TryLock())
                m := map[string]counter{"a": {}}
                m["b"] = m["a"]
                x := m["a"]
                x.mu.Lock()
                y := m["b"]
                fmt.Println("map copy", y.mu.TryLock())
                arr := [2]counter{}
                for idx, v := range arr {
                    v.mu.Lock()
                    fmt.Println("range", idx, arr[idx].mu.TryLock())
                }
                for idx := range ls {
                    ls[idx].wg.Add(1)
                }
                done := make(chan bool)
                for idx := range ls {
                    go func(l *local) {
                        l.wg.Done()
                        done <- true
                    }(&ls[idx])
                }
                for range ls {
                    <-done
                }
                for idx := range ls {
                    ls[idx].wg.Wait()
                }
                fmt.Println("waited")
                sl := make([]counter, 1, 1)
                p := &sl[0]
                sl = append(sl, counter{})
                p.mu.Lock()
                fmt.Println("grow", sl[0].mu.TryLock())
                cl := make([]counter, 2)
                cl[0].mu.Lock()
                clear(cl)
                fmt.Println("clear", cl[0].mu.TryLock(), cl[1].mu.TryLock())
                sl2 := append([]counter(nil), cl...)
                fmt.Println("append spread", sl2[0].mu.TryLock(), sl2[1].mu.TryLock())
            }
            """#
        #expect(
            try run(source + "\n")
                == """
                true true false
                value receiver false false
                ptr value receiver false
                alias true
                once 0
                once 1
                assert false
                multi false
                closure false
                closure after true
                conv false
                map copy true
                range 0 true
                range 1 true
                waited
                grow true
                clear true true
                append spread false false

                """)
    }

    /// `shardFor(key).mu.Lock()`: a field reached through a pointer has an address, as in Go.
    @Test func aLockReachedThroughAPointerResultIsAddressable() throws {
        let source = #"""
            package main

            import (
                "fmt"
                "sync"
            )

            type shard struct {
                sync.RWMutex
                mu sync.Mutex
                wg sync.WaitGroup
            }

            var shards [2]shard

            func get(i int) *shard { return &shards[i] }

            func main() {
                get(0).Lock()
                fmt.Println(get(0).TryLock(), get(1).TryLock())
                get(0).mu.Lock()
                fmt.Println(get(0).mu.TryLock(), get(1).mu.TryLock())
                get(0).wg.Add(1)
                get(0).wg.Done()
                get(0).wg.Wait()
                fmt.Println("ok")
            }
            """#
        #expect(
            try run(source + "\n")
                == """
                false true
                false true
                ok

                """)
    }

    /// Two packages of one module: a shard type of one, made, copied, and locked by the other.
    @Test func locksCrossPackages() throws {
        let file0 = #"""
            package main

            import (
                f "fmt"
                "sync"

                "example/m/lib"
            )

            type Alias = lib.Shard

            func main() {
                shards := lib.NewShards(3)
                shards[0].Lock()
                f.Println(shards[1].TryLock(), shards[2].TryLock())
                c := lib.Copy(shards[0])
                f.Println("copy of locked", c.TryLock())
                shards[0].Unlock()
                f.Println("copy stays locked", c.TryLock())
                var cache lib.Cache
                cache.For("a").Lock()
                f.Println(cache.For("bb").TryLock(), cache.For("e").TryLock())
                caches := make([]lib.Cache, 2)
                caches[0].Shards[1].Lock()
                f.Println(caches[1].Shards[1].TryLock())
                var as []Alias
                as = append(as, Alias{}, Alias{})
                as[0].Lock()
                f.Println(as[1].TryLock())
                var wg sync.WaitGroup
                results := make([]int, 4)
                for i := range 4 {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        sh := cache.For(f.Sprint(i, i))
                        if sh.TryLock() {
                            results[i] = sh.Count()
                            sh.Unlock()
                        }
                    }()
                }
                wg.Wait()
                f.Println(results)
                type local struct {
                    mu [2]sync.Mutex
                }
                ls := make(map[int]local)
                l1 := ls[1]
                l1.mu[0].Lock()
                ls[1] = l1
                l2 := ls[1]
                f.Println(l2.mu[0].TryLock(), l2.mu[1].TryLock())
                l3 := ls[2]
                f.Println(l3.mu[0].TryLock())
            }
            """#
        let file1 = #"""
            package lib

            import s "sync"

            // Shard is one part of a cache.
            type Shard struct {
                s.Mutex
                M  map[string]int
                wg s.WaitGroup
            }

            type Cache struct {
                Shards [4]Shard
            }

            func NewShards(n int) []Shard { return make([]Shard, n) }

            func Copy(sh Shard) Shard { return sh }

            func (c *Cache) For(key string) *Shard { return &c.Shards[len(key)%4] }

            func (sh *Shard) Count() int {
                sh.wg.Add(1)
                defer sh.wg.Done()
                return len(sh.M)
            }
            """#
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m",
                    sources: [GoSourceFile(path: "/m/main.go", text: file0 + "\n")]),
                GoPackageSource(
                    importPath: "example/m/lib",
                    sources: [GoSourceFile(path: "/m/lib/lib.go", text: file1 + "\n")]),
            ], root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(
            output
                == """
                true true
                copy of locked false
                copy stays locked false
                true false
                true
                true
                [0 0 0 0]
                false true
                true

                """)
    }

    /// Go's runtime ends the program when a mutex that is not locked is unlocked: no
    /// deferred call runs and `recover` does not see it.
    @Test func unlockingAnUnlockedMutexEndsTheProgram() throws {
        let source = """
            package main

            import (
                "fmt"
                "sync"
            )

            func main() {
                defer fmt.Println("deferred")
                defer func() { fmt.Println("recovered", recover()) }()
                var mu sync.Mutex
                mu.Lock()
                mu.Unlock()
                mu.Unlock()
            }
            """
        #expect {
            _ = try run(source + "\n")
        } throws: { error in
            String(describing: error) == "fatal error: sync: unlock of unlocked mutex"
        }
    }
}
