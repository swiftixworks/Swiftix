/// Types declared inside functions: what the parser makes of them, how they
/// become types of the package, their scope and identity, the diagnostics,
/// and how `gofmt -r` meets them. What such programs print is compared with
/// Go in `GoConformanceTests`, and how `gofmt` lays them out in
/// `GoGofmtConformanceTests`.

@testable import SwiftixGo
@testable import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go local types")
struct GoLocalTypeTests: GoTestHarness {

    private func parse(_ text: String, path: String = "main.go") throws -> GoFile {
        try GoParser.parse(GoSourceFile(path: path, text: text))
    }

    private func output(_ text: String) throws -> String {
        try output([("main.go", text)])
    }

    private func output(_ files: [(path: String, text: String)]) throws -> String {
        let executable = try GoCompiler.compile(
            sources: files.map { GoSourceFile(path: $0.path, text: $0.text) })
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    private func diagnostic(_ text: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    /// `body` as the statements of `main`, after `import "fmt"`.
    private func program(_ body: String) -> String {
        "package main\nimport \"fmt\"\nfunc main() {\n" + body + "\n}\n"
    }

    private func hoisted(_ name: String, _ number: Int) -> String {
        name + String(GoLocalTypes.marker) + String(number)
    }

    // MARK: Syntax

    @Test func aFunctionMayDeclareTypes() throws {
        let file = try parse(
            """
            package main

            func main() {
                type id int
                type pair struct {
                    a id
                }
                type (
                    names []string
                    table map[string]*pair
                )
                type ()
                var p pair
                p.a = 1
            }
            """)

        // A declaration is a statement where it stands, one for each type.
        let statements = file.functions[0].body.statements
        #expect(file.declaresLocalTypes)
        #expect(statements.count == 6)
        #expect(statements.prefix(4).compactMap(\.localType?.name) == ["id", "pair", "names", "table"])
        // Each is where its name is: the place Go reports it by.
        #expect(statements.prefix(4).compactMap(\.localType?.position.line) == [4, 5, 9, 10])
        #expect(statements.prefix(4).compactMap(\.localType?.position.column) == [10, 10, 9, 9])
        guard case .named("int", _)? = statements[0].localType?.type,
            case .structure(let fields, _)? = statements[1].localType?.type,
            case .map(_, .pointer(.named("pair", _), _), _)? = statements[3].localType?.type
        else {
            Issue.record("unexpected types: \(statements)")
            return
        }
        #expect(fields.map(\.name) == ["a"])
        #expect(statements[4].localType == nil)
        #expect(file.typeDeclarations.isEmpty)

        #expect(try !parse("package main\ntype id int\nfunc main() {}\n").declaresLocalTypes)
        #expect(diagnostic(program(" type")) == "main.go:5:1: expected type name")
        #expect(diagnostic(program(" type (\n  a int\n")) == "main.go:7:1: expected type name")
    }

    // MARK: Resolution

    @Test func aLocalTypeBecomesATypeOfThePackage() throws {
        let files = [
            try parse(
                """
                package main

                type pair struct {
                    z int
                }

                func first() pair {
                    var before pair
                    type pair struct {
                        a int
                        next *pair
                    }
                    var after pair
                    after.a = before.z
                    return before
                }
                """, path: "a.go"),
            try parse(
                """
                package main

                func second(v interface{}) bool {
                    type pair int
                    if pair(1) > 0 {
                        type pair string
                        _, ok := v.(pair)
                        return ok
                    }
                    for i := range []pair{1} {
                        pair := []pair{2}
                        return len(pair) > i
                    }
                    return false
                }
                """, path: "b.go"),
        ]
        let resolved = try GoLocalTypes.hoist(files)

        // One number for each local type of the package keeps them apart.
        #expect(resolved[0].typeDeclarations.map(\.name) == ["pair", hoisted("pair", 1)])
        #expect(resolved[1].typeDeclarations.map(\.name) == [hoisted("pair", 2), hoisted("pair", 3)])
        #expect(resolved.allSatisfy { !$0.declaresLocalTypes })

        // The declaration is gone from the body; a use before it is the
        // package's type, a use after it the function's.
        let first = resolved[0].functions[0]
        #expect(first.resultTypes == [.named("pair", position: first.resultTypes[0].position)])
        #expect(first.body.statements.count == 4)
        guard case .declaration("before", .named("pair", _)?, _, _, _) = first.body.statements[0],
            case .declaration("after", .named(hoisted("pair", 1), _)?, _, _, _) = first.body.statements[1],
            // A type may refer to itself.
            case .structure(let fields, _) = resolved[0].typeDeclarations[1].type,
            case .pointer(.named(hoisted("pair", 1), _), _) = fields[1].type
        else {
            Issue.record("unexpected tree: \(first.body.statements)")
            return
        }

        // An inner block's type hides the outer one until the block ends,
        // and a variable takes the name from the end of its declaration.
        let second = resolved[1].functions[0]
        guard case .ifStatement(let condition, let inner, _, _) = second.body.statements[0],
            case .binary(.call(.identifier(hoisted("pair", 2), _), _, _), _, _, _) = condition,
            case .multiDeclaration(_, .typeAssertion(_, .named(hoisted("pair", 3), _), _), _) =
                inner.statements[0],
            case .forRangeStatement(_, _, let collection, let loop, _) = second.body.statements[1],
            case .compositeLiteral(.slice(.named(hoisted("pair", 2), _), _), _, _) = collection,
            case .declaration("pair", _, .compositeLiteral(.slice(.named(hoisted("pair", 2), _), _), _, _)?, _, _) =
                loop.statements[0],
            case .returnValues(let values, _) = loop.statements[1],
            case .binary(.call(_, let arguments, _), _, _, _) = values[0],
            case .identifier("pair", _) = arguments[0]
        else {
            Issue.record("unexpected tree: \(second.body.statements)")
            return
        }

        // Files without local types are left as they are.
        let plain = [try parse("package main\ntype t int\nfunc main() {}\n")]
        #expect(try GoLocalTypes.hoist(plain) == plain)
        #expect(try GoNames.resolve(resolved) == resolved)
    }

    @Test func theNameOfALocalTypeIsWhatTheSourceCallsIt() {
        #expect(GoLocalTypes.sourceName(hoisted("pair", 12)) == "pair")
        #expect(GoLocalTypes.sourceName("pair") == "pair")
        // The VM prints a type of the main package with `main.`, and one of
        // another package with the last element of its path.
        #expect(GoTypeDescriptor.goName(hoisted("pair", 3)) == "main.pair")
        #expect(GoTypeDescriptor.goName("*" + hoisted("pair", 3)) == "*main.pair")
        #expect(GoTypeDescriptor.goName(hoisted("example/m/lib.pair", 3)) == "lib.pair")
        #expect(GoTypeDescriptor.packagePath(ofTypeName: hoisted("pair", 3)) == "main")
        #expect(GoTypeDescriptor.packagePath(ofTypeName: "*" + hoisted("example/m/lib.pair", 3)) == "example/m/lib")
    }

    // MARK: Behavior

    @Test func aLocalTypeReachesFromItsDeclarationToTheEndOfItsBlock() throws {
        #expect(
            try output(
                """
                package main

                import "fmt"

                type point struct {
                    X int
                }

                func main() {
                    p := point{X: 1}
                    type point struct {
                        Name string
                    }
                    q := point{Name: "local"}
                    fmt.Println(p, q)
                    if p.X == 1 {
                        type point int
                        var r point = 7
                        fmt.Printf("%v %T\\n", r, r)
                    }
                    for i := 0; i < 1; i++ {
                        point := i + 2
                        fmt.Println(point)
                    }
                    var s point
                    s.Name = "again"
                    fmt.Printf("%+v %T %T\\n", s, s, p)
                }
                """)
                == "{1} {local}\n7 main.point\n2\n{Name:again} main.point main.point\n")
    }

    @Test func typesOfOneNameInTwoFunctionsAreTwoTypes() throws {
        #expect(
            try output(
                """
                package main

                import "fmt"

                func first() interface{} {
                    type pair struct {
                        A int
                    }
                    return pair{A: 1}
                }

                func second(v interface{}) string {
                    type pair struct {
                        A int
                    }
                    if _, ok := v.(pair); ok {
                        return "the same"
                    }
                    return fmt.Sprintf("another %T", v)
                }

                func third() string {
                    type pair struct {
                        A int
                    }
                    var v interface{} = pair{A: 3}
                    p, ok := v.(pair)
                    return fmt.Sprint(p.A, ok)
                }

                func main() {
                    fmt.Println(second(first()), third())
                }
                """)
                == "another main.pair 3 true\n")
    }

