/// Compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `&^=`,
/// `<<=`, `>>=`), `return f()` forwarding of a multi-result call, and
/// package-level initializers that call imported packages.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go compound assignment and result forwarding")
struct GoCompoundAssignmentTests: GoTestHarness {

    @Test func everyOperatorAssignsTheCombinedValue() throws {
        let output = try runGoMain(
            """
            x := 31
            x += 2
            x -= 1
            x *= 3
            x /= 2
            x %= 7
            x <<= 4
            x >>= 1
            x |= 5
            x &= 63
            x ^= 420
            x &^= 16
            fmt.Println(x)
            """)
        #expect(output == "385\n")
    }

    @Test func targetsMayBeVariablesElementsFieldsAndGlobals() throws {
        let output = try runGoMain(
            """
            var b byte = 250
            b += 10
            s := "a"
            s += "b"
            a := []int{1, 2}
            a[1] += 5
            p := point{N: 1}
            p.N *= 10
            q := &p
            q.N -= 1
            *counter += 2
            m := map[string]int{"k": 1}
            m["k"] += 41
            total += 1
            for i := 0; i < 6; i += 2 {
                total += i
            }
            fmt.Println(b, s, a[1], p.N, m["k"], total)
            """,
            declarations: "type point struct {\n\tN int\n}\nvar total = 16\nvar counter = &total")
        #expect(output == "4 ab 7 9 42 25\n")
    }

    @Test func invalidCompoundAssignmentsAreDiagnosed() {
        #expect(goMainDiagnostic("x := 1\nx += \"s\"") == "mismatched types int and string")
        #expect(goMainDiagnostic("s := \"a\"\ns -= \"a\"") == "operator requires integer operands")
        #expect(goMainDiagnostic("x += 1") == "undefined: x")
        #expect(goMainDiagnostic("x := 1\nx <<= -1") == "invalid negative shift count -1")
        #expect(goMainDiagnostic("x := 1\nx +=") == "expected expression")
        #expect(
            goMainDiagnostic("x += 1", declarations: "const x = 1") == "cannot assign to x")
        // The target is evaluated twice, so anything with an effect is refused.
        #expect(
            goMainDiagnostic(
                "a := []int{1}\na[next()] += 1", declarations: "func next() int { return 0 }")
                == "+= target must not contain a call or a channel receive")
        #expect(
            goMainDiagnostic("c := make(chan int, 1)\na := []int{1}\na[<-c] |= 1")
                == "|= target must not contain a call or a channel receive")
    }

    @Test func compoundAssignmentIsCheapAndBounded() throws {
        // One loop iteration with `+=` executes what `total = total + index` does.
        func instructions(_ statement: String) throws -> Int {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(
                        "total := 0\nfor index := 0; index < 500; index++ {\n\(statement)\n}\nfmt.Println(total)"))
            ])
            return executable.functions.first { $0.name == "main" }?.instructions.count ?? 0
        }
        #expect(try instructions("total += index") == instructions("total = total + index"))
        #expect(throws: GoRuntimeError.instructionLimitExceeded) {
            try runGoMain(
                "x := 0\nfor {\nx += 1\n}",
                machine: GoVirtualMachine(maximumInstructions: 5_000))
        }
    }

    @Test func gofmtKeepsCompoundAssignmentsAndRewritesOnlyTheirOperands() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc main(){x:=1\nx+=2\nx<<=1\nx&^=3\nx = x + 4\n}\n")
        let formatted = try GoFormatter.format(source)
        #expect(
            formatted
                == "package main\n\nfunc main() {\n\tx := 1\n\tx += 2\n\tx <<= 1\n\tx &^= 3\n\tx = x + 4\n}\n")
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: formatted)) == formatted)

        // `a + b` matches the written addition, never the one `+=` stands for.
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(path: "main.go", text: formatted), rule: "a + b -> b + a")
        #expect(rewritten.text.contains("\tx += 2\n"))
        #expect(rewritten.text.contains("\tx = 4 + x\n"))
    }

    // MARK: Result forwarding

    @Test func returnForwardsEveryResultOfACall() throws {
        let output = try runGoMain(
            """
            a, b := forward()
            c, d := viaMethod(box{N: 9})
            rows, columns := native()
            e, f := named()
            fmt.Println(a, b, c, d, rows, columns, e+10, f)
            """,
            imports: ["fmt", "swiftix/userland"],
            declarations: """
                type box struct {
                    N int
                }
                func (b box) two() (int, bool) { return b.N, true }
                func pair(x int) (int, string) { return x, "p" }
                func forward() (int, string) { return pair(4) }
                func viaMethod(b box) (int, bool) { return b.two() }
                func native() (int, int) { return userland.WindowSize() }
                func bytes() (byte, string) { return 250, "b" }
                func named() (first byte, second string) { return bytes() }
                """)
        #expect(output == "4 p 9 true 0 0 4 b\n")
    }

    @Test func forwardedResultsMustMatchTheSignature() {
        let one = "func one() int { return 1 }\nfunc two() (int, int) { return 1, 2 }\n"
        #expect(
            goMainDiagnostic("f()", declarations: one + "func f() (int, string) { return one() }")
                == "not enough return values")
        #expect(
            goMainDiagnostic("f()", declarations: one + "func f() (int, string) { return two() }")
                == "cannot use int as string value in return statement")
        #expect(
            goMainDiagnostic(
                "f()",
                declarations: one + "func three() (int, int, int) { return 1, 2, 3 }\nfunc f() (int, int) { return three() }")
                == "too many return values")
        // Results still cannot be spread into an argument list.
        #expect(
            goMainDiagnostic(
                "fmt.Println(sum(two()))",
                declarations: one + "func sum(a int, b int) int { return a + b }")
                == "not enough arguments in call to sum")
    }

    // MARK: Package-level initializers

    @Test func packageLevelInitializersMayCallImportedPackages() throws {
        let output = try runGoMain(
            "fmt.Println(banner, width, joined)",
            imports: ["fmt", "strings", "strconv"],
            declarations: """
                var banner = strings.Repeat("=", 3)
                var width = len(strconv.Itoa(1234))
                var joined = strings.Join([]string{banner, "x"}, "-")
                """)
        #expect(output == "=== 4 ===-x\n")

        // The initializer sees only the imports of its own file.
        let first = GoSourceFile(
            path: "a.go", text: "package main\nvar banner = strings.Repeat(\"=\", 3)\n")
        let second = GoSourceFile(
            path: "b.go",
            text: "package main\nimport \"fmt\"\nimport \"strings\"\nfunc main() {\n\tfmt.Println(strings.Repeat(banner, 2))\n}\n")
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [first, second])
        }
    }
}
