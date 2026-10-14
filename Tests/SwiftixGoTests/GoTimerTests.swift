/// `time.NewTimer`, `time.NewTicker`, and `time.AfterFunc`.
///
/// A `*time.Timer` and a `*time.Ticker` point to the structs Go has, with the
/// channel `C`, and `Stop` and `Reset` are native calls. The timers run on the
/// VM's logical clock, so no test waits for real time. What each program
/// prints is what Go 1.24.5 prints for it, and each error pinned with its
/// place is the first one its compiler reports, copied without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go time.Timer, time.Ticker, and time.AfterFunc")
struct GoTimerTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// Go's results: `Stop` and `Reset` are true for a timer that had not
    /// been used up, which since Go 1.23 includes one that fired and whose time
    /// nobody received; that time is taken back, so nothing stale is received.
    @Test func aTimerFiresOnceAndStopAndResetSayWhetherItWasStillToFire() throws {
        #expect(
            try runGoMain(
                """
                start := time.Now()
                t := time.NewTimer(20 * time.Millisecond)
                at := <-t.C
                fmt.Println(at.Sub(start) >= 20*time.Millisecond, time.Since(start) < time.Second)
                fmt.Println("stop after it fired:", t.Stop())
                fmt.Println("reset when idle:", t.Reset(10*time.Millisecond))
                fmt.Println("stop while running:", t.Stop(), t.Stop())
                select {
                case <-t.C:
                    fmt.Println("stale time")
                case <-time.After(30 * time.Millisecond):
                    fmt.Println("nothing after stop")
                }
                """,
                imports: ["fmt", "sync", "time"])
                == """
                true true
                stop after it fired: false
                reset when idle: false
                stop while running: true false
                nothing after stop

                """)
        #expect(
            try runGoMain(
                """
                t := time.NewTimer(time.Millisecond)
                time.Sleep(5 * time.Millisecond)
                fmt.Println("stop unread:", t.Stop())
                select {
                case <-t.C:
                    fmt.Println("stale time")
                default:
                    fmt.Println("taken back")
                }
                t = time.NewTimer(time.Millisecond)
                time.Sleep(5 * time.Millisecond)
                fmt.Println("reset unread:", t.Reset(5*time.Millisecond))
                <-t.C
                fmt.Println("reset:", t.Reset(time.Hour), t.Reset(time.Millisecond))
                <-t.C
                zero := time.NewTimer(0)
                <-zero.C
                past := time.NewTimer(-time.Second)
                <-past.C
                fmt.Println("fired at once")
                """,
                imports: ["fmt", "sync", "time"])
                == """
                stop unread: true
                taken back
                reset unread: true
                reset: false true
                fired at once

                """)
        #expect(
            try runGoMain(
                """
                work := make(chan int)
                go func() {
                    time.Sleep(5 * time.Millisecond)
                    work <- 7
                }()
                timeout := time.NewTimer(50 * time.Millisecond)
                select {
                case v := <-work:
                    fmt.Println("work", v, timeout.Stop())
                case <-timeout.C:
                    fmt.Println("timeout")
                }
                timeout.Reset(time.Millisecond)
                select {
                case v := <-work:
                    fmt.Println("work", v)
                case <-timeout.C:
                    fmt.Println("timeout")
                }
                timers := []*time.Timer{time.NewTimer(3 * time.Millisecond), time.NewTimer(time.Millisecond), time.NewTimer(2 * time.Millisecond)}
                got := make(chan int, 3)
                for i, tm := range timers {
                    go func() {
                        <-tm.C
                        got <- i
                    }()
                }
                fmt.Println(<-got, <-got, <-got)
                """,
                imports: ["fmt", "sync", "time"])
                == "work 7 true\ntimeout\n1 2 0\n")
    }

    /// A ticker sends the time every interval, drops the ticks nobody reads,
    /// and sends none after `Stop`; `Reset` gives it another interval.
    @Test func aTickerTicksUntilItIsStopped() throws {
        #expect(
            try runGoMain(
                """
                k := time.NewTicker(10 * time.Millisecond)
                begin := time.Now()
                n := 0
                for range k.C {
                    n++
                    if n == 3 {
                        break
                    }
                }
                k.Stop()
                k.Stop()
                fmt.Println(n, time.Since(begin) >= 30*time.Millisecond)
                select {
                case <-k.C:
                    fmt.Println("tick after stop")
                case <-time.After(30 * time.Millisecond):
                    fmt.Println("no tick after stop")
                }
                k = time.NewTicker(time.Millisecond)
                time.Sleep(20 * time.Millisecond)
                <-k.C
                select {
                case <-k.C:
                    fmt.Println("queued")
                default:
                    fmt.Println("one tick kept")
                }
                k.Reset(5 * time.Millisecond)
                begin = time.Now()
                <-k.C
                fmt.Println(time.Since(begin) >= 5*time.Millisecond)
                k.Stop()
                """,
                imports: ["fmt", "sync", "time"])
                == "3 true\nno tick after stop\none tick kept\ntrue\n")
    }

    /// `time.AfterFunc` takes any function value. `Stop` before the timer
    /// fires keeps the function from running, and `Reset` has it run again.
    @Test func afterFuncCallsItsFunctionInAGoroutineOfItsOwn() throws {
        #expect(
            try runGoMain(
                """
                var wg sync.WaitGroup
                var mu sync.Mutex
                order := []string{}
                note := func(s string) {
                    mu.Lock()
                    order = append(order, s)
                    mu.Unlock()
                }
                wg.Add(1)
                f := time.AfterFunc(10*time.Millisecond, func() {
                    note("func")
                    wg.Done()
                })
                fmt.Println(f.C == nil)
                note("main")
                wg.Wait()
                fmt.Println(order, f.Stop())
                stopped := time.AfterFunc(5*time.Millisecond, func() { note("never") })
                fmt.Println(stopped.Stop(), stopped.Stop())
                time.Sleep(10 * time.Millisecond)
                wg.Add(2)
                again := time.AfterFunc(time.Hour, wg.Done)
                fmt.Println(again.Reset(time.Millisecond))
                time.Sleep(5 * time.Millisecond)
                fmt.Println(again.Reset(time.Millisecond))
                wg.Wait()
                fmt.Println(order)
                """,
                imports: ["fmt", "sync", "time"])
                == "true\n[main func] false\ntrue false\ntrue\nfalse\n[main func]\n")
    }

    /// The zero value of the pointers is nil, the structs have zero values,
    /// the methods are values, and a pointer is whatever interface its methods
    /// satisfy.
    @Test func timersAreFieldsValuesAndInterfaceValues() throws {
        #expect(
            try runGoMain(
                #"""
                var zt *time.Timer
                var zk *time.Ticker
                fmt.Println(zt == nil, zk == nil)
                fmt.Printf("%T %T\n", zt, zk)
                s := &server{idle: time.NewTimer(time.Hour), beat: time.NewTicker(time.Hour), closed: make(chan bool, 1)}
                stop, reset := s.idle.Stop, s.idle.Reset
                fmt.Printf("%T %T %T %T %T\n", stop, reset, s.beat.Stop, s.beat.Reset, s.idle.C)
                fmt.Println(reset(time.Hour), stop(), stop())
                var st stopper = s.idle
                fmt.Println(st.Stop())
                defer s.beat.Stop()
                s.beat.Reset(time.Millisecond)
                select {
                case <-s.beat.C:
                    fmt.Println("beat")
                case <-s.idle.C:
                    fmt.Println("idle")
                case <-s.closed:
                    fmt.Println("closed")
                }
                var a any = s.beat
                _, isStopper := a.(stopper)
                _, isTicker := a.(*time.Ticker)
                _, hasStop := a.(interface{ Stop() })
                _, wrongReset := a.(interface{ Reset(int) })
                fmt.Println(isStopper, isTicker, hasStop, wrongReset)
                t, k := time.Timer{}, time.Ticker{}
                fmt.Println(t.C == nil, k.C == nil, t, k)
                u := *s.idle
                fmt.Println(u.C == s.idle.C, u == *s.idle)
                fmt.Printf("%T %T %T\n", time.AfterFunc, time.NewTimer, time.NewTicker)
                """#,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type server struct {
                        idle   *time.Timer
                        beat   *time.Ticker
                        closed chan bool
                    }

                    type stopper interface{ Stop() bool }
                    """)
                == """
                true true
                *time.Timer *time.Ticker
                func() bool func(time.Duration) bool func() func(time.Duration) <-chan time.Time
                true true false
                false
                beat
                false true true false
                true true {<nil> false} {<nil> false}
                true true
                func(time.Duration, func()) *time.Timer func(time.Duration) *time.Timer func(time.Duration) *time.Ticker

                """)
    }

    /// A timer nobody made, an interval that is not positive, and a nil
    /// pointer panic as they do in Go, and `recover` gets the text.
    @Test func misuseIsAPanicWithGosText() throws {
        #expect(
            try runGoMain(
                """
                try := func(f func()) {
                    defer func() { fmt.Println(recover()) }()
                    f()
                }
                var t time.Timer
                var k time.Ticker
                var none *time.Timer
                k.Stop()
                try(func() { t.Stop() })
                try(func() { t.Reset(time.Second) })
                try(func() { k.Reset(time.Second) })
                try(func() { time.NewTicker(0) })
                try(func() { time.NewTicker(time.Second).Reset(-1) })
                try(func() { none.Stop() })
                """,
                imports: ["fmt", "sync", "time"])
                == """
                time: Stop called on uninitialized Timer
                time: Reset called on uninitialized Timer
                time: Reset called on uninitialized Ticker
                non-positive interval for NewTicker
                non-positive interval for Ticker.Reset
                runtime error: invalid memory address or nil pointer dereference

                """)
    }

    /// The first error of Go's compiler for each.
    @Test func wrongCallsAreReportedAsGoReportsThem() {
        #expect(
            firstError(
                """
                t := time.NewTimer()
                _ = t
                """,
                imports: ["fmt", "sync", "time"])
                == "7:6: not enough arguments in call to time.NewTimer\n\thave ()\n\twant (time.Duration)")
        #expect(
            firstError(
                """
                t := time.NewTimer("1s")
                _ = t
                """,
                imports: ["fmt", "sync", "time"])
                == "7:20: cannot use \"1s\" (untyped string constant) as time.Duration value in argument to time.NewTimer")
        #expect(
            firstError(
                """
                t := time.NewTimer(5)
                t.Reset()
                """,
                imports: ["fmt", "sync", "time"])
                == "8:1: not enough arguments in call to t.Reset\n\thave ()\n\twant (time.Duration)")
        #expect(
            firstError(
                """
                t := time.NewTimer(time.Second)
                var n int = 3
                t.Reset(n)
                """,
                imports: ["fmt", "sync", "time"])
                == "9:9: cannot use n (variable of type int) as time.Duration value in argument to t.Reset")
        #expect(
            firstError(
                """
                t := time.NewTicker(time.Second)
                x := t.Stop()
                _ = x
                """,
                imports: ["fmt", "sync", "time"])
                == "8:6: t.Stop() (no value) used as value")
        #expect(
            firstError(
                """
                t := time.NewTimer(time.Second)
                t.C <- time.Now()
                """,
                imports: ["fmt", "sync", "time"])
                == "8:1: invalid operation: cannot send to receive-only channel t.C (variable of type <-chan time.Time)")
        #expect(
            firstError(
                """
                t := time.NewTimer(time.Second)
                _ = t.initTimer
                """,
                imports: ["fmt", "sync", "time"])
                == "8:7: t.initTimer undefined (cannot refer to unexported field initTimer)")
        #expect(
            firstError(
                """
                t := time.AfterFunc(time.Second)
                _ = t
                """,
                imports: ["fmt", "sync", "time"])
                == "7:21: not enough arguments in call to time.AfterFunc\n\thave (time.Duration)\n\twant (time.Duration, func())")
        #expect(
            firstError(
                """
                t := time.AfterFunc(time.Second, 5)
                _ = t
                """,
                imports: ["fmt", "sync", "time"])
                == "7:34: cannot use 5 (untyped int constant) as func() value in argument to time.AfterFunc")
        #expect(
            firstError(
                """
                t := time.AfterFunc(time.Second, func(int) {})
                _ = t
                """,
                imports: ["fmt", "sync", "time"])
                == "7:34: cannot use func(int) {} (value of type func(int)) as func() value in argument to time.AfterFunc")
        #expect(
            firstError(
                """
                var t *time.Timer = time.NewTicker(time.Second)
                _ = t
                """,
                imports: ["fmt", "sync", "time"])
                == "7:21: cannot use time.NewTicker(time.Second) (value of type *time.Ticker) as *time.Timer value in variable declaration")
    }
}
