/// `sync.Once`: `once.Do(f)` calls `f` the first time and never again.
///
/// It is Go text of the library, compiled with the program that uses it
/// (`GoSourceLibrary`), beside the native `sync.Mutex` it locks. What each
/// program prints is what Go 1.24.5 prints for it; a message pinned alone
/// is one this dialect words in its own way.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go sync.Once")
struct GoSyncOnceTests: GoTestHarness {

    /// A `sync.Once` is a variable of a package, of a function, a field, and
    /// an element; its zero value is ready, and each has calls of its own.
    @Test func doCallsItsFunctionOnce() throws {
        #expect(
            try runGoMain(
                #"""
                once.Do(func() { fmt.Println("once") })
                once.Do(func() { fmt.Println("twice") })
                var local sync.Once
                n := 0
                for i := 0; i < 3; i++ {
                    local.Do(func() { n += i + 1 })
                }
                fmt.Println(n)
                l := &lazy{}
                fmt.Println(l.get(), l.get(), l.calls)
                var p *sync.Once = &local
                p.Do(func() { fmt.Println("not through a pointer either") })
                slots := make([]sync.Once, 2)
                for i := range slots {
                    slots[i].Do(func() { fmt.Println("slot", i) })
                    slots[i].Do(func() { fmt.Println("slot again", i) })
                }
                byName := map[string]*sync.Once{"a": &sync.Once{}, "b": &sync.Once{}}
                for _, name := range []string{"a", "b", "a"} {
                    byName[name].Do(func() { fmt.Println("first", name) })
                }
                fmt.Printf("%T %T\n", once, p)
                """#,
                imports: ["fmt", "sync"],
                declarations: """
                    var once sync.Once

                    type lazy struct {
                        once  sync.Once
                        value int
                        calls int
                    }

                    func (l *lazy) get() int {
                        l.once.Do(func() {
                            l.calls++
                            l.value = 42
                        })
                        return l.value
                    }
                    """)
                == "once\n1\n42 42 1\nslot 0\nslot 1\nfirst a\nfirst b\nsync.Once *sync.Once\n")
    }

    /// The panic passes through `Do` to whoever recovers it, and `Do` calls
    /// nothing again.
    @Test func aFunctionThatPanicsHasBeenCalled() throws {
        #expect(
            try runGoMain(
                """
                var once sync.Once
                func() {
                    defer func() { fmt.Println("recovered:", recover()) }()
                    once.Do(func() { panic("first") })
                }()
                once.Do(func() { fmt.Println("never") })
                fmt.Println("after the panic")
                var again sync.Once
                func() {
                    defer func() { fmt.Println("recovered:", recover()) }()
                    again.Do(func() {
                        var m map[string]int
                        m["x"] = 1
                    })
                }()
                again.Do(func() { fmt.Println("never") })
                defer func() { fmt.Println("at the end:", recover()) }()
                var nothing sync.Once
                nothing.Do(nil)
                """,
                imports: ["fmt", "sync"])
                == """
                recovered: first
                after the panic
                recovered: assignment to entry in nil map
                at the end: runtime error: invalid memory address or nil pointer dereference

                """)
    }

    /// A call of `Do` while the function is running returns when it has
    /// returned, so every caller sees what it did.
    @Test func otherGoroutinesWaitForTheFirstCall() throws {
        #expect(
            try runGoMain(
                """
                var once sync.Once
                var wg sync.WaitGroup
                count := 0
                for i := 0; i < 5; i++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        once.Do(func() {
                            time.Sleep(10 * time.Millisecond)
                            count++
                            fmt.Println("initialized by one goroutine")
                        })
                        fmt.Println("sees", count)
                    }()
                }
                wg.Wait()
                ready := make(chan bool)
                var shared sync.Once
                go shared.Do(func() {
                    <-ready
                    fmt.Println("released")
                })
                ready <- true
                shared.Do(func() { fmt.Println("never") })
                fmt.Println("done")
                """,
                imports: ["fmt", "sync", "time"])
                == """
                initialized by one goroutine
                sees 1
                sees 1
                sees 1
                sees 1
                sees 1
                released
                done

                """)
    }

    /// A method value, a deferred call, a function of the library as its
    /// argument, and the type under another name.
    @Test func doIsAMethodLikeAnyOther() throws {
        #expect(
            try runGoMain(
                #"""
                var once guard
                do := once.Do
                do(hello)
                do(hello)
                fmt.Printf("%T\n", do)
                var mu sync.Mutex
                mu.Lock()
                var unlocked sync.Once
                unlocked.Do(mu.Unlock)
                unlocked.Do(mu.Unlock)
                mu.Lock()
                var last std.Once
                defer last.Do(func() { f.Println("deferred") })
                last.Do(func() { f.Println("first") })
                var wg sync.WaitGroup
                wg.Add(1)
                var finished sync.Once
                finish := func() { finished.Do(wg.Done) }
                finish()
                finish()
                wg.Wait()
                fmt.Println("finished")
                """#,
                imports: ["fmt", "sync"],
                declarations: """
                    import (
                        f "fmt"
                        std "sync"
                    )

                    type guard = sync.Once

                    func hello() { fmt.Println("hello") }
                    """)
                == "hello\nfunc(func())\nfirst\nfinished\n")
    }

    /// `Do` takes a `func()`. Go names the operand and the call:
    /// `cannot use 1 (untyped int constant) as func() value in argument to once.Do`.
    @Test func aWrongArgumentIsRefused() {
        #expect(
            goMainDiagnostic(
                """
                var once sync.Once
                once.Do(1)
                fmt.Println(1)
                """,
                imports: ["fmt", "sync"])
                == "cannot use int as func() value")
        #expect(
            goMainDiagnostic(
                """
                var once sync.Once
                once.Do(func() int { return 1 })
                fmt.Println(1)
                """,
                imports: ["fmt", "sync"])
                == "cannot use func() int as func() value")
        #expect(
            goMainDiagnostic(
                """
                var once sync.Once
                once.Do()
                fmt.Println(1)
                """,
                imports: ["fmt", "sync"])
                == "not enough arguments in call to Do")
        #expect(
            goMainDiagnostic(
                """
                var once sync.Once
                once.Done()
                fmt.Println(1)
                """,
                imports: ["fmt", "sync"])
                == "sync.Once has no field or method Done")
        #expect(
            goMainDiagnostic(
                """
                var twice sync.Twice
                fmt.Println(twice)
                """,
                imports: ["fmt", "sync"])
                == "undefined: sync.Twice")
    }
}