    @Test func localTypesOfEveryKind() throws {
        #expect(
            try output(
                """
                package main

                import "fmt"

                type square struct {
                    Side int
                }

                func (s square) Area() int { return s.Side * s.Side }

                var steps int

                func init() {
                    type weight int
                    steps += int(weight(4))
                }

                func (s square) label() string {
                    type tag struct {
                        text string
                    }
                    return tag{text: fmt.Sprint("<", s.Side, ">")}.text
                }

                func list() []string {
                    type node struct {
                        name string
                        next *node
                    }
                    head := &node{name: "a", next: &node{name: "b"}}
                    var names []string
                    for n := head; n != nil; n = n.next {
                        names = append(names, n.name)
                    }
                    return names
                }

                func main() {
                    type (
                        id    int
                        names []string
                        table map[string]id
                        shape interface {
                            Area() int
                        }
                    )
                    t := table{"a": 1, "b": 2}
                    var s shape = square{Side: 3}
                    queue := make(chan id, 1)
                    queue <- t["b"]
                    fmt.Println(t["a"]+<-queue, names{"x", "y"}, s.Area(), list(), steps)
                    fmt.Printf("%T %T %T %s\\n", t, names{}, id(3), square{Side: 2}.label())
                    defer func() {
                        type id string
                        fmt.Printf("%T %v\\n", id("deferred"), id("deferred"))
                    }()
                }
                """)
                == "3 [x y] 9 [a b] 4\nmain.table main.names main.id <2>\nmain.id deferred\n")
    }

    @Test func aFailedAssertionSaysWhatKeepsTheTypesApart() throws {
        #expect(
            try output(
                """
                package main

                import "fmt"

                type pair struct {
                    Z int
                }

                func make1() interface{} {
                    type pair struct {
                        A int
                    }
                    return &pair{A: 1}
                }

                func try(v interface{}) {
                    defer func() {
                        fmt.Println(recover())
                    }()
                    fmt.Println(v.(*pair))
                }

                func main() {
                    try(make1())
                    try(3)
                }
                """)
                == "interface conversion: interface {} is *main.pair, not *main.pair (types from different scopes)\n"
                + "interface conversion: interface {} is int, not *main.pair\n")
    }

    @Test func localTypesOfAnotherPackage() throws {
        let packages = [
            GoPackageSource(
                importPath: "example/m",
                sources: [
                    GoSourceFile(
                        path: "/m/main.go",
                        text: """
                            package main

                            import (
                                "fmt"

                                first "example/m/a/util"
                                second "example/m/b/util"
                            )

                            func try(v interface{}) {
                                defer func() {
                                    fmt.Println(recover())
                                }()
                                fmt.Println(second.Must(v))
                            }

                            func main() {
                                v := first.Make()
                                fmt.Printf("%v %T\\n", v, v)
                                try(first.T{N: 1})
                            }
                            """)
                ]),
            GoPackageSource(
                importPath: "example/m/a/util",
                sources: [
                    GoSourceFile(
                        path: "/m/a/util/util.go",
                        text: """
                            package util

                            type T struct {
                                N int
                            }

                            func Make() interface{} {
                                type local struct {
                                    Text string
                                }
                                return local{Text: "made"}
                            }
                            """)
                ]),
            GoPackageSource(
                importPath: "example/m/b/util",
                sources: [
                    GoSourceFile(
                        path: "/m/b/util/util.go",
                        text: "package util\n\ntype T struct {\n N int\n}\n\nfunc Must(v interface{}) T { return v.(T) }\n")
                ]),
        ]
        let executable = try GoCompiler.compile(packages: packages, root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output
                == "{made} util.local\n"
                + "interface conversion: interface {} is util.T, not util.T (types from different packages)\n")
    }

    // MARK: Diagnostics

    @Test func aBlockDeclaresANameOnce() {
        #expect(
            diagnostic(program(" type T int\n type T string\n var x T\n fmt.Println(x)"))
                == "main.go:5:7: T redeclared in this block")
        #expect(
            diagnostic(program(" x := 1\n type x int\n fmt.Println(x)"))
                == "main.go:5:7: x redeclared in this block")
        #expect(
            diagnostic(program(" type x int\n var x = 1\n fmt.Println(x)"))
                == "main.go:5:2: x redeclared in this block")
        #expect(
            diagnostic(program(" type (\n  a int\n  a string\n )\n fmt.Println(a(1))"))
                == "main.go:6:3: a redeclared in this block")
        // Another block may use the name again.
        #expect(diagnostic(program(" type T int\n if T(1) > 0 {\n  type T string\n  fmt.Println(T(\"x\"))\n }")) == nil)
    }

    @Test func aTypeIsNotDeclaredBeforeItsDeclaration() {
        #expect(
            diagnostic(program(" var x T\n type T int\n fmt.Println(x)"))
                == "main.go:4:8: undefined: T")
        #expect(
            diagnostic(program(" if true {\n  type T int\n }\n var x T\n fmt.Println(x)"))
                == "main.go:7:8: undefined: T")
        #expect(
            diagnostic("package main\nfunc f() {\n type T int\n}\nfunc main() {\n var x T\n _ = x\n}\n")
                == "main.go:6:8: undefined: T")
    }

    @Test func aDiagnosticNamesWhatTheSourceNames() {
        #expect(
            diagnostic(program(" type T int\n type U string\n var x T = 1\n var y U = x\n fmt.Println(x, y)"))
                == "main.go:7:12: cannot use x (variable of int type T) as U value in variable declaration")
        #expect(
            diagnostic(program(" type T struct{ A int }\n var v T\n v.B = 1\n fmt.Println(v)"))
                == "main.go:6:4: v.B undefined (type T has no field or method B)")
        #expect(
            diagnostic(program(" type T struct{ A int }\n fmt.Println(T{B: 1})"))
                == "main.go:5:16: unknown field B in struct literal of type T")
        // A method belongs to a type of the package.
        #expect(
            diagnostic("package main\nfunc main() {\n type T int\n}\nfunc (t T) M() {}\n")
                == "main.go:5:9: undefined: T")
    }

    // MARK: gofmt -r

    @Test func aRewriteRuleMeetsTheNameOfALocalType() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main

                import "fmt"

                func main() {
                \ttype pair struct {
                \t\tA int
                \t\tB int
                \t}
                \tp := pair{A: 1, B: 2}
                \tfmt.Println(sum(p.A, p.B))
                }

                func sum(a int, b int) int { return a + b }

                """)

        // The declaration is no call, though the parser carries it as one.
        let swapped = try GoSourceRewriter.rewrite(source, rule: "sum(a, b) -> sum(b, a)")
        #expect(swapped.text.contains("type pair struct {\n\t\tA int\n\t\tB int\n\t}"))
        #expect(swapped.text.contains("fmt.Println(sum(p.B, p.A))"))
        let literal = try GoSourceRewriter.rewrite(source, rule: "pair{A: a, B: b} -> pair{A: b, B: a}")
        #expect(literal.text.contains("type pair struct {"))
        #expect(literal.text.contains("p := pair{A: 2, B: 1}"))
    }
}
