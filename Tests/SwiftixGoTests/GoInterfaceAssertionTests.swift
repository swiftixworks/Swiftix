/// Type assertions to an interface type, and calls of interface methods with
/// several results or a variadic parameter. A program's types that implement
/// an interface are worked out by the compiler from exact method signatures;
/// what such programs print is compared with Go in `GoConformanceTests` too.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go interface assertions")
struct GoInterfaceAssertionTests: GoTestHarness {

    private static let declarations = """
        type namer interface {
            name() string
        }
        type store interface {
            get(string) (string, bool)
            add(string, ...int) int
        }
        type memory struct {
            total int
        }
        func (m *memory) get(key string) (string, bool) {
            return key + "!", m.total > 0
        }
        func (m *memory) add(key string, values ...int) int {
            for _, value := range values {
                m.total += value
            }
            return m.total
        }
        type label string
        func (l label) name() string {
            return string(l)
        }
        """

    /// The output of this program is what Go 1.24.5 prints for it. `probe`
    /// asserts to its own interfaces values of types it does not import, and
    /// `Dot.Corner` has the name and the arity of the method asked for but
    /// not its parameter type.
    @Test func implementersAreFoundAcrossPackagesByExactSignature() throws {
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/crosscheck",
                    sources: [
                        GoSourceFile(
                            path: "/m/main.go",
                            text: """
                                package main

                                import "example/crosscheck/probe"
                                import "example/crosscheck/shape"
                                import "fmt"

                                type cornered interface {
                                    Corner(shape.Point) shape.Point
                                }

                                type measured interface {
                                    Area() int
                                    Grow(int) error
                                }

                                func main() {
                                    square := shape.Square{Side: 4}
                                    dot := shape.Dot{At: shape.Point{X: 1, Y: 2}}
                                    fmt.Println(probe.Describe(square), "|", probe.Describe(&square), "|", probe.Describe(dot), "|", probe.Describe(3))
                                    fmt.Println(square.Side)

                                    var values []interface{}
                                    values = append(values, square, &square, dot, &dot)
                                    for _, value := range values {
                                        c, ok := value.(cornered)
                                        _, grows := value.(measured)
                                        if ok {
                                            fmt.Println(ok, grows, c.Corner(shape.Point{X: 1, Y: 1}))
                                        } else {
                                            fmt.Println(ok, grows)
                                        }
                                    }
                                    fmt.Println(shape.Sum(2), shape.Sum(2, 1, 2), shape.Sum(3, []int{1, 1}...))
                                    var m measured = &square
                                    err := m.Grow(-1)
                                    fmt.Println(err, m.Area())
                                }

                                """)
                    ]),
                GoPackageSource(
                    importPath: "example/crosscheck/shape",
                    sources: [
                        GoSourceFile(
                            path: "/m/shape/shape.go",
                            text: """
                                package shape

                                import "errors"

                                type Point struct {
                                    X int
                                    Y int
                                }

                                type Square struct {
                                    Side int
                                }

                                func (s Square) Area() int {
                                    return s.Side * s.Side
                                }

                                func (s Square) Corner(offset Point) Point {
                                    return Point{X: offset.X + s.Side, Y: offset.Y + s.Side}
                                }

                                func (s *Square) Grow(by int) error {
                                    if by < 0 {
                                        return errors.New("cannot shrink")
                                    }
                                    s.Side += by
                                    return nil
                                }

                                type Dot struct {
                                    At Point
                                }

                                func (d Dot) Area() int {
                                    return 0
                                }

                                func (d Dot) Corner(offset int) Point {
                                    return d.At
                                }

                                func Sum(scale int, sides ...int) int {
                                    total := 0
                                    for _, side := range sides {
                                        total += side * scale
                                    }
                                    return total
                                }

                                """)
                    ]),
                GoPackageSource(
                    importPath: "example/crosscheck/probe",
                    sources: [
                        GoSourceFile(
                            path: "/m/probe/probe.go",
                            text: """
                                package probe

                                type area interface {
                                    Area() int
                                }

                                type grower interface {
                                    Area() int
                                    Grow(int) error
                                }

                                func Describe(value interface{}) string {
                                    text := ""
                                    a, hasArea := value.(area)
                                    if hasArea {
                                        text += "area "
                                        if a.Area() > 10 {
                                            text += "large "
                                        }
                                    }
                                    g, grows := value.(grower)
                                    if grows {
                                        err := g.Grow(1)
                                        if err == nil {
                                            text += "grown "
                                        }
                                    }
                                    return text
                                }

                                """)
                    ]),
            ],
            root: "example/crosscheck")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output
                == [
                    "area large  | area large grown  | area  | ",
                    "5",
                    "true false {6 6}",
                    "true true {6 6}",
                    "false false",
                    "false false",
                    "0 6 6",
                    "cannot shrink 25",
                    "",
                ].joined(separator: "\n"))
    }

    @Test func anAssertionKeepsTheValueAndItsType() throws {
        let output = try runGoMain(
            """
            var value interface{} = label("x")
            n := value.(namer)
            back, ok := n.(label)
            fmt.Println(n.name(), back, ok)
            fmt.Printf("%T %v\\n", n, n)
            backing := memory{total: 0}
            var held interface{} = &backing
            s, isStore := held.(store)
            _, isNamer := held.(namer)
            fmt.Println(isStore, isNamer, s.add("k", 1, 2), s.add("k"), s.add("k", []int{3}...))
            text, found := s.get("k")
            fmt.Println(text, found)
            var nothing interface{}
            _, ok = nothing.(namer)
            fmt.Println(ok)
            """,
            declarations: Self.declarations)

        #expect(output == "x x true\nmain.label x\ntrue false 3 3 6\nk! true\nfalse\n")
    }

    @Test func aFailedAssertionPanicsWithGosMessage() throws {
        #expect(
            throws: GoRuntimeError.panicError(
                "interface conversion: main.memory is not main.namer: missing method name")
        ) {
            _ = try runGoMain(
                "var value interface{} = memory{total: 1}\nfmt.Println(value.(namer).name())",
                declarations: Self.declarations)
        }
        #expect(
            throws: GoRuntimeError.panicError(
                "interface conversion: interface is nil, not main.store")
        ) {
            _ = try runGoMain(
                "var value interface{}\nfmt.Println(value.(store).add(\"k\"))",
                declarations: Self.declarations)
        }
    }

    @Test func interfaceMethodCallsAreChecked() {
        func diagnostic(_ body: String, declarations: String = "") -> String? {
            goMainDiagnostic(
                "backing := memory{total: 0}\nvar s store = &backing\n" + body,
                declarations: Self.declarations + "\n" + declarations)
        }
        #expect(diagnostic("fmt.Println(s.add())") == "not enough arguments in call to s.add\n\thave ()\n\twant (string, ...int)")
        #expect(diagnostic("fmt.Println(s.add(\"k\", \"v\"))") != nil)
        #expect(diagnostic("fmt.Println(s.add(\"k\", []string{\"v\"}...))") != nil)
        #expect(diagnostic("text, found := s.get()\nfmt.Println(text, found)") != nil)
        #expect(diagnostic("text, found := s.get(1)\nfmt.Println(text, found)") != nil)
        #expect(
            diagnostic("text, found := s.get(\"k\")\nfmt.Println(text, found, s.add(\"k\"))")
                == nil)
        #expect(
            diagnostic("", declarations: "type bad interface {\n\tadd(...int, string) int\n}")
                == "can only use ... with final parameter in list")
    }

    @Test func aFinalPanicEndsAFunctionWithResults() {
        #expect(
            goMainDiagnostic(
                "fmt.Println(pick(1))",
                declarations: """
                    func pick(code int) int {
                        if code > 0 {
                            return code
                        }
                        panic("no code")
                    }
                    """) == nil)
        #expect(
            goMainDiagnostic(
                "fmt.Println(pick(1))",
                declarations: """
                    func pick(code int) int {
                        if code > 0 {
                            return code
                        }
                        fmt.Println("no code")
                    }
                    """) == "missing return")
    }
}
