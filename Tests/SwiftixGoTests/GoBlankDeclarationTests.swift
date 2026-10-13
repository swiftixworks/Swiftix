/// The blank identifier where a package declares: `var _ I = (*T)(nil)`,
/// `var _ = register()`, `const _ = iota`, `func _() {}`, `type _ struct{}`.
///
/// A package may have any number of each. They declare nothing, and they
/// are checked like any other declaration; the value of a variable is
/// still evaluated, in its place among the others. What each program prints
/// is what Go 1.24.5 prints for it. An error pinned with its place is at
/// the place of the first one Go's compiler reports; where the message is
/// Go's too it was copied without change, and otherwise it is this
/// dialect's, which names a value by its type.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go blank declarations")
struct GoBlankDeclarationTests: GoTestHarness {

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

    /// Every later stage keeps what a package declares by name, so each blank
    /// variable, function, and type gets one of its own, numbered through the
    /// files of its package. A blank constant is dropped by the parser, and a
    /// diagnostic prints the name as `_`.
    @Test func aBlankDeclarationHasANameNoSourceCanSpell() throws {
        let sources = [
            "package main\nvar _ = 1\nvar a, _ = 2, 3\nconst _ = 4\nfunc _() {}\ntype _ int\n",
            "package main\nvar _ = 5\nfunc main() {}\nfunc _() {}\n",
        ]
        let parsed = try sources.enumerated().map { index, text in
            try GoParser.parse(GoSourceFile(path: "f\(index).go", text: text))
        }
        #expect(parsed[0].globalDeclarations.map(\.name) == ["_", "a", "_"])

        let files = GoBlankNames.name(parsed)
        let marker = String(repeating: String(GoLocalTypes.marker), count: 2)
        #expect(files[0].typeDeclarations.map(\.name) == ["_\(marker)1"])
        #expect(files[0].globalDeclarations.map(\.name) == ["_\(marker)2", "a", "_\(marker)3"])
        #expect(files[0].functions.map(\.name) == ["_\(marker)4"])
        #expect(files[1].globalDeclarations.map(\.name) == ["_\(marker)5"])
        #expect(files[1].functions.map(\.name) == ["main", "_\(marker)6"])
        #expect(GoLocalTypes.sourceNames(in: "_\(marker)12 redeclared") == "_ redeclared")
        // Named once: what was named is left as it is.
        #expect(GoBlankNames.name(files) == files)
    }

