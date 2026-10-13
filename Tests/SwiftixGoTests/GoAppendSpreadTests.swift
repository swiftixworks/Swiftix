/// Go `append(slice, source...)`: growth, shared backing arrays, string
/// sources, overlapping ranges, type checking, and how `gofmt` prints it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go append with a spread argument")
struct GoAppendSpreadTests: GoTestHarness {

    @Test func appendsEveryElementOfTheSource() throws {
        let output = try runGoMain(
            """
            numbers := []int{1, 2}
            numbers = append(numbers, []int{3, 4, 5}...)
            fmt.Println(numbers, len(numbers))
            var empty []int
            grown := append(empty, numbers[1:3]...)
            fmt.Println(grown, len(grown), cap(grown), empty == nil)
            same := append(numbers, empty...)
            fmt.Println(same, len(same) == len(numbers), append(empty, empty...) == nil)
            words := append([]string{"a"}, []string{"b", "c"}...)
            fmt.Println(words, len(words))
            nested := append([]int{0}, append([]int{1}, []int{2, 3}...)...)
            fmt.Println(nested)
            """)

        #expect(
            output == """
                [1 2 3 4 5] 5
                [2 3] 2 2 true
                [1 2 3 4 5] true true
                [a b c] 3
                [0 1 2 3]

                """)
    }

    @Test func bytesAcceptAStringSource() throws {
        let output = try runGoMain(
            """
            reply := []byte("+")
            reply = append(reply, "OK"...)
            reply = append(reply, []byte{13, 10}...)
            fmt.Println(len(reply), reply, string(reply[:3]))
            var line []byte
            line = append(line, "é"...)
            line = append(line, ""...)
            fmt.Println(line, string(line))
            """)

        #expect(output == "5 [43 79 75 13 10] +OK\n[195 169] é\n")
    }

    @Test func spareCapacityIsFilledInPlaceAndThenTheSliceGrows() throws {
        let output = try runGoMain(
            """
            backing := make([]int, 2, 6)
            alias := backing[:4]
            first := append(backing, []int{7, 8}...)
            fmt.Println(first, len(first), cap(first), alias)
            second := append(first, []int{9, 10}...)
            fmt.Println(second, cap(second), alias)
            // Past the capacity the result has an array of its own.
            third := append(second, []int{11, 12, 13}...)
            third[0] = -1
            fmt.Println(third, len(third), cap(third) >= 9, second[0], alias[0])
            """)

        #expect(
            output == """
                [0 0 7 8] 4 6 [0 0 7 8]
                [0 0 7 8 9 10] 6 [0 0 7 8]
                [-1 0 7 8 9 10 11 12 13] 9 true 0 0

                """)
    }

    @Test func overlappingSourcesAreReadBeforeTheyAreWritten() throws {
        let output = try runGoMain(
            """
            doubled := []int{1, 2, 3}
            doubled = append(doubled, doubled...)
            fmt.Println(doubled)
            // The delete idiom: remove index 1 by appending the tail.
            items := []int{10, 20, 30, 40}
            items = append(items[:1], items[2:]...)
            fmt.Println(items, len(items), cap(items))
            // Inserting through spare capacity that the source also covers.
            window := make([]int, 3, 8)
            window[0] = 1
            window[1] = 2
            window[2] = 3
            window = append(window[:1], window...)
            fmt.Println(window)
            """)

        #expect(output == "[1 2 3 1 2 3]\n[10 30 40] 3 4\n[1 1 2 3]\n")
    }

    @Test func largeAppendsCostOneInstructionEach() throws {
        let output = try runGoMain(
            """
            chunk := make([]byte, 1024)
            chunk[1023] = 9
            var buffer []byte
            for round := 0; round < 64; round++ {
                buffer = append(buffer, chunk...)
            }
            fmt.Println(len(buffer), buffer[1023], buffer[65535], buffer[65534])
            """,
            machine: GoVirtualMachine(maximumInstructions: 20_000))

        #expect(output == "65536 9 9 0\n")
    }

    @Test func collectionLimitAppliesToTheNewLength() throws {
        let machine = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(maximumCollectionElements: 10))

        // Doubling the capacity of 6 would pass the limit; the length fits.
        let fits = try runGoMain(
            """
            values := []int{1, 2, 3, 4, 5, 6}
            values = append(values, []int{7, 8, 9}...)
            fmt.Println(len(values), cap(values))
            """,
            machine: machine)
        #expect(fits == "9 10\n")

        #expect(throws: GoRuntimeError.resourceLimitExceeded("slice elements")) {
            _ = try runGoMain(
                """
                values := []int{1, 2, 3, 4, 5, 6}
                values = append(values, values...)
                """,
                machine: machine)
        }
    }

    @Test func spreadAndCopyLinkAcrossPackages() throws {
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m",
                    sources: [
                        GoSourceFile(
                            path: "/m/main.go",
                            text: """
                                package main
                                import "fmt"
                                import "example/m/buf"
                                func main() {
                                    joined := buf.Join([]byte("ab"), []byte("cd"))
                                    joined = append(joined, buf.Tail()...)
                                    fmt.Println(string(joined), buf.Fill(joined[:2]), string(joined))
                                }

                                """)
                    ]),
                GoPackageSource(
                    importPath: "example/m/buf",
                    sources: [
                        GoSourceFile(
                            path: "/m/buf/buf.go",
                            text: """
                                package buf
                                func Join(a []byte, b []byte) []byte {
                                    return append(a, b...)
                                }
                                func Tail() []byte {
                                    return []byte("!")
                                }
                                func Fill(target []byte) int {
                                    return copy(target, "xyz")
                                }

                                """)
                    ]),
            ],
            root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "abcd! 2 xycd!\n")
    }

    @Test func spreadIsTypeChecked() {
        #expect(
            goMainDiagnostic("x := append([]int{1}, []string{\"a\"}...)\nfmt.Println(x)")
                == "cannot use []string as []int value in append")
        #expect(
            goMainDiagnostic("x := append([]int{1}, \"text\"...)\nfmt.Println(x)")
                == "cannot use string as []int value in append")
        #expect(
            goMainDiagnostic("x := append([]int{1}, 5...)\nfmt.Println(x)")
                == "cannot use int as []int value in append")
        #expect(
            goMainDiagnostic("x := append([]int{1}, 2, []int{3}...)\nfmt.Println(x)")
                == "can only use ... with final argument in list")
        #expect(
            goMainDiagnostic("x := append([]int{1}, []int{2}..., 3)\nfmt.Println(x)")
                == "can only use ... with final argument in list")
        // The library's `...any` takes a `[]any`, and a function that is not
        // variadic takes no spread at all.
        #expect(
            goMainDiagnostic("fmt.Println([]int{1}...)")
                == "cannot use []int as []interface{} value in argument")
        #expect(goMainDiagnostic("fmt.Println(1, []any{2}...)") != nil)
        #expect(
            goMainDiagnostic(
                "fmt.Println(total([]int{1}...))",
                declarations: "func total(values []int) int {\n\treturn len(values)\n}")
                == "can only use ... with final argument in list")
        #expect(goMainDiagnostic("x := []int{1}...\nfmt.Println(x)") != nil)
        #expect(goMainDiagnostic("var x int = 1 ... 2\nfmt.Println(x)") != nil)
    }

    @Test func gofmtKeepsTheSpread() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                func main() {
                x:=append( x ,y ... )
                z = append(z[ :1 ],tail[1:] ...)
                }

                """)

        #expect(
            try GoFormatter.format(source) == """
                package main

                func main() {
                \tx := append(x, y...)
                \tz = append(z[:1], tail[1:]...)
                }

                """)
    }

    @Test func rewriteRulesMatchAndPrintASpread() throws {
        func rewritten(_ body: String, rule: String) throws -> String {
            let source = GoSourceFile(
                path: "main.go", text: "package main\nfunc main() {\n\t\(body)\n}\n")
            let lines = try GoSourceRewriter.rewrite(source, rule: rule).text.split(separator: "\n")
            return String(lines[2].dropFirst())
        }
        // A spread pattern matches a spread and nothing else.
        #expect(
            try rewritten(
                "x = append(x, tail[1:]...)", rule: "append(a, b...) -> concat(a, b)")
                == "x = concat(x, tail[1:])")
        #expect(
            try rewritten("x = append(x, y)", rule: "append(a, b...) -> concat(a, b)")
                == "x = append(x, y)")
        #expect(
            try rewritten("x = append(x, y...)", rule: "append(a, b) -> push(a, b)")
                == "x = push(x, y...)")
        // A replacement prints the spread back, and operands are rewritten
        // inside one.
        #expect(
            try rewritten("x = concat(x, y)", rule: "concat(a, b) -> append(a, b...)")
                == "x = append(x, y...)")
        #expect(
            try rewritten("x = append(x, old(y)...)", rule: "old(a) -> fresh(a)")
                == "x = append(x, fresh(y)...)")

        let call = GoExpression.spread(
            .identifier("values", position: Self.position(12)), position: Self.position(18))

        #expect(call.spreadOperand == .identifier("values", position: Self.position(12)))
        #expect(GoExpression.identifier("values", position: Self.position(0)).spreadOperand == nil)
        #expect(call.bitwiseOperation == nil)
        // An ordinary call to a function is not a spread.
        #expect(
            GoExpression.call(
                callee: .identifier("f", position: Self.position(0)), arguments: [call],
                position: Self.position(1)
            ).spreadOperand == nil)
    }

    private static func position(_ offset: Int) -> GoSourcePosition {
        GoSourcePosition(path: "main.go", offset: offset, line: 1, column: offset + 1)
    }
}
