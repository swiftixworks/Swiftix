/// Variables of a loop: each iteration has its own, which a program can
/// tell once a pointer outlives the iteration. The compiler pays for that
/// only where a pointer can reach the variable. What such programs print is
/// compared with Go in `GoConformanceTests`.

@testable import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go loop variables")
struct GoLoopVariableTests: GoTestHarness {

    private static let declarations = """
        type counter struct {
            n int
        }
        func (c *counter) bump() {
            c.n++
        }
        func (c counter) value() int {
            return c.n
        }
        func sum(pointers []*int) int {
            total := 0
            for _, pointer := range pointers {
                total = total*10 + *pointer
            }
            return total
        }
        """

    /// The calls that start a new variable in the compiled `main`.
    private func renewals(_ body: String) throws -> Int {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go", text: goMainSource(body, declarations: Self.declarations))
        ])
        guard let main = executable.functions.first(where: { $0.name == "main" }) else { return -1 }
        return main.instructions.filter { instruction in
            if case .call(let name, _) = instruction { return GoNative.freshLocal(name) != nil }
            return false
        }.count
    }

    @Test func aPointerKeepsTheVariableOfItsIteration() throws {
        let output = try runGoMain(
            """
            var declared []*int
            var clause []*int
            var ranged []*int
            source := []int{7, 8, 9}
            for i := 1; i < 4; i++ {
                x := i * 2
                declared = append(declared, &x)
                clause = append(clause, &i)
            }
            for _, value := range source {
                ranged = append(ranged, &value)
            }
            fmt.Println(sum(declared), sum(clause), sum(ranged))
            *declared[0] = 5
            fmt.Println(sum(declared))
            var last *int
            for i := 0; i < 3; i++ {
                last = &i
                *last += 10
            }
            fmt.Println(*last)
            """,
            declarations: Self.declarations)

        // The last loop ends after one iteration: the store through the
        // pointer changes that iteration's `i`, which the next one copies.
        #expect(output == "246 123 789\n546\n10\n")
    }

    @Test func aMethodWithAPointerReceiverAndASlicedArrayCount() throws {
        let output = try runGoMain(
            """
            var kept []*counter
            var views [][]int
            for i := 0; i < 3; i++ {
                c := counter{n: i}
                c.bump()
                kept = append(kept, &c)
                buffer := [2]int{i, i}
                views = append(views, buffer[:])
            }
            fmt.Println(kept[0].n, kept[1].n, kept[2].n, views)
            """,
            declarations: Self.declarations)

        #expect(output == "1 2 3 [[0 0] [1 1] [2 2]]\n")
    }

    @Test func onlyAVariableAPointerCanReachIsRenewed() throws {
        // Nothing takes an address: the loop compiles as it always did.
        #expect(
            try renewals(
                """
                total := 0
                for i := 0; i < 3; i++ {
                    step := i * 2
                    c := counter{n: step}
                    total += c.value()
                }
                for index, value := range []int{1, 2} {
                    total += index + value
                }
                fmt.Println(total)
                """) == 0)
        // Outside a loop a declaration runs once in a call.
        #expect(try renewals("x := 1\np := &x\nfmt.Println(*p)") == 0)
        // One declaration in the body, and the clause variable once an iteration.
        #expect(
            try renewals(
                """
                var list []*int
                for i := 0; i < 3; i++ {
                    x := i
                    y := i
                    list = append(list, &x)
                    fmt.Println(y)
                }
                fmt.Println(len(list))
                """) == 1)
        #expect(
            try renewals(
                """
                var list []*int
                for i := 0; i < 3; i++ {
                    list = append(list, &i)
                }
                fmt.Println(len(list))
                """) == 1)
        // A value receiver takes no address; a pointer receiver does.
        #expect(
            try renewals(
                "for i := 0; i < 3; i++ {\nc := counter{n: i}\nfmt.Println(c.value())\n}") == 0)
        #expect(
            try renewals(
                "for i := 0; i < 3; i++ {\nc := counter{n: i}\nc.bump()\nfmt.Println(c.n)\n}") == 1)
        // A slice shares no storage with its variable; an array does.
        #expect(
            try renewals(
                "for i := 0; i < 3; i++ {\ns := []int{i}\nfmt.Println(s[:1])\n}") == 0)
        #expect(
            try renewals(
                "for i := 0; i < 3; i++ {\na := [1]int{i}\nfmt.Println(a[:1])\n}") == 1)
    }

    @Test func theAnalysisFindsWhatAPointerCanReach() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: """
                    package main
                    func main() {
                        p := &a
                        q := &b.field[0]
                        r := *c
                        d.join(x)
                        e.inner.bump()
                        f := g[1:]
                        go func(h int) {
                            k := &hidden
                        }(m)
                        if n := &o; n != nil {
                        }
                    }

                    """))
        let variables = GoAddressedVariables(file.functions[0].body)

        #expect(variables.addressed == ["a", "b", "o"])
        #expect(variables.sliced == ["g"])
        #expect(variables.receivers == ["d": ["join"]])
        #expect(variables.nestedReceivers == ["e": ["bump"]])
        #expect(GoAddressedVariables.root(of: .integer(1, position: file.functions[0].position)) == nil)
    }

    @Test func aRenewalNamesALocalOfTheFrame() {
        #expect(GoNative.freshLocal("$fresh.12") == 12)
        #expect(GoNative.freshLocal("$fresh.") == nil)
        #expect(GoNative.freshLocal("$fresh.x") == nil)
        #expect(GoNative.freshLocal("$new") == nil)
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 1,
                    instructions: [.call("$fresh.3", argumentCount: 0), .return])
            ])
        #expect(throws: GoRuntimeError.invalidLocal(3)) {
            try GoVirtualMachine().run(executable) { _ in }
        }
    }
}
