/// `fmt.Stringer`, `fmt.GoStringer`, `fmt.Formatter`, and `fmt.State` are
/// names, Go text of the library, and `fmt` asks a value how it prints as
/// Go's does: by its `Format` method under every verb, by `GoString` under
/// `%#v`, and by `Error` or `String` under the verbs for text, as an operand
/// and wherever it is not behind an unexported field.
///
/// The VM runs `Format` as it runs `String`, as a guest call of the native
/// that formats, with a `fmt.State` of its own, `*fmt.pp`. Every expected
/// output here was taken from Go 1.24.5.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go fmt.Formatter, fmt.GoStringer, and fmt.Stringer")
struct GoFormatMethodTests: GoTestHarness {

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

    /// The interfaces are types: of variables, of slices, of assertions, and of
    /// method expressions.
    @Test func theInterfacesAreNames() throws {
        #expect(
            try runGoMain(
                #"""
                var s fmt.Stringer = P{1, 2}
                fmt.Println(s.String(), s)
                ss := []fmt.Stringer{P{}, time.Second}
                fmt.Println(ss)
                if st, ok := any(P{}).(fmt.Stringer); ok {
                    fmt.Println("stringer", st)
                }
                _, ok := any(3).(fmt.Stringer)
                fmt.Println(ok)
                var gs fmt.GoStringer = P{3, 4}
                fmt.Println(gs.GoString(), fmt.GoStringer.GoString(gs))
                var f fmt.Formatter
                fmt.Println(f == nil)
                fmt.Printf("%T %T\n", s, fmt.Stringer.String)
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type P struct{ x, y int }

                    func (p P) String() string   { return "p" }
                    func (p P) GoString() string { return fmt.Sprintf("P(%d,%d)", p.x, p.y) }
                    """)
                == """
                p p
                [p 1s]
                stringer p
                false
                P(3,4) P(3,4)
                true
                main.P func(fmt.Stringer) string

                """)
    }

    /// `GoString` under `%#v`, of a value, a pointer, an element, and with a
    /// width or a precision; not behind an unexported field, and `<nil>` for a nil
    /// pointer whose method needs the value.
    @Test func goStringPrintsUnderSharpV() throws {
        #expect(
            try runGoMain(
                #"""
                p := P{1, 2}
                fmt.Printf("%#v %v %s\n", p, p, p)
                fmt.Printf("%#v %#v\n", []P{p}, &p)
                fmt.Printf("%#v\n", struct{ g P }{p})
                g := &GS{7}
                fmt.Printf("%#v %v\n", g, g)
                fmt.Printf("%#v %#v\n", GS{8}, []*GS{g})
                var none *GS
                fmt.Printf("%#v\n", none)
                fmt.Printf("[%#8v] [%#-8v] [%#.2v]\n", p, p, p)
                """#,
                imports: ["fmt"],
                declarations: """
                    type P struct{ x, y int }

                    func (p P) GoString() string { return fmt.Sprintf("P(%d,%d)", p.x, p.y) }
                    func (p P) String() string   { return "p" }

                    type GS struct{ n int }

                    func (g *GS) GoString() string { return fmt.Sprintf("GS#%d", g.n) }
                    """)
                == """
                P(1,2) p p
                []main.P{P(1,2)} P(1,2)
                struct { g main.P }{g:main.P{x:1, y:2}}
                GS#7 &{7}
                main.GS{n:8} []*main.GS{GS#7}
                <nil>
                [  P(1,2)] [P(1,2)  ] [P(]

                """)
    }

    /// `Format` is given the verb, the flags, the width, and the precision, and
    /// what it writes is the text: as an operand, an element, a field, under
    /// `Print`, `Sprint`, `Errorf`, and before `Error`.
    @Test func formatPrintsUnderEveryVerb() throws {
        #expect(
            try runGoMain(
                #"""
                f := F{3}
                fmt.Printf("%v|%+8.2x|%#d|%s|% 05d|%-4v\n", f, f, f, f, f, f)
                fmt.Println(f, []F{{1}}, map[string]F{"a": {2}})
                fmt.Println(fmt.Sprint(f), fmt.Sprintf("%q", f), fmt.Sprintf("%T", f))
                fmt.Println(Inner(3), Outer{1, 2}, &Outer{3, 4})
                fmt.Printf("%+v\n", Outer{5, 6})
                fmt.Println(Err{}, error(Err{}), fmt.Errorf("wrap: %w", Err{}))
                fmt.Println(Val{}, &Val{})
                """#,
                imports: ["fmt"],
                declarations: """
                    type F struct{ v int }

                    func (f F) Format(s fmt.State, verb rune) {
                        w, wok := s.Width()
                        p, pok := s.Precision()
                        fmt.Fprintf(s, "F[%c %d %v %d %v", verb, w, wok, p, pok)
                        for _, c := range "+-# 0" {
                            fmt.Fprint(s, " ", s.Flag(int(c)))
                        }
                        s.Write([]byte("]"))
                    }

                    type Inner int

                    func (i Inner) Format(s fmt.State, verb rune) { fmt.Fprintf(s, "<%d:%c>", int(i), verb) }

                    type Outer struct {
                        A Inner
                        b Inner
                    }

                    type Err struct{}

                    func (Err) Error() string                 { return "err text" }
                    func (Err) Format(s fmt.State, verb rune) { s.Write([]byte("formatted err")) }

                    type Val struct{}

                    func (v *Val) Format(s fmt.State, verb rune) { fmt.Fprint(s, "ptrfmt") }
                    """)
                == """
                F[v 0 false 0 false false false false false false]|F[x 8 true 2 true true false false false false]|F[d 0 false 0 false false false true false false]|F[s 0 false 0 false false false false false false]|F[d 5 true 0 false false false false true true]|F[v 4 true 0 false false true false false false]
                F[v 0 false 0 false false false false false false] [F[v 0 false 0 false false false false false false]] map[a:F[v 0 false 0 false false false false false false]]
                F[v 0 false 0 false false false false false false] F[q 0 false 0 false false false false false false] main.F
                <3:v> {<1:v> 2} &{<3:v> 4}
                {A:<5:v> b:6}
                formatted err formatted err wrap: formatted err
                {} ptrfmt

                """)
    }

    /// The state is a `*fmt.pp` and an `io.Writer`; a method of a nil pointer
    /// runs; one that panics prints as Go prints it.
    @Test func theStateIsGos() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(St{})
                var none *N
                fmt.Println(none, Boom{})
                fmt.Printf("%d\n", Boom{})
                """#,
                imports: ["fmt", "io"],
                declarations: """
                    type St struct{}

                    func (St) Format(s fmt.State, verb rune) {
                        fmt.Fprintf(s, "%T", s)
                        _, ok := s.(io.Writer)
                        fmt.Fprint(s, " ", ok)
                        io.WriteString(s, "!")
                    }

                    type N struct{}

                    func (n *N) Format(s fmt.State, verb rune) {
                        if n == nil {
                            io.WriteString(s, "nil N")
                        }
                    }

                    type Boom struct{}

                    func (Boom) Format(s fmt.State, verb rune) { panic("boom") }
                    """)
                == """
                *fmt.pp true!
                nil N %!v(PANIC=Format method: boom)
                %!d(PANIC=Format method: boom)

                """)
    }

    /// An aliased import, a type declared in a function, an alias, and a
    /// closure.
    @Test func formatThroughEveryPass() throws {
        #expect(
            try runGoMain(
                """
                type local int
                type named = Inner
                var s f.Stringer = Inner(1)
                show := func() string { return f.Sprintf("%v %d", s, named(2)) }
                f.Println(show())
                _ = local(0)
                """,
                imports: ["fmt"],
                declarations: """
                    import f "fmt"

                    type Inner int

                    func (i Inner) Format(s f.State, verb rune) { f.Fprintf(s, "<%d:%c>", int(i), verb) }
                    func (i Inner) String() string              { return "unused" }
                    """)
                == "<1:v> <2:d>\n")
    }

    /// A method of the wrong signature implements nothing.
    @Test func theInterfacesAreCheckedAsGos() {
        #expect(
            firstError(
                """
                var x fmt.GoStringer = T{}
                _ = x
                """,
                imports: ["fmt"],
                declarations: """
                    type T struct{}

                    func (T) GoString() int { return 0 }
                    """)
                == "7:24: cannot use T{} (value of struct type T) as fmt.GoStringer value in variable declaration: T does not implement fmt.GoStringer (wrong type for method GoString)\n\t\thave GoString() int\n\t\twant GoString() string")
        #expect(
            firstError(
                """
                var x fmt.Stringer = 3
                _ = x
                """,
                imports: ["fmt"])
                == "5:22: cannot use 3 (constant of type int) as fmt.Stringer value in variable declaration: int does not implement fmt.Stringer (missing method String)")
    }
}
