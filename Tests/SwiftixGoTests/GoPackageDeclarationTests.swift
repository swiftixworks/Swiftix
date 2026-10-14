/// What a package declares, where Go and this dialect differed: several
/// variables that one expression gives their values, the order package
/// variables are initialized in, and where a name declared twice is
/// reported.
///
/// What each program prints is what Go 1.24.5 prints for it. An error pinned
/// with its place is at the place of the first one Go's compiler reports;
/// where the message is Go's too it was copied without change, and otherwise
/// it is this dialect's.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go package-level declarations")
struct GoPackageDeclarationTests: GoTestHarness {

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

    /// The packages of a module `example/m` whose files are `files`, each
    /// by its path below the module's root.
    private func packages(_ files: [(String, String)]) -> [GoPackageSource] {
        var byPath: [String: [GoSourceFile]] = [:]
        for (path, text) in files {
            let directory = path.split(separator: "/").dropLast().joined(separator: "/")
            byPath[directory.isEmpty ? "example/m" : "example/m/" + directory, default: []]
                .append(GoSourceFile(path: path, text: text))
        }
        return byPath.keys.sorted().map {
            GoPackageSource(importPath: $0, sources: byPath[$0] ?? [])
        }
    }

    /// What the module prints.
    private func runModule(_ files: [(String, String)]) throws -> String {
        let executable = try GoCompiler.compile(packages: packages(files), root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// The first error of compiling the module, as Go prints it:
    /// `path:line:column: message`.
    private func moduleError(_ files: [(String, String)]) -> String? {
        do {
            _ = try GoCompiler.compile(packages: packages(files), root: "example/m")
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    /// `GoGlobalDeclaration` has one name and one value. `var a, b = f()` is a
    /// declaration for each name, whose value is its place among the values of
    /// the one expression.
    @Test func severalVariablesOfOneExpressionAreSeveralDeclarations() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\nvar a, b = f()\nvar c, d = 1, 2\nfunc main() {}\n"))
        let globals = file.globalDeclarations

        #expect(globals.map(\.name) == ["a", "b", "c", "d"])
        let first = try #require(globals[0].expression?.groupedResult)
        let second = try #require(globals[1].expression?.groupedResult)
        #expect(first.index == 0)
        #expect(second.index == 1)
        #expect(first.count == 2)
        // Both hold the one call.
        #expect(first.value == second.value)
        // A value for each name is no group.
        #expect(globals[2].expression?.groupedResult == nil)
        #expect(globals.map { file.namePosition(of: $0).column } == [5, 8, 5, 8])
    }

    /// The call is made once, where the first of its variables is
    /// initialized.
    @Test func oneCallGivesSeveralPackageVariablesTheirValues() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(a, b, c, d)
                x, y = x+1, y+"!"
                px := &x
                *px += 10
                fmt.Println(x, y, n, err, count, failed != nil)
                """,
                imports: ["fmt", "strconv"],
                declarations: """
                    var a, b = pair("first")
                    var (
                        c, d = pair("second")
                        x, y = pair("third")
                    )
                    var n, err = fmt.Println("printed")
                    var count, failed = strconv.Atoi("x")

                    func pair(s string) (int, string) {
                        fmt.Println("pair", s)
                        return len(s), s
                    }
                    """)
                == """
                pair first
                pair second
                pair third
                printed
                5 first 6 second
                16 third! 8 <nil> 0 true

                """)
        #expect(
            try runGoMain(
                """
                p.a = 9
                q.b = 8
                fmt.Println(*p, q, three, e == nil)
                """,
                declarations: """
                    type both struct{ a, b int }

                    var p, q = make2()
                    var three, e = func() (int, error) { return 3, nil }()

                    func make2() (*both, both) { return &both{1, 2}, both{3, 4} }
                    """)
                == "{9 2} {3 8} 3 true\n")
    }

    /// The comma-ok forms, as in a function.
    @Test func aMapIndexATypeAssertionAndAReceiveGiveTwo() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(v, ok, w, missing)
                fmt.Println(n, isInt, s == "", isString)
                fmt.Println(first, open)
                """,
                declarations: """
                    var table = map[string]int{"a": 1}
                    var v, ok = table["a"]
                    var w, missing = table["zz"]

                    var boxed any = 7
                    var n, isInt = boxed.(int)
                    var s, isString = boxed.(string)

                    var queue = filled()
                    var first, open = <-queue

                    func filled() chan int {
                        c := make(chan int, 1)
                        c <- 4
                        return c
                    }
                    """)
                == "1 true 0 false\n7 true true false\n4 true\n")
    }

