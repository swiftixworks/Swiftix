/// Alias declarations, `type Name = T`: what the parser makes of them, how
/// every use becomes the type the alias stands for, and the diagnostics.
/// What such programs print is compared with Go in `GoConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go type aliases")
struct GoTypeAliasTests: GoTestHarness {

    private func parse(_ text: String) throws -> GoFile {
        try GoParser.parse(GoSourceFile(path: "main.go", text: text))
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

    @Test func anAliasDeclarationIsMarkedAsOne() throws {
        let file = try parse(
            """
            package main

            type celsius = int
            type point struct{ x int }
            type (
                coord = point
                list  []coord
                index = map[string]list
            )

            func main() {
                type local = coord
                type own coord
            }
            """)

        #expect(file.typeDeclarations.map(\.name) == ["celsius", "point", "coord", "list", "index"])
        #expect(file.typeDeclarations.map(\.isAlias) == [true, false, true, false, true])
        // A declaration is where its name is: the place Go reports it by.
        #expect(file.typeDeclarations.map(\.position.column) == [6, 6, 5, 5, 5])
        let position = file.typeDeclarations[0].position
        #expect(!GoTypeDeclaration(name: "t", type: .named("int", position: position), position: position).isAlias)
        let statements = file.functions[0].body.statements
        #expect(statements.compactMap(\.localType?.isAlias) == [true, false])
    }

    @Test func anAliasIsReplacedByItsType() throws {
        let files = [
            try parse(
                """
                package main

                type point struct{ x int }
                type coord = point
                type again = coord
                type index = map[string][]again

                var origin coord

                func (c again) twice() coord { return coord{x: c.x * 2} }

                func find(i index, key string) []coord {
                    again := i[key]
                    return append(again, again...)
                }

                func main() {
                    type local = *coord
                    var p local = &origin
                    _ = index{"k": []coord{*p}}
                    _ = again(origin)
                    _ = make(index)
                }
                """)
        ]
        let resolved = try GoNames.resolve(program: GoNames.resolve(files))[0]
        func named(_ name: String) -> GoTypeExpression {
            .named(name, position: GoSourcePosition(path: "", offset: 0, line: 0, column: 0))
        }
        func isPoint(_ type: GoTypeExpression?) -> Bool {
            if case .named("point", _)? = type { return true }
            return false
        }

        // No alias is left, declared or used; an alias of an alias is the
        // type at the end.
        #expect(resolved.typeDeclarations.map(\.name) == ["point"])
        #expect(resolved.aliasTargets.count == 4)
        #expect(isPoint(resolved.globalDeclarations[0].explicitType))
        #expect(isPoint(resolved.functions[0].receiver?.type))
        #expect(isPoint(resolved.functions[0].resultTypes.first))
        guard case .map(_, .slice(let element, _), _) = resolved.functions[1].parameters[0].type,
            // A variable of the function hides the alias of its name.
            case .declaration("again", _, _, _, _) = resolved.functions[1].body.statements[0],
            case .returnValues(let values, _) = resolved.functions[1].body.statements[1],
            case .call(_, let arguments, _) = values[0],
            case .identifier("again", _) = arguments[0],
            // Where a value is written, a name stays an identifier and
            // another type becomes a type expression.
            case .declaration(_, .pointer(let pointee, _)?, _, _, _) = resolved.functions[2].body.statements[0],
            case .assignment(_, .call(.identifier("point", _), _, _), _) = resolved.functions[2].body.statements[2],
            case .assignment(_, .call(_, let made, _), _) = resolved.functions[2].body.statements[3],
            case .typeExpression(.map, _) = made[0]
        else {
            Issue.record("unexpected tree: \(resolved.functions)")
            return
        }
        #expect(isPoint(element))
        #expect(isPoint(pointee))

        // Files without an alias are left as they are.
        let plain = [try parse("package main\ntype t int\nfunc main() {}\n")]
        #expect(try GoNames.resolve(program: plain) == plain)
    }

    @Test func anAliasAndItsTypeAreOneType() throws {
        #expect(
            try runGoMain(
                """
                var c coord = point{X: 1, Y: 2}
                c.X = 5
                var again point = c
                var s shape = c
                var v interface{} = c
                p, isPoint := v.(point)
                fmt.Printf("%v %T %T %d %v %v\\n", again, c, coord{}, s.Area(), p.Y, isPoint)

                b := bytes("hi")
                b = append(b, 33)
                idx := index{"a": []coord{c}}
                idx["a"] = append(idx["a"], coord{X: 9})
                fmt.Printf("%s %d %T %T %T\\n", text(b), idx["a"][1].X, b, idx, make(bytes, 2))

                var n tally = 4
                var m counter = n.Twice()
                var e failure = fail()
                fmt.Printf("%v %T %v\\n", m, n, e)

                type local = point
                type pair struct{ L, R local }
                fmt.Printf("%v %T\\n", pair{L: c, R: local{X: 7}}.R.X, pair{}.L)
                """,
                imports: ["errors", "fmt"],
                declarations: """
                    type point struct{ X, Y int }

                    type (
                        coord   = point
                        bytes   = []byte
                        text    = string
                        index   = map[string][]coord
                        failure = error
                        counter int
                        tally   = counter
                        figure  = shape
                    )

                    type shape interface {
                        Area() int
                    }

                    func (c coord) Area() int { return c.X * c.Y }

                    func (t tally) Twice() tally { return t * 2 }

                    func fail() failure { return errors.New("failed") }
                    """)
                == "{5 2} main.point main.point 10 2 true\nhi! 9 []uint8 map[string][]main.point []uint8\n"
                + "8 main.counter failed\n7 main.point\n")
    }

