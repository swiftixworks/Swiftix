/// A function literal called where it is written, `func(xs ...int) {}(1, 2)`,
/// by a call, a `go` statement, or a `defer`: a variadic parameter takes the
/// arguments past the fixed ones as a slice, or a `slice...` as it is, and
/// an argument given to an interface parameter keeps its type.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go function literals called where they are written")
struct GoVariadicLiteralCallTests: GoTestHarness {

    /// With no arguments past the fixed ones, several, or a spread slice, and
    /// with a result.
    @Test func aVariadicLiteralIsCalledWhereItIsWritten() throws {
        #expect(
            try runGoMain(
                """
                n := func(p string, xs ...int) int { fmt.Println(p, xs, len(xs)); return len(xs) }("a", 1, 2, 3)
                func(xs ...int) { fmt.Println(xs == nil) }()
                s := []int{7, 8}
                func(xs ...int) { fmt.Println(xs) }(s...)
                fmt.Println(n, func(xs ...any) string { return fmt.Sprint(xs...) }(1, "b"))
                """)
                == "a [1 2 3] 3\ntrue\n[7 8]\n3 1b\n")
    }

    /// A literal that captures nothing and one that captures a variable, in
    /// the order a `defer` runs them.
    @Test func goAndDeferCallAVariadicLiteral() throws {
        #expect(
            try runGoMain(
                #"""
                k := 10
                defer func(xs ...int) { fmt.Println("d0", xs, k, xs == nil) }()
                defer func(xs ...int) { fmt.Println("d1", xs, k) }(1)
                defer func(p string, xs ...int) { fmt.Println("d2", p, xs) }("p", 1, 2)
                s := []int{3}
                defer func(xs ...int) { fmt.Println("d3", xs) }(s...)
                defer func(xs ...int) { fmt.Println("d4", xs, xs == nil) }()
                defer func(xs ...any) { fmt.Printf("d5 %v %T\n", xs, xs[0]) }(int8(1), "a", 2.5)
                done := make(chan bool)
                go func(xs ...int) { fmt.Println("g", xs); close(done) }(4, 5)
                <-done
                other := make(chan bool)
                go func(c chan bool, xs ...int) { fmt.Println("g2", xs); close(c) }(other)
                <-other
                k = 11
                """#)
                == """
                g [4 5]
                g2 []
                d5 [1 a 2.5] int8
                d4 [] true
                d3 [3]
                d2 p [1 2]
                d1 [1] 11
                d0 [] 11 true

                """)
    }

    /// Given to an interface parameter, a value is boxed with its type, as for
    /// any call.
    @Test func anArgumentOfADeferredLiteralKeepsItsType() throws {
        #expect(
            try runGoMain(
                #"""
                type point struct{ a int }
                defer func(x any, e error) { fmt.Printf("%T %v %v\n", x, x, e == nil) }(int8(1), nil)
                defer func(x any) { fmt.Printf("%T %v\n", x, x) }(point{2})
                defer func(x float64) { fmt.Println(x) }(1)
                done := make(chan bool)
                go func(x any) { fmt.Printf("%T\n", x); close(done) }(uint16(4))
                <-done
                """#)
                == "uint16\n1\nmain.point {2}\nint8 1 true\n")
    }
}