    /// Go reports a number of values that does not match where the values
    /// begin.
    @Test func theNumberAndTheTypesOfTheValuesAreChecked() {
        #expect(
            firstError("", declarations: """
                    var a, b = three()

                    func three() (int, int, int) { return 1, 2, 3 }
                    """)
                == "3:12: assignment mismatch: 2 variables but three returns 3 values")
        #expect(
            firstError("", declarations: """
                    var a, b = one()

                    func one() int { return 1 }
                    """)
                == "3:12: assignment mismatch: 2 variables but one returns 1 value")
        #expect(
            firstError("", declarations: """
                    var a, b int = pair()

                    func pair() (int, string) { return 1, "a" }
                    """)
                == "3:16: cannot use pair() (value of type string) as int value in assignment")
        #expect(
            firstError("", declarations: """
                    var table = map[string]int{}
                    var a, b, c = table["k"]
                    """)
                == "4:15: assignment mismatch: 3 variables but 1 value")
    }

    /// Again and again the first variable, as the source has them, that reads
    /// no variable still to be initialized, directly or through the functions it
    /// calls. A variable that waits for a later one lets the independent ones
    /// between them go first.
    @Test func variablesAreInitializedInGoOrder() throws {
        #expect(
            try runGoMain("fmt.Println(total, verbose, base)", declarations: """
                    var total = add("total", base, 2)
                    var verbose = show("verbose", 1)
                    var base = show("base", 40)

                    func add(name string, a, b int) int {
                        fmt.Println("init", name)
                        return a + b
                    }

                    func show(name string, n int) int {
                        fmt.Println("init", name)
                        return n
                    }
                    """)
                == "init verbose\ninit base\ninit total\n42 1 40\n")
        #expect(
            try runGoMain("fmt.Println(a, b, c, d, e)", declarations: """
                    var a = needs("a", z, y)
                    var b = show("b", 2)
                    var z = show("z", 26)
                    var c, d = two("c d", e)
                    var y = show("y", 25)
                    var e = show("e", 5)

                    const scale = 2

                    func needs(name string, values ...int) int {
                        fmt.Println("init", name)
                        sum := 0
                        for _, v := range values {
                            sum += v * scale
                        }
                        return sum
                    }

                    func show(name string, n int) int {
                        fmt.Println("init", name)
                        return n * scale
                    }

                    func two(name string, n int) (int, int) {
                        fmt.Println("init", name)
                        return n, n + 1
                    }
                    """)
                == "init b\ninit z\ninit y\ninit a\ninit e\ninit c d\n204 4 10 11 10\n")
        #expect(
            try runGoMain("fmt.Println(x, y)", declarations: """
                    var x, _ = pair()
                    var _ = show("blank")
                    var y = show("y")
                    var _, _ = pair()

                    func pair() (int, int) {
                        fmt.Println("pair")
                        return y, 2
                    }

                    func show(s string) int {
                        fmt.Println("init", s)
                        return 5
                    }
                    """)
                == "init blank\ninit y\npair\npair\n5 5\n")
    }

    /// The files of a package are one list of variables, and a package is
    /// initialized after those it imports.
    @Test func initializationFollowsTheFilesAndThePackages() throws {
        #expect(
            try runModule([
                (
                    "lib/a.go",
                    """
                    package lib

                    import "fmt"

                    var A = trace("A", B)
                    var _ = trace("blank-a", A)

                    func trace(name string, n int) int {
                        fmt.Println(name, n)
                        return n + 1
                    }
                    """
                ),
                (
                    "lib/b.go",
                    """
                    package lib

                    var B = trace("B", 0)
                    var _ = trace("blank-b", B)
                    var _, C = two()

                    func two() (int, int) {
                        trace("two", A)
                        return 1, 2
                    }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    var x, _ = pair()
                    var _ = show("m1")
                    var y = show("y")

                    func pair() (int, int) {
                        fmt.Println("pair")
                        return y, 2
                    }

                    func show(s string) int {
                        fmt.Println("init", s)
                        return 5
                    }

                    func main() { fmt.Println(lib.A, lib.B, lib.C, x, y) }
                    """
                ),
            ])
                == "B 0\nA 1\nblank-a 2\nblank-b 1\ntwo 2\ninit m1\ninit y\npair\n2 1 2 5 5\n")
    }

    /// At the name, and at the one of the two that comes second in the
    /// source, whatever kinds of declaration they are.
    @Test func aNameDeclaredTwiceIsReportedWhereItIsDeclaredAgain() {
        #expect(
            firstError("", declarations: """
                    var x = 1
                    var x = 2
                    """)
                == "4:5: x redeclared in this block\n\tmain.go:3:5: other declaration of x")
        #expect(
            firstError("", declarations: """
                    var (
                        a = 1
                        b, a = 2, 3
                    )
                    """)
                == "5:8: a redeclared in this block\n\tmain.go:4:5: other declaration of a")
        #expect(
            firstError("", declarations: """
                    const (
                        x, _, y = 1, 2, 3
                        y = 4
                    )
                    """)
                == "5:5: y redeclared in this block\n\tmain.go:4:11: other declaration of y")
        #expect(
            firstError("", declarations: """
                    func f() {}
                    var f = 1
                    """)
                == "4:5: f redeclared in this block\n\tmain.go:3:6: other declaration of f")
        #expect(
            firstError("", declarations: """
                    var f = 1
                    func f() {}
                    """)
                == "4:6: f redeclared in this block\n\tmain.go:3:5: other declaration of f")
        #expect(
            firstError("", declarations: """
                    type f int
                    func f() {}
                    """)
                == "4:6: f redeclared in this block\n\tmain.go:3:6: other declaration of f")
        #expect(
            firstError("", declarations: """
                    var _, x = 1, 2
                    var x = 3
                    """)
                == "4:5: x redeclared in this block\n\tmain.go:3:8: other declaration of x")
        #expect(
            firstError(
                """
                var x = 1
                var x = 2
                fmt.Println(x)
                """)
                == "6:5: x redeclared in this block\n\tmain.go:5:5: other declaration of x")
        #expect(
            firstError(
                """
                x := 1
                var y, x = 2, 3
                fmt.Println(x, y)
                """)
                == "6:8: x redeclared in this block\n\tmain.go:5:1: other declaration of x")
    }

    /// Nothing else may have those names in a package.
    @Test func initAndMainAreFunctions() {
        #expect(
            firstError("", declarations: "var init = 1")
                == "3:5: cannot declare init - must be func")
        #expect(
            firstError("", declarations: "const init = 1")
                == "3:7: cannot declare init - must be func")
        #expect(
            firstError("", declarations: "type init int")
                == "3:6: cannot declare init - must be func")
    }

    /// Go refuses the method.
    @Test func aFieldAndAMethodMayNotShareAName() {
        #expect(
            firstError("", declarations: """
                    type t struct{ a int }

                    func (t) a() {}
                    """)
                == "5:10: field and method with the same name a\n\tmain.go:3:16: other declaration of a")
        #expect(
            firstError("", declarations: """
                    type t struct{ a, b int }

                    func (x *t) b() int { return x.a }
                    """)
                == "5:13: field and method with the same name b\n\tmain.go:3:19: other declaration of b")
    }

    /// A package-level value that names nothing is reported as that, where
    /// the name is.
    @Test func aNameNothingDeclaresIsNoCycle() {
        #expect(
            firstError("", declarations: "var x = y + 1")
                == "3:9: undefined: y")
        #expect(
            firstError("", declarations: """
                    var x = f(missing)

                    func f(n int) int { return n }
                    """)
                == "3:11: undefined: missing")
    }
}
