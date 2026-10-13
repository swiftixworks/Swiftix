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

    @Test func anUnrecoveredPanicPrintsItsValueAsGoPrintsIt() {
        // What follows `panic: ` in Go 1.24.5, with the address masked.
        let declarations = """
            type failure struct {
                Code int
            }

            type problem struct {
                Code int
            }

            func (p problem) Error() string { return fmt.Sprint("problem ", p.Code) }

            type label struct {
                Text string
            }

            func (l label) String() string { return "label " + l.Text }

            type code int

            type name string

            type flag bool
            """
        func text(_ body: String) -> String? {
            do {
                _ = try runGoMain(body, imports: ["errors", "fmt"], declarations: declarations)
                return nil
            } catch GoRuntimeError.panicError(let message) {
                return message.replacing(/0x[0-9a-f]{6,}/, with: "0xADDR")
            } catch {
                return "unexpected error: \(error)"
            }
        }

        // A number, a string, and a truth value as they are.
        #expect(text("panic(7)") == "7")
        #expect(text("panic(\"text\")") == "text")
        #expect(text("panic(true)") == "true")
        #expect(text("var b byte = 7\npanic(b)") == "7")
        // One of a named type with the type around it.
        #expect(text("panic(code(4))") == "main.code(4)")
        #expect(text("panic(name(\"x\"))") == "main.name(\"x\")")
        #expect(text("panic(flag(true))") == "main.flag(true)")
        // Anything else by its type and where it lies.
        #expect(text("panic(failure{Code: 3})") == "(main.failure) 0xADDR")
        #expect(text("panic(&failure{Code: 3})") == "(*main.failure) 0xADDR")
        #expect(text("var p *failure\npanic(p)") == "(*main.failure) 0x0")
        #expect(text("panic([]int{1, 2})") == "([]int) 0xADDR")
        #expect(text("panic([2]int{1, 2})") == "([2]int) 0xADDR")
        #expect(text("panic(map[string]int{\"a\": 1})") == "(map[string]int) 0xADDR")
        #expect(text("var v interface{} = failure{Code: 1}\npanic(v)") == "(main.failure) 0xADDR")
        // An error by its text and a value with a `String` method by that,
        // which are the program's to compute.
        #expect(text("panic(errors.New(\"made\"))") == "made")
        #expect(text("panic(fmt.Errorf(\"wrapped %d\", 1))") == "wrapped 1")
        #expect(text("panic(problem{Code: 5})") == "problem 5")
        #expect(text("panic(&problem{Code: 6})") == "problem 6")
        #expect(text("panic(label{Text: \"t\"})") == "label t")
    }

    @Test func aPanicKeepsTheTypeOfItsValue() throws {
        #expect(
            try runGoMain(
                """
                report(4)
                report(code(4))
                report(failure{Code: 1})
                report(&failure{Code: 2})
                report([]string{"a"})
                """,
                declarations: """
                    type failure struct {
                        Code int
                    }

                    type code int

                    func report(value interface{}) {
                        defer func() {
                            r := recover()
                            _, isCode := r.(code)
                            fmt.Printf("%v %T %v\\n", r, r, isCode)
                        }()
                        panic(value)
                    }
                    """)
                == "4 int false\n4 main.code true\n{1} main.failure false\n&{2} *main.failure false\n[a] []string false\n")
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
