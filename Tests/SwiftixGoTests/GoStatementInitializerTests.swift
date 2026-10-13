/// `if` and `switch` with an initializer statement: scope, control flow,
/// diagnostics, and formatting. What such programs print is compared with Go
/// in `GoConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go statement initializers")
struct GoStatementInitializerTests: GoTestHarness {

    private static let declarations = """
        func pair(n int) (int, bool) {
            return n * 2, n > 0
        }
        """

    private func diagnostic(_ body: String, declarations: String = "") -> String? {
        goMainDiagnostic(body, declarations: Self.declarations + "\n" + declarations)
    }

    @Test func theInitializerIsScopedToItsStatement() throws {
        let output = try runGoMain(
            """
            x := 1
            if x := x + 10; x > 5 {
                fmt.Println("then", x)
            } else {
                fmt.Println("else", x)
            }
            if double, ok := pair(0); ok {
                fmt.Println("positive", double)
            } else if double, ok := pair(3); ok {
                fmt.Println("second", double)
            } else {
                fmt.Println("neither", double)
            }
            switch x := x * 4; x {
            case 4:
                fmt.Println("four", x)
            default:
                fmt.Println("other", x)
            }
            switch y := x + 1; {
            case y > 1:
                fmt.Println("tagless", y)
            }
            if ; x == 1 {
                fmt.Println("empty initializer", x)
            }
            fmt.Println(x)
            """,
            declarations: Self.declarations)

        #expect(output == "then 11\nsecond 6\nfour 4\ntagless 2\nempty initializer 1\n1\n")
    }

    @Test func breakAndContinueBelongToTheEnclosingLoop() throws {
        let output = try runGoMain(
            """
            total := 0
            for i := 0; i < 10; i++ {
                if odd := i % 2; odd == 1 {
                    continue
                }
                if square := i * i; square > 30 {
                    break
                }
                switch half := i / 2; half {
                case 1:
                    continue
                }
                total += i
            }
            fmt.Println(total)
            """)

        // 0 and 4 are added; 2 continues from inside the switch; 6 breaks.
        #expect(output == "4\n")
    }

    @Test func initializersAreChecked() {
        #expect(
            diagnostic("if x := 1; x > 0 {\n}\nfmt.Println(x)") == "undefined: x")
        #expect(
            diagnostic("switch x := 1; x {\ncase 1:\n}\nfmt.Println(x)") == "undefined: x")
        #expect(diagnostic("if x := 1 {\n}") == "missing condition in if statement")
        #expect(diagnostic("if x := 1; x {\n}") != nil)
        #expect(diagnostic("if x := \"a\"; x > 0 {\n}") != nil)
        #expect(
            diagnostic("if x := 1; x > 0 {\nbreak\n}")
                == "break is not in a loop, switch, or select")
        #expect(diagnostic("if x := 1; x > 0 {\ncontinue\n}") == "continue is not in a loop")
        #expect(
            diagnostic("switch x := 1; x {\ncase 1:\ncontinue\n}")
                == "continue is not in a loop")
        // A `break` inside a `switch` ends the switch, with an initializer too.
        #expect(diagnostic("switch x := 1; x {\ncase 1:\nbreak\n}") == nil)
        #expect(diagnostic("if x, ok := pair(1); ok {\nfmt.Println(x)\n}") == nil)
    }

    @Test func aFunctionMayEndInAnInitializedIf() {
        func diagnostic(_ function: String) -> String? {
            goMainDiagnostic("fmt.Println(pick(4))", declarations: function)
        }
        #expect(
            diagnostic(
                """
                func pick(n int) int {
                    if half := n / 2; half > 1 {
                        return half
                    } else {
                        return 0
                    }
                }
                """) == nil)
        #expect(
            diagnostic(
                """
                func pick(n int) int {
                    switch half := n / 2; {
                    case half > 1:
                        return half
                    default:
                        return 0
                    }
                }
                """) == nil)
        #expect(
            diagnostic(
                """
                func pick(n int) int {
                    if half := n / 2; half > 1 {
                        return half
                    }
                }
                """) == "missing return")
        // A `for` that only loops while a `break` leaves it does not end one.
        #expect(
            diagnostic(
                """
                func pick(n int) int {
                    for {
                        if half := n / 2; half > 1 {
                            break
                        }
                    }
                }
                """) == "missing return")
    }

    @Test func theEncodingIsTheStatementAndItsInitializer() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: """
                    package main
                    func main() {
                        if x := 1; x > 0 {
                        }
                        for i := 0; ; i++ {
                            break
                        }
                        for {
                            break
                        }
                    }

                    """))
        let statements = file.functions[0].body.statements

        guard let scoped = statements[0].initialized else {
            Issue.record("the if with an initializer is not recognized")
            return
        }
        if case .declaration(let name, _, _, _, _) = scoped.initializer {
            #expect(name == "x")
        } else {
            Issue.record("unexpected initializer")
        }
        if case .ifStatement = scoped.statement {} else { Issue.record("unexpected statement") }
        // No loop a program can write is mistaken for one.
        #expect(statements[1].initialized == nil)
        #expect(statements[2].initialized == nil)
    }

    @Test func gofmtKeepsTheHeaderOnOneLine() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main

                func main() {
                if v,ok:=m["a"];ok&&v>0{
                f(v)
                }else if w:=v+1 ;w>1 {
                f(w)
                }
                switch y:=len(m);y{
                case 1:
                f(y)
                }
                switch z:=2;{
                case z>1:
                f(z)
                }
                for i:=0;i<2;i++{
                if j:=i*2;j>0{
                continue
                }
                }
                }

                """)

        #expect(
            try GoFormatter.format(source) == """
                package main

                func main() {
                \tif v, ok := m["a"]; ok && v > 0 {
                \t\tf(v)
                \t} else if w := v + 1; w > 1 {
                \t\tf(w)
                \t}
                \tswitch y := len(m); y {
                \tcase 1:
                \t\tf(y)
                \t}
                \tswitch z := 2; {
                \tcase z > 1:
                \t\tf(z)
                \t}
                \tfor i := 0; i < 2; i++ {
                \t\tif j := i * 2; j > 0 {
                \t\t\tcontinue
                \t\t}
                \t}
                }

                """)
    }
}
