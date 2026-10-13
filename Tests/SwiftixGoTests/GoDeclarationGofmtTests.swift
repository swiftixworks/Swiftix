/// How `gofmt` lays out blank declarations and receivers, parameters, and
/// results without names.
///
/// Each expected text is what Go 1.24.5's `gofmt` makes of the source
/// beside it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go gofmt of declarations without names")
struct GoDeclarationGofmtTests: GoTestHarness {

    /// Compares line by line, so a failure shows the one line that differs.
    private func expectGofmt(_ source: String, _ expected: String) throws {
        let formatted = try GoFormatter.format(GoSourceFile(path: "main.go", text: source))
        let actual = formatted.split(separator: "\n", omittingEmptySubsequences: false)
        let wanted = expected.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(actual.count == wanted.count)
        for (number, pair) in zip(actual, wanted).enumerated() {
            #expect(pair.0 == pair.1, "line \(number + 1)")
        }
        // What Go's printer wrote, it writes again.
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: expected)) == expected)
    }

    /// A variadic type that begins a list stands against its parenthesis.
    @Test func receiversAndParametersWithoutNames() throws {
        try expectGofmt(
            """
                package main

                import "fmt"

                type T struct{ n int }
                type handler func(int,string) bool
                type I interface{ M( ...string ); N(a int, rest ...[]int) }

                func ( T )  a( ) int { return 1 }
                func (*T) M() int { return 2 }
                func ( _ T) c(int,string) int { return 3 }
                func (_ *T) d( _ int , _ string ) (_ int,_ error) { return 4, nil }
                func f(int,string) {}
                func g( _ int, _ ...string ) {}
                func h( ...int ) int { return 0 }
                func k(a int,_ string,_ bool) (n int, _ error) { return a, nil }

                var v func( ...int )
                var w func(string, ...*int)

                func main() {
                    f1 := func(int,string) int { return 1 }
                    f2 := func( _ int , _ string ) (int,error) { return 2, nil }
                    go func(int){}(1)
                    defer func(_ string){}("x")
                    fmt.Println(f1(1, "a"), f2)
                }
                """ + "\n",
            """
                package main

                import "fmt"

                type T struct{ n int }
                type handler func(int, string) bool
                type I interface {
                \tM(...string)
                \tN(a int, rest ...[]int)
                }

                func (T) a() int                                 { return 1 }
                func (*T) M() int                                { return 2 }
                func (_ T) c(int, string) int                    { return 3 }
                func (_ *T) d(_ int, _ string) (_ int, _ error)  { return 4, nil }
                func f(int, string)                              {}
                func g(_ int, _ ...string)                       {}
                func h(...int) int                               { return 0 }
                func k(a int, _ string, _ bool) (n int, _ error) { return a, nil }

                var v func(...int)
                var w func(string, ...*int)

                func main() {
                \tf1 := func(int, string) int { return 1 }
                \tf2 := func(_ int, _ string) (int, error) { return 2, nil }
                \tgo func(int) {}(1)
                \tdefer func(_ string) {}("x")
                \tfmt.Println(f1(1, "a"), f2)
                }
                """ + "\n")
    }

    /// Alone and in groups, where the names, the types, and the values are
    /// columns.
    @Test func blankDeclarations() throws {
        try expectGofmt(
            """
                package main

                import "fmt"

                type I interface{ M() int }
                type T struct{ n int }
                type ptr *T

                var _ I = (*T)(nil)
                var _  =  say( "a" )
                var a,_ = pair()
                var _,b = pair()
                var (
                    _ = say("group1")
                    _ int = say("group2")
                    total   int = 3
                )
                const _ = 5
                const (
                    A = iota
                    _
                    C
                    _, D = iota, iota*10
                )

                func (*T) M() int { return 2 }
                func _() {}
                func _() { fmt.Println("never") }
                func say(s string) int { fmt.Println("init", s); return len(s) }
                func pair() (int, int) { return 1, 2 }

                func main() {
                    var p ptr = &T{n:1}
                    p.n=5
                    x:=1
                    x,y:=2,3
                    _=x+y
                    var _ = p
                    fmt.Println(a, b, A, C, D, total)
                }
                """ + "\n",
            """
                package main

                import "fmt"

                type I interface{ M() int }
                type T struct{ n int }
                type ptr *T

                var _ I = (*T)(nil)
                var _ = say("a")
                var a, _ = pair()
                var _, b = pair()
                var (
                \t_         = say("group1")
                \t_     int = say("group2")
                \ttotal int = 3
                )

                const _ = 5
                const (
                \tA = iota
                \t_
                \tC
                \t_, D = iota, iota * 10
                )

                func (*T) M() int      { return 2 }
                func _()               {}
                func _()               { fmt.Println("never") }
                func say(s string) int { fmt.Println("init", s); return len(s) }
                func pair() (int, int) { return 1, 2 }

                func main() {
                \tvar p ptr = &T{n: 1}
                \tp.n = 5
                \tx := 1
                \tx, y := 2, 3
                \t_ = x + y
                \tvar _ = p
                \tfmt.Println(a, b, A, C, D, total)
                }
                """ + "\n")
    }

    /// `gofmt -r` meets the call of `var a, b = f()` once, as Go's does.
    @Test func aRuleRewritesTheOneExpressionOfSeveralVariables() throws {
        let source = "package main\n\nvar a, b = pair(1)\nvar _ = pair(2)\n\nfunc pair(n int) (int, int) { return n, n }\n\nfunc main() {}\n"
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(path: "main.go", text: source), rule: "pair(x) -> pair(x + 1)")
        #expect(
            rewritten.text
                == "package main\n\nvar a, b = pair(1 + 1)\nvar _ = pair(2 + 1)\n\nfunc pair(n int) (int, int) { return n, n }\n\nfunc main() {}\n")
    }
}
