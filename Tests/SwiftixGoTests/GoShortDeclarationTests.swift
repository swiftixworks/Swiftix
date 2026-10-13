/// Go multi-value `:=` that reuses a variable of the same block: the old
/// variable is assigned, a new name is declared, and an inner block shadows.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go short variable redeclaration")
struct GoShortDeclarationTests: GoTestHarness {

    private static let helpers = """
        func pair(a int, b int) (int, int) {
            return a, b
        }
        func parse(text string) (int, error) {
            return strconv.Atoi(text)
        }
        func describe(err error) string {
            if err != nil {
                return "failed"
            }
            return "ok"
        }
        """

    private func run(_ body: String, declarations: String = "") throws -> String {
        try runGoMain(
            body, imports: ["fmt", "strconv"],
            declarations: Self.helpers + "\n" + declarations)
    }

    private func diagnostic(_ body: String) -> String? {
        goMainDiagnostic(body, imports: ["fmt", "strconv"], declarations: Self.helpers)
    }

    @Test func aReusedNameIsAssignedNotShadowed() throws {
        let output = try run(
            """
            first, err := parse("12")
            seen := &err
            second, err := parse("x")
            fmt.Println(first, second, describe(err), describe(*seen))
            third, err := parse("30")
            fmt.Println(third, describe(err), describe(*seen))

            a, b := pair(1, 2)
            keep := &b
            c, b := pair(3, 4)
            b, d := pair(5, 6)
            fmt.Println(a, b, c, d, *keep)
            """)

        // `seen` and `keep` point at the one variable every `:=` assigns.
        #expect(output == "12 0 failed failed\n30 ok ok\n1 5 3 6 5\n")
    }

    @Test func anInnerBlockDeclaresItsOwnVariable() throws {
        let output = try run(
            """
            value, err := parse("7")
            if value > 0 {
                inner, err := parse("x")
                fmt.Println(inner, describe(err))
                again, err := parse("8")
                fmt.Println(again, describe(err))
            }
            for i := 0; i < 2; i++ {
                step, value := pair(i, i*10)
                fmt.Println(step, value)
            }
            fmt.Println(value, describe(err))
            """)

        #expect(output == "0 failed\n8 ok\n0 0\n1 10\n7 ok\n")
    }

    @Test func everyMultiValueFormCanReuseAName() throws {
        let output = try run(
            """
            ages := map[string]int{"a": 1}
            first, ok := ages["a"]
            second, ok := ages["b"]
            fmt.Println(first, second, ok)

            queue := make(chan int, 1)
            queue <- 5
            received, ok := <-queue
            close(queue)
            drained, ok := <-queue
            fmt.Println(received, drained, ok)

            var boxed any = "text"
            text, ok := boxed.(string)
            number, ok := boxed.(int)
            fmt.Println(text, number, ok)

            _, ok, count := triple()
            fmt.Println(ok, count)
            """,
            declarations: """
                func triple() (int, bool, int) {
                    return 1, true, 3
                }
                """)

        #expect(output == "1 0 false\n5 0 false\ntext 0 false\ntrue 3\n")
    }

    @Test func parametersAndNamedResultsAreReusable() throws {
        let output = try run(
            """
            total, err := sum("4", "x")
            fmt.Println(total, describe(err))
            total, err = sum("4", "5")
            fmt.Println(total, describe(err))
            """,
            declarations: """
                func sum(left string, right string) (total int, err error) {
                    a, err := parse(left)
                    if err != nil {
                        return
                    }
                    b, err := parse(right)
                    total = a + b
                    return
                }
                """)

        #expect(output == "4 failed\n9 ok\n")
    }

    @Test func aReusedNameKeepsItsType() {
        #expect(
            diagnostic(
                """
                flag := true
                number, flag := pair(1, 2)
                fmt.Println(number, flag)
                """) == "cannot use int as bool value")
    }

    @Test func aStatementWithoutANewNameIsStillARedeclaration() {
        #expect(
            diagnostic(
                """
                a, b := pair(1, 2)
                a, b := pair(3, 4)
                fmt.Println(a, b)
                """) == "no new variables on left side of :=")
        #expect(
            diagnostic(
                """
                value, err := parse("1")
                _, err := parse("2")
                fmt.Println(value, err)
                """) == "no new variables on left side of :=")
        #expect(
            diagnostic(
                """
                a, b := pair(1, 2)
                b, c, c := three()
                fmt.Println(a, b, c)
                """) != nil)
    }

    @Test func standInsDoNotLeakIntoTheProgram() {
        let statements = GoStatement.redeclaration(
            names: ["n", "err", "_"],
            expression: .identifier("f", position: Self.position),
            position: Self.position,
            declared: ["err"])

        #expect(
            statements == [
                .multiDeclaration(
                    names: ["n", "$redeclared.9.err", "_"],
                    expression: .identifier("f", position: Self.position),
                    position: Self.position),
                .assignment(
                    target: .identifier("err", position: Self.position),
                    expression: .identifier("$redeclared.9.err", position: Self.position),
                    position: Self.position),
            ])
        #expect(
            GoStatement.redeclaration(
                names: ["n", "err"], expression: .identifier("f", position: Self.position),
                position: Self.position, declared: []) == nil)
        #expect(
            GoStatement.redeclaration(
                names: ["n", "err"], expression: .identifier("f", position: Self.position),
                position: Self.position, declared: ["n", "err"]) == nil)
    }

    private static let position = GoSourcePosition(path: "main.go", offset: 9, line: 2, column: 1)
}
