/// A block that is a statement of its own, `{ ... }`: its scope, what
/// `break` and `continue` mean inside it, and whether it ends a function.
/// How `gofmt` lays blocks out is compared with Go's in
/// `GoGofmtConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go block statements")
struct GoBlockStatementTests: GoTestHarness {

    @Test func aBlockIsCarriedAsALoopNoSourceCanWrite() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\nfunc main() {\n {\n  x := 1\n  _ = x\n }\n for {\n }\n {\n }\n}\n"))
        let statements = file.functions[0].body.statements

        #expect(statements.count == 3)
        #expect(statements[0].block?.statements.count == 2)
        #expect(statements[1].block == nil)
        #expect(statements[2].block?.statements.isEmpty == true)
        // Neither is a statement with an initializer, which is carried alike.
        #expect(statements.allSatisfy { $0.initialized == nil })
    }

    @Test func aBlockHasAScopeOfItsOwn() throws {
        #expect(
            try runGoMain(
                """
                x := 1
                {
                    x := 10
                    fmt.Print(x, " ")
                    {
                        x := 100
                        fmt.Print(x, " ")
                    }
                    x++
                    fmt.Print(x, " ")
                }
                {
                    x = 2
                }
                fmt.Println(x)
                """) == "10 100 11 2\n")
        #expect(goMainDiagnostic("{\n x := 1\n fmt.Println(x)\n}\nfmt.Println(x)") == "undefined: x")
    }

    @Test func breakAndContinueLookPastABlock() throws {
        #expect(
            try runGoMain(
                """
                for i := 0; i < 6; i++ {
                    {
                        if i == 1 {
                            continue
                        }
                        {
                            if i == 4 {
                                break
                            }
                        }
                    }
                    fmt.Print(i)
                }
                switch {
                default:
                    {
                        break
                    }
                    fmt.Print("unreachable")
                }
                fmt.Println()
                """) == "023\n")
        #expect(goMainDiagnostic("{\n break\n}") == "break is not in a loop, switch, or select")
    }

    @Test func aBlockEndsAFunctionWhenItsLastStatementDoes() throws {
        #expect(
            try runGoMain(
                "fmt.Println(sign(-1), sign(0), sign(1))",
                declarations: """
                    func sign(n int) string {
                        if n < 0 {
                            return "-"
                        }
                        {
                            if n == 0 {
                                return "0"
                            }
                            {
                                return "+"
                            }
                        }
                    }
                    """) == "- 0 +\n")
        #expect(
            goMainDiagnostic(
                "fmt.Println(f(1))",
                declarations: "func f(n int) int {\n {\n  if n > 0 {\n   return 1\n  }\n }\n}")
                == "missing return")
        // A `break` in the block leaves the loop around it, which then ends.
        #expect(
            goMainDiagnostic(
                "fmt.Println(f(1))",
                declarations: "func f(n int) int {\n for {\n  {\n   break\n  }\n }\n}")
                == "missing return")
    }

    @Test func aBlockMustBeClosed() {
        #expect(goMainDiagnostic("{\n fmt.Println(1)") == "expected '}'")
    }

    @Test func gofmtAndItsRulesMeetABlock() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\n\nfunc main() {\n\tx := 1\n\t{\n\t\tx := 2+0\n\t\t_ = x\n\t}\n\t{ _ = x }\n\t{}\n}\n")
        #expect(
            try GoFormatter.format(source)
                == "package main\n\nfunc main() {\n\tx := 1\n\t{\n\t\tx := 2 + 0\n\t\t_ = x\n\t}\n\t{\n\t\t_ = x\n\t}\n\t{\n\t}\n}\n")
        // A rule reaches the statements of the block and nothing the parser
        // made up to carry it.
        #expect(
            try GoSourceRewriter.rewrite(source, rule: "a + 0 -> a").text.contains("x := 2\n"))
    }
}
