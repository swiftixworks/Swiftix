/// Composite literals that leave to their type what it can say: the type
/// of an element or a key (`[]point{{1, 2}}`, `map[point]string{{1, 2}: "a"}`),
/// the `&` of an element that is a pointer (`[]*point{{1, 2}}`), the index an
/// element of an array or a slice stands at (`[]int{2: 5, 7}`), and the length
/// of `[...]T`.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change. A message this dialect words in its own way, by the type
/// of an operand where Go quotes the operand, is pinned as it is. How `gofmt`
/// lays such literals out is compared with Go's in `GoLiteralFormattingTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go composite literals without element types")
struct GoElidedLiteralTests: GoTestHarness {

    /// The module of `everyPackageOfAModuleWritesThem`, and what Go prints for it.
    private static let moduleMain = #"""
        package main

        import (
            f "fmt"

            "example/m/internal/conf"
            sh "example/m/shapes"
            . "example/m/shapes"
        )

        type local = sh.Point

        func main() {
            p := sh.Path{{1, 2}, {3, 4}}
            q := Pointers{{1, 2}, {X: 3}}
            n := sh.Named{"a": {1, 2}}
            b := ByPoint{{1, 2}: "x"}
            l := []local{{5, 6}}
            pairs := []Pair{{1, 2}, {A: 3}}
            names := [...]string{sh.Blue: "b", Red: "r"}
            colors := map[Color]int{Red: 1, sh.Green: 2}
            sp := []int{sh.Offset: 1, Offset + 1: 2}
            f.Println(p, *q[0], *q[1], n, b, l, pairs, names, colors, sp)
            f.Printf("%T %T %T %T\n", p, q, pairs, l)
            f.Println(sh.Unit, sh.Table, sh.Names, conf.Defaults, conf.Limits)
            type inner struct{ a, b int }
            type list []inner
            count := 0
            add := func(extra ...inner) []inner {
                count++
                return append(list{{count, count}}, extra...)
            }
            f.Println(list{{1, 2}, {b: 3}}, map[string]inner{"x": {1, 2}}, add(), add(inner{9, 9}), count)
        }

        """#

    private static let moduleShapes = #"""
        package shapes

        type Point struct{ X, Y int }

        type Path []Point

        type Pointers []*Point

        type Named map[string]Point

        type ByPoint map[Point]string

        type Color int

        const (
            Red Color = iota
            Green
            Blue
        )

        const Offset = 2

        type Pair = struct{ A, B int }

        var Names = [...]string{Red: "red", Green: "green", Blue: "blue"}

        var Unit = Path{{1, 0}, {0, 1}}

        var Table = []struct {
            Name string
            At   Point
        }{
            {"origin", Point{}},
            {Name: "unit", At: Point{1, 1}},
        }

        """#

    private static let moduleConf = #"""
        package conf

        type Entry struct {
            Key   string
            Value []int
        }

        type Entries []Entry

        var Defaults = Entries{{"a", []int{1}}, {Key: "b"}}

        var Limits = map[string]struct{ Lo, Hi int }{"x": {1, 2}}

        """#

    private static let moduleOutput = #"""
        [{1 2} {3 4}] {1 2} {3 0} map[a:{1 2}] map[{1 2}:x] [{5 6}] [{1 2} {3 0}] [r  b] map[0:1 1:2] [0 0 1 2]
        shapes.Path shapes.Pointers []struct { A int; B int } []shapes.Point
        [{1 0} {0 1}] [{origin {0 0}} {unit {1 1}}] [red green blue] [{a [1]} {b []}] map[x:{1 2}]
        [{1 2} {0 3}] map[x:{1 2}] [{1 1}] [{2 2} {9 9}] 2

        """#

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

    /// A literal inside a literal of a slice, an array, or a map is of the
    /// element type when it names no type, at any depth.
    @Test func anElementTakesTheElementTypeOfItsLiteral() throws {
        #expect(
            try runGoMain(
                #"""
                ps := []point{{1, 2}, {3, 4}}
                grid := [][]int{{1}, {2, 3}, {}}
                arr := [2]point{{1, 2}, {X: 3}}
                deep := [][]point{{{1, 2}, {3, 4}}, {}, nil}
                fmt.Println(ps, grid, arr, deep, len(grid[2]), deep[2] == nil)
                fmt.Printf("%T %T %T\n", ps[0], grid[1], deep[0][1])
                """#,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == """
                [{1 2} {3 4}] [[1] [2 3] []] [{1 2} {3 0}] [[{1 2} {3 4}] [] []] 0 true
                main.point []int main.point

