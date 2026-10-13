/// Run-time errors as panics: what `recover` sees, what an unrecovered one
/// reports, and which failures stay fatal. The messages and the order of
/// deferred calls are compared with Go in `GoConformanceTests`.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go run-time panics")
struct GoRuntimePanicTests: GoTestHarness {

    private static let declarations = """
        type node struct {
            name string
        }
        func guard(label string) {
            if r := recover(); r != nil {
                err, isError := r.(error)
                fmt.Println(label, r, isError, err != nil)
            }
        }
        """

    private func failure(_ body: String) -> GoRuntimeError? {
        do {
            _ = try runGoMain(body, declarations: Self.declarations)
            return nil
        } catch {
            return error as? GoRuntimeError
        }
    }

    @Test func anUnrecoveredRunTimeErrorIsReportedAsGoReportsIt() {
        #expect(
            failure("values := []int{1}\ni := 3\nfmt.Println(values[i])")
                == .panicError("runtime error: index out of range [3] with length 1"))
        #expect(
            failure("values := []int{1}\ni := -1\nvalues[i] = 2")
                == .panicError("runtime error: index out of range [-1]"))
        #expect(
            failure("values := []int{1}\ni := 4\nfmt.Println(values[:i])")
                == .panicError("runtime error: slice bounds out of range [:4] with capacity 1"))
        #expect(
            failure("zero := 0\nfmt.Println(5 % zero)")
                == .panicError("runtime error: integer divide by zero"))
        #expect(
            failure("var n *node\nfmt.Println(n.name)")
                == .panicError("runtime error: invalid memory address or nil pointer dereference"))
        #expect(
            failure("var m map[string]int\nm[\"k\"] = 1")
                == .panicError("assignment to entry in nil map"))
        #expect(
            failure("var value interface{} = \"s\"\nfmt.Println(value.(int))")
                == .panicError("interface conversion: interface {} is string, not int"))
        #expect(
            failure("count := -1\nfmt.Println(1 << count)")
                == .panicError("runtime error: negative shift amount"))
        #expect(
            failure("n := -1\nfmt.Println(len(make([]int, n)))")
                == .panicError("runtime error: makeslice: len out of range"))
    }

    @Test func recoverReturnsAnErrorAndTheProgramGoesOn() throws {
        let output = try runGoMain(
            """
            fmt.Println(first(), second(), third())
            fmt.Println("done")
            """,
            declarations: Self.declarations + """

                func first() int {
                    defer guard("index:")
                    var values []int
                    return values[2]
                }
                func second() int {
                    defer guard("divide:")
                    zero := 0
                    return 7 / zero
                }
                func third() string {
                    defer guard("nil:")
                    var n *node
                    return n.name
                }
                """)

        #expect(
            output == """
                index: runtime error: index out of range [2] with length 0 true true
                divide: runtime error: integer divide by zero true true
                nil: runtime error: invalid memory address or nil pointer dereference true true
                0 0\u{20}
                done

                """)
    }

    @Test func aGoroutineCanRecoverItsOwnRunTimeError() throws {
        let output = try runGoMain(
            """
            results := make(chan string)
            go serve(results, 0)
            go serve(results, 4)
            first := <-results
            second := <-results
            fmt.Println(first == "25" || second == "25", first == "failed" || second == "failed")
            """,
            declarations: """
                func serve(results chan string, divisor int) {
                    defer done(results)
                    results <- fmt.Sprint(100 / divisor)
                }
                func done(results chan string) {
                    if r := recover(); r != nil {
                        results <- "failed"
                    }
                }
                """)

        #expect(output == "true true\n")
    }

    /// The output is what Go 1.24.5 prints for this program: two bounds
    /// errors with the same index and length are equal, as the struct values
    /// Go panics with are.
    @Test func runTimeErrorValuesCompareByWhatTheySay() throws {
        let output = try runGoMain(
            """
            a := caught(3)
            b := caught(3)
            c := caught(4)
            fmt.Println(a == b, a == c, a != nil, caught(0) == nil)
            fmt.Printf("%T %v|%s|%q\\n", a, a, a, a)
            _, isString := a.(string)
            err, isError := a.(error)
            fmt.Println(isString, isError, err.Error())
            """,
            declarations: """
                func caught(index int) interface{} {
                    holder := []interface{}{nil}
                    attempt(holder, []int{1}, index)
                    return holder[0]
                }
                func attempt(holder []interface{}, values []int, index int) {
                    defer keep(holder)
                    values[index] = 1
                }
                func keep(holder []interface{}) {
                    holder[0] = recover()
                }
                """)

        let message = "runtime error: index out of range [3] with length 1"
        #expect(
            output == """
                true false true true
                runtime.boundsError \(message)|\(message)|"\(message)"
                false true \(message)

                """)
    }

    @Test func aFaultOfTheMachineIsNotAPanic() {
        // An image that indexes with a string operand is malformed, not a
        // program that went out of range: nothing can recover from it.
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.push(.string("abc")), .push(.string("x")), .getIndex])
            ])
        #expect(throws: GoRuntimeError.typeMismatch) {
            try GoVirtualMachine().run(executable) { _ in }
        }
    }
}