    @Test func anAliasReachesAcrossPackages() throws {
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

                                "example/m/geo"
                            )

                            type place = geo.Coord

                            func main() {
                                var p place = geo.Point{X: 2}
                                var list geo.Path = []place{p, geo.Origin()}
                                fmt.Printf("%v %T %T %d\\n", list, p, list, geo.Sum(list))
                            }
                            """)
                ]),
            GoPackageSource(
                importPath: "example/m/geo",
                sources: [
                    GoSourceFile(
                        path: "/m/geo/geo.go",
                        text: """
                            package geo

                            type Point struct{ X int }

                            type (
                                Coord = Point
                                Path  = []Coord
                            )

                            func Origin() Coord { return Coord{} }

                            func Sum(p Path) int {
                                total := 0
                                for _, c := range p {
                                    total += c.X
                                }
                                return total
                            }
                            """)
                ]),
        ]
        var output = ""
        try GoVirtualMachine().run(try GoCompiler.compile(packages: packages, root: "example/m")) {
            output += $0
        }

        #expect(output == "[{2} {0}] geo.Point []geo.Point 2\n")
    }

    @Test func anAliasMustStandForAType() {
        #expect(
            diagnostic("package main\ntype A = A\nfunc main() {}\n")
                == "main.go:2:6: invalid recursive type: A refers to itself")
        #expect(
            diagnostic("package main\ntype A = B\ntype B = []A\nfunc main() {}\n")
                == "main.go:2:6: invalid recursive type A")
        // Used or not.
        #expect(
            diagnostic("package main\ntype A = Missing\nfunc main() {}\n")
                == "main.go:2:10: undefined: Missing")
        #expect(
            diagnostic("package main\ntype A = map[string][]Missing\nfunc main() {}\n")
                == "main.go:2:23: undefined: Missing")
        #expect(
            diagnostic("package main\nfunc main() {\n type A = B\n type B = A\n}\n")
                == "main.go:3:11: undefined: B")
        #expect(
            diagnostic("package main\nfunc main() {\n var a A\n type A = int\n _ = a\n}\n")
                == "main.go:3:8: undefined: A")
    }

    @Test func anAliasIsANameOfItsBlock() {
        #expect(
            diagnostic("package main\ntype A = int\ntype A = string\nfunc main() {}\n")
                == "main.go:3:6: A redeclared in this block")
        #expect(
            diagnostic("package main\ntype A int\ntype A = string\nfunc main() {}\n")
                == "main.go:3:6: A redeclared in this block")
        #expect(
            diagnostic("package main\nfunc A() {}\ntype A = int\nfunc main() {}\n")
                == "main.go:3:6: A redeclared in this block")
        #expect(
            diagnostic("package main\nfunc main() {\n type A = int\n type A = string\n}\n")
                == "main.go:4:7: A redeclared in this block")
    }

    @Test func aMistakeIsReportedWhereTheAliasIsUsed() {
        // Not where it is declared, and by the type it stands for.
        #expect(
            diagnostic("package main\ntype A = int\nfunc (a A) M() {}\nfunc main() {}\n")
                == "main.go:3:9: invalid receiver type int")
        #expect(
            diagnostic(
                "package main\ntype T struct{ X int }\ntype A = T\ntype U T\nfunc main() {\n var a A\n var u U = a\n _ = u\n}\n")
                == "main.go:7:12: cannot use T as U value")
    }

    @Test func gofmtAlignsTheNamesOfAGroup() throws {
        #expect(
            try GoFormatter.format(
                GoSourceFile(
                    path: "main.go",
                    text: "package main\n\ntype   coord=point\ntype (\n\ttext = string\n\tcounter int\n\ttally = counter // alias\n)\n"))
                == "package main\n\ntype coord = point\ntype (\n\ttext    = string\n\tcounter int\n\ttally   = counter // alias\n)\n")
    }
}