                """)
        #expect(
            try runGoMain(
                """
                m := map[string]point{"a": {1, 2}, "b": {Y: 3}}
                lists := map[string][]int{"a": {1}, "b": {}, "c": nil}
                nested := map[string]map[string]point{"x": {"y": {1, 2}}}
                fmt.Println(m, lists, nested, lists["c"] == nil, len(lists["b"]))
                """,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "map[a:{1 2} b:{0 3}] map[a:[1] b:[] c:[]] map[x:map[y:{1 2}]] true 0\n")
    }

    /// The key of a map entry is a literal of the key type when it names none.
    @Test func aKeyTakesTheKeyTypeOfItsMap() throws {
        #expect(
            try runGoMain(
                """
                names := map[point]string{{1, 2}: "a", {X: 3}: "b"}
                pairs := map[[2]int][]point{{1, 2}: {{3, 4}}}
                fmt.Println(names[point{1, 2}], names[point{3, 0}], pairs, len(names))
                """,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "a b map[[1 2]:[{3 4}]] 2\n")
    }

    /// Where the element type is `*T`, a literal without a type is `&T{...}`: a
    /// pointer to a variable of its own, each time the literal is evaluated.
    @Test func anElementThatIsAPointerIsANewVariable() throws {
        #expect(
            try runGoMain(
                #"""
                ps := []*point{{1, 2}, {X: 3}}
                ps[0].X = 9
                fmt.Println(*ps[0], *ps[1], ps[0] != ps[1])
                byName := map[string]*point{"a": {1, 1}}
                byName["a"].Y = 5
                var made []*point
                for i := 0; i < 3; i++ {
                    made = append(made, []*point{{i, i}}...)
                }
                made[0].X = 7
                slices := []*[]int{{1, 2}}
                fmt.Println(*byName["a"], *made[0], *made[1], *made[2], made[0] != made[1], *slices[0])
                fmt.Printf("%T %T\n", ps, ps[0])
                """#,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == """
                {9 2} {3 0} true
                {1 5} {7 0} {1 1} {2 2} true [1 2]
                []*main.point *main.point

