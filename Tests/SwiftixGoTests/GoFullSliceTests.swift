/// Full slice expressions `a[low:high:max]` of slices, arrays, and pointers
/// to arrays: the result has the capacity `max - low`, so what is appended
/// to it does not reach the elements of `a` past `max`.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go full slice expressions")
struct GoFullSliceTests: GoTestHarness {

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

    /// `GoExpression.slicing` has room for two indexes: the second of a full
    /// slice expression is a call no source can write, of `high` and `max`.
    @Test func aFullSliceIsCarriedInTheSecondIndex() throws {
        let file = try GoParser.parse(
            GoSourceFile(path: "main.go", text: "package main\nfunc main() { _ = s[1:2:3] }\n"))
        guard case .assignment(_, .slicing(_, let low, let high, _), _)? =
            file.functions.first?.body.statements.first
        else {
            Issue.record("not a slice expression")
            return
        }
        #expect(low.map { if case .integer(1, _) = $0 { true } else { false } } == true)
        let bounds = try #require(high?.fullSliceBounds)
        #expect(bounds.high.sourceSpelling == "2")
        #expect(bounds.max.sourceSpelling == "3")
    }

    /// Of a slice, an array, and a pointer to an array; `low` may be left out.
    /// An append past the capacity copies, so the elements after `max` keep
    /// their values.
    @Test func theCapacityIsMaxLessLow() throws {
        #expect(
            try runGoMain(
                """
                s := []int{1, 2, 3, 4, 5}
                t := s[1:3:4]
                fmt.Println(t, len(t), cap(t))
                t = append(t, 9)
                fmt.Println(s, t)
                t = append(t, 10)
                t[0] = 0
                fmt.Println(s, t, cap(t))
                u := s[:2:2]
                u = append(u, 7)
                fmt.Println(s, u)
                a := [4]int{1, 2, 3, 4}
                v := a[1:2:3]
                v = append(v, 8)
                fmt.Println(a, v, len(v), cap(v))
                p := &a
                w := p[0:0:1]
                w = append(w, []int{6, 5}...)
                fmt.Println(a, w, cap(p[:4:4]), len(a[4:4:4]))
                var none []int
                n := none[0:0:0]
                fmt.Println(n == nil, len(n), cap(n))
                i, j, k := 1, 2, 3
                fmt.Println(s[i:j:k], s[i+1:j+1:k+1], s[:j:k][1:2:2])
                """)
                == """
                [2 3] 2 3
                [1 2 3 9 5] [2 3 9]
                [1 2 3 9 5] [0 3 9 10] 6
                [1 2 3 9 5] [1 2 7]
                [1 2 8 4] [2 8] 2 2
                [1 2 8 4] [6 5] 4 0
                true 0 0
                [2] [3] [2]

                """)
    }

    /// `max` is tested against the capacity (the length of an array) first,
    /// then `high` against `max`, then `low` against `high`; a negative bound
    /// fails the first test it is in. A nil pointer to an array is followed.
    @Test func boundsOutOfRangePanicAsGoSays() throws {
        #expect(
            try runGoMain(
                """
                s := make([]int, 2, 4)
                a := [4]int{}
                var p *[4]int
                for _, n := range []int{5, -1} {
                    guarded("max", func() { _ = s[0:1:n] })
                    guarded("array", func() { _ = a[0:1:n] })
                    guarded("high", func() { _ = s[0 : n+3 : 2] })
                    guarded("low", func() { _ = s[n+2 : 1 : 2] })
                }
                guarded("nil", func() { _ = p[0:1:2] })
                """,
                declarations: #"""
                    func guarded(name string, f func()) {
                        defer func() {
                            r := recover()
                            fmt.Printf("%s: %v (%T)\n", name, r, r)
                        }()
                        f()
                    }
                    """#)
                == """
                max: runtime error: slice bounds out of range [::5] with capacity 4 (runtime.boundsError)
                array: runtime error: slice bounds out of range [::5] with length 4 (runtime.boundsError)
                high: runtime error: slice bounds out of range [:8:2] (runtime.boundsError)
                low: runtime error: slice bounds out of range [7:1:] (runtime.boundsError)
                max: runtime error: slice bounds out of range [::-1] (runtime.boundsError)
                array: runtime error: slice bounds out of range [::-1] (runtime.boundsError)
                high: <nil> (<nil>)
                low: <nil> (<nil>)
                nil: runtime error: invalid memory address or nil pointer dereference (runtime.errorString)

                """)
    }

    /// A string has no capacity; the second and the third index are written;
    /// constant indexes are integers, not negative, within an array, and in
    /// order.
    @Test func wrongFullSlicesAreRefused() {
        #expect(
            firstError(
                """
                s := "abcd"
                fmt.Println(s[1:2:3])
                """)
                == "6:19: invalid operation: 3-index slice of string")
        #expect(
            firstError(
                """
                s := []int{1, 2, 3}
                fmt.Println(s[1::3])
                """)
                == "6:17: middle index required in 3-index slice")
        #expect(
            firstError(
                """
                s := []int{1, 2, 3}
                fmt.Println(s[1:2:])
                """)
                == "6:19: final index required in 3-index slice")
        #expect(
            firstError(
                """
                s := []int{1, 2, 3}
                fmt.Println(s[2:1:3])
                """)
                == "6:17: invalid slice indices: 1 < 2")
        #expect(
            firstError(
                """
                s := []int{1, 2, 3}
                fmt.Println(s[1:3:2])
                """)
                == "6:19: invalid slice indices: 2 < 3")
        #expect(
            firstError(
                """
                a := [4]int{}
                fmt.Println(a[1:2:5])
                """)
                == "6:19: invalid argument: index 5 out of bounds [0:5]")
        #expect(
            firstError(
                """
                s := []int{1}
                fmt.Println(s[1:2:-1])
                """)
                == "6:19: invalid argument: index -1 (constant of type int) must not be negative")
        #expect(
            firstError(
                """
                s := []int{1}
                fmt.Println(s[1.5:2:3])
                """)
                == "6:15: 1.5 (untyped float constant) truncated to int")
        #expect(
            firstError(
                """
                s := []int{1}
                fmt.Println(s[0:1:"x"])
                """)
                == "6:19: cannot convert \"x\" (untyped string constant) to type int")
        #expect(
            firstError(
                """
                s := []int{1}
                fmt.Println(s[int8(-1):1:1])
                """)
                == "6:15: invalid argument: index int8(-1) (constant -1 of type int8) must not be negative")
        #expect(
            firstError(
                """
                m := map[int]int{}
                fmt.Println(m[0:1:2])
                """)
                == "6:13: invalid operation: cannot slice m (variable of type map[int]int)")
    }

    /// As in a full slice expression, which shares the rule.
    @Test func constantIndexesOfTwoIndexSlicesAreChecked() throws {
        #expect(
            firstError(
                """
                s := []int{1, 2, 3}
                fmt.Println(s[2:1])
                """)
                == "6:17: invalid slice indices: 1 < 2")
        #expect(
            firstError(
                """
                a := [4]int{}
                fmt.Println(a[1:5])
                """)
                == "6:17: invalid argument: index 5 out of bounds [0:5]")
        #expect(
            firstError(
                """
                s := []int{1}
                fmt.Println(s[-1:])
                """)
                == "6:15: invalid argument: index -1 (constant of type int) must not be negative")
        #expect(
            try runGoMain(
                """
                a := [4]int{}
                fmt.Println(a[4:], a[:4], a[2:2])
                """)
                == "[] [0 0 0 0] []\n")
    }

    /// The array a literal slices is the variable of the function around it.
    @Test func aFullSliceInAClosureAndALocalType() throws {
        #expect(
            try runGoMain(
                """
                type pair [2]int
                type same = pair
                var arr same = same{1, 2}
                grow := func(x int) []int {
                    t := arr[0:1:1]
                    return append(t, x)
                }
                g := grow(9)
                g[0] = 5
                fmt.Println(arr, g, cap(arr[1:1:2]))
                """)
                == "[1 2] [5 9] 1\n")
    }
}