    /// Alone, with a type, and in a group. Each initializer runs, in the order
    /// of the source among the variables that have names.
    @Test func aPackageMayDeclareAnyNumberOfBlankVariables() throws {
        #expect(
            try runGoMain("fmt.Println(\"main\", first, last)", declarations: """
                    var _ = say("one")
                    var first = say("first")
                    var _ int = say("two")
                    var (
                        _      = say("three")
                        _ int  = say("four")
                        last   = say("last")
                        _, _   = say("five"), say("six")
                    )
                    var _ int
                    var _, _ string

                    func say(s string) int {
                        fmt.Println("init", s)
                        return len(s)
                    }
                    """)
                == """
                init one
                init first
                init two
                init three
                init four
                init last
                init five
                init six
                main 5 4

                """)
        #expect(
            try runGoMain("fmt.Println(\"main\")", declarations: """
                    var _ = trace("a")

                    func init() { fmt.Println("init function") }

                    var _ = trace("b")

                    func trace(s string) bool {
                        fmt.Println("variable", s)
                        return true
                    }
                    """)
                == "variable a\nvariable b\ninit function\nmain\n")
    }

    /// `var _ I = (*T)(nil)` costs nothing at run time and fails to compile
    /// when `*T` lacks a method. Go reports the value, where it begins.
    @Test func aBlankVariableChecksThatATypeImplementsAnInterface() throws {
        #expect(
            try runGoMain(
                """
                var s shape = &square{side: 3}
                fmt.Println(s.area())
                """,
                declarations: """
                    type shape interface{ area() int }
                    type square struct{ side int }

                    func (s *square) area() int { return s.side * s.side }

                    var _ shape = (*square)(nil)
                    var _ shape = &square{}
                    var (
                        _ shape = (*square)(nil)
                        _ interface{} = square{}
                    )
                    """)
                == "9\n")
        #expect(
            firstError("", declarations: """
                    type shape interface{ area() int }
                    type square struct{ side int }

                    func (s *square) area() int { return s.side * s.side }

                    var _ shape = square{}
                    """)
                == "8:15: cannot use square as shape value")
        #expect(
            firstError("", declarations: """
                    type shape interface{ area() int }
                    type square struct{ side int }

                    func (s *square) area() int { return s.side * s.side }

                    type circle struct{}

                    var _ shape = (*circle)(nil)
                    """)
                == "10:15: cannot use *circle as shape value")
        #expect(
            firstError("", declarations: """
                    type shape interface{ area() int }
                    type square struct{ side int }

                    func (s *square) area() int { return s.side * s.side }

                    type circle struct{}

                    var (
                        _ shape = &square{}
                        _ shape = &circle{}
                    )
                    """)
                == "12:15: cannot use *circle as shape value")
        #expect(
            firstError("", declarations: """
                    type shape interface{ area() int }
                    type square struct{ side int }

                    func (s *square) area() int { return s.side * s.side }

                    type circle struct{}

                    func (c *circle) area(scale int) int { return scale }

                    var _ shape = (*circle)(nil)
                    """)
                == "12:15: cannot use *circle as shape value")
        #expect(
            firstError("var _ shape = (*circle)(nil)", declarations: """
                    type shape interface{ area() int }
                    type square struct{ side int }

                    func (s *square) area() int { return s.side * s.side }

                    type circle struct{}
                    """)
                == "10:15: cannot use *circle as shape value")
    }

    /// It takes the value at its place and keeps none.
    @Test func theBlankIdentifierStandsAmongSeveralNames() throws {
        #expect(
            try runGoMain("fmt.Println(a, b, c, d)", declarations: """
                    var a, _ = pair("first")
                    var _, b = pair("second")
                    var _, _ = pair("third")
                    var c, _, d = 1, 2, 3

                    func pair(s string) (int, int) {
                        fmt.Println("pair", s)
                        return len(s), len(s) * 2
                    }
                    """)
                == "pair first\npair second\npair third\n5 12 1 3\n")
    }

    /// Nothing is declared, and the constants after it count on.
    @Test func aBlankConstantTakesItsPlaceInTheCountOfIota() throws {
        #expect(
            try runGoMain(
                """
                const (
                    _ = iota * 10
                    ten
                    _
                    thirty
                )
                fmt.Println(kb, mb, gb, first, third, d, ten, thirty)
                """,
                declarations: """
                    const _ = 5
                    const _, _ = 6, 7

                    const (
                        _  = iota
                        kb = 1 << (10 * iota)
                        mb
                        gb
                    )

                    const (
                        first = iota
                        _
                        third
                        _, d = iota, iota * 10
                    )
                    """)
                == "1024 1048576 1073741824 0 2 30 10 30\n")
    }

    /// Go allows any number of `func _()`, which the generators of code use
    /// to make the compiler check something.
    @Test func blankFunctionsMethodsAndTypesAreCheckedAndNeverRun() throws {
        #expect(
            try runGoMain("fmt.Println(t{}.name())", declarations: """
                    type t struct{}

                    type _ int
                    type _ struct{ a, b int }

                    func _() {}
                    func _() { fmt.Println("never") }
                    func _(a, b int) int { return a + b }

                    func (t) _() {}
                    func (t) _() int { return 1 }
                    func (t) name() string { return "t" }
                    """)
                == "t\n")
        #expect(
            firstError("", declarations: "func _() int { return missing }")
                == "3:23: undefined: missing")
        #expect(
            firstError("", declarations: """
                    type t struct{}

                    func (t) _() string { return 1 + nothing }
                    """)
                == "5:34: undefined: nothing")
    }

    /// Nothing it declares can be read, called, or stored in by name.
    @Test func theBlankIdentifierIsNoValue() {
        #expect(
            firstError("fmt.Println(_)")
                == "5:13: cannot use _ as value or type")
        #expect(
            firstError(
                """
                x := _
                fmt.Println(x)
                """,
                declarations: "var _ = 1")
                == "5:6: cannot use _ as value or type")
        #expect(
            firstError("_()", declarations: "func _() {}")
                == "5:1: cannot use _ as value or type")
        #expect(
            firstError("_++")
                == "5:1: cannot use _ as value or type")
        #expect(
            firstError(
                """
                p := &_
                fmt.Println(p)
                """)
                == "5:7: cannot use _ as value or type")
        #expect(
            firstError("", declarations: "func f(_ int) int { return _ + 1 }")
                == "3:28: cannot use _ as value or type")
    }

    /// A name nothing declares is reported as that, where it is, and a value
    /// that does not fit the type where it begins.
    @Test func whatABlankVariableIsGivenIsChecked() {
        #expect(
            firstError("", declarations: "var _ = undefined")
                == "3:9: undefined: undefined")
        #expect(
            firstError("", declarations: "var _ = 1 + missing(2)")
                == "3:13: undefined: missing")
        #expect(
            firstError("", declarations: "var _ int = \"s\"")
                == "3:13: cannot use string as int value")
        #expect(
            firstError("", declarations: "var _, _ = 1, undefined")
                == "3:15: undefined: undefined")
    }

    /// Any number of them in one block: each value is checked and evaluated.
    @Test func aFunctionMayDeclareBlankVariablesToo() throws {
        #expect(
            try runGoMain(
                """
                var _ = say("a")
                var _ int = say("b")
                var _, _ = say("c"), say("d")
                var _, _ = two()
                var x, _ = two()
                const _ = 5
                _ = say("e")
                _, y := two()
                fmt.Println(x, y)
                """,
                declarations: """
                    func say(s string) int {
                        fmt.Println("say", s)
                        return 0
                    }

                    func two() (int, int) { return 1, 2 }
                    """)
                == "say a\nsay b\nsay c\nsay d\nsay e\n1 2\n")
        #expect(
            firstError("_ := 1")
                == "5:3: no new variables on left side of :=")
        #expect(
            firstError("_, _ := 1, 2")
                == "5:6: no new variables on left side of :=")
    }

    /// Blank declarations of several files and several packages are apart,
    /// and a `_` in a statement of a package that has them is still the blank
    /// identifier. Initialization goes package by package, in the order of the
    /// source.
    @Test func everyPackageOfAModuleHasItsOwn() throws {
        #expect(
            try runModule([
                (
                    "lib/lib.go",
                    """
                    package lib

                    import f "fmt"

                    type Shape interface{ Area() int }
                    type Square struct{ Side int }

                    func (s Square) Area() int { return s.Side * s.Side }

                    var _ Shape = Square{}
                    var _ Shape = (*Square)(nil)
                    var _ = note("lib one")
                    var _, Count = pair()
                    var _ = note("lib two")

                    func _() { f.Println("never") }
                    func _() {}

                    func note(s string) int {
                        f.Println("init", s)
                        return len(s)
                    }

                    func pair() (int, int) {
                        f.Println("pair")
                        return 1, 2
                    }

                    func Each(_ int, visit func(int, string)) {
                        for i := 0; i < 2; i++ {
                            _ = i
                            _, unused := i, i
                            _ = unused
                            visit(i, "x")
                        }
                    }
                    """
                ),
                (
                    "lib/more.go",
                    """
                    package lib

                    var _ = note("lib more")
                    var _ Shape = Square{Side: 2}

                    func _() {}
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        f "fmt"

                        "example/m/lib"
                    )

                    type local interface{ Area() int }

                    var _ local = lib.Square{}
                    var _ = say("main one")
                    var _ lib.Shape = lib.Square{}

                    func _() {}

                    func say(s string) int {
                        f.Println("init", s)
                        return 0
                    }

                    func main() {
                        total := 0
                        lib.Each(1, func(i int, _ string) { total += i })
                        lib.Each(2, func(int, string) { total += 10 })
                        f.Println(total, lib.Count)
                    }
                    """
                ),
            ])
                == "init lib one\npair\ninit lib two\ninit lib more\ninit main one\n21 2\n")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type Shape interface{ Area() int }
                    type Circle struct{}

                    var _ Shape = (*Circle)(nil)
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import _ "example/m/lib"

                    func main() {}
                    """
                ),
            ])
                == "lib/lib.go:6:15: cannot use *Circle as Shape value")
    }

    /// A blank variable of an alias's type, and one in a function beside a
    /// type the function declares.
    @Test func aliasesAndLocalTypesSeeThem() throws {
        #expect(
            try runGoMain(
                """
                type point struct{ x, y number }
                type sink func(point, ...number) number
                var _ sink = func(point, ...number) number { return 0 }
                var _ point = point{}
                var s sink = func(p point, _ ...number) number { return p.x + p.y }
                fmt.Println(s(point{1, 2}), s(point{3, 4}, 5, 6))
                """,
                declarations: """
                    type handler = func(int, string) int
                    type number = int

                    var _ handler = func(number, string) number { return 0 }
                    var _, _ = pair()
                    var _ = []number{1, 2}

                    func pair() (number, number) { return 1, 2 }
                    """)
                == "3 7\n")
    }
}
