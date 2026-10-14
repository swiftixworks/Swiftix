/// A compound assignment and `++`/`--` evaluate their target once, as Go
/// does: `m[f()] += 1` calls `f` once, `a[<-ch]++` receives once, and
/// `p().x -= 2` calls `p` once.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go targets evaluated once")
struct GoSingleEvaluationTests: GoTestHarness {

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

    /// Every operand of the target that is a call or a receive is made once,
    /// before the value on the right, and the place it names is read and
    /// written: an element of a map, a slice, an array, an array behind a
    /// pointer, a field behind a pointer a call returns, and a promoted one.
    @Test func aTargetWithACallIsEvaluatedOnce() throws {
        #expect(
            try runGoMain(
                """
                m := map[int]int{}
                m[at("k", 1)] += at("v", 10)
                m[at("k", 1)] *= 3
                m[at("k", 2)]++
                m[at("k", 2)] <<= 4
                ch := make(chan int, 3)
                ch <- 0
                ch <- 1
                ch <- 1
                a := []int{5, 6}
                a[<-ch]++
                a[<-ch]--
                a[<-ch] |= 8
                origin().x -= 2
                origin().y++
                box().x += 7
                box().cells[at("i", 2)] += 9
                arr := [3]int{}
                arr[at("j", 1)] += 4
                pa := &arr
                pa[at("j", 2)]--
                grid := [][]int{{1}, {2}}
                grid[at("row", 1)][at("col", 0)] += 100
                fmt.Println(m, a, shared, held, arr, grid)
                fmt.Println(trace)
                """,
                declarations: """
                    type point struct{ x, y int }
                    type outer struct {
                        point
                        cells [3]int
                    }

                    var trace []string

                    func at(name string, v int) int { trace = append(trace, name); return v }
                    func origin() *point          { trace = append(trace, "p"); return &shared }
                    func box() *outer             { trace = append(trace, "o"); return &held }

                    var shared point
                    var held outer
                    """)
                == """
                map[1:30 2:16] [6 13] {-2 1} {{7 0} [0 0 9]} [0 4 -1] [[1] [102]]
                [k v k k k p p o o i j j row col]

                """)
        #expect(
            try runGoMain(
                """
                small := []uint8{250}
                small[at("u", 0)] += 10
                fl := []float64{1.5}
                fl[at("f", 0)]++
                fl[at("f", 0)] *= 2
                words := map[string]string{"a": "x"}
                words[fmt.Sprint("a")] += "y"
                for i := 0; i < 2; small[at("post", 0)]++ {
                    i++
                }
                fmt.Println(small, fl, words, trace)
                """,
                declarations: """
                    type point struct{ x, y int }
                    type outer struct {
                        point
                        cells [3]int
                    }

                    var trace []string

                    func at(name string, v int) int { trace = append(trace, name); return v }
                    func origin() *point          { trace = append(trace, "p"); return &shared }
                    func box() *outer             { trace = append(trace, "o"); return &held }

                    var shared point
                    var held outer
                    """)
                == "[6] [5] map[a:xy] [u f f post post]\n")
    }

    /// `p().x = v` stores in the field of what `p` returns, as Go does with any
    /// pointer, and so does an assertion to a pointer type or a receive.
    @Test func aPointerThatACallReturnsHasFieldsToAssign() throws {
        #expect(
            try runGoMain(
                """
                origin().x = 4
                var v any = &point{}
                v.(*point).y += 2
                ch := make(chan *point, 1)
                ch <- &shared
                (<-ch).y = 9
                fmt.Println(shared, v, trace)
                """,
                declarations: """
                    type point struct{ x, y int }
                    type outer struct {
                        point
                        cells [3]int
                    }

                    var trace []string

                    func at(name string, v int) int { trace = append(trace, name); return v }
                    func origin() *point          { trace = append(trace, "p"); return &shared }
                    func box() *outer             { trace = append(trace, "o"); return &held }

                    var shared point
                    var held outer
                    """)
                == "{4 9} &{0 2} [p]\n")
    }

    /// A field of a struct a call returns, or an element of an array one
    /// returns, is no variable.
    @Test func targetsThatAreNoVariablesAreRefused() {
        #expect(
            firstError(
                """
                value().x += 1
                _ = fmt.Sprint()
                """,
                declarations: """
                    type point struct{ x int }

                    func value() point { return point{} }
                    """)
                == "7:1: cannot assign to value().x (neither addressable nor a map index expression)")
        #expect(
            firstError(
                """
                value().x++
                _ = fmt.Sprint()
                """,
                declarations: """
                    type point struct{ x int }

                    func value() point { return point{} }
                    """)
                == "7:1: cannot assign to value().x (neither addressable nor a map index expression)")
        #expect(
            firstError(
                """
                pair()[0] -= 1
                _ = fmt.Sprint()
                """,
                declarations: "func pair() [2]int { return [2]int{} }")
                == "5:1: cannot assign to pair()[0] (neither addressable nor a map index expression)")
        #expect(
            firstError(
                """
                x := 1
                x += value()
                _ = fmt.Sprint()
                """,
                declarations: """
                    type point struct{ x int }

                    func value() point { return point{} }
                    """)
                == "8:1: invalid operation: x += value() (mismatched types int and point)")
    }

    /// `f()[1:]` slices what one call returns: the length that the missing
    /// upper bound stands for is that of the same value.
    @Test func aSliceExpressionReadsItsBaseOnce() throws {
        #expect(
            try runGoMain(
                """
                a := many()[1:]
                b := many()[:2]
                c := many()[1:2]
                d := array()[1:]
                e := text()[2:]
                ch := make(chan []int, 1)
                ch <- []int{7, 8}
                g := (<-ch)[1:]
                fmt.Println(a, b, c, d, e, g, calls)
                """,
                declarations: """
                    var calls int

                    func many() []int { calls++; return []int{1, 2, 3} }

                    var arr = [3]int{4, 5, 6}

                    func array() *[3]int { calls++; return &arr }
                    func text() string   { calls++; return "hello" }
                    """)
                == "[2 3] [1 2] [2] [5 6] llo [8] 5\n")
    }

    /// A struct in a map is a copy: its fields are not assigned, nor the fields
    /// of a struct in it; through a pointer element or field they are.
    @Test func aFieldOfAMapElementIsNoVariable() throws {
        #expect(
            firstError(
                """
                m := map[int]point{}
                m[1].y = 1
                fmt.Println(m)
                """,
                declarations: "type point struct{ x, y int }")
                == "6:1: cannot assign to struct field m[1].y in map")
        #expect(
            firstError(
                """
                m := map[int]point{}
                m[1].y += 1
                fmt.Println(m)
                """,
                declarations: "type point struct{ x, y int }")
                == "6:1: cannot assign to struct field m[1].y in map")
        #expect(
            firstError(
                """
                m := map[int]point{}
                m[1].y++
                fmt.Println(m)
                """,
                declarations: "type point struct{ x, y int }")
                == "6:1: cannot assign to struct field m[1].y in map")
        #expect(
            firstError(
                """
                m := map[int]outer{}
                m[1].x = 1
                fmt.Println(m)
                """,
                declarations: """
                    type point struct{ x, y int }
                    type outer struct{ point }
                    """)
                == "7:1: cannot assign to struct field m[1].x in map")
        #expect(
            firstError(
                """
                m := map[int]nest{}
                m[1].p.x = 1
                fmt.Println(m)
                """,
                declarations: """
                    type point struct{ x, y int }
                    type nest struct{ p point }
                    """)
                == "7:1: cannot assign to m[1].p.x (neither addressable nor a map index expression)")
        #expect(
            try runGoMain(
                """
                m := map[int]*point{1: {}}
                m[1].x = 4
                n := map[int]link{1: {&point{}}}
                n[1].p.y = 3
                fmt.Println(*m[1], *n[1].p)
                """,
                declarations: """
                    type point struct{ x, y int }
                    type link struct{ p *point }
                    """)
                == "{4 0} {0 3}\n")
    }

    /// With a type declared in the function and an alias, and inside a literal
    /// whose variables live in the function around it. An aliased import and a
    /// second package are in `GoExpressionPassTests`.
    @Test func everyPassSeesTheTarget() throws {
        #expect(
            try runGoMain(
                """
                type cell struct{ n int }
                type same = cell
                cells := []same{{1}, {2}}
                next := 0
                pick := func() int { next++; return next - 1 }
                cells[pick()].n += 10
                cells[pick()].n++
                total := 0
                bump := func() {
                    counts := map[string]int{}
                    key := func() string { total++; return "k" }
                    counts[key()] += 2
                    counts[key()] <<= 3
                    fmt.Println(counts)
                }
                bump()
                fmt.Println(cells, next, total)
                """)
                == "map[k:16]\n[{11} {3}] 2 2\n")
    }
}
