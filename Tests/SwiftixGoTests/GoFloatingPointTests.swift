/// `float64` and `float32`: literals, constants, arithmetic, conversions,
/// and how `fmt`, `strconv`, and `math` print, read, and compute them.
///
/// A VM value has no case for a floating-point number. A `float64` is its
/// IEEE 754 bit pattern in the integer a value holds, and a `float32` is the
/// pattern of the `float64` with the same value; every operation is chosen
/// by the checker from the static type and is a reserved call (`$num.f*`).
/// A constant is exact until it is given a type, as Go has it: `1.0 / 3` is
/// a third, rounded once. See `GoNumericKind` and `GoFloat`.
///
/// What each program prints is what Go 1.24.5 prints for it. An error pinned
/// with its place is the first one Go's compiler reports, copied without
/// change; one pinned by its message alone is worded as this dialect words
/// such messages, and was compared with Go's when the test was written.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go floating point")
struct GoFloatingPointTests: GoTestHarness {

    /// A point, an exponent, digit separators, and the hexadecimal form with
    /// its binary exponent. The default type of a literal is `float64`.
    @Test func literalsHaveEveryFormOfGo() throws {
        #expect(
            try runGoMain(
                #"""
                x := 1.5
                fmt.Println(x, .5, 1., 1e9, 1E-3, 1_000.5, 0x1p-2, 0X1.8P+3, 0x.8p1, 08.5, 1e+0, 2.5e3, 0.000001, 123456789.125)
                fmt.Printf("%T %T %T %T\n", x, 1e9, 0x1p-2, .5)
                fmt.Println(3.0, 1e21, 1e20, 1e-7, 100000000.0, 5e-324, 1.7976931348623157e308, 0.1, 2.675, 1e6, 123456789012345678.0)
                """#)
                == """
                1.5 0.5 1 1e+09 0.001 1000.5 0.25 12 1 8.5 1 2500 1e-06 1.23456789125e+08
                float64 float64 float64 float64
                3 1e+21 1e+20 1e-07 1e+08 5e-324 1.7976931348623157e+308 0.1 2.675 1e+06 1.2345678901234568e+17

                """)
        #expect(
            goMainDiagnostic(
                """
                x := 0x1.8
                fmt.Println(x)
                """)
                == "hexadecimal mantissa requires a 'p' exponent")
        #expect(
            goMainDiagnostic(
                """
                x := 1e
                fmt.Println(x)
                """)
                == "exponent has no digits")
        #expect(
            goMainDiagnostic(
                """
                x := 1_.5
                fmt.Println(x)
                """)
                == "'_' must separate successive digits")
    }

    /// An untyped constant is exact: `1.0 / 3 * 3` is one, and `0.1 + 0.2`
    /// is three tenths. An operation on an integer and a floating-point constant
    /// is floating-point; one with an integer value is a value of an integer type.
    @Test func constantsAreExactUntilTheyHaveAType() throws {
        #expect(
            try runGoMain(
                #"""
                var i int = 2.0
                var u uint8 = 1e2
                var f float32 = 1 << 30
                var g float64 = big / 1e98
                var h = third * 3
                fmt.Println(half, third, h, 0.1+0.2, float64(0.1)+0.2, tenth*3, i, u, f, g, 7/2, 7/2.0, 7.0/2, 1/3.0, 'a'*1.5, big > 1)
                fmt.Printf("%T %T %T %T %T %T\n", half, 7/2, 7/2.0, 'a'*1.5, typed, typed/3)
                fmt.Println(typed, typed/3, single, single*3, math.Pi, math.E, math.MaxFloat64, math.SmallestNonzeroFloat64, math.MaxFloat32, float32(math.Pi))
                var w float32 = 0.1
                var d float64 = 0.1
                fmt.Println(w, d, float64(w), float64(w) == d, w == 0.1, d == 0.1, float32(d) == w)
                """#,
                imports: ["fmt", "math"],
                declarations: """
                    const half = 1.0 / 2
                    const third = 1.0 / 3
                    const tenth = 0.1
                    const big = 1e100
                    const typed float64 = 1.0 / 3
                    const single float32 = 1.0 / 3
                    """)
                == """
                0.5 0.3333333333333333 1 0.3 0.30000000000000004 0.3 2 100 1.0737418e+09 100 3 3.5 3.5 0.3333333333333333 145.5 true
                float64 int float64 float64 float64 float64
                0.3333333333333333 0.1111111111111111 0.33333334 1 3.141592653589793 2.718281828459045 1.7976931348623157e+308 5e-324 3.4028234663852886e+38 3.1415927
                0.1 0.1 0.10000000149011612 false true true true

                """)
        #expect(
            goMainDiagnostic(
                """
                var i int = 1.5
                fmt.Println(i)
                """)
                == "cannot use 1.5 (untyped float constant) as int value in variable declaration (truncated)")
        #expect(
            goMainDiagnostic(
                """
                var i int = 3
                fmt.Println(i + 2.5)
                """)
                == "2.5 (untyped float constant) truncated to int")
        #expect(
            goMainDiagnostic("fmt.Println(int(2.5))")
                == "constant 2.5 truncated to int")
        #expect(
            goMainDiagnostic(
                """
                var f float64 = 1e400
                fmt.Println(f)
                """)
                == "cannot use 1e400 (untyped float constant 1e+400) as float64 value in variable declaration (overflows)")
        #expect(
            goMainDiagnostic(
                """
                var f float32 = 1e39
                fmt.Println(f)
                """)
                == "cannot use 1e39 (untyped float constant 1e+39) as float32 value in variable declaration (overflows)")
        #expect(
            goMainDiagnostic(
                """
                x := 5 % 2.0
                fmt.Println(x)
                """)
                == "invalid operation: 5 % 2.0 (mismatched types untyped int and untyped float)")
        #expect(
            goMainDiagnostic("fmt.Println(1.5 / 0)")
                == "invalid operation: division by zero")
    }

    /// The four operations and the six comparisons. A division by zero is
    /// an infinity or a NaN and no panic, and a NaN is equal to nothing.
    @Test func arithmeticAndComparisonAreIEEE() throws {
        #expect(
            try runGoMain(
                """
                x, y := 1.5, 2.0
                zero := 0.0
                nan := zero / zero
                fmt.Println(x+y, x-y, x*y, x/y, -x, +x, x < y, x <= y, x > y, x >= y, x == y, x != y)
                fmt.Println(1/zero, -1/zero, nan, x/zero, zero*-1, nan == nan, nan != nan, nan < 1, nan > 1, 1/zero > 1e308, -zero == zero)
                x++
                x += 2
                x *= 1.5
                x /= 4
                y--
                y -= 0.25
                fmt.Println(x, y, 0.1+0.2 == 0.3, zero+0.1+0.2 == 0.3, x > 1 && y < 2, math.IsNaN(nan), math.IsInf(1/zero, 1), math.IsInf(-1/zero, 0), math.Inf(-1), math.NaN())
                var a, b float32 = 16777216, 1
                fmt.Println(a+b, a+b+b, float64(a)+float64(b), a*a*a*a*a*a, a/3, -a, a == a+b)
                sum := 0.0
                for i := 0; i < 10; i++ {
                    sum += 0.1
                }
                fmt.Println(sum, sum == 1, float32(sum), sum*10)
                """,
                imports: ["fmt", "math"])
                == """
                3.5 -0.5 3 0.75 -1.5 1.5 true true false false false true
                +Inf -Inf NaN +Inf -0 false true false false true true
                1.6875 0.75 true false true true true true -Inf NaN
                1.6777216e+07 1.6777216e+07 1.6777217e+07 +Inf 5.5924055e+06 -1.6777216e+07 true
                0.9999999999999999 false 1 9.999999999999998

                """)
        #expect(
            goMainDiagnostic(
                """
                f := 1.5
                i := 2
                fmt.Println(f * i)
                """)
                == "invalid operation: f * i (mismatched types float64 and int)")
        #expect(
            goMainDiagnostic(
                """
                var f float64 = 1
                var g float32 = 2
                fmt.Println(f + g)
                """)
                == "invalid operation: f + g (mismatched types float64 and float32)")
        #expect(
            goMainDiagnostic(
                """
                f := 1.5
                var i int = f
                fmt.Println(i)
                """)
                == "cannot use f (variable of type float64) as int value in variable declaration")
        #expect(
            goMainDiagnostic(
                """
                var f float64 = 2
                fmt.Println(f % 2)
                """)
                == "invalid operation: operator % not defined on f (variable of type float64)")
        #expect(
            goMainDiagnostic(
                """
                var f float64 = 2
                fmt.Println(f << 1)
                """)
                == "invalid operation: shifted operand f (variable of type float64) must be integer")
        #expect(
            goMainDiagnostic(
                """
                var s []int
                f := 1.0
                fmt.Println(s[f])
                """)
                == "invalid argument: index f (variable of type float64) must be integer")
    }

    /// An integer becomes the nearest floating-point number, and a
    /// floating-point number an integer by dropping what is after the point.
    @Test func conversionsTruncateAndRound() throws {
        #expect(
            try runGoMain(
                """
                i := 7
                f := float64(i) / 2
                var big int64 = 1<<62 + 1
                var wide uint64 = 1<<64 - 1
                var small int8 = -5
                fmt.Println(f, int(f), int(-f), int64(f*0.85), uint8(f), float32(i)/2, float64(big), float64(wide), float32(wide), float64(small)/2, float32(small))
                g := 123456.789
                h := -0.999
                fmt.Println(int(g), int32(g), int16(g/10), uint16(g), int8(h), uint(g), uint64(g*1e6), float32(g), float64(float32(g)), float64(float32(0.1)))
                fmt.Println(float64(i/2), float64(i)/2, i/2, 1e3 == float64(1000), int(2.5e3), uint32(4e9), int64(-9.2e18), uint64(1.8e19))
                """)
                == """
                3.5 3 -3 2 3 3.5 4.611686018427388e+18 1.8446744073709552e+19 1.8446744e+19 -2.5 -5
                123456 123456 12345 57920 0 123456 123456789000 123456.79 123456.7890625 0.10000000149011612
                3 3.5 3 true 2500 4000000000 -9200000000000000000 18000000000000000000

                """)
    }

    /// `%v` and `Println` print the shortest text that reads back as the same
    /// number, with an exponent below 1e-4 and from 1e21; the other verbs, widths,
    /// precisions, and flags are Go's.
    @Test func fmtPrintsFloatsAsGoDoes() throws {
        #expect(
            try runGoMain(
                #"""
                values := []float64{0, 1, -1, 3.0, 0.5, 1.5, 100, 1e6, 1e20, 1e21, 1e-4, 1e-5, 123456789.125, 2.675, 0.1, math.Pi, -math.E, 1.0 / 3, 5e-324, math.MaxFloat64, math.Inf(1), math.Inf(-1), math.NaN()}
                for _, f := range values {
                    fmt.Printf("%v|%g|%f|%e|%G|%E|%.2f|%8.3f|%-8.2f|%+.1f|%08.3f|% .2f|%.0f|%10.3e|%x\n", f, f, f, f, f, f, f, f, f, f, f, f, f, f, f)
                }
                fmt.Printf("%6.2f%% %5.1f|%-7.1f|%7.1f|%.3g|%.10g|%#g|%#.3g|%#v|%+v|%T|%t|%d|%s\n", 12.3456, 9.96, 9.96, 9.96, 1234.5678, 1.0/3, 2.5, 100.0, 1e21, 1.5, 1.5, 1.5, 1.5, 1.5)
                var f32 float32 = 0.1
                fmt.Println(f32, f32*3, float32(1)/3, float32(16777216), float32(1e10), float32(math.Pi), -f32, []float32{1.5, 2, f32})
                fmt.Printf("%v %g %f %e %.3f %T %6.2f|%x\n", f32, f32, f32, f32, f32, f32, f32, f32)
                fmt.Println(fmt.Sprint(1.5, 2.0, "a", 3.25), fmt.Sprintf("%5.1f|%-6.2f|%06.2f", 3.14159, 2.5, -1.5), fmt.Sprint(1e21, 1e-7))
                """#,
                imports: ["fmt", "math"])
                == """
                0|0|0.000000|0.000000e+00|0|0.000000E+00|0.00|   0.000|0.00    |+0.0|0000.000| 0.00|0| 0.000e+00|0x0p+00
                1|1|1.000000|1.000000e+00|1|1.000000E+00|1.00|   1.000|1.00    |+1.0|0001.000| 1.00|1| 1.000e+00|0x1p+00
                -1|-1|-1.000000|-1.000000e+00|-1|-1.000000E+00|-1.00|  -1.000|-1.00   |-1.0|-001.000|-1.00|-1|-1.000e+00|-0x1p+00
                3|3|3.000000|3.000000e+00|3|3.000000E+00|3.00|   3.000|3.00    |+3.0|0003.000| 3.00|3| 3.000e+00|0x1.8p+01
                0.5|0.5|0.500000|5.000000e-01|0.5|5.000000E-01|0.50|   0.500|0.50    |+0.5|0000.500| 0.50|0| 5.000e-01|0x1p-01
                1.5|1.5|1.500000|1.500000e+00|1.5|1.500000E+00|1.50|   1.500|1.50    |+1.5|0001.500| 1.50|2| 1.500e+00|0x1.8p+00
                100|100|100.000000|1.000000e+02|100|1.000000E+02|100.00| 100.000|100.00  |+100.0|0100.000| 100.00|100| 1.000e+02|0x1.9p+06
                1e+06|1e+06|1000000.000000|1.000000e+06|1E+06|1.000000E+06|1000000.00|1000000.000|1000000.00|+1000000.0|1000000.000| 1000000.00|1000000| 1.000e+06|0x1.e848p+19
                1e+20|1e+20|100000000000000000000.000000|1.000000e+20|1E+20|1.000000E+20|100000000000000000000.00|100000000000000000000.000|100000000000000000000.00|+100000000000000000000.0|100000000000000000000.000| 100000000000000000000.00|100000000000000000000| 1.000e+20|0x1.5af1d78b58c4p+66
                1e+21|1e+21|1000000000000000000000.000000|1.000000e+21|1E+21|1.000000E+21|1000000000000000000000.00|1000000000000000000000.000|1000000000000000000000.00|+1000000000000000000000.0|1000000000000000000000.000| 1000000000000000000000.00|1000000000000000000000| 1.000e+21|0x1.b1ae4d6e2ef5p+69
                0.0001|0.0001|0.000100|1.000000e-04|0.0001|1.000000E-04|0.00|   0.000|0.00    |+0.0|0000.000| 0.00|0| 1.000e-04|0x1.a36e2eb1c432dp-14
                1e-05|1e-05|0.000010|1.000000e-05|1E-05|1.000000E-05|0.00|   0.000|0.00    |+0.0|0000.000| 0.00|0| 1.000e-05|0x1.4f8b588e368f1p-17
                1.23456789125e+08|1.23456789125e+08|123456789.125000|1.234568e+08|1.23456789125E+08|1.234568E+08|123456789.12|123456789.125|123456789.12|+123456789.1|123456789.125| 123456789.12|123456789| 1.235e+08|0x1.d6f34548p+26
                2.675|2.675|2.675000|2.675000e+00|2.675|2.675000E+00|2.67|   2.675|2.67    |+2.7|0002.675| 2.67|3| 2.675e+00|0x1.5666666666666p+01
                0.1|0.1|0.100000|1.000000e-01|0.1|1.000000E-01|0.10|   0.100|0.10    |+0.1|0000.100| 0.10|0| 1.000e-01|0x1.999999999999ap-04
                3.141592653589793|3.141592653589793|3.141593|3.141593e+00|3.141592653589793|3.141593E+00|3.14|   3.142|3.14    |+3.1|0003.142| 3.14|3| 3.142e+00|0x1.921fb54442d18p+01
                -2.718281828459045|-2.718281828459045|-2.718282|-2.718282e+00|-2.718281828459045|-2.718282E+00|-2.72|  -2.718|-2.72   |-2.7|-002.718|-2.72|-3|-2.718e+00|-0x1.5bf0a8b145769p+01
                0.3333333333333333|0.3333333333333333|0.333333|3.333333e-01|0.3333333333333333|3.333333E-01|0.33|   0.333|0.33    |+0.3|0000.333| 0.33|0| 3.333e-01|0x1.5555555555555p-02
                5e-324|5e-324|0.000000|4.940656e-324|5E-324|4.940656E-324|0.00|   0.000|0.00    |+0.0|0000.000| 0.00|0|4.941e-324|0x1p-1074
                1.7976931348623157e+308|1.7976931348623157e+308|179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.000000|1.797693e+308|1.7976931348623157E+308|1.797693E+308|179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.00|179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.000|179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.00|+179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.0|179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.000| 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.00|179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368|1.798e+308|0x1.fffffffffffffp+1023
                +Inf|+Inf|+Inf|+Inf|+Inf|+Inf|+Inf|    +Inf|+Inf    |+Inf|    +Inf| Inf|+Inf|      +Inf|+Inf
                -Inf|-Inf|-Inf|-Inf|-Inf|-Inf|-Inf|    -Inf|-Inf    |-Inf|    -Inf|-Inf|-Inf|      -Inf|-Inf
                NaN|NaN|NaN|NaN|NaN|NaN|NaN|     NaN|NaN     |+NaN|     NaN| NaN|NaN|       NaN|NaN
                 12.35%  10.0|10.0   |   10.0|1.23e+03|0.3333333333|2.50000|100.|1e+21|1.5|float64|%!t(float64=1.5)|%!d(float64=1.5)|%!s(float64=1.5)
                0.1 0.3 0.33333334 1.6777216e+07 1e+10 3.1415927 -0.1 [1.5 2 0.1]
                0.1 0.1 0.100000 1.000000e-01 0.100 float32   0.10|0x1.99999ap-04
                1.5 2a3.25   3.1|2.50  |-01.50 1e+21 1e-07

                """)
        #expect(
            try runGoMain(
                #"""
                p := point{1, 2.5, 3}
                s := []float64{1.5, 2, 3.25, 1e21}
                m := map[string]float64{"a": 0.5, "b": 1e9}
                keys := map[float64]string{2.5: "x", -1: "y", 0: "z", 1e21: "w"}
                var a any = 2.5
                var b any = float32(2.5)
                fmt.Println(p, s, m, keys, &p, [2]float32{1.5, 2}, a, b, a == b, a == any2(), Celsius(36.6), Celsius(100).F())
                fmt.Printf("%v %+v %#v %T %v %.1f %5.2f %v %T %T\n", p, p, p, p, s, s, m, keys, a, b)
                fmt.Printf("%v %.2f %T %#v %e\n", Celsius(21.5), Celsius(21.5), Celsius(1), Celsius(1.5), Celsius(1234.5))
                """#,
                declarations: """
                    type Celsius float64

                    func (c Celsius) F() Celsius { return c*9/5 + 32 }

                    type point struct {
                        X, Y float64
                        W    float32
                    }

                    func any2() any { return 2.5 }
                    """)
                == """
                {1 2.5 3} [1.5 2 3.25 1e+21] map[a:0.5 b:1e+09] map[-1:y 0:z 2.5:x 1e+21:w] &{1 2.5 3} [1.5 2] 2.5 2.5 false true 36.6 212
                {1 2.5 3} {X:1 Y:2.5 W:3} main.point{X:1, Y:2.5, W:3} main.point [1.5 2 3.25 1e+21] [1.5 2.0 3.2 1000000000000000000000.0] map[%!f(string=    a): 0.50 %!f(string=    b):1000000000.00] map[-1:y 0:z 2.5:x 1e+21:w] float64 float32
                21.5 21.50 main.Celsius 1.5 1.234500e+03

                """)
    }

    /// A floating-point number behind an interface keeps its type; a `switch`
    /// compares by value; `min` and `max` give a NaN for a NaN; and a duration
    /// counts in seconds, minutes, and hours.
    @Test func interfacesSwitchesAndBuiltinsKnowFloats() throws {
        #expect(
            try runGoMain(
                #"""
                values := []any{1.5, float32(1.5), 2, "x", Celsius(3), math.NaN()}
                for _, v := range values {
                    switch n := v.(type) {
                    case float64:
                        fmt.Print("float64:", n+1, " ")
                    case float32:
                        fmt.Print("float32:", n*2, " ")
                    case int:
                        fmt.Print("int:", n, " ")
                    case Celsius:
                        fmt.Print("celsius:", n, " ")
                    default:
                        fmt.Print("other ")
                    }
                }
                f, ok := values[0].(float64)
                _, isSingle := values[0].(float32)
                fmt.Println(f, ok, isSingle)
                for _, x := range []float64{0, -0.0, 1.5, 2, math.NaN()} {
                    switch x {
                    case 0:
                        fmt.Print("zero ")
                    case 1.5, 2.5:
                        fmt.Print("one-and-a-half ")
                    case 2:
                        fmt.Print("two ")
                    default:
                        fmt.Print("other ")
                    }
                }
                fmt.Println()
                g, h := 2.5, float32(1.25)
                var u, v uint64 = 1 << 63, 5
                fmt.Println(min(g, 1, 3.5), max(g, -1, 10), min(h, 2), max(1, 2.5), min(1.5, 2), max(g, math.NaN()), min(math.Inf(1), g), min(u, v), max(u, v))
                fmt.Printf("%T %T %T %T\n", min(g, 1), max(1, 2.5), min(h, 2), max(u, 1))
                d := 90*time.Minute + 1500*time.Millisecond
                fmt.Println(d.Seconds(), d.Minutes(), d.Hours(), time.Duration(1).Seconds(), (-d).Hours(), time.Duration(1<<62).Hours())
                xs := []float64{2.5, -1, math.Inf(-1), 3, math.NaN(), 0}
                sort.Float64s(xs)
                fmt.Println(xs, avg(1, 2, 4), scale(xs[2:4], 0.5), total)
                """#,
                imports: ["fmt", "math", "sort", "time"],
                declarations: """
                    type Celsius float64

                    var total = avg(0.5, 1.5) * 2

                    func avg(xs ...float64) float64 {
                        sum := 0.0
                        for _, x := range xs {
                            sum += x
                        }
                        return sum / float64(len(xs))
                    }

                    func scale(xs []float64, by float64) []float64 {
                        out := make([]float64, len(xs))
                        apply := func(i int) { out[i] = xs[i] * by }
                        for i := range xs {
                            apply(i)
                        }
                        return out
                    }
                    """)
                == "float64:2.5 float32:3 int:2 other celsius:3 float64:NaN 1.5 true false\nzero zero one-and-a-half two other \n1 10 1.25 2.5 1.5 NaN 2.5 5 9223372036854775808\nfloat64 float64 float32 uint64\n5401.5 90.025 1.5004166666666667 1e-09 -1.5004166666666667 1.2810238940076078e+06\n[NaN -Inf -1 0 2.5 3] 2.3333333333333335 [-0.5 0] 2\n")
        #expect(
            goMainDiagnostic("fmt.Println(min(1.5, \"a\"))")
                == "invalid argument: mismatched types untyped float (previous argument) and untyped string (type of \"a\")")
        #expect(
            goMainDiagnostic(
                """
                var f float64 = 1
                var g float32 = 2
                fmt.Println(max(f, g))
                """)
                == "invalid argument: mismatched types float64 (previous argument) and float32 (type of g)")
    }

    /// `strconv.ParseFloat` and `FormatFloat`, and the functions of `math`.
    @Test func strconvAndMathAreGos() throws {
        #expect(
            try runGoMain(
                """
                for _, s := range []string{"3.25", "-1e-3", "1e400", "-1e400", "0x1p-2", ".5", "1_000.5", "inf", "-Inf", "NaN", "", "x1", "1.2.3", " 1", "1e", "4.9e-324", "2.5e-324", "0.1", "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368"} {
                    v, err := strconv.ParseFloat(s, 64)
                    w, err32 := strconv.ParseFloat(s, 32)
                    fmt.Println(v, err, w, err32)
                }
                f := 1.0 / 3
                fmt.Println(strconv.FormatFloat(f, 'f', 4, 64), strconv.FormatFloat(f, 'e', -1, 64), strconv.FormatFloat(1e21, 'g', -1, 64), strconv.FormatFloat(2.5, 'e', 3, 32), strconv.FormatFloat(f, 'g', 5, 64), strconv.FormatFloat(f, 'f', -1, 32), strconv.FormatFloat(255.5, 'x', -1, 64), strconv.FormatFloat(1234.5678, 'G', 3, 64), strconv.FormatFloat(0.000001234, 'g', -1, 64))
                """,
                imports: ["fmt", "strconv"])
                == """
                3.25 <nil> 3.25 <nil>
                -0.001 <nil> -0.0010000000474974513 <nil>
                +Inf strconv.ParseFloat: parsing "1e400": value out of range +Inf strconv.ParseFloat: parsing "1e400": value out of range
                -Inf strconv.ParseFloat: parsing "-1e400": value out of range -Inf strconv.ParseFloat: parsing "-1e400": value out of range
                0.25 <nil> 0.25 <nil>
                0.5 <nil> 0.5 <nil>
                1000.5 <nil> 1000.5 <nil>
                +Inf <nil> +Inf <nil>
                -Inf <nil> -Inf <nil>
                NaN <nil> NaN <nil>
                0 strconv.ParseFloat: parsing "": invalid syntax 0 strconv.ParseFloat: parsing "": invalid syntax
                0 strconv.ParseFloat: parsing "x1": invalid syntax 0 strconv.ParseFloat: parsing "x1": invalid syntax
                0 strconv.ParseFloat: parsing "1.2.3": invalid syntax 0 strconv.ParseFloat: parsing "1.2.3": invalid syntax
                0 strconv.ParseFloat: parsing " 1": invalid syntax 0 strconv.ParseFloat: parsing " 1": invalid syntax
                0 strconv.ParseFloat: parsing "1e": invalid syntax 0 strconv.ParseFloat: parsing "1e": invalid syntax
                5e-324 <nil> 0 <nil>
                5e-324 <nil> 0 <nil>
                0.1 <nil> 0.10000000149011612 <nil>
                1.7976931348623157e+308 <nil> +Inf strconv.ParseFloat: parsing "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368": value out of range
                0.3333 3.333333333333333e-01 1e+21 2.500e+00 0.33333 0.33333334 0x1.ffp+07 1.23E+03 1.234e-06

                """)
        #expect(
            try runGoMain(
                #"""
                fmt.Println(math.Sqrt(2), math.Sqrt(-1), math.Floor(-1.5), math.Ceil(1.2), math.Trunc(-1.7), math.Round(2.5), math.Round(-2.5), math.RoundToEven(2.5), math.Abs(-3.2))
                fmt.Println(math.Max(1, 2), math.Min(1, 2), math.Max(math.NaN(), 1), math.Min(-0.0, 0), math.Pow(2, 10), math.Pow(2, 0.5), math.Pow(-8, 1.0/3), math.Pow(10, -3), math.Mod(7, 3), math.Mod(-7, 3), math.Mod(5.5, 2))
                fmt.Println(math.Inf(1), math.Inf(-1), math.NaN(), math.IsNaN(math.NaN()), math.IsInf(math.Inf(-1), -1), math.IsInf(1, 0), math.Signbit(-0.0), math.Copysign(3, -1))
                fmt.Println(math.Float64bits(1.5), math.Float64frombits(0x4000000000000000), math.Float32bits(1.5), math.Float32frombits(0x40490fdb), math.Pi, math.Sqrt2, math.Ln2, math.MaxFloat32, math.SmallestNonzeroFloat32)
                r := 2.0
                area := math.Pi * math.Pow(r, 2)
                hyp := math.Sqrt(3*3 + 4*4)
                fmt.Printf("%.4f %.1f %v %v\n", area, hyp, math.Floor(area), int(math.Round(area*100)))
                """#,
                imports: ["fmt", "math"])
                == """
                1.4142135623730951 NaN -2 2 -1 3 -3 2 3.2
                2 1 NaN 0 1024 1.4142135623730951 NaN 0.001 1 -1 1.5
                +Inf -Inf NaN true true false false -3
                4609434218613702656 2 1069547520 3.1415927 3.141592653589793 1.4142135623730951 0.6931471805599453 3.4028234663852886e+38 1.401298464324817e-45
                12.5664 5.0 12 1257

                """)
    }

    /// Four thousand numbers of every magnitude, as `float64` and as
    /// `float32`, each printed in its shortest form and read back: the hash of all
    /// the text is the one Go computes.
    @Test func shortestTextAgreesOnRandomValues() throws {
        #expect(
            try runGoMain(
                """
                x := uint64(88172645463325252)
                var hash uint64 = 14695981039346656037
                count, bytes := 0, 0
                for i := 0; i < 1000; i++ {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                    f := math.Float64frombits(x)
                    if i%3 == 1 {
                        f = float64(int64(x>>40)) / 1024
                    }
                    text := strconv.FormatFloat(f, 'g', -1, 64)
                    if i%4 == 2 {
                        text = strconv.FormatFloat(float64(float32(f)), 'g', -1, 32)
                    }
                    for j := 0; j < len(text); j++ {
                        hash = (hash ^ uint64(text[j])) * 1099511628211
                    }
                    back, err := strconv.ParseFloat(text, 64)
                    if err == nil && (back == f || back != back) {
                        count++
                    }
                    bytes += len(text)
                }
                fmt.Println(hash, count, bytes, strconv.FormatFloat(math.Float64frombits(x), 'g', -1, 64))
                """,
                imports: ["fmt", "math", "strconv"])
                == "14985936215705774172 752 16230 1.5250504165817188e-217\n")
        #expect(
            try runGoMain(
                """
                x := uint64(2463534242)
                var hash uint64 = 14695981039346656037
                count, bytes := 0, 0
                for i := 0; i < 1000; i++ {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                    f := math.Float64frombits(x)
                    if i%3 == 1 {
                        f = float64(int64(x>>40)) / 1000
                    }
                    text := strconv.FormatFloat(f, 'g', -1, 64)
                    if i%4 == 2 {
                        text = strconv.FormatFloat(float64(float32(f)), 'g', -1, 32)
                    }
                    for j := 0; j < len(text); j++ {
                        hash = (hash ^ uint64(text[j])) * 1099511628211
                    }
                    back, err := strconv.ParseFloat(text, 64)
                    if err == nil && (back == f || back != back) {
                        count++
                    }
                    bytes += len(text)
                }
                fmt.Println(hash, count, bytes, strconv.FormatFloat(math.Float64frombits(x), 'g', -1, 64))
                """,
                imports: ["fmt", "math", "strconv"])
                == "2541723141351220748 833 14680 -1.7005458270641983e+135\n")
        #expect(
            try runGoMain(
                """
                x := uint64(11400714819323198485)
                var hash uint64 = 14695981039346656037
                count, bytes := 0, 0
                for i := 0; i < 1000; i++ {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                    f := math.Float64frombits(x)
                    if i%3 == 1 {
                        f = float64(int64(x>>40)) / 3
                    }
                    text := strconv.FormatFloat(f, 'g', -1, 64)
                    if i%4 == 2 {
                        text = strconv.FormatFloat(float64(float32(f)), 'g', -1, 32)
                    }
                    for j := 0; j < len(text); j++ {
                        hash = (hash ^ uint64(text[j])) * 1099511628211
                    }
                    back, err := strconv.ParseFloat(text, 64)
                    if err == nil && (back == f || back != back) {
                        count++
                    }
                    bytes += len(text)
                }
                fmt.Println(hash, count, bytes, strconv.FormatFloat(math.Float64frombits(x), 'g', -1, 64))
                """,
                imports: ["fmt", "math", "strconv"])
                == "2590115963757717904 779 17338 5.25773671759147e+109\n")
        #expect(
            try runGoMain(
                """
                x := uint64(1)
                var hash uint64 = 14695981039346656037
                count, bytes := 0, 0
                for i := 0; i < 1000; i++ {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                    f := math.Float64frombits(x)
                    if i%3 == 1 {
                        f = float64(int64(x>>40)) / 1e7
                    }
                    text := strconv.FormatFloat(f, 'g', -1, 64)
                    if i%4 == 2 {
                        text = strconv.FormatFloat(float64(float32(f)), 'g', -1, 32)
                    }
                    for j := 0; j < len(text); j++ {
                        hash = (hash ^ uint64(text[j])) * 1099511628211
                    }
                    back, err := strconv.ParseFloat(text, 64)
                    if err == nil && (back == f || back != back) {
                        count++
                    }
                    bytes += len(text)
                }
                fmt.Println(hash, count, bytes, strconv.FormatFloat(math.Float64frombits(x), 'g', -1, 64))
                """,
                imports: ["fmt", "math", "strconv"])
                == "7487429687506111100 825 14959 -1.5079915142888746e-161\n")
    }

    /// Through imports with names of their own, a type alias, a type declared
    /// in a function, and a closure: floating-point types with methods, typed and
    /// untyped constants, and a panic with a floating-point value.
    @Test func floatsCrossPackages() throws {
        let main = #"""
            package main

            import (
                f "fmt"
                m "math"

                "example/m/lib"
            )

            type celsius = float64

            func main() {
                type reading struct {
                    at    lib.Meters
                    value celsius
                }
                r := reading{1500, 21.5}
                lib.Offset += lib.Half
                ratio, whole := lib.Narrow(lib.Third * 10)
                total := 0.0
                add := func(x float64) { total += x * lib.Scale }
                add(1.5)
                add(lib.Half)
                var small float32 = lib.Tiny * 3
                f.Println(r, r.at.Feet(), lib.Offset, ratio, whole, total, small, lib.Mean(1, 2, lib.Half), lib.Big/1e29, lib.Third*3)
                f.Printf("%T %T %T %T %T %.3f %v\n", r.at, r.value, ratio, lib.Half, lib.Tiny, m.Sqrt(lib.Scale), m.Floor(lib.Big/1e29))
                defer func() { f.Println("recovered:", recover()) }()
                var boxed any = lib.Meters(2.5)
                f.Println(boxed.(lib.Meters).Feet(), boxed)
                panic(lib.Scale)
            }

            """#
        let library = #"""
            package lib

            type Meters float64
            type Ratio = float32

            const (
                Half          = 1.0 / 2
                Third         = 1.0 / 3
                Scale float64 = 2.5
                Tiny  Ratio   = 1e-3
                Big           = 1e30
            )

            var Offset = 0.25

            func (m Meters) Feet() Meters { return m * 3.28084 }

            func Mean(xs ...float64) float64 {
                sum := 0.0
                for _, x := range xs {
                    sum += x
                }
                return sum / float64(len(xs))
            }

            func Narrow(f float64) (Ratio, int) { return Ratio(f), int(f) }

            """#
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m", sources: [GoSourceFile(path: "main.go", text: main)]),
                GoPackageSource(
                    importPath: "example/m/lib",
                    sources: [GoSourceFile(path: "lib/lib.go", text: library)]),
            ], root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(
            output
                == """
                {1500 21.5} 4921.26 0.75 3.3333333 3 5 0.003 1.1666666666666667 10 1
                lib.Meters float64 float32 float64 float32 1.581 10
                8.2021 2.5
                recovered: 2.5

                """)
    }

    /// A floating-point literal is one token to `gofmt`, which leaves its
    /// digits alone and writes the letter of an exponent and of a base prefix in
    /// lower case.
    @Test func gofmtWritesFloatLiteralsAsGoDoes() throws {
        let messy = #"""
            package main
            import "fmt"
            const half=1.0/2
            var (
                a=1.5
                bb  float32=.5
                c=1e9+2.5E-3
            )
            func main(){
            x:=1_000.5*2+.25
            y:=0X1P-2+0x1.8p+3
            z:=[]float64{1.,2.5,3e10,1E6}
            w:=float64(3)/2-x*y
            fmt.Printf("%v %.2f\n",x,y)
            fmt.Println(half,a,bb,c,z,w,-1.5,x-.5,1e-9, 08.5, 1.e+0)
            if x>2.5&&y<=1e3{ fmt.Println(x*2.0+y/4) }
            }

            """#
        let formatted = try GoFormatter.format(GoSourceFile(path: "main.go", text: messy))
        #expect(
            formatted
                == """
                package main

                import "fmt"

                const half = 1.0 / 2

                var (
                \ta          = 1.5
                \tbb float32 = .5
                \tc          = 1e9 + 2.5e-3
                )

                func main() {
                \tx := 1_000.5*2 + .25
                \ty := 0x1p-2 + 0x1.8p+3
                \tz := []float64{1., 2.5, 3e10, 1e6}
                \tw := float64(3)/2 - x*y
                \tfmt.Printf("%v %.2f\\n", x, y)
                \tfmt.Println(half, a, bb, c, z, w, -1.5, x-.5, 1e-9, 08.5, 1.e+0)
                \tif x > 2.5 && y <= 1e3 {
                \t\tfmt.Println(x*2.0 + y/4)
                \t}
                }

                """)
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: formatted)) == formatted)
    }
}
