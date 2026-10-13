/// Function literals and the variables they capture.
///
/// A literal uses the variables of the functions around it, not copies of
/// their values: it reads what they hold when it runs, what it assigns is
/// seen outside, and they live as long as a literal that uses them does.
/// Function values as such are in `GoFunctionValueTests`.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go closures")
struct GoClosureTests: GoTestHarness {

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

    /// The variables of the functions around a literal that it uses, those a
    /// literal inside it uses among them; not its own, and not those of the
    /// package.
    @Test func theCheckerRecordsWhatEachLiteralCaptures() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: """
                    package main

                    var global int

                    func main() {
                        a, b, unused := 1, 2, 3
                        _ = unused
                        outer := func(p int) int {
                            local := p + a + global
                            inner := func() int { return local + b }
                            return inner()
                        }
                        plain := func(x int) int { return x + global }
                        _, _ = outer, plain
                    }

                    """))
        let captures = try GoTypeChecker.check([file]).literalCaptures
        let lists = captures.values.map { $0.sorted().joined(separator: " ") }.sorted()

        // `outer` captures what it uses and what `inner` needs from
        // outside it, and `inner` its two. `plain` captures nothing, and
        // only a literal that captures is recorded.
        #expect(lists == ["a b", "b local"])
        #expect(captures.keys.allSatisfy { $0.hasPrefix("$literal.main.go.") })
    }

    /// What it reads is what the variable holds when it runs; what it assigns
    /// is seen by everything else that uses the variable.
    @Test func aLiteralCapturesVariablesNotValues() throws {
        #expect(
            try runGoMain(
                """
                x := 1
                read := func() int { return x }
                write := func(v int) { x = v }
                x = 2
                fmt.Print(read(), " ")
                write(10)
                x++
                fmt.Println(read(), x)

                total, calls := 0, 0
                each([]int{1, 2, 3}, func(v int) {
                    total += v
                    calls++
                })
                words := []string{}
                add := func(w string) { words = append(words, w) }
                add("a")
                add("b")
                fmt.Println(total, calls, words, len(words))
                """,
                declarations: """
                    func each(values []int, visit func(int)) {
                        for _, v := range values {
                            visit(v)
                        }
                    }
                    """)
                == "2 11 11\n6 3 [a b] 2\n")
    }

    /// Every call of the function around a literal makes variables of its
    /// own, and the literal keeps them.
    @Test func capturedVariablesOutliveTheirFunction() throws {
        #expect(
            try runGoMain(
                """
                next, other := counter(), counter()
                fmt.Println(next(), next(), next(), other(), next())
                get, set := cell(5)
                set(get() * 2)
                fmt.Println(get())
                square := memo(func(n int) int { return n * n })
                fmt.Println(square(4), square(4), square(5))
                """,
                declarations: """
                    func counter() func() int {
                        n := 0
                        return func() int {
                            n++
                            return n
                        }
                    }

                    func cell(start int) (func() int, func(int)) {
                        value := start
                        return func() int { return value }, func(v int) { value = v }
                    }

                    func memo(f func(int) int) func(int) int {
                        seen := map[int]int{}
                        calls := 0
                        return func(n int) int {
                            if v, ok := seen[n]; ok {
                                return v + calls*1000
                            }
                            calls++
                            seen[n] = f(n)
                            return seen[n]
                        }
                    }
                    """)
                == "1 2 3 1 4\n10\n16 1016 25\n")
    }

    /// A literal made in a loop keeps the variable of its iteration, as Go
    /// has had it since 1.22; what it does to the variable is carried into the
    /// next iteration.
    @Test func everyIterationHasItsOwnVariable() throws {
        #expect(
            try runGoMain(
                """
                var fs []func() int
                for i := 0; i < 3; i++ {
                    fs = append(fs, func() int { return i * 10 })
                }
                for _, v := range []int{7, 8} {
                    fs = append(fs, func() int { return v })
                }
                for k := range map[string]int{"only": 1} {
                    fs = append(fs, func() int { return len(k) })
                }
                for _, f := range fs {
                    fmt.Print(f(), " ")
                }
                fmt.Println()
                for i := 0; i < 6; i++ {
                    skip := func() { i++ }
                    skip()
                    fmt.Print(i, " ")
                }
                fmt.Println()
                """)
                == "0 10 20 7 8 4 \n1 3 5 \n")
    }

    /// A literal inside a literal reaches the variables of every function
    /// around it.
    @Test func literalsNestAndCaptureThroughEachOther() throws {
        #expect(
            try runGoMain(
                """
                depth := 0
                var visit func(n int) int
                visit = func(n int) int {
                    depth++
                    if n == 0 {
                        return func() int { return depth * 100 }()
                    }
                    return visit(n-1) + n
                }
                fmt.Println(visit(3), depth)
                adder := func(a int) func(int) func(int) int {
                    return func(b int) func(int) int {
                        return func(c int) int {
                            depth++
                            return a + b + c
                        }
                    }
                }
                fmt.Println(adder(1)(2)(3), adder(10)(20)(30), depth)
                """)
                == "406 4\n6 60 6\n")
    }

    /// They are variables of the function like any other.
    @Test func aLiteralCapturesParametersReceiversAndResults() throws {
        #expect(
            try runGoMain(
                """
                a := &account{owner: "ann"}
                plus5, plus7 := a.depositor(5), a.depositor(7)
                fmt.Println(plus5(), plus7(), plus5(), a.balance, a.describe()("="))
                fmt.Println(total([]int{1, 2, 3}, func(sum, v int) int { return sum + v }))
                fmt.Println(total([]int{1, 2, 3}, func(sum, v int) int { return sum - v }))
                """,
                declarations: """
                    type account struct {
                        owner   string
                        balance int
                    }

                    func (a *account) depositor(amount int) func() int {
                        return func() int {
                            a.balance += amount
                            return a.balance
                        }
                    }

                    func (a account) describe() func(string) string {
                        return func(sep string) string { return a.owner + sep + fmt.Sprint(a.balance) }
                    }

                    func total(values []int, step func(sum, v int) int) (result int) {
                        defer func() {
                            if result < 0 {
                                result = 0
                            }
                        }()
                        for _, v := range values {
                            result = step(result, v)
                        }
                        return result
                    }
                    """)
                == "5 12 17 17 ann=17\n6\n0\n")
    }

    /// With arguments, for a value, or as a statement.
    @Test func aLiteralIsCalledWhereItIsWritten() throws {
        #expect(
            try runGoMain(
                """
                n := 3
                fmt.Println(func(x int) int { return x * x }(7), func() int { return n + 1 }())
                func() {
                    n *= 2
                }()
                a, b := func(x int) (int, int) { return x, x + n }(1)
                fmt.Println(n, a, b)
                """)
                == "49 4\n6 1 7\n")
    }

    /// Its parameters hide the variables outside; its `return` leaves the
    /// literal; a `break` in it does not reach a loop outside it.
    @Test func aLiteralHasAScopeAndAControlFlowOfItsOwn() throws {
        #expect(
            try runGoMain(
                """
                x := 1
                shadow := func(x int) int { return x * 10 }
                inner := func() int {
                    x := x + 1
                    return x
                }
                first := func(values []int) int {
                    for _, v := range values {
                        if v > 1 {
                            return v
                        }
                    }
                    return -1
                }
                fmt.Println(shadow(5), inner(), x, first([]int{1, 4, 9}), first(nil))
                for i := 0; i < 3; i++ {
                    func() {
                        for {
                            break
                        }
                        if i == 1 {
                            return
                        }
                        fmt.Print(i, " ")
                    }()
                }
                fmt.Println()
                """)
                == "50 2 1 4 -1\n0 2 \n")
        #expect(
            firstError(
                """
                for {
                    func() { break }()
                }
                """)
                == "6:14: break is not in a loop, switch, or select")
        #expect(
            firstError(
                """
                for i := 0; i < 2; i++ {
                    func() { continue }()
                }
                """)
                == "6:14: continue is not in a loop")
        #expect(
            firstError(
                """
                f := func() int { fmt.Println() }
                f()
                """)
                == "5:33: missing return")
        #expect(
            firstError("func() { y := 1 }()")
                == "5:10: declared and not used: y")
    }

    /// A literal that reads a variable uses it; one that only assigns it does
    /// not.
    @Test func aVariableOnlyALiteralAssignsIsUnused() throws {
        #expect(
            firstError(
                """
                x := 1
                f := func() { x = 2 }
                f()
                """)
                == "5:1: declared and not used: x")
        #expect(
            try runGoMain(
                """
                x := 1
                f := func() int { return x }
                fmt.Println(f())
                """)
                == "1\n")
    }

    /// A goroutine's literal shares the variables of the function that
    /// started it. A deferred literal reads them when it runs, where the
    /// arguments of a deferred call were read when it was deferred.
    @Test func closuresRunAsGoroutinesAndDeferredCalls() throws {
        #expect(
            try runGoMain(
                """
                var wg sync.WaitGroup
                var mu sync.Mutex
                total := 0
                for i := 1; i <= 4; i++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        mu.Lock()
                        total += i
                        mu.Unlock()
                    }()
                }
                wg.Wait()
                done := make(chan int)
                for _, v := range []int{10, 20} {
                    go func(w int) { done <- v + w }(1)
                }
                a, b := <-done, <-done
                fmt.Println(total, a+b)

                n := 1
                defer fmt.Println("argument read when deferred:", n)
                defer func() { fmt.Println("variable read when run:", n) }()
                defer func(n int) { fmt.Println("parameter:", n) }(n * 100)
                n = 2
                """,
                imports: ["fmt", "sync"])
                == """
                10 32
                parameter: 100
                variable read when run: 2
                argument read when deferred: 1

                """)
    }

    /// Twelve literals inside each other, and twenty statements: what a
    /// compiler built without optimization must manage on the stack of a test,
    /// where each level once cost more than a tenth of it.
    @Test func literalsAndStatementsNestDeeply() throws {
        #expect(
            try runGoMain(
                """
                total := 0
                v0 := 1
                total += func(by int) int {
                    v1 := 2
                    total += func(by int) int {
                        v2 := 3
                        total += func(by int) int {
                            v3 := 4
                            total += func(by int) int {
                                v4 := 5
                                total += func(by int) int {
                                    v5 := 6
                                    total += func(by int) int {
                                        v6 := 7
                                        total += func(by int) int {
                                            v7 := 8
                                            total += func(by int) int {
                                                v8 := 9
                                                total += func(by int) int {
                                                    v9 := 10
                                                    total += func(by int) int {
                                                        v10 := 11
                                                        total += func(by int) int {
                                                            v11 := 12
                                                            total += func(by int) int {
                                                                return by + v0 + v1 + v2 + v3 + v4 + v5 + v6 + v7 + v8 + v9 + v10 + v11
                                                            }(110)
                                                            return total + by
                                                        }(100)
                                                        return total + by
                                                    }(90)
                                                    return total + by
                                                }(80)
                                                return total + by
                                            }(70)
                                            return total + by
                                        }(60)
                                        return total + by
                                    }(50)
                                    return total + by
                                }(40)
                                return total + by
                            }(30)
                            return total + by
                        }(20)
                        return total + by
                    }(10)
                    return total + by
                }(0)
                fmt.Println(total)
                """)
                == "569364\n")
        #expect(
            try runGoMain(
                """
                count := 0
                for i0 := 0; i0 < 2; i0++ {
                if count >= 0 {
                switch {
                case count >= 0:
                {
                for range []int{1, 2} {
                for i5 := 0; i5 < 2; i5++ {
                if count >= 0 {
                switch {
                case count >= 0:
                {
                for range []int{1, 2} {
                for i10 := 0; i10 < 2; i10++ {
                if count >= 0 {
                switch {
                case count >= 0:
                {
                for range []int{1, 2} {
                for i15 := 0; i15 < 2; i15++ {
                if count >= 0 {
                switch {
                case count >= 0:
                {
                for range []int{1, 2} {
                count++
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
                fmt.Println(count)
                """)
                == "256\n")
    }

    /// A literal made over and over is a new value each time, with the
    /// variables of that time.
    @Test func manyLiteralsShareNothingTheyDoNotCapture() throws {
        #expect(
            try runGoMain(
                """
                sum := 0
                var last func() int
                for i := 0; i < 500; i++ {
                    last = func() int { return i }
                    sum += last() % 7
                }
                table := map[string]func(int) int{}
                for _, by := range []int{2, 3, 5} {
                    table[fmt.Sprint("x", by)] = func(n int) int { return n * by }
                }
                fmt.Println(sum, last(), table["x2"](10), table["x3"](10), table["x5"](10), len(table))
                """)
                == "1494 499 20 30 50 3\n")
    }
}
