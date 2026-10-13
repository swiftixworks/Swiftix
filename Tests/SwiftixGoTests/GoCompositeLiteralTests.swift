/// Struct literals without fields (`T{}`) and the address of a composite
/// literal (`&T{...}`), which is a new variable each time it is evaluated.
/// What such programs print is compared with Go in `GoConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go composite literals")
struct GoCompositeLiteralTests: GoTestHarness {

    private static let declarations = """
        type point struct {
            X int
            Y int
        }
        type node struct {
            name string
            next *node
            tags []string
            at   point
        }
        func (n *node) rename(name string) *node {
            n.name = name
            return n
        }
        func build(name string) *node {
            return &node{name: name}
        }
        """

    private func diagnostic(_ body: String) -> String? {
        goMainDiagnostic(body, declarations: Self.declarations)
    }

    @Test func anEmptyLiteralIsTheZeroValue() throws {
        let output = try runGoMain(
            """
            zero := point{}
            empty := node{}
            fmt.Println(zero, zero == point{}, empty.name == "", empty.next == nil, empty.tags == nil, empty.at)
            fmt.Printf("%+v %#v\\n", point{}, point{Y: 2})
            fmt.Println([]point{point{}, point{X: 1}}, [2]point{}, map[string]point{"z": point{}})
            """,
            declarations: Self.declarations)

        #expect(
            output == """
                {0 0} true true true true {0 0}
                {X:0 Y:0} main.point{X:0, Y:2}
                [{0 0} {1 0}] [{0 0} {0 0}] map[z:{0 0}]

                """)
    }

    @Test func theAddressOfALiteralIsANewVariableEachTime() throws {
        let output = try runGoMain(
            """
            p := &point{X: 1, Y: 2}
            q := &point{X: 1, Y: 2}
            fmt.Println(p == q, *p == *q, p == p)
            p.X = 10
            fmt.Println(*p, *q, (&point{X: 3}).X, *(&point{}))
            var list []*point
            for i := 0; i < 3; i++ {
                list = append(list, &point{X: i})
            }
            list[0].X = 100
            fmt.Println(*list[0], *list[1], *list[2], list[0] == list[1])
            n := build("a")
            n.next = &node{name: "b", next: &node{}}
            fmt.Println(n.rename("c").name, n.next.name, n.next.next.next == nil)
            fmt.Printf("%v %+v %T\\n", p, q, &node{})
            table := map[string]*point{"k": &point{X: 7}}
            found := table["k"]
            found.Y = 8
            fmt.Println(*table["k"], *(&[]int{1, 2}), *(&map[string]int{"a": 1}))
            """,
            declarations: Self.declarations)

        #expect(
            output == """
                false true true
                {10 2} {1 2} 3 {0 0}
                {100 0} {1 0} {2 0} false
                c b true
                &{10 2} &{X:1 Y:2} *main.node
                {7 8} [1 2] map[a:1]

                """)
    }

    @Test func aLiteralBehindAPointerOutlivesItsFunction() throws {
        let output = try runGoMain(
            """
            var kept []*node
            for round := 0; round < 5000; round++ {
                kept = append(kept, build("n"))
                if len(kept) > 3 {
                    kept = kept[1:]
                }
            }
            fmt.Println(len(kept), kept[0].name, kept[0] != kept[1])
            """,
            declarations: Self.declarations,
            machine: GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumHeapCells: 2_000)))

        // Five thousand nodes were made in a heap that holds two thousand
        // cells: those no pointer reaches any more were collected.
        #expect(output == "3 n true\n")
    }

    @Test func literalsAreChecked() {
        #expect(
            diagnostic("fmt.Println(point{1})")
                == "too few values in struct literal of type point")
        #expect(
            diagnostic("fmt.Println(point{1, 2, 3})")
                == "too many values in struct literal of type point")
        #expect(
            diagnostic("fmt.Println(&point{Z: 1})")
                == "unknown field Z in struct literal of type point")
        #expect(diagnostic("fmt.Println(&point{X: \"a\"})") != nil)
        #expect(
            diagnostic("p := &5\nfmt.Println(p)")
                == "invalid operation: cannot take address of a value that is not a variable")
        #expect(diagnostic("var p *point = &node{}\nfmt.Println(p)") != nil)
        #expect(diagnostic("var p *point = &point{}\nfmt.Println(p, point{}, &node{})") == nil)
    }

    @Test func gofmtPrintsPointerElementTypes() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main

                type node struct {
                next *node
                list []*node
                byKey map[string]*node
                }

                var index map[string]*node

                func main() {
                p:=&node{}
                list:=[]*node{&node{next:p},&node{}}
                more:=make([]*node,0,4)
                byKey:=map[string]*node{"a":list[0]}
                z:=node{}
                }

                """)

        #expect(
            try GoFormatter.format(source) == """
                package main

                type node struct {
                \tnext *node
                \tlist []*node
                \tbyKey map[string]*node
                }

                var index map[string]*node

                func main() {
                \tp := &node{}
                \tlist := []*node{&node{next: p}, &node{}}
                \tmore := make([]*node, 0, 4)
                \tbyKey := map[string]*node{"a": list[0]}
                \tz := node{}
                }

                """)
    }
}
