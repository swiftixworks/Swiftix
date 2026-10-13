/// `time.Duration`: a named integer type of the run-time library, with the
/// constants, the methods, and the text Go gives it.
///
/// A duration is an integer with a name, so the rules are those of a
/// program's `type Celsius int`: an untyped constant becomes one, an `int`
/// variable does not, and `fmt` prints it by its `String` method. Its methods
/// are native, and the VM provides them as functions under the names a
/// program's methods have, which is how `fmt`, a call through an interface,
/// and a method value find them (`GoLibraryTypes`, `GoLibraryMethods`).
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change; a message pinned alone is one this dialect words in its
/// own way, at Go's position where the test says so. Three things cannot be
/// taken from Go and are derived from it: how long a run took (the tests run
/// on the VM's logical clock, where a sleep takes exactly its time), the
/// results Go gives as `int64` (an `int` here), and the methods that give a
/// `float64` (`Seconds`, `Minutes`, `Hours`), which this dialect lacks.

@testable import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go time.Duration")
struct GoDurationTests: GoTestHarness {

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

    /// Compiles `text`, one whole file, and returns what the program prints.
    private func runGoProgram(_ text: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// The message of the diagnostic that compiling `text` produces, or nil.
    private func goProgramDiagnostic(_ text: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    /// The type of a variable, a field, a parameter, a result, an element, a
    /// map value, and a channel, with zero as its zero value.
    @Test func aDurationIsANamedIntegerType() throws {
        #expect(
            try runGoMain(
                #"""
                var d time.Duration = 1500 * time.Millisecond
                var zero time.Duration
                fmt.Println(d, time.Second, d > time.Second, zero, zero == 0)
                fmt.Printf("%T %T %T %d\n", d, time.Second, 2*time.Minute, d)
                c := config{Timeout: 5 * time.Second, Backoff: []time.Duration{time.Millisecond, 2 * time.Millisecond}}
                c.Limits = map[string]time.Duration{"read": time.Minute, "write": 0}
                c.Backoff = append(c.Backoff, 4*time.Millisecond, 8)
                fmt.Println(c.Timeout, c.Backoff, c.Limits, retry(c.Timeout), total(c.Backoff...), total())
                fmt.Printf("%v %+v %T %T\n", c, c, c.Backoff, c.Limits)
                waits := make(chan time.Duration, 2)
                waits <- c.Timeout / 2
                waits <- 7
                fmt.Println(<-waits, <-waits, len(waits))
                byLength := map[time.Duration]string{time.Second: "second", time.Millisecond: "millisecond"}
                fmt.Println(byLength, byLength[time.Second], byLength[1000000])
                p := &d
                *p += time.Second
                fmt.Println(d, *p, p == nil)
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type config struct {
                        Timeout time.Duration
                        Backoff []time.Duration
                        Limits  map[string]time.Duration
                    }

                    func retry(d time.Duration) time.Duration { return d * 2 }

                    func total(durations ...time.Duration) time.Duration {
                        var sum time.Duration
                        for _, d := range durations {
                            sum += d
                        }
                        return sum
                    }
                    """)
                == """
                1.5s 1s true 0s true
                time.Duration time.Duration time.Duration 1500000000
                5s [1ms 2ms 4ms 8ns] map[read:1m0s write:0s] 10s 7.000008ms 0s
                {5s [1ms 2ms 4ms 8ns] map[read:1m0s write:0s]} {Timeout:5s Backoff:[1ms 2ms 4ms 8ns] Limits:map[read:1m0s write:0s]} []time.Duration map[string]time.Duration
                2.5s 7ns 0
                map[1ms:millisecond 1s:second] second millisecond
                2.5s 2.5s false

                """)
    }

    /// `time.Nanosecond` to `time.Hour` are constants of the type, and an
    /// operator between two durations gives a duration.
    @Test func theUnitsOfTimeAreDurations() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(time.Nanosecond, time.Microsecond, time.Millisecond, time.Second, time.Minute, time.Hour)
                fmt.Println(int(time.Nanosecond), int(time.Microsecond), int(time.Millisecond), int(time.Second), int(time.Minute), int(time.Hour))
                n := 3
                d := time.Duration(n) * time.Millisecond
                fmt.Println(d, 2*time.Second, time.Second*2, d/time.Millisecond, d%time.Second, int(d/time.Millisecond))
                fmt.Println(d < time.Second, d == 3*time.Millisecond, d != 0, -d, +d, d+time.Hour, time.Hour-d)
                fmt.Println(time.Hour/time.Minute, time.Hour%(7*time.Minute), time.Second<<1, time.Second>>1, time.Second&0xff, time.Second|1, time.Second^1)
                d += time.Second
                d *= 2
                d -= 6 * time.Millisecond
                d /= 4
                d++
                d--
                d %= time.Second
                fmt.Println(d)
                for backoff := time.Millisecond; backoff < 20*time.Millisecond; backoff *= 2 {
                    fmt.Print(backoff, " ")
                }
                fmt.Println()
                switch d {
                case 0:
                    fmt.Println("zero")
                case 500 * time.Millisecond:
                    fmt.Println("half a second")
                default:
                    fmt.Println("other")
                }
                """,
                imports: ["fmt", "time"])
                == "1ns 1µs 1ms 1s 1m0s 1h0m0s\n1 1000 1000000 1000000000 60000000000 3600000000000\n3ms 2s 2s 3ns 3ms 3\ntrue true true -3ms 3ms 1h0m0.003s 59m59.997s\n60ns 4m0s 2s 500ms 0s 1.000000001s 1.000000001s\n500ms\n1ms 2ms 4ms 8ms 16ms \nhalf a second\n")
    }

    /// As for any named integer type: `time.Sleep(100)` and `d * 2` are legal,
    /// and a constant declared from durations is one.
    @Test func anUntypedConstantBecomesADuration() throws {
        #expect(
            try runGoMain(
                #"""
                var d time.Duration = 100
                d = d*2 + 50
                e := plain * time.Millisecond
                fmt.Println(d, e, timeout, timeout*2, 2*timeout, timeout/plain, retry(100), retry(plain), retry('a'))
                fmt.Println(short, long, tick, tock, tuck, defaultWait, d > 100, d == 250, 250 == d)
                fmt.Printf("%T %T %T %T\n", timeout, short, e, defaultWait)
                time.Sleep(100)
                time.Sleep(plain)
                time.Sleep(1 << 10)
                <-time.After(1000)
                c := config{Timeout: 5, Backoff: []time.Duration{1, 2}, Limits: map[string]time.Duration{"x": 3}}
                c.Timeout = 30
                fmt.Println(c, time.Duration(42), time.Duration(plain), time.Duration(-1))
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type config struct {
                        Timeout time.Duration
                        Backoff []time.Duration
                        Limits  map[string]time.Duration
                    }

                    func retry(d time.Duration) time.Duration { return d * 2 }

                    func total(durations ...time.Duration) time.Duration {
                        var sum time.Duration
                        for _, d := range durations {
                            sum += d
                        }
                        return sum
                    }

                    const plain = 250
                    const timeout = 5 * time.Second
                    const (
                        short time.Duration = 100
                        long                = 2 * time.Hour
                    )
                    const (
                        tick time.Duration = iota * time.Millisecond
                        tock
                        tuck
                    )

                    var defaultWait = 3 * time.Minute
                    """)
                == """
                250ns 250ms 5s 10s 10s 20ms 200ns 500ns 194ns
                100ns 2h0m0s 0s 1ms 2ms 3m0s true true true
                time.Duration time.Duration time.Duration time.Duration
                {30ns [1ns 2ns] map[x:3ns]} 42ns 250ns -1ns

                """)
    }

    /// What this dialect used to accept and Go refuses: an `int` where a
    /// duration is wanted, and the reverse. Each is reported where Go reports it,
    /// in this dialect's words; an argument of a library call names the call, as
    /// Go does.
    @Test func anIntIsNoDuration() {
        #expect(
            goMainDiagnostic(
                """
                n := 3
                time.Sleep(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to time.Sleep")
        #expect(
            goMainDiagnostic(
                """
                const k int = 3
                time.Sleep(k)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to time.Sleep")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                <-time.After(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to time.After")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                <-time.Tick(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to time.Tick")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                ctx, cancel := context.WithTimeout(context.Background(), n)
                cancel()
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt", "time"])
                == "cannot use int as time.Duration value in argument to context.WithTimeout")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                t := time.Now()
                fmt.Println(t.Add(n))
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to t.Add")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                fmt.Println(time.Now().Add(n))
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to time.Now().Add")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                n := 3
                fmt.Println(d.Round(n))
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to d.Round")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                n := 3
                fmt.Println(d.Truncate(n))
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value in argument to d.Truncate")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                fmt.Println(retry(n))
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type config struct {
                        Timeout time.Duration
                        Backoff []time.Duration
                        Limits  map[string]time.Duration
                    }

                    func retry(d time.Duration) time.Duration { return d * 2 }

                    func total(durations ...time.Duration) time.Duration {
                        var sum time.Duration
                        for _, d := range durations {
                            sum += d
                        }
                        return sum
                    }
                    """)
                == "cannot use int as time.Duration value in argument to retry")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                d := 2 * time.Second
                fmt.Println(d * n)
                """,
                imports: ["fmt", "time"])
                == "mismatched types time.Duration and int")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                d := 2 * time.Second
                fmt.Println(n + d)
                """,
                imports: ["fmt", "time"])
                == "mismatched types int and time.Duration")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                fmt.Println(n * time.Second)
                """,
                imports: ["fmt", "time"])
                == "mismatched types int and time.Duration")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                fmt.Println(time.Second > n)
                """,
                imports: ["fmt", "time"])
                == "mismatched types time.Duration and int")
        #expect(
            goMainDiagnostic(
                """
                var d time.Duration = 5
                var n int = d
                fmt.Println(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use time.Duration as int value")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                var d time.Duration = n
                fmt.Println(d)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value")
        #expect(
            goMainDiagnostic(
                """
                const timeout = 5 * time.Second
                var n int = timeout
                fmt.Println(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use time.Duration as int value")
        #expect(
            goMainDiagnostic(
                """
                var n int = time.Since(time.Now())
                fmt.Println(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use time.Duration as int value")
        #expect(
            goMainDiagnostic(
                """
                t := time.Now()
                var n int = t.Sub(t)
                fmt.Println(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use time.Duration as int value")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                c := config{Timeout: n}
                fmt.Println(c)
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type config struct {
                        Timeout time.Duration
                        Backoff []time.Duration
                        Limits  map[string]time.Duration
                    }

                    func retry(d time.Duration) time.Duration { return d * 2 }

                    func total(durations ...time.Duration) time.Duration {
                        var sum time.Duration
                        for _, d := range durations {
                            sum += d
                        }
                        return sum
                    }
                    """)
                == "cannot use int as time.Duration value in struct literal")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                var c config
                c.Timeout = n
                fmt.Println(c)
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type config struct {
                        Timeout time.Duration
                        Backoff []time.Duration
                        Limits  map[string]time.Duration
                    }

                    func retry(d time.Duration) time.Duration { return d * 2 }

                    func total(durations ...time.Duration) time.Duration {
                        var sum time.Duration
                        for _, d := range durations {
                            sum += d
                        }
                        return sum
                    }
                    """)
                == "cannot use int as time.Duration value")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                ds := []time.Duration{1}
                ds = append(ds, n)
                fmt.Println(ds)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as time.Duration value")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                waits := make(chan time.Duration, 1)
                waits <- n
                """,
                imports: ["fmt", "time"])
                == "cannot send int value on time.Duration channel")
        #expect(
            goMainDiagnostic("fmt.Println(wait())", imports: ["fmt", "time"],
                declarations: """
                    func wait() time.Duration {
                        n := 1
                        return n
                    }
                    """)
                == "cannot use int as time.Duration value in return statement")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                fmt.Println(strconv.Itoa(d))
                """,
                imports: ["fmt", "strconv", "time"])
                == "cannot use time.Duration as int value")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                fmt.Println(d + "s")
                """,
                imports: ["fmt", "time"])
                == "mismatched types time.Duration and string")
        #expect(
            goMainDiagnostic(
                """
                var d time.Duration = time.Now()
                fmt.Println(d)
                """,
                imports: ["fmt", "time"])
                == "cannot use time.Time as time.Duration value")
        #expect(
            goMainDiagnostic("fmt.Println(time.Until(5))", imports: ["fmt", "time"])
                == "cannot use int as time.Time value")
        #expect(
            goMainDiagnostic("fmt.Println(time.Duration(\"1s\"))", imports: ["fmt", "time"])
                == "cannot convert string to type time.Duration")
        #expect(
            goMainDiagnostic(
                """
                d, err := time.ParseDuration(5)
                fmt.Println(d, err)
                """,
                imports: ["fmt", "time"])
                == "cannot use int as string value")
    }

    /// Reported as Go reports them, word for word.
    @Test func theTypeIsNoValueAndAnUnknownMemberIsUndefined() {
        #expect(
            firstError(
                """
                x := time.Duration
                fmt.Println(x)
                """,
                imports: ["fmt", "time"])
                == "6:6: time.Duration (type) is not an expression")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                fmt.Println(d.Seconds2())
                """,
                imports: ["fmt", "time"])
                == "time.Duration has no field or method Seconds2")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                fmt.Println(d / 0)
                """,
                imports: ["fmt", "time"])
                == "division by zero")
    }

    /// `String`: the largest unit first, no unit that is zero before it, one
    /// unit below a second, the micro sign, and `0s`.
    @Test func aDurationPrintsAsGoPrintsIt() throws {
        #expect(
            try runGoMain(
                """
                values := []time.Duration{
                    0, 1, -1, 999, 1000, 1001, 1500, 999999, 1000000, 1000001, 1500000, 2500000,
                    999999999, 1000000000, 1000000001, 1000001000, 1100000000, 1500000000,
                    59999999999, 60000000000, 60000000001, 61000000000, 3599999999999,
                    3600000000000, 3600000000001, 3661000000000, 86400000000000, 90061001001001,
                    9223372036854775807, -9223372036854775807 - 1, -1500, -1500000, -1500000000,
                    -3661000000001, 123456789, 12345678912345, 100 * time.Hour,
                    2*time.Hour + 30*time.Minute, 150 * time.Millisecond, 7 * time.Microsecond,
                    700 * time.Microsecond, 7700 * time.Microsecond,
                }
                for _, d := range values {
                    fmt.Println(d.String(), int(d))
                }
                """,
                imports: ["fmt", "time"])
                == """
                0s 0
                1ns 1
                -1ns -1
                999ns 999
                1µs 1000
                1.001µs 1001
                1.5µs 1500
                999.999µs 999999
                1ms 1000000
                1.000001ms 1000001
                1.5ms 1500000
                2.5ms 2500000
                999.999999ms 999999999
                1s 1000000000
                1.000000001s 1000000001
                1.000001s 1000001000
                1.1s 1100000000
                1.5s 1500000000
                59.999999999s 59999999999
                1m0s 60000000000
                1m0.000000001s 60000000001
                1m1s 61000000000
                59m59.999999999s 3599999999999
                1h0m0s 3600000000000
                1h0m0.000000001s 3600000000001
                1h1m1s 3661000000000
                24h0m0s 86400000000000
                25h1m1.001001001s 90061001001001
                2562047h47m16.854775807s 9223372036854775807
                -2562047h47m16.854775808s -9223372036854775808
                -1.5µs -1500
                -1.5ms -1500000
                -1.5s -1500000000
                -1h1m1.000000001s -3661000000001
                123.456789ms 123456789
                3h25m45.678912345s 12345678912345
                100h0m0s 360000000000000
                2h30m0s 9000000000000
                150ms 150000000
                7µs 7000
                700µs 700000
                7.7ms 7700000

                """)
    }

    /// Under `%v`, `%s`, `%q`, `%x`, and `%X`, as an operand and inside a
    /// struct, a slice, an array, a map, and behind a pointer, but not behind an
    /// unexported field; `%d` and `%#v` print the integer.
    @Test func fmtPrintsADurationByItsStringMethod() throws {
        #expect(
            try runGoMain(
                #"""
                d := 1500 * time.Millisecond
                fmt.Println(d, 2*time.Second, time.Second*2, d/2, -d, time.Duration(0))
                fmt.Printf("%v|%s|%d|%10v|%-10v|%q|%x|%X|%+v|%#v|%T|%012d|%5.2v|%c\n", d, d, d, d, d, d, d, d, d, d, d, d, d, d)
                fmt.Print(d, time.Second, "x", time.Minute, 5, "\n")
                fmt.Println(fmt.Sprint(d, time.Hour), fmt.Sprintf("%v/%s/%d", d, d, d), fmt.Sprintln(d) == "1.5s\n")
                fmt.Println(span{time.Second, time.Minute}, &span{time.Second, time.Minute}, []time.Duration{1, 1000, 0}, [2]time.Duration{time.Hour, -time.Hour})
                fmt.Printf("%v %+v %#v\n", span{time.Second, 2}, span{time.Second, 2}, span{time.Second, 2})
                fmt.Printf("%v %d %#v %s\n", []time.Duration{time.Second, 90 * time.Second}, []time.Duration{time.Second}, []time.Duration{time.Second}, []time.Duration{time.Second})
                fmt.Println(map[time.Duration]string{time.Second: "s", time.Millisecond: "ms"}, map[string]time.Duration{"a": 90 * time.Second})
                p := &d
                var held any = d
                values := []any{d, p == nil, held, 5}
                fmt.Println(*p, held, values)
                fmt.Printf("%v %s %d\n", p, p, *p)
                fmt.Println(fmt.Errorf("gave up after %v (%d ns)", d, d))
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type span struct {
                        From time.Duration
                        to   time.Duration
                    }
                    """)
                == """
                1.5s 2s 2s 750ms -1.5s 0s
                1.5s|1.5s|1500000000|      1.5s|1.5s      |"1.5s"|312e3573|312E3573|1.5s|1500000000|time.Duration|001500000000|   1.|�
                1.5s 1sx1m0s 5
                1.5s 1h0m0s 1.5s/1.5s/1500000000 true
                {1s 60000000000} &{1s 60000000000} [1ns 1µs 0s] [1h0m0s -1h0m0s]
                {1s 2} {From:1s to:2} main.span{From:1000000000, to:2}
                [1s 1m30s] [1000000000] []time.Duration{1000000000} [1s]
                map[1ms:ms 1s:s] map[a:1m30s]
                1.5s 1.5s [1.5s false 1.5s 5]
                1.5s 1.5s 1500000000
                gave up after 1.5s (1500000000 ns)

                """)
        #expect(
            try runGoMain(
                #"""
                var none *time.Duration
                d := 90 * time.Second
                fmt.Println(none, &d == nil)
                fmt.Printf("%v|%s|%d|%q|%x|%5v|%-5v|\n", none, none, none, none, none, none, none)
                b := box{P: none, D: d, A: d, h: d, S: []time.Duration{d, 0}, M: map[string]*time.Duration{"n": nil}}
                fmt.Println(b.D, b.A, b.S, b.M, b.P)
                fmt.Printf("%v\n%+v\n", b, b)
                fmt.Printf("%8v|%-8v|%08v|%.2v|%8.3s|%q|% x|%#x|%X\n", d, d, d, d, d, d, d, d, d)
                fmt.Printf("%v %v\n", []any{d, none, &d == nil}, [2]any{d, 1})
                fmt.Printf("%s %v %d\n", []time.Duration{d}, map[time.Duration]time.Duration{d: d}, map[time.Duration]time.Duration{d: d})
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type box struct {
                        P *time.Duration
                        D time.Duration
                        A any
                        h time.Duration
                        S []time.Duration
                        M map[string]*time.Duration
                    }
                    """)
                == """
                <nil> false
                <nil>|<nil>|0|<nil>|<nil>|<nil>|<nil>|
                1m30s 1m30s [1m30s 0s] map[n:<nil>] <nil>
                {<nil> 1m30s 1m30s 90000000000 [1m30s 0s] map[n:<nil>]}
                {P:<nil> D:1m30s A:1m30s h:90000000000 S:[1m30s 0s] M:map[n:<nil>]}
                   1m30s|1m30s   |0001m30s|1m|     1m3|"1m30s"|31 6d 33 30 73|0x316d333073|316D333073
                [1m30s <nil> false] [1m30s 1]
                [1m30s] map[1m30s:1m30s] map[90000000000:90000000000]

                """)
    }

    /// The text of a duration is computed where `fmt` formats it: printing a
    /// thousand of them is one instruction, not a method frame for each. The
    /// program and what it prints are Go's.
    @Test func fmtPrintsADurationWithoutCallingAFunction() throws {
        let output = try runGoMain(
            """
            samples := []time.Duration{1500 * time.Microsecond}
            for len(samples) < 1024 {
                samples = append(samples, samples...)
            }
            text := fmt.Sprint(samples)
            fmt.Println(len(samples), len(text), text[:16])
            """,
            imports: ["fmt", "time"],
            machine: GoVirtualMachine(maximumInstructions: 1_000))

        #expect(output == "1024 6145 [1.5ms 1.5ms 1.5\n")
        #expect(
            try GoLibraryMethods.text(of: .int(1_500_000_000), owner: "time.Duration") { _ in .nilValue }
                == "1.5s")
        #expect(
            try GoLibraryMethods.text(of: .nilValue, owner: "*time.Duration") { _ in .nilValue }
                == "<nil>")
        #expect(try GoLibraryMethods.text(of: .int(5), owner: "interval") { _ in .nilValue } == nil)
    }

    /// `Nanoseconds`, `Microseconds`, and `Milliseconds` (an `int` here, an
    /// `int64` in Go), `Abs`, and a call on a constant, a field, an element, a
    /// result, and a pointer.
    @Test func theMethodsGiveIntegersAndDurations() throws {
        #expect(
            try runGoMain(
                """
                d := 1500 * time.Millisecond
                fmt.Println(int(d.Nanoseconds()), int(d.Microseconds()), int(d.Milliseconds()), d.String(), d.Abs(), (-d).Abs())
                fmt.Println(int((-d).Microseconds()), int((-d).Milliseconds()), int(time.Duration(999).Microseconds()), int(time.Duration(-999).Microseconds()))
                lowest := time.Duration(-9223372036854775807 - 1)
                fmt.Println(lowest.Abs(), int(lowest.Abs()), time.Duration(0).Abs())
                c := config{Timeout: 90 * time.Second, Backoff: []time.Duration{time.Millisecond}, Limits: map[string]time.Duration{"x": time.Hour}}
                fmt.Println(time.Second.String(), (2 * time.Hour).String(), c.Timeout.String(), c.Backoff[0].String(), c.Limits["x"].String(), retry(c.Timeout).String())
                p := &d
                fmt.Println(p.String(), p.Abs(), int(p.Milliseconds()), p.Round(time.Second), (&c).Timeout.Truncate(time.Minute))
                text := d.String() + "/" + time.Minute.String()
                fmt.Println(text, len(d.String()))
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type config struct {
                        Timeout time.Duration
                        Backoff []time.Duration
                        Limits  map[string]time.Duration
                    }

                    func retry(d time.Duration) time.Duration { return d * 2 }

                    func total(durations ...time.Duration) time.Duration {
                        var sum time.Duration
                        for _, d := range durations {
                            sum += d
                        }
                        return sum
                    }
                    """)
                == """
                1500000000 1500000 1500 1.5s 1.5s 1.5s
                -1500000 -1500 0 0
                2562047h47m16.854775807s 9223372036854775807 0s
                1s 2h0m0s 1m30s 1ms 1h0m0s 3m0s
                1.5s 1.5s 1500 2s 1m0s
                1.5s/1m0s 4

                """)
    }

    /// A multiple of the unit, halves away from zero for `Round`, toward zero
    /// for `Truncate`, the duration itself for a unit that is not positive, and
    /// the largest or smallest duration where the result has no other.
    @Test func roundAndTruncateFollowGo() throws {
        #expect(
            try runGoMain(
                """
                values := []time.Duration{
                    0, 1, -1, 1499, 1500, 1501, -1499, -1500, -1501, 2500 * time.Millisecond,
                    90 * time.Second, 3599 * time.Second, -90 * time.Second, 12345678912345,
                    9223372036854775807, -9223372036854775807 - 1,
                }
                units := []time.Duration{
                    0, -1, 1, 2, 3, 1000, time.Millisecond, time.Second, time.Minute, time.Hour,
                    7 * time.Second, 9223372036854775807, 1 << 62,
                }
                for _, d := range values {
                    for _, m := range units {
                        fmt.Print(d.Round(m), " ", d.Truncate(m), " ", int(d.Round(m)), " ", int(d.Truncate(m)), "; ")
                    }
                    fmt.Println()
                }
                """,
                imports: ["fmt", "time"])
                == "0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n1ns 1ns 1 1; 1ns 1ns 1 1; 1ns 1ns 1 1; 2ns 0s 2 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n-1ns -1ns -1 -1; -1ns -1ns -1 -1; -1ns -1ns -1 -1; -2ns 0s -2 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n1.499µs 1.499µs 1499 1499; 1.499µs 1.499µs 1499 1499; 1.499µs 1.499µs 1499 1499; 1.5µs 1.498µs 1500 1498; 1.5µs 1.497µs 1500 1497; 1µs 1µs 1000 1000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n1.5µs 1.5µs 1500 1500; 1.5µs 1.5µs 1500 1500; 1.5µs 1.5µs 1500 1500; 1.5µs 1.5µs 1500 1500; 1.5µs 1.5µs 1500 1500; 2µs 1µs 2000 1000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n1.501µs 1.501µs 1501 1501; 1.501µs 1.501µs 1501 1501; 1.501µs 1.501µs 1501 1501; 1.502µs 1.5µs 1502 1500; 1.5µs 1.5µs 1500 1500; 2µs 1µs 2000 1000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n-1.499µs -1.499µs -1499 -1499; -1.499µs -1.499µs -1499 -1499; -1.499µs -1.499µs -1499 -1499; -1.5µs -1.498µs -1500 -1498; -1.5µs -1.497µs -1500 -1497; -1µs -1µs -1000 -1000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n-1.5µs -1.5µs -1500 -1500; -1.5µs -1.5µs -1500 -1500; -1.5µs -1.5µs -1500 -1500; -1.5µs -1.5µs -1500 -1500; -1.5µs -1.5µs -1500 -1500; -2µs -1µs -2000 -1000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n-1.501µs -1.501µs -1501 -1501; -1.501µs -1.501µs -1501 -1501; -1.501µs -1.501µs -1501 -1501; -1.502µs -1.5µs -1502 -1500; -1.5µs -1.5µs -1500 -1500; -2µs -1µs -2000 -1000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n2.5s 2.5s 2500000000 2500000000; 2.5s 2.5s 2500000000 2500000000; 2.5s 2.5s 2500000000 2500000000; 2.5s 2.5s 2500000000 2500000000; 2.499999999s 2.499999999s 2499999999 2499999999; 2.5s 2.5s 2500000000 2500000000; 2.5s 2.5s 2500000000 2500000000; 3s 2s 3000000000 2000000000; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; 0s 0s 0 0; \n1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 1m30s 1m30s 90000000000 90000000000; 2m0s 1m0s 120000000000 60000000000; 0s 0s 0 0; 1m31s 1m24s 91000000000 84000000000; 0s 0s 0 0; 0s 0s 0 0; \n59m59s 59m59s 3599000000000 3599000000000; 59m59s 59m59s 3599000000000 3599000000000; 59m59s 59m59s 3599000000000 3599000000000; 59m59s 59m59s 3599000000000 3599000000000; 59m59.000000001s 59m58.999999998s 3599000000001 3598999999998; 59m59s 59m59s 3599000000000 3599000000000; 59m59s 59m59s 3599000000000 3599000000000; 59m59s 59m59s 3599000000000 3599000000000; 1h0m0s 59m0s 3600000000000 3540000000000; 1h0m0s 0s 3600000000000 0; 59m58s 59m58s 3598000000000 3598000000000; 0s 0s 0 0; 0s 0s 0 0; \n-1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -1m30s -1m30s -90000000000 -90000000000; -2m0s -1m0s -120000000000 -60000000000; 0s 0s 0 0; -1m31s -1m24s -91000000000 -84000000000; 0s 0s 0 0; 0s 0s 0 0; \n3h25m45.678912345s 3h25m45.678912345s 12345678912345 12345678912345; 3h25m45.678912345s 3h25m45.678912345s 12345678912345 12345678912345; 3h25m45.678912345s 3h25m45.678912345s 12345678912345 12345678912345; 3h25m45.678912346s 3h25m45.678912344s 12345678912346 12345678912344; 3h25m45.678912345s 3h25m45.678912345s 12345678912345 12345678912345; 3h25m45.678912s 3h25m45.678912s 12345678912000 12345678912000; 3h25m45.679s 3h25m45.678s 12345679000000 12345678000000; 3h25m46s 3h25m45s 12346000000000 12345000000000; 3h26m0s 3h25m0s 12360000000000 12300000000000; 3h0m0s 3h0m0s 10800000000000 10800000000000; 3h25m48s 3h25m41s 12348000000000 12341000000000; 0s 0s 0 0; 0s 0s 0 0; \n2562047h47m16.854775807s 2562047h47m16.854775807s 9223372036854775807 9223372036854775807; 2562047h47m16.854775807s 2562047h47m16.854775807s 9223372036854775807 9223372036854775807; 2562047h47m16.854775807s 2562047h47m16.854775807s 9223372036854775807 9223372036854775807; 2562047h47m16.854775807s 2562047h47m16.854775806s 9223372036854775807 9223372036854775806; 2562047h47m16.854775806s 2562047h47m16.854775806s 9223372036854775806 9223372036854775806; 2562047h47m16.854775807s 2562047h47m16.854775s 9223372036854775807 9223372036854775000; 2562047h47m16.854775807s 2562047h47m16.854s 9223372036854775807 9223372036854000000; 2562047h47m16.854775807s 2562047h47m16s 9223372036854775807 9223372036000000000; 2562047h47m0s 2562047h47m0s 9223372020000000000 9223372020000000000; 2562047h47m16.854775807s 2562047h0m0s 9223372036854775807 9223369200000000000; 2562047h47m16.854775807s 2562047h47m12s 9223372036854775807 9223372032000000000; 2562047h47m16.854775807s 2562047h47m16.854775807s 9223372036854775807 9223372036854775807; 2562047h47m16.854775807s 1281023h53m38.427387904s 9223372036854775807 4611686018427387904; \n-2562047h47m16.854775808s -2562047h47m16.854775808s -9223372036854775808 -9223372036854775808; -2562047h47m16.854775808s -2562047h47m16.854775808s -9223372036854775808 -9223372036854775808; -2562047h47m16.854775808s -2562047h47m16.854775808s -9223372036854775808 -9223372036854775808; -2562047h47m16.854775808s -2562047h47m16.854775808s -9223372036854775808 -9223372036854775808; -2562047h47m16.854775808s -2562047h47m16.854775806s -9223372036854775808 -9223372036854775806; -2562047h47m16.854775808s -2562047h47m16.854775s -9223372036854775808 -9223372036854775000; -2562047h47m16.854775808s -2562047h47m16.854s -9223372036854775808 -9223372036854000000; -2562047h47m16.854775808s -2562047h47m16s -9223372036854775808 -9223372036000000000; -2562047h47m0s -2562047h47m0s -9223372020000000000 -9223372020000000000; -2562047h47m16.854775808s -2562047h0m0s -9223372036854775808 -9223369200000000000; -2562047h47m16.854775808s -2562047h47m12s -9223372036854775808 -9223372032000000000; -2562047h47m16.854775807s -2562047h47m16.854775807s -9223372036854775807 -9223372036854775807; -2562047h47m16.854775808s -2562047h47m16.854775808s -9223372036854775808 -9223372036854775808; \n")
    }

    /// `time.Sleep`, `time.After`, `time.Tick`, `time.Since`, `time.Until`,
    /// `t.Sub`, `t.Add`, and `context.WithTimeout`. The program prints nothing that
    /// depends on how long it ran.
    @Test func whatTheLibraryTakesAndGivesIsADuration() throws {
        #expect(
            try runGoMain(
                #"""
                start := time.Unix(1760000000, 0)
                later := start.Add(90 * time.Minute)
                fmt.Println(later.Sub(start), start.Sub(later), later.Add(-30*time.Minute).Sub(start), start.Add(0).Sub(start))
                fmt.Printf("%T %T %T\n", later.Sub(start), time.Since(start), time.Until(start))
                var elapsed time.Duration = later.Sub(start)
                fmt.Println(elapsed.Round(time.Hour), elapsed > time.Hour, elapsed/time.Minute, int(elapsed/time.Minute))
                began := time.Now()
                time.Sleep(2 * time.Millisecond)
                fmt.Println(time.Since(began) >= 2*time.Millisecond, time.Until(began) < 0, time.Until(began.Add(time.Hour)) > 59*time.Minute)
                select {
                case fired := <-time.After(time.Millisecond):
                    fmt.Println(fired.Sub(began) >= time.Millisecond)
                }
                tick := time.Tick(time.Millisecond)
                first := <-tick
                second := <-tick
                fmt.Println(second.Sub(first) > 0)
                wait := 5 * time.Millisecond
                ctx, cancel := context.WithTimeout(context.Background(), wait)
                time.Sleep(4 * wait)
                fmt.Println(ctx.Err())
                cancel()
                """#,
                imports: ["context", "fmt", "time"])
                == """
                1h30m0s -1h30m0s 1h0m0s 0s
                time.Duration time.Duration time.Duration
                2h0m0s true 90ns 90
                true true true
                true
                true
                context deadline exceeded

                """)
    }

    /// On the VM's logical clock a sleep takes its time and no more, so what
    /// `time.Since`, `time.Until`, and `t.Sub` give prints as that duration. Go's
    /// clock gives a little more each run, in the same format.
    @Test func theLogicalClockMeasuresASleepExactly() throws {
        let output = try runGoMain(
            """
            start := time.Now()
            time.Sleep(1500 * time.Millisecond)
            now := time.Now()
            fmt.Println(time.Since(start), now.Sub(start), start.Sub(now), time.Until(start))
            fired := <-time.After(250 * time.Millisecond)
            fmt.Println(fired.Sub(start), time.Since(now), time.Until(now.Add(time.Hour)))
            fmt.Printf("%v %d %T\\n", time.Since(start), time.Since(start), time.Since(start))
            """,
            imports: ["fmt", "time"])

        #expect(
            output == """
                1.5s 1.5s -1.5s -1.5s
                1.75s 250ms 59m59.75s
                1.75s 1750000000 time.Duration

                """)
    }

    /// `time.ParseDuration`, with Go's errors for what is no duration.
    @Test func parseDurationReadsWhatStringWrites() throws {
        #expect(
            try runGoMain(
                #"""
                inputs := []string{
                    "0", "+0", "-0", "", "-", "+", "5", "5s", "+5s", "-5s", "1h", "1h30m", "1h30m15.5s",
                    "1.5h", ".5s", "5.s", ".s", "-.s", "1.5", "1x", "1ss", "1 s", " 1s", "1s ", "300ms",
                    "-1.5h", "1.5h30m", "1us", "1µs", "1μs", "1ns", "1.5ns", "0.5ns", "0.000000001s",
                    "0.0000000001s", "1.000000001s", "9223372036854775807ns", "9223372036854775808ns",
                    "-9223372036854775808ns", "-9223372036854775809ns", "2562047h47m16.854775807s",
                    "2562047h47m16.854775808s", "2562048h", "1d", "1m1m1m", "0ms0h", "00001h", "1e3s",
                    "3.14159265358979323846s", "0.33333333333333333333333333333333h",
                    "9223372036854775808ns9223372036854775808ns", "1h\"x", "1\\s", "\tx", "1é",
                    "100000000000000000000ns", "1.5ms2.5us", "1h-5m", "1.2.3s", "3000000h", "ms", "1MS",
                }
                for _, input := range inputs {
                    d, err := time.ParseDuration(input)
                    fmt.Printf("%q %v %d %v\n", input, d, d, err)
                }
                d, err := time.ParseDuration("90m")
                fmt.Println(d, d == 90*time.Minute, err == nil, err)
                _, err = time.ParseDuration("soon")
                fmt.Printf("%T %v %q\n", err, err, err.Error())
                for _, d := range []time.Duration{0, 1, 1500, 90 * time.Second, -36 * time.Hour, 9223372036854775807} {
                    back, err := time.ParseDuration(d.String())
                    fmt.Print(back == d, err == nil, " ")
                }
                fmt.Println()
                """#,
                imports: ["fmt", "time"])
                == "\"0\" 0s 0 <nil>\n\"+0\" 0s 0 <nil>\n\"-0\" 0s 0 <nil>\n\"\" 0s 0 time: invalid duration \"\"\n\"-\" 0s 0 time: invalid duration \"-\"\n\"+\" 0s 0 time: invalid duration \"+\"\n\"5\" 0s 0 time: missing unit in duration \"5\"\n\"5s\" 5s 5000000000 <nil>\n\"+5s\" 5s 5000000000 <nil>\n\"-5s\" -5s -5000000000 <nil>\n\"1h\" 1h0m0s 3600000000000 <nil>\n\"1h30m\" 1h30m0s 5400000000000 <nil>\n\"1h30m15.5s\" 1h30m15.5s 5415500000000 <nil>\n\"1.5h\" 1h30m0s 5400000000000 <nil>\n\".5s\" 500ms 500000000 <nil>\n\"5.s\" 5s 5000000000 <nil>\n\".s\" 0s 0 time: invalid duration \".s\"\n\"-.s\" 0s 0 time: invalid duration \"-.s\"\n\"1.5\" 0s 0 time: missing unit in duration \"1.5\"\n\"1x\" 0s 0 time: unknown unit \"x\" in duration \"1x\"\n\"1ss\" 0s 0 time: unknown unit \"ss\" in duration \"1ss\"\n\"1 s\" 0s 0 time: unknown unit \" s\" in duration \"1 s\"\n\" 1s\" 0s 0 time: invalid duration \" 1s\"\n\"1s \" 0s 0 time: unknown unit \"s \" in duration \"1s \"\n\"300ms\" 300ms 300000000 <nil>\n\"-1.5h\" -1h30m0s -5400000000000 <nil>\n\"1.5h30m\" 2h0m0s 7200000000000 <nil>\n\"1us\" 1µs 1000 <nil>\n\"1µs\" 1µs 1000 <nil>\n\"1μs\" 1µs 1000 <nil>\n\"1ns\" 1ns 1 <nil>\n\"1.5ns\" 1ns 1 <nil>\n\"0.5ns\" 0s 0 <nil>\n\"0.000000001s\" 1ns 1 <nil>\n\"0.0000000001s\" 0s 0 <nil>\n\"1.000000001s\" 1.000000001s 1000000001 <nil>\n\"9223372036854775807ns\" 2562047h47m16.854775807s 9223372036854775807 <nil>\n\"9223372036854775808ns\" 0s 0 time: invalid duration \"9223372036854775808ns\"\n\"-9223372036854775808ns\" -2562047h47m16.854775808s -9223372036854775808 <nil>\n\"-9223372036854775809ns\" 0s 0 time: invalid duration \"-9223372036854775809ns\"\n\"2562047h47m16.854775807s\" 2562047h47m16.854775807s 9223372036854775807 <nil>\n\"2562047h47m16.854775808s\" 0s 0 time: invalid duration \"2562047h47m16.854775808s\"\n\"2562048h\" 0s 0 time: invalid duration \"2562048h\"\n\"1d\" 0s 0 time: unknown unit \"d\" in duration \"1d\"\n\"1m1m1m\" 3m0s 180000000000 <nil>\n\"0ms0h\" 0s 0 <nil>\n\"00001h\" 1h0m0s 3600000000000 <nil>\n\"1e3s\" 0s 0 time: unknown unit \"e\" in duration \"1e3s\"\n\"3.14159265358979323846s\" 3.141592653s 3141592653 <nil>\n\"0.33333333333333333333333333333333h\" 20m0s 1200000000000 <nil>\n\"9223372036854775808ns9223372036854775808ns\" 0s 0 <nil>\n\"1h\\\"x\" 0s 0 time: unknown unit \"h\\\"x\" in duration \"1h\\\"x\"\n\"1\\\\s\" 0s 0 time: unknown unit \"\\\\s\" in duration \"1\\\\s\"\n\"\\tx\" 0s 0 time: invalid duration \"\\x09x\"\n\"1é\" 0s 0 time: unknown unit \"\\xc3\\xa9\" in duration \"1\\xc3\\xa9\"\n\"100000000000000000000ns\" 0s 0 time: invalid duration \"100000000000000000000ns\"\n\"1.5ms2.5us\" 1.5025ms 1502500 <nil>\n\"1h-5m\" 0s 0 time: unknown unit \"h-\" in duration \"1h-5m\"\n\"1.2.3s\" 0s 0 time: missing unit in duration \"1.2.3s\"\n\"3000000h\" 0s 0 time: invalid duration \"3000000h\"\n\"ms\" 0s 0 time: invalid duration \"ms\"\n\"1MS\" 0s 0 time: unknown unit \"MS\" in duration \"1MS\"\n1h30m0s true true <nil>\n*errors.errorString time: invalid duration \"soon\" \"time: invalid duration \\\"soon\\\"\"\ntrue true true true true true true true true true true true \n")
    }

    /// An interface value that holds a duration holds a `time.Duration`: `%T`
    /// says so, it asserts as one and not as an `int`, it equals another, and it
    /// implements the interfaces its methods satisfy, also for an assertion and a
    /// call through the interface.
    @Test func aDurationKeepsItsTypeInAnInterface() throws {
        #expect(
            try runGoMain(
                #"""
                d := 90 * time.Second
                var a any = d
                var s stringer = d
                var r rounder = d
                back, ok := a.(time.Duration)
                _, isInt := a.(int)
                fmt.Println(a, s, r, back, ok, isInt)
                fmt.Printf("%T %T %T %v %d\n", a, s, r, a, a)
                fmt.Println(s.String(), r.Round(time.Minute), r.Abs(), r.Round(time.Hour).String())
                var b any = 90 * time.Second
                var n any = int(d)
                fmt.Println(a == b, a == n, a != nil)
                held, isStringer := a.(stringer)
                _, isRounder := a.(rounder)
                _, isNamed := a.(named)
                _, isAbsInt := a.(absInt)
                fmt.Println(held, held.String(), isStringer, isRounder, isNamed, isAbsInt)
                var five any = 5
                _, intIsStringer := five.(stringer)
                var p any = &d
                _, pointerIsStringer := p.(stringer)
                fmt.Println(intIsStringer, pointerIsStringer, p.(stringer).String(), describe(d), describe(&d), describe(5), describe(time.Minute))
                mixed := []any{time.Second, 5, "x", zero, []time.Duration{1}}
                for _, v := range mixed {
                    fmt.Printf("%v %T|", v, v)
                }
                fmt.Println()
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type stringer interface{ String() string }

                    type rounder interface {
                        Round(time.Duration) time.Duration
                        Abs() time.Duration
                    }

                    type absInt interface{ Abs() int }

                    type named interface {
                        String() string
                        Name() string
                    }

                    var zero time.Duration

                    func describe(v any) string {
                        if d, ok := v.(time.Duration); ok {
                            return "duration " + d.String()
                        }
                        if s, ok := v.(stringer); ok {
                            return "stringer " + s.String()
                        }
                        return fmt.Sprint("other ", v)
                    }
                    """)
                == """
                1m30s 1m30s 1m30s 1m30s true false
                time.Duration time.Duration time.Duration 1m30s 90000000000
                1m30s 2m0s 1m30s 0s
                true false true
                1m30s 1m30s true true false false
                false true 1m30s duration 1m30s stringer 1m30s other 5 duration 1m0s
                1s time.Duration|5 int|x string|0s time.Duration|[1ns] []time.Duration|

                """)
        #expect(
            try runGoMain(
                #"""
                defer func() {
                    r := recover()
                    fmt.Printf("%v %T\n", r, r)
                }()
                var a any = time.Second
                fmt.Println(a.(int))
                """#,
                imports: ["fmt", "time"])
                == """
                interface conversion: interface {} is time.Duration, not int *runtime.TypeAssertionError

                """)
        #expect(
            try runGoMain(
                """
                defer func() { fmt.Println(recover()) }()
                var a any = 5
                fmt.Println(a.(time.Duration))
                """,
                imports: ["fmt", "time"])
                == "interface conversion: interface {} is int, not time.Duration\n")
        #expect(
            try runGoMain(
                """
                defer func() { fmt.Println(recover()) }()
                var a any = time.Second
                fmt.Println(a.(named))
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type stringer interface{ String() string }

                    type rounder interface {
                        Round(time.Duration) time.Duration
                        Abs() time.Duration
                    }

                    type absInt interface{ Abs() int }

                    type named interface {
                        String() string
                        Name() string
                    }
                    """)
                == """
                interface conversion: time.Duration is not main.named: missing method Name

                """)
        #expect(
            try runGoMain(
                """
                defer func() { fmt.Println(recover()) }()
                var a any = time.Second
                fmt.Println(a.(absInt))
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type stringer interface{ String() string }

                    type rounder interface {
                        Round(time.Duration) time.Duration
                        Abs() time.Duration
                    }

                    type absInt interface{ Abs() int }

                    type named interface {
                        String() string
                        Name() string
                    }
                    """)
                == """
                interface conversion: time.Duration is not main.absInt: missing method Abs

                """)
        #expect(
            goMainDiagnostic(
                """
                var s absInt = time.Second
                fmt.Println(s)
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type stringer interface{ String() string }

                    type rounder interface {
                        Round(time.Duration) time.Duration
                        Abs() time.Duration
                    }

                    type absInt interface{ Abs() int }

                    type named interface {
                        String() string
                        Name() string
                    }
                    """)
                == "cannot use time.Duration as absInt value")
    }

    /// It has the integer and none of the methods, as in Go: it prints as a
    /// number unless it declares a `String` of its own, and converts both ways.
    @Test func aTypeDefinedOverADurationIsAnotherType() throws {
        #expect(
            try runGoMain(
                #"""
                t := Timeout(1500 * time.Millisecond)
                i := interval(time.Minute)
                fmt.Println(t, i, time.Duration(i), Timeout(i), time.Duration(t).Round(time.Second), i*2, i > 5)
                fmt.Printf("%v %d %T %T %s %v\n", t, t, t, i, t, []interval{1, 2})
                var a any = i
                _, isDuration := a.(time.Duration)
                _, isStringer := a.(stringer)
                back, isInterval := a.(interval)
                fmt.Println(isDuration, isStringer, back, isInterval)
                var s stringer = t
                fmt.Println(s, s.String())
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type stringer interface{ String() string }

                    type rounder interface {
                        Round(time.Duration) time.Duration
                        Abs() time.Duration
                    }

                    type absInt interface{ Abs() int }

                    type named interface {
                        String() string
                        Name() string
                    }

                    type Timeout time.Duration

                    func (t Timeout) String() string { return "timeout(" + time.Duration(t).String() + ")" }

                    type interval time.Duration
                    """)
                == """
                timeout(1.5s) 60000000000 1m0s timeout(1m0s) 2s 120000000000 true
                timeout(1.5s) 1500000000 main.Timeout main.interval timeout(1.5s) [1 2]
                false false 60000000000 true
                timeout(1.5s) timeout(1.5s)

                """)
        #expect(
            goMainDiagnostic(
                """
                t := interval(time.Second)
                fmt.Println(t.String())
                """,
                imports: ["fmt", "time"],
                declarations: "type interval time.Duration")
                == "interval has no field or method String")
        #expect(
            goMainDiagnostic(
                """
                t := interval(time.Second)
                time.Sleep(t)
                """,
                imports: ["fmt", "time"],
                declarations: "type interval time.Duration")
                == "cannot use interval as time.Duration value in argument to time.Sleep")
        #expect(
            goMainDiagnostic(
                """
                var t interval = time.Second
                fmt.Println(t)
                """,
                imports: ["fmt", "time"],
                declarations: "type interval time.Duration")
                == "cannot use time.Duration as interval value")
    }

    /// A method value has its receiver, read when the method is selected.
    @Test func aMethodOfADurationIsAValue() throws {
        #expect(
            try runGoMain(
                """
                d := 90 * time.Second
                text := d.String
                round := d.Round
                d = time.Hour
                fmt.Println(text(), round(time.Minute), round(time.Hour), d.String())
                call := func(f func() string) string { return f() }
                fmt.Println(call(d.String), call(time.Millisecond.String), call((2 * d).String))
                p := &d
                abs := p.Abs
                *p = -time.Second
                fmt.Println(abs(), p.Abs())
                fs := []func(time.Duration) time.Duration{d.Round, d.Truncate}
                for _, f := range fs {
                    fmt.Print(f(0), " ")
                }
                fmt.Println()
                defer fmt.Println("deferred")
                defer d.String()
                go d.Round(time.Second)
                """,
                imports: ["fmt", "time"])
                == "1m30s 2m0s 0s 1h0m0s\n1h0m0s 1ms 2h0m0s\n1h0m0s 1s\n-1s -1s \ndeferred\n")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                var s string = d.String
                fmt.Println(s)
                """,
                imports: ["fmt", "time"])
                == "cannot use func() string as string value")
    }

    /// Behind an import that names the package, behind one that lends its
    /// names, in a type a function declares, under an alias, and in a function
    /// literal that captures a duration.
    @Test func everyPassSeesTheType() throws {
        #expect(
            try runGoProgram(
                #"""
                package main

                import (
                    f "fmt"
                    t "time"
                )

                type D = t.Duration

                type config struct{ Timeout t.Duration }

                func wait(d D) D { return d + t.Millisecond }

                func main() {
                    type local t.Duration
                    type pair struct{ a, b t.Duration }
                    var d t.Duration = 1500 * t.Millisecond
                    var e D = t.Second
                    time := 5
                    f.Println(d, e, wait(d), t.Duration(time)*t.Second, local(d), pair{d, e}, config{d})
                    f.Printf("%T %T %T %v\n", d, e, local(d), d.Round(t.Second))
                    x, err := t.ParseDuration("3m")
                    f.Println(x, err, D(7), t.Duration(7).String(), D(7).String())
                    t.Sleep(1)
                    f.Println(t.Since(t.Now()) < t.Second)
                    grow := func() { d *= 2 }
                    double := func(x t.Duration) t.Duration { return x + d }
                    grow()
                    f.Println(d, double(t.Millisecond), func() string { return d.String() }())
                }
                """#)
                == """
                1.5s 1s 1.501s 5s 1500000000 {1500000000 1000000000} {1.5s}
                time.Duration time.Duration main.local 2s
                3m0s <nil> 7ns 7ns 7ns
                true
                3s 3.001s 3s

                """)
        #expect(
            try runGoProgram(
                """
                package main

                import (
                    . "fmt"
                    . "time"
                )

                func main() {
                    var d Duration = 90 * Second
                    Println(d, Minute, d > Minute, Duration(5), d.Round(Minute), Since(Now()) < Hour)
                    parsed, err := ParseDuration("1.5h")
                    Println(parsed, err)
                    Sleep(Millisecond)
                }
                """)
                == "1m30s 1m0s true 5ns 2m0s true\n1h30m0s <nil>\n")
        #expect(
            goProgramDiagnostic(
                """
                package main

                import t "time"

                func main() {
                    n := 3
                    t.Sleep(n)
                }
                """)
                == "cannot use int as time.Duration value in argument to t.Sleep")
    }

    /// A recovered duration is the value with its type, and one nothing
    /// recovers ends the program with the text of its `String`, as in Go.
    @Test func aPanicWithADurationSaysItsText() throws {
        #expect(throws: GoRuntimeError.panicError("1.5s")) {
            _ = try runGoMain("panic(1500 * time.Millisecond)", imports: ["time"])
        }
        #expect(
            try runGoMain(
                #"""
                defer func() {
                    r := recover()
                    d, ok := r.(time.Duration)
                    fmt.Printf("%v %T %v %v\n", r, r, d, ok)
                }()
                panic(1500 * time.Millisecond)
                """#,
                imports: ["fmt", "time"])
                == "1.5s time.Duration 1.5s true\n")
    }

    /// Constants, variables, fields, parameters, and results of the type in
    /// packages that import `time` under its own name and under another, used by
    /// a package that does not import it at all.
    @Test func durationsCrossThePackagesOfAModule() throws {
        let packages = [
            GoPackageSource(
                importPath: "example/m",
                sources: [
                    GoSourceFile(
                        path: "/m/main.go",
                        text: #"""
                            package main

                            import (
                                "fmt"

                                "example/m/conf"
                                "example/m/retry"
                            )

                            func main() {
                                c := conf.Default()
                                fmt.Println(c, c.Timeout, c.Idle, c.Limit(), conf.Timeout, conf.Grace, conf.Backoff)
                                c.Extend(conf.Grace)
                                c.Extend(1000)
                                fmt.Printf("%v %+v %T %T\n", c.Timeout, c, c.Timeout, conf.Timeout)
                                delays := retry.Delays(conf.Backoff[0], 4)
                                fmt.Println(delays, conf.Longest(delays...), conf.Longest(), retry.Within(c, delays[3]), retry.Within(c, conf.Timeout*2))
                                every := conf.Interval(conf.Timeout)
                                fmt.Println(every, retry.Describe(c.Idle), retry.Describe(every), retry.Describe(5), c.Timeout.Round(conf.Timeout))
                                next := retry.After(conf.Grace)
                                fmt.Println(next(), next(), conf.Timeout > c.Idle, c.Idle.String())
                                var clock conf.Clock = c.Idle + 29*conf.Timeout
                                fmt.Println(clock, clock.Round(conf.Timeout*12))
                            }
                            """#)
                ]),
            GoPackageSource(
                importPath: "example/m/conf",
                sources: [
                    GoSourceFile(
                        path: "/m/conf/conf.go",
                        text: #"""
                            package conf

                            import "time"

                            // Timeout is how long a request may take.
                            const Timeout = 5 * time.Second

                            const Grace time.Duration = 250

                            var Backoff = []time.Duration{time.Millisecond, 10 * time.Millisecond}

                            type Config struct {
                                Timeout time.Duration
                                Idle    time.Duration
                                limit   time.Duration
                            }

                            type Interval time.Duration

                            func (i Interval) String() string { return "every " + time.Duration(i).String() }

                            type Clock interface {
                                String() string
                                Round(time.Duration) time.Duration
                            }

                            func Default() Config { return Config{Timeout: Timeout, Idle: 2 * time.Minute, limit: time.Hour} }

                            func (c Config) Limit() time.Duration { return c.limit }

                            func (c *Config) Extend(by time.Duration) { c.Timeout += by }

                            func Longest(durations ...time.Duration) time.Duration {
                                var longest time.Duration
                                for _, d := range durations {
                                    if d > longest {
                                        longest = d
                                    }
                                }
                                return longest
                            }
                            """#)
                ]),
            GoPackageSource(
                importPath: "example/m/retry",
                sources: [
                    GoSourceFile(
                        path: "/m/retry/retry.go",
                        text: #"""
                            package retry

                            import (
                                t "time"

                                "example/m/conf"
                            )

                            // Delays are the waits before each of n attempts, doubling from first.
                            func Delays(first t.Duration, n int) []t.Duration {
                                var delays []t.Duration
                                for wait := first; len(delays) < n; wait *= 2 {
                                    delays = append(delays, wait)
                                }
                                return delays
                            }

                            func Within(c conf.Config, d t.Duration) bool { return d <= c.Timeout }

                            func Describe(v any) string {
                                if clock, ok := v.(conf.Clock); ok {
                                    return "clock " + clock.String() + " " + clock.Round(t.Minute).String()
                                }
                                return "no clock"
                            }

                            func After(d t.Duration) func() t.Duration {
                                return func() t.Duration {
                                    d *= 2
                                    return d
                                }
                            }
                            """#)
                ]),
        ]
        let executable = try GoCompiler.compile(packages: packages, root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output == """
                {5s 2m0s 3600000000000} 5s 2m0s 1h0m0s 5s 250ns [1ms 10ms]
                5.00000125s {Timeout:5.00000125s Idle:2m0s limit:3600000000000} time.Duration time.Duration
                [1ms 2ms 4ms 8ms] 8ms 0s true false
                every 5s clock 2m0s 2m0s no clock no clock 5s
                500ns 1µs false 2m0s
                4m25s 4m0s

                """)
    }

    /// The type exists for the checker. A program Go also accepted before
    /// compiles to the instructions it compiled to when a duration was an `int`:
    /// a unit is its number of nanoseconds, a conversion to the type is no
    /// instruction, and a method is one native call.
    @Test func aProgramThatBoxesNoDurationIsCompiledAsItWas() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    n := 3
                    time.Sleep(50 * time.Millisecond)
                    time.Sleep(time.Duration(n) * time.Second)
                    d := time.Since(time.Now())
                    if d > 2*time.Second {
                        time.Sleep(d.Round(time.Second))
                    }
                    """, imports: ["time"]))
        ])
        let main = try #require(executable.functions.first { $0.name == "main" })

        #expect(executable.functions.count == 1)
        #expect(
            main.instructions == [
                .push(.int(3)), .store(1), .load(1), .store(0),
                .push(.int(50)), .store(2), .push(.int(1_000_000)), .store(3),
                .load(2), .load(3), .multiply, .store(4), .load(4), .timeSleep,
                .push(.int(1_000_000_000)), .store(5),
                .load(0), .load(5), .multiply, .store(6), .load(6), .timeSleep,
                .call("$time.Now", argumentCount: 0), .store(8),
                .load(8), .call("$time.Since", argumentCount: 1), .store(9), .load(9), .store(7),
                .push(.int(2)), .store(10), .push(.int(1_000_000_000)), .store(11),
                .load(10), .load(11), .multiply, .store(12),
                .load(7), .load(12), .greater, .store(13), .load(13), .jumpIfFalse(51),
                .push(.int(1_000_000_000)), .store(14),
                .load(7), .load(14), .call("$time.Duration.Round", argumentCount: 2), .store(15),
                .load(15), .timeSleep,
                .return,
            ])
    }

    /// A duration converted to an interface is boxed as a defined type is,
    /// with what it is defined as, and the image has no function for its methods:
    /// the VM has them, each a native call, under the names `fmt` and a call
    /// through an interface look a method up by.
    @Test func aBoxedDurationCarriesItsDefinitionAndTheVMItsMethods() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    d := 90 * time.Second
                    var s interface{ String() string } = d
                    fmt.Println(d, []time.Duration{d}, s.String())
                    """, imports: ["fmt", "time"]))
        ])
        let boxes = executable.functions.flatMap(\.instructions).compactMap { instruction -> String? in
            if case .makeInterface(let typeName) = instruction { return typeName }
            return nil
        }

        #expect(executable.functions.map(\.name) == ["main"])
        #expect(
            boxes == [
                "$TN13:time.Duration\n13:time.Durationm",
                "$TN13:time.Duration\n13:time.Durationm",
                "$T[N13:time.Duration\n13:time.Durationm",
            ])
        let descriptor = try #require(GoTypeDescriptor(typeName: boxes[0]))
        #expect(descriptor.type == .named("time.Duration"))
        #expect(descriptor.underlying(descriptor.type) == .number(.int64))
        #expect(GoTypeDescriptor.name(of: descriptor.type) == "time.Duration")
        #expect(GoTypeDescriptor.methodOwner(ofTypeName: boxes[0]) == "time.Duration")

        #expect(
            GoLibraryMethods.functions.keys.sorted() == [
                "time.Duration.Abs", "time.Duration.Hours", "time.Duration.Microseconds",
                "time.Duration.Milliseconds", "time.Duration.Minutes",
                "time.Duration.Nanoseconds", "time.Duration.Round", "time.Duration.Seconds",
                "time.Duration.String", "time.Duration.Truncate",
            ])
        #expect(
            GoLibraryMethods.functions.keys.sorted()
                == GoLibraryTypes.durationMethods.map { "time.Duration." + $0 }.sorted())
        let round = try #require(GoLibraryMethods.functions["time.Duration.Round"])
        #expect(round.parameterCount == 2)
        #expect(round.returnCount == 1)
        #expect(
            round.instructions == [
                .load(0), .load(1), .call("$time.Duration.Round", argumentCount: 2),
                .returnValues(count: 1),
            ])
        for name in GoLibraryTypes.nativeCallNames {
            #expect(GoStandardLibrary.isNativeCallName(name))
        }
    }

    /// What the natives compute, without a program. The values are what Go's
    /// `time` package gives for the same operands.
    @Test func theTextAndTheArithmeticArePureFunctions() {
        #expect(GoDuration.string(0) == "0s")
        #expect(GoDuration.string(1) == "1ns")
        #expect(GoDuration.string(1_500) == "1.5\u{B5}s")
        #expect(GoDuration.string(150_000_000) == "150ms")
        #expect(GoDuration.string(1_000_000_001) == "1.000000001s")
        #expect(GoDuration.string(-90_000_000_000) == "-1m30s")
        #expect(GoDuration.string(3_600_000_000_000) == "1h0m0s")
        #expect(GoDuration.string(.max) == "2562047h47m16.854775807s")
        #expect(GoDuration.string(.min) == "-2562047h47m16.854775808s")

        #expect(GoDuration.round(1_500, 1_000) == 2_000)
        #expect(GoDuration.round(-1_500, 1_000) == -2_000)
        #expect(GoDuration.round(1_499, 1_000) == 1_000)
        #expect(GoDuration.round(7, 0) == 7)
        #expect(GoDuration.round(.max, 1 << 62) == .max)
        #expect(GoDuration.round(.min, .max) == .min + 1)
        #expect(GoDuration.truncate(-1_999, 1_000) == -1_000)
        #expect(GoDuration.truncate(7, -1) == 7)
        #expect(GoDuration.absolute(.min) == .max)

        #expect(GoDuration.parse("1h30m").duration == 5_400_000_000_000)
        #expect(GoDuration.parse("-1.5h").duration == -5_400_000_000_000)
        #expect(GoDuration.parse("1\u{B5}s").duration == 1_000)
        #expect(GoDuration.parse("-9223372036854775808ns").duration == .min)
        #expect(GoDuration.parse("9223372036854775808ns").error == "time: invalid duration \"9223372036854775808ns\"")
        #expect(GoDuration.parse("5").error == "time: missing unit in duration \"5\"")
        #expect(
            GoDuration.parse("1\u{E9}").error
                == "time: unknown unit \"\\xc3\\xa9\" in duration \"1\\xc3\\xa9\"")

        #expect(GoNative.time("$time.Until", [40], now: 42) == .int(-2))
        #expect(GoNative.time("$time.Duration.String", [1_500_000_000], now: 0) == .string("1.5s"))
        #expect(GoNative.time("$time.Duration.Microseconds", [-1_999], now: 0) == .int(-1))
        #expect(GoNative.time("$time.Duration.Milliseconds", [1_999_999], now: 0) == .int(1))
        #expect(GoNative.time("$time.Duration.Seconds", [1], now: 0)
                == .int(Int64(bitPattern: (1e-9).bitPattern)))
    }
}
