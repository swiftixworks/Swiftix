/// A pointer to an array where Go follows it without a `*`: `p[i]` read and
/// assigned, `&p[i]`, `p[a:b]`, `len(p)`, `cap(p)`, and `for i, v := range p`.
///
/// `p[i]` and `p[a:b]` are `(*p)[i]` and `(*p)[a:b]`, and a nil `p` panics
/// there as `*p` does. `len(p)` and `cap(p)` are the length of the array type,
/// for which the pointer is not followed, and neither is it by a `range` that
/// takes no element: both work on a nil pointer.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go pointers to arrays")
struct GoArrayPointerTests: GoTestHarness {

    /// Reading and assigning an element, taking its address, slicing, and the
    /// length, all through the pointer.
    @Test func indexingSlicingAndLength() throws {
        #expect(
            try runGoMain(
                """
                a := [3]int{1, 2, 3}
                p := &a
                fmt.Println(p[1], len(p), cap(p), p[0:2], p[:], p[1:])
                p[2] = 9
                q := &p[1]
                *q = 5
                p[0]++
                p[2] += 10
                i, j := 0, 2
                p[i], p[j] = p[j], p[i]
                s := p[:]
                s[1] = 8
                fmt.Println(a, *p, len(p[:2]), s, len(s), cap(s))
                """)
                == "2 3 3 [1 2] [1 2 3] [2 3]\n[19 8 2] [19 8 2] 2 [19 8 2] 3 3\n")
        #expect(
            try runGoMain(
                """
                g := grid{{1, 2}, {3, 4}}
                p := &g
                p[1][0] = 9
                t := &holder{}
                q := &t.a
                q[1] = 4
                x := [3]string{"a", "b", "c"}
                px := &x
                var pp **[3]string = &px
                m := map[string]*[2]int{"k": {1, 2}}
                m["k"][1] = 5
                n := new([2]point)
                n[1].X = 3
                fmt.Println(p[1], p[0][1], len(p), len(p[0]), g, t.a, (*pp)[1], len(*pp), m["k"][1], *m["k"], *n, len(n))
                """,
                declarations: """
                    type grid [2][2]int
                    type holder struct{ a [3]int }
                    type point struct{ X, Y int }
                    """)
                == "[9 4] 2 2 2 [[1 2] [9 4]] [0 4 0] b 3 5 [1 5] [{0 0} {3 0}] 2\n")
    }

    /// A `range` with a value reads the elements of the array the pointer
    /// points to as they are when it reaches them, where a `range` over the array
    /// itself would read a copy. One without a value only counts.
    @Test func rangeThroughThePointer() throws {
        #expect(
            try runGoMain(
                """
                a := [3]int{1, 2, 3}
                p := &a
                for i, v := range p {
                    if i == 0 {
                        p[2] = 9
                    }
                    fmt.Print(i, v, " ")
                }
                for i := range p {
                    fmt.Print(i)
                }
                for range p {
                    fmt.Print("x")
                }
                g := [2][2]int{{1, 2}, {3, 4}}
                for _, row := range &g {
                    for _, v := range row {
                        fmt.Print(" ", v)
                    }
                }
                fmt.Println()
                """)
                == "0 1 1 2 2 9 012xxx 1 2 3 4\n")
    }

    /// The length of the array type needs no array: `len`, `cap`, and a `range`
    /// without a value work on a nil pointer, and call what the operand calls.
    /// Everything that reads or writes an element panics as `*p` does.
    @Test func aNilPointer() throws {
        #expect(
            try runGoMain(
                """
                var p *[3]int
                fmt.Println(len(p), cap(p), len(none()), cap(none()))
                for i := range p {
                    fmt.Print(i)
                }
                for i, _ := range p {
                    fmt.Print(i)
                }
                for i := range none() {
                    fmt.Print(i)
                }
                var empty *[0]int
                for i, v := range empty {
                    fmt.Print(i, v)
                }
                fmt.Println()
                show(func() { fmt.Println(p[1]) })
                show(func() { p[1] = 2 })
                show(func() { fmt.Println(p[1:]) })
                show(func() { fmt.Println(&p[1] == nil) })
                show(func() {
                    for i, v := range p {
                        fmt.Println(i, v)
                    }
                })
                a := [3]int{}
                q := &a
                i := 5
                show(func() { fmt.Println(q[i]) })
                """,
                declarations: """
                    func none() *[3]int {
                        fmt.Print("called ")
                        return nil
                    }

                    func show(f func()) {
                        defer func() { fmt.Println(recover()) }()
                        f()
                    }
                    """)
                == """
                called called 3 3 3 3
                012012called 012
                runtime error: invalid memory address or nil pointer dereference
                runtime error: invalid memory address or nil pointer dereference
                runtime error: invalid memory address or nil pointer dereference
                runtime error: invalid memory address or nil pointer dereference
                runtime error: invalid memory address or nil pointer dereference
                runtime error: index out of range [5] with length 3

                """)
    }

    /// Only a pointer to an array is followed: one to a slice or to anything
    /// else is not indexed.
    @Test func whatIsNotIndexed() {
        #expect(
            goMainDiagnostic(
                """
                var p *[]int
                fmt.Println(p[0])
                """)
                == "invalid operation: cannot index p (variable of type *[]int)")
        #expect(
            goMainDiagnostic(
                """
                var p *int
                fmt.Println(p[0])
                """)
                == "invalid operation: cannot index p (variable of type *int)")
        #expect(
            goMainDiagnostic(
                """
                var p *[]int
                fmt.Println(len(p))
                """)
                == "invalid argument: p (variable of type *[]int) for built-in len")
        #expect(
            goMainDiagnostic(
                """
                var p *[]int
                for range p {
                }
                """)
                == "cannot range over p (variable of type *[]int)")
    }
}
