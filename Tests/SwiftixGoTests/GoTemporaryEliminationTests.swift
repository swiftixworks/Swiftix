/// The bytecode pass that removes the compiler's single-use temporaries
/// (`GoTemporaryElimination`).
///
/// The compiler runs it on every image. These tests build each program with
/// the pass turned off, apply it, and check that the program prints the
/// same with fewer instructions, and that the compiler's image is the one
/// the pass makes.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go temporary elimination")
struct GoTemporaryEliminationTests: GoTestHarness {

    /// What the program prints with and without the pass, and how many
    /// instructions its functions have in each.
    private func compare(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) throws -> (before: String, after: String, instructions: (Int, Int)) {
        let sources = [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(body, imports: imports, declarations: declarations))
        ]
        let executable = try GoTemporaryElimination.$isEnabled.withValue(false) {
            try GoCompiler.compile(sources: sources)
        }
        let eliminated = GoTemporaryElimination.apply(to: executable)
        #expect(try GoCompiler.compile(sources: sources) == eliminated)
        var before = ""
        var after = ""
        try GoVirtualMachine().run(executable) { before += $0 }
        try GoVirtualMachine().run(eliminated) { after += $0 }
        func count(_ executable: GoExecutable) -> Int {
            executable.functions.reduce(0) { $0 + $1.instructions.count }
        }
        return (before, after, (count(executable), count(eliminated)))
    }

    @Test func aLoopPrintsTheSameWithFewerInstructions() throws {
        let result = try compare(
            """
            s := strings.Repeat("ab,c\\n", 50)
            lines, commas := 0, 0
            for i := 0; i < len(s); i++ {
                c := s[i]
                if c == '\\n' {
                    lines++
                } else if c == ',' {
                    commas++
                }
            }
            fmt.Println(len(s), lines, commas)
            """,
            imports: ["fmt", "strings"])
        #expect(result.before == "250 50 50\n")
        #expect(result.after == result.before)
        #expect(result.instructions.1 < result.instructions.0)
    }

    /// Jumps, closures that capture variables, multiple results, deferred
    /// calls, and `select` name locals and program counters the pass must
    /// keep right.
    @Test func controlFlowClosuresAndSelectSurvive() throws {
        let result = try compare(
            """
            total := 0
            add := func(n int) { total += n }
            for i := 0; i < 10; i++ {
                switch {
                case i%3 == 0:
                    add(i)
                case i%3 == 1 && i > 4:
                    add(2 * i)
                default:
                    continue
                }
            }
            q, r := divmod(17, 5)
            ch := make(chan int, 1)
            ch <- q + r
            select {
            case v := <-ch:
                fmt.Println(total, q, r, v, named())
            default:
                fmt.Println("none")
            }
            """,
            declarations: """
                func divmod(a, b int) (int, int) { return a / b, a % b }

                func named() (n int) {
                    defer func() { n *= 2 }()
                    n = 21
                    return n
                }
                """)
        #expect(result.before == "32 3 2 5 42\n")
        #expect(result.after == result.before)
        #expect(result.instructions.1 < result.instructions.0)
    }
}