                """)
    }

    /// The type of a literal may be a name: what it is declared as says what
    /// its elements are, also for a type that is made of itself.
    @Test func aNamedTypeGivesItsElementsTheirType() throws {
        #expect(
            try runGoMain(
                #"""
                p := path{{1, 2}, {3, 4}}
                g := grid{{1, 2}, {3, 4}}
                ix := index{"a": {{1, 2}}, "b": {}}
                ps := ptrs{{1, 2}, {X: 3}}
                fmt.Println(p, g, ix, *ps[0], *ps[1])
                fmt.Printf("%T %T %T %T\n", p, g, ix, ps)
                """#,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }

                    type path []point
                    type grid [2][2]int
                    type index map[string][]point
                    type ptrs []*point
                    type color int

                    const (
                        red color = iota
                        green
                        blue
                    )

                    const offset = 2
                    """)
                == """
                [{1 2} {3 4}] [[1 2] [3 4]] map[a:[{1 2}] b:[]] {1 2} {3 0}
                main.path main.grid main.index main.ptrs

                """)
        #expect(
            try runGoMain(
                """
                s := tree{{}, {{}, {}}}
                n := node{kids: []node{{}, {kids: []node{{}}}}, next: &node{}}
                fmt.Println(len(s), len(s[1]), len(n.kids), len(n.kids[1].kids), n.next.next == nil)
                """,
                declarations: """
                    type tree []tree

                    type node struct {
                        kids []node
                        next *node
                    }
                    """)
                == "2 2 2 1 true\n")
    }

    /// Go lets the elements of an array, a slice, and a map leave their type
    /// out, not the fields of a struct: inside a struct literal a nested one is
    /// written with its type.
    @Test func aStructFieldNamesItsType() throws {
        #expect(
            try runGoMain(
                """
                ls := []line{{point{1, 2}, point{3, 4}}, {A: point{5, 6}}}
                fmt.Println(ls)
                """,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "[{{1 2} {3 4}} {{5 6} {0 0}}]\n")
        #expect(
            firstError("fmt.Println(line{{1, 2}, {3, 4}})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:18: missing type in composite literal")
        #expect(
            firstError("fmt.Println([]int{{1}})")
                == "5:19: invalid composite literal element type int")
    }

    /// An element of an array or a slice may say where it stands, by a constant
    /// index; the ones after it follow, and what no element fills is zero.
    @Test func anIndexPlacesAnElement() throws {
        #expect(
            try runGoMain(
                """
                a := []int{2: 5, 7}
                b := [5]int{1: 10, 3: 30}
                c := []string{2: "c", 0: "a"}
                d := [...]int{5: 1, 2, 3, 1: 9, 8}
                e := []int{5: 1, 2, 3, 1: 9, 8, 7, 6}
                f := [4]byte{'a', 2: 'c'}
                fmt.Println(a, len(a), b, c, len(c), d, len(d), e, f)
                """)
                == """
                [0 0 5 7] 4 [0 10 0 30 0] [a  c] 3 [0 9 8 0 0 1 2 3] 8 [0 9 8 7 6 1 2 3] [97 0 99 0]

                """)
        #expect(
            try runGoMain(
                """
                names := [...]string{red: "red", green: "green", blue: "blue"}
                by := map[color]string{red: "r", blue: "b"}
                sp := []int{offset: 1, offset + 2: 3, 9}
                const local = 1
                loc := []string{local: "x", local + 1: "y"}
                points := []point{2: {1, 2}, {3, 4}}
                fmt.Println(names, len(names), by, sp, len(sp), loc, points)
                """,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }

                    type path []point
                    type grid [2][2]int
                    type index map[string][]point
                    type ptrs []*point
                    type color int

                    const (
                        red color = iota
                        green
                        blue
                    )

                    const offset = 2
                    """)
                == """
                [red green blue] 3 map[0:r 2:b] [0 0 1 0 3 9] 6 [ x y] [{0 0} {0 0} {1 2} {3 4}]

                """)
        #expect(
            try runGoMain(
                """
                x, y := 1, 2
                keys := map[string]int{"a": x, "b": y}
                k := "key"
                byKey := table{k: x, "b": y}
                byInt := byNumber{1: "a", 2: "b"}
                fmt.Println(keys, byKey, byInt, byInt[1])
                """,
                declarations: """
                    type table map[string]int
                    type byNumber map[int]string
                    """)
                == "map[a:1 b:2] map[b:2 key:1] map[1:a 2:b] a\n")
    }

    /// `[...]T` is an array type whose length is that of the literal it is the
    /// type of: the highest index and one more.
    @Test func anArrayIsAsLongAsItsLiteral() throws {
        #expect(
            try runGoMain(
                #"""
                a := [...]int{1, 2, 3}
                b := [...]string{3: "x"}
                c := [...][]int{{1}, {2, 3}}
                d := [...]point{{1, 2}}
                e := [...]int{}
                fmt.Println(a, len(a), len(b), b[3], c, len(c), d, len(e))
                fmt.Printf("%T %T %T %T\n", a, b, c, e)
                """#,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == """
                [1 2 3] 3 4 x [[1] [2 3]] 2 [{1 2}] 0
                [3]int [4]string [2][]int [0]int

                """)
        #expect(
            firstError(
                """
                var a [...]int
                fmt.Println(a)
                """)
                == "5:7: invalid use of [...] array (outside a composite literal)")
        #expect(
            firstError("fmt.Println([][...]int{{1}})")
                == "5:15: invalid use of [...] array (outside a composite literal)")
    }

    /// A literal at package level is settled like one in a function, and so is
    /// one inside a function literal that uses the variables around it and a type
    /// its function declares.
    @Test func literalsOfThePackageAndOfClosures() throws {
        #expect(
            try runGoMain(
                """
                type inner struct{ a, b int }
                type list []inner
                count := 0
                add := func(extra ...inner) []inner {
                    count++
                    return append(list{{count, count}}, extra...)
                }
                fmt.Println(table, grid, byName, *refs[0], add(), add(inner{9, 9}), count)
                fmt.Println(list{{1, 2}, {b: 3}}, map[string]inner{"x": {1, 2}}, []*inner{{4, 5}}[0].b)
                """,
                declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }

                    var table = []point{{1, 2}, {3, 4}}
                    var grid = [][]int{{1, 2}, {3}}
                    var byName = map[string]point{"a": {1, 2}}
                    var refs = []*point{{5, 6}}
                    """)
                == """
                [{1 2} {3 4}] [[1 2] [3]] map[a:{1 2}] {5 6} [{1 1}] [{2 2} {9 9}] 2
                [{1 2} {0 3}] map[x:{1 2}] 5

                """)
    }

    /// The types and constants of another package say as much as those of the
    /// same one: under the name an import gives the package, under none after
    /// `import .`, and through an alias declaration.
    @Test func everyPackageOfAModuleWritesThem() throws {
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m",
                    sources: [GoSourceFile(path: "/m/main.go", text: Self.moduleMain)]),
                GoPackageSource(
                    importPath: "example/m/shapes",
                    sources: [GoSourceFile(path: "/m/shapes/shapes.go", text: Self.moduleShapes)]),
                GoPackageSource(
                    importPath: "example/m/internal/conf",
                    sources: [
                        GoSourceFile(path: "/m/internal/conf/conf.go", text: Self.moduleConf)
                    ]),
            ],
            root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == Self.moduleOutput)
    }

    /// The mistakes Go reports in the elements of a literal, each where Go
    /// reports it.
    @Test func whatALiteralMayNotSay() {
        #expect(
            firstError("fmt.Println([]int{2: 5, 2: 7})")
                == "5:25: duplicate index 2 in array or slice literal")
        #expect(
            firstError("fmt.Println([]int{1: 5, 0: 1, 2})")
                == "5:31: duplicate index 1 in array or slice literal")
        #expect(
            firstError("fmt.Println([3]int{3: 1})")
                == "5:20: invalid argument: index 3 out of bounds [0:3]")
        #expect(
            firstError("fmt.Println([3]int{1, 2, 3, 4})")
                == "5:29: index 3 is out of bounds (>= 3)")
        #expect(
            firstError("fmt.Println([]int{-1: 1})")
                == "5:19: invalid argument: index -1 (constant of type int) must not be negative")
        #expect(
            firstError(
                """
                i := 1
                fmt.Println([]int{i: 1})
                """)
                == "6:19: index i must be integer constant")
        #expect(
            firstError("fmt.Println(map[string]int{\"a\": 1, \"a\": 2})")
                == "5:36: duplicate key \"a\" in map literal")
        #expect(
            firstError("fmt.Println(map[int]string{1: \"a\", 1: \"b\"})")
                == "5:36: duplicate key 1 in map literal")
        #expect(
            firstError("fmt.Println(map[string]int{\"a\"})")
                == "5:28: missing key in map literal")
        #expect(
            firstError("fmt.Println(point{X: 2, 3})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:25: mixture of field:value and value elements in struct literal")
        #expect(
            firstError("fmt.Println([]point{{X: 1, 2}})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:28: mixture of field:value and value elements in struct literal")
        #expect(
            firstError("fmt.Println(point{1})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:20: too few values in struct literal of type point")
        #expect(
            firstError("fmt.Println(point{1, 2, 3})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:25: too many values in struct literal of type point")
        #expect(
            firstError("fmt.Println([]point{{X: 1, Z: 2}})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:28: unknown field Z in struct literal of type point")
        #expect(
            firstError("fmt.Println(point{X: 2, X: 3})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:25: duplicate field name X in struct literal")
        #expect(
            firstError("fmt.Println(point{1: 2})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:19: invalid field name 1 in struct literal")
        #expect(
            firstError("fmt.Println(point{\"X\": 2})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:19: invalid field name \"X\" in struct literal")
        #expect(
            goMainDiagnostic("fmt.Println([]*int{{1}})")
                == "invalid composite literal element type int")
        #expect(
            firstError("fmt.Println([]point{{1, \"a\"}})", declarations: """
                    type point struct{ X, Y int }
                    type line struct{ A, B point }
                    """)
                == "6:25: cannot use \"a\" (untyped string constant) as int value in struct literal")
        #expect(
            firstError("fmt.Println(map[string][]int{\"a\": {1, \"b\"}})")
                == "5:39: cannot use \"b\" (untyped string constant) as int value in array or slice literal")
        #expect(
            firstError("fmt.Println(map[string]int{1: 2})")
                == "5:28: cannot use 1 (untyped int constant) as string value in map literal")
        #expect(
            firstError("fmt.Println([]int{\"a\": 1})")
                == "5:19: cannot convert \"a\" (untyped string constant) to type int")
        #expect(
            goMainDiagnostic(
                """
                fmt.Println([]int{1
                })
                """)
                == "expected ',' or '}' in composite literal")
    }

    /// The key of a struct literal names a field, whatever else has that name:
    /// a variable beside it is still unused, and a package of that name is not
    /// misused.
    @Test func aFieldNameIsNoUseOfAVariable() throws {
        #expect(
            firstError(
                """
                x := 5
                t := named{x: 1}
                fmt.Println(t)
                """,
                declarations: "type named struct{ x int }")
                == "5:1: declared and not used: x")
        #expect(
            try runGoMain(
                """
                p := clock{time: 1, fmt: 2, strings: 3}
                q := []clock{{time: 4}}
                fmt.Println(p, q, time.Second > 0, strings.ToUpper("x"))
                """,
                imports: ["fmt", "strings", "time"],
                declarations: "type clock struct{ time, fmt, strings int }")
                == "{1 2 3} [{4 0 0}] true X\n")
    }
}
