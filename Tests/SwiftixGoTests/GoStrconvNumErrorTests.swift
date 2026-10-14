/// The errors of `strconv.Atoi`, `ParseInt`, `ParseUint`, and `ParseFloat`:
/// Go's `*strconv.NumError`, with Go's `Func`, `Num`, and `Err`, and the
/// value Go returns with them. The functions are Go text of the library
/// (`Sources/SwiftixGoLibrary/strconv/parse.go`) around the natives that
/// read the numbers.
///
/// What each program prints is what Go 1.24.5 prints for it. The text is
/// held to Go's `strconv` on every combination of input, base, and bit size
/// by `Scripts/go-library-harness/run.sh strconv`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go strconv.NumError")
struct GoStrconvNumErrorTests: GoTestHarness {

    /// Each failure is a `*strconv.NumError` that wraps `ErrSyntax` or
    /// `ErrRange`, or Go's error for a base or bit size that is none; out of
    /// range, the value is the nearest that fits.
    @Test func theErrorsAreNumErrors() throws {
        #expect(
            try runGoMain(
                #"""
                show := func(name string, value any, err error) {
                    var numError *strconv.NumError
                    as := errors.As(err, &numError)
                    fmt.Printf("%s: %v %v | %T %v %v %v", name, value, err, err, as, errors.Is(err, strconv.ErrSyntax), errors.Is(err, strconv.ErrRange))
                    if as {
                        fmt.Printf(" | %s %q %v", numError.Func, numError.Num, numError.Err)
                    }
                    fmt.Println()
                }
                for _, s := range []string{"42", "-7", "", "x", "1x", " 1", "0x1f", "1_000", "300", "-129", "99999999999999999999", "-99999999999999999999", "18446744073709551615", "\"q\"", "１"} {
                    n, err := strconv.Atoi(s)
                    show("Atoi "+s, n, err)
                    i, err := strconv.ParseInt(s, 0, 8)
                    show("ParseInt "+s, i, err)
                    u, err := strconv.ParseUint(s, 10, 64)
                    show("ParseUint "+s, u, err)
                }
                for _, s := range []string{"1.5", "x", "1e400", "-1e400", "1e-400", "3.4e39", "inf", "0x1p-2", ""} {
                    f, err := strconv.ParseFloat(s, 64)
                    show("ParseFloat "+s, f, err)
                    f, err = strconv.ParseFloat(s, 32)
                    show("ParseFloat32 "+s, f, err)
                }
                _, err := strconv.ParseInt("1", 1, 64)
                show("base 1", 0, err)
                _, err = strconv.ParseUint("1", 37, 64)
                show("base 37", 0, err)
                _, err = strconv.ParseInt("1", 10, 65)
                show("bit size 65", 0, err)
                """#,
                imports: ["errors", "fmt", "strconv"])
                == #"""
                Atoi 42: 42 <nil> | <nil> false false false
                ParseInt 42: 42 <nil> | <nil> false false false
                ParseUint 42: 42 <nil> | <nil> false false false
                Atoi -7: -7 <nil> | <nil> false false false
                ParseInt -7: -7 <nil> | <nil> false false false
                ParseUint -7: 0 strconv.ParseUint: parsing "-7": invalid syntax | *strconv.NumError true true false | ParseUint "-7" invalid syntax
                Atoi : 0 strconv.Atoi: parsing "": invalid syntax | *strconv.NumError true true false | Atoi "" invalid syntax
                ParseInt : 0 strconv.ParseInt: parsing "": invalid syntax | *strconv.NumError true true false | ParseInt "" invalid syntax
                ParseUint : 0 strconv.ParseUint: parsing "": invalid syntax | *strconv.NumError true true false | ParseUint "" invalid syntax
                Atoi x: 0 strconv.Atoi: parsing "x": invalid syntax | *strconv.NumError true true false | Atoi "x" invalid syntax
                ParseInt x: 0 strconv.ParseInt: parsing "x": invalid syntax | *strconv.NumError true true false | ParseInt "x" invalid syntax
                ParseUint x: 0 strconv.ParseUint: parsing "x": invalid syntax | *strconv.NumError true true false | ParseUint "x" invalid syntax
                Atoi 1x: 0 strconv.Atoi: parsing "1x": invalid syntax | *strconv.NumError true true false | Atoi "1x" invalid syntax
                ParseInt 1x: 0 strconv.ParseInt: parsing "1x": invalid syntax | *strconv.NumError true true false | ParseInt "1x" invalid syntax
                ParseUint 1x: 0 strconv.ParseUint: parsing "1x": invalid syntax | *strconv.NumError true true false | ParseUint "1x" invalid syntax
                Atoi  1: 0 strconv.Atoi: parsing " 1": invalid syntax | *strconv.NumError true true false | Atoi " 1" invalid syntax
                ParseInt  1: 0 strconv.ParseInt: parsing " 1": invalid syntax | *strconv.NumError true true false | ParseInt " 1" invalid syntax
                ParseUint  1: 0 strconv.ParseUint: parsing " 1": invalid syntax | *strconv.NumError true true false | ParseUint " 1" invalid syntax
                Atoi 0x1f: 0 strconv.Atoi: parsing "0x1f": invalid syntax | *strconv.NumError true true false | Atoi "0x1f" invalid syntax
                ParseInt 0x1f: 31 <nil> | <nil> false false false
                ParseUint 0x1f: 0 strconv.ParseUint: parsing "0x1f": invalid syntax | *strconv.NumError true true false | ParseUint "0x1f" invalid syntax
                Atoi 1_000: 0 strconv.Atoi: parsing "1_000": invalid syntax | *strconv.NumError true true false | Atoi "1_000" invalid syntax
                ParseInt 1_000: 127 strconv.ParseInt: parsing "1_000": value out of range | *strconv.NumError true false true | ParseInt "1_000" value out of range
                ParseUint 1_000: 0 strconv.ParseUint: parsing "1_000": invalid syntax | *strconv.NumError true true false | ParseUint "1_000" invalid syntax
                Atoi 300: 300 <nil> | <nil> false false false
                ParseInt 300: 127 strconv.ParseInt: parsing "300": value out of range | *strconv.NumError true false true | ParseInt "300" value out of range
                ParseUint 300: 300 <nil> | <nil> false false false
                Atoi -129: -129 <nil> | <nil> false false false
                ParseInt -129: -128 strconv.ParseInt: parsing "-129": value out of range | *strconv.NumError true false true | ParseInt "-129" value out of range
                ParseUint -129: 0 strconv.ParseUint: parsing "-129": invalid syntax | *strconv.NumError true true false | ParseUint "-129" invalid syntax
                Atoi 99999999999999999999: 9223372036854775807 strconv.Atoi: parsing "99999999999999999999": value out of range | *strconv.NumError true false true | Atoi "99999999999999999999" value out of range
                ParseInt 99999999999999999999: 127 strconv.ParseInt: parsing "99999999999999999999": value out of range | *strconv.NumError true false true | ParseInt "99999999999999999999" value out of range
                ParseUint 99999999999999999999: 18446744073709551615 strconv.ParseUint: parsing "99999999999999999999": value out of range | *strconv.NumError true false true | ParseUint "99999999999999999999" value out of range
                Atoi -99999999999999999999: -9223372036854775808 strconv.Atoi: parsing "-99999999999999999999": value out of range | *strconv.NumError true false true | Atoi "-99999999999999999999" value out of range
                ParseInt -99999999999999999999: -128 strconv.ParseInt: parsing "-99999999999999999999": value out of range | *strconv.NumError true false true | ParseInt "-99999999999999999999" value out of range
                ParseUint -99999999999999999999: 0 strconv.ParseUint: parsing "-99999999999999999999": invalid syntax | *strconv.NumError true true false | ParseUint "-99999999999999999999" invalid syntax
                Atoi 18446744073709551615: 9223372036854775807 strconv.Atoi: parsing "18446744073709551615": value out of range | *strconv.NumError true false true | Atoi "18446744073709551615" value out of range
                ParseInt 18446744073709551615: 127 strconv.ParseInt: parsing "18446744073709551615": value out of range | *strconv.NumError true false true | ParseInt "18446744073709551615" value out of range
                ParseUint 18446744073709551615: 18446744073709551615 <nil> | <nil> false false false
                Atoi "q": 0 strconv.Atoi: parsing "\"q\"": invalid syntax | *strconv.NumError true true false | Atoi "\"q\"" invalid syntax
                ParseInt "q": 0 strconv.ParseInt: parsing "\"q\"": invalid syntax | *strconv.NumError true true false | ParseInt "\"q\"" invalid syntax
                ParseUint "q": 0 strconv.ParseUint: parsing "\"q\"": invalid syntax | *strconv.NumError true true false | ParseUint "\"q\"" invalid syntax
                Atoi １: 0 strconv.Atoi: parsing "１": invalid syntax | *strconv.NumError true true false | Atoi "１" invalid syntax
                ParseInt １: 0 strconv.ParseInt: parsing "１": invalid syntax | *strconv.NumError true true false | ParseInt "１" invalid syntax
                ParseUint １: 0 strconv.ParseUint: parsing "１": invalid syntax | *strconv.NumError true true false | ParseUint "１" invalid syntax
                ParseFloat 1.5: 1.5 <nil> | <nil> false false false
                ParseFloat32 1.5: 1.5 <nil> | <nil> false false false
                ParseFloat x: 0 strconv.ParseFloat: parsing "x": invalid syntax | *strconv.NumError true true false | ParseFloat "x" invalid syntax
                ParseFloat32 x: 0 strconv.ParseFloat: parsing "x": invalid syntax | *strconv.NumError true true false | ParseFloat "x" invalid syntax
                ParseFloat 1e400: +Inf strconv.ParseFloat: parsing "1e400": value out of range | *strconv.NumError true false true | ParseFloat "1e400" value out of range
                ParseFloat32 1e400: +Inf strconv.ParseFloat: parsing "1e400": value out of range | *strconv.NumError true false true | ParseFloat "1e400" value out of range
                ParseFloat -1e400: -Inf strconv.ParseFloat: parsing "-1e400": value out of range | *strconv.NumError true false true | ParseFloat "-1e400" value out of range
                ParseFloat32 -1e400: -Inf strconv.ParseFloat: parsing "-1e400": value out of range | *strconv.NumError true false true | ParseFloat "-1e400" value out of range
                ParseFloat 1e-400: 0 <nil> | <nil> false false false
                ParseFloat32 1e-400: 0 <nil> | <nil> false false false
                ParseFloat 3.4e39: 3.4e+39 <nil> | <nil> false false false
                ParseFloat32 3.4e39: +Inf strconv.ParseFloat: parsing "3.4e39": value out of range | *strconv.NumError true false true | ParseFloat "3.4e39" value out of range
                ParseFloat inf: +Inf <nil> | <nil> false false false
                ParseFloat32 inf: +Inf <nil> | <nil> false false false
                ParseFloat 0x1p-2: 0.25 <nil> | <nil> false false false
                ParseFloat32 0x1p-2: 0.25 <nil> | <nil> false false false
                ParseFloat : 0 strconv.ParseFloat: parsing "": invalid syntax | *strconv.NumError true true false | ParseFloat "" invalid syntax
                ParseFloat32 : 0 strconv.ParseFloat: parsing "": invalid syntax | *strconv.NumError true true false | ParseFloat "" invalid syntax
                base 1: 0 strconv.ParseInt: parsing "1": invalid base 1 | *strconv.NumError true false false | ParseInt "1" invalid base 1
                base 37: 0 strconv.ParseUint: parsing "1": invalid base 37 | *strconv.NumError true false false | ParseUint "1" invalid base 37
                bit size 65: 0 strconv.ParseInt: parsing "1": invalid bit size 65 | *strconv.NumError true false false | ParseInt "1" invalid bit size 65

                """#)
    }

    /// Two failures are two values; a `NumError` is matched by a type switch
    /// and unwrapped, and the functions are values.
    @Test func aNumErrorIsAValueLikeGos() throws {
        #expect(
            try runGoMain(
                #"""
                _, a := strconv.Atoi("x")
                _, b := strconv.Atoi("x")
                fmt.Println(a == b, a.Error() == b.Error(), errors.Unwrap(a) == strconv.ErrSyntax)
                switch e := a.(type) {
                case *strconv.NumError:
                    fmt.Println("NumError", e.Func, e.Num)
                default:
                    fmt.Println("other")
                }
                parse := strconv.Atoi
                fmt.Println(parse("12"))
                fmt.Println(parse("z"))
                wrapped := fmt.Errorf("reading port: %w", a)
                fmt.Println(wrapped, errors.Is(wrapped, strconv.ErrSyntax))
                fmt.Printf("%T %T\n", strconv.Atoi, strconv.ParseInt)
                """#,
                imports: ["errors", "fmt", "strconv"])
                == """
                false true true
                NumError Atoi x
                12 <nil>
                0 strconv.Atoi: parsing "z": invalid syntax
                reading port: strconv.Atoi: parsing "x": invalid syntax true
                func(string) (int, error) func(string, int, int) (int64, error)

                """)
    }

    /// A package-level `var n, err = strconv.Atoi(...)` is no initialization
    /// cycle: the `err` of the functions it calls is theirs. The same holds for
    /// a function of the program.
    @Test func packageVariablesMayHoldTheResults() throws {
        #expect(
            try runGoMain("fmt.Println(n, err, port, failure, total, sum)", imports: ["errors", "fmt", "strconv"],
                declarations: """
                    var n, err = strconv.Atoi("42")
                    var port, failure = strconv.Atoi("http")

                    var total, sum = add([]int{1, 2, 3})

                    func add(values []int) (n, err int) {
                        for _, err := range values {
                            n += err
                        }
                        m, err := n, 1
                        return m, err
                    }
                    """)
                == "42 <nil> 0 strconv.Atoi: parsing \"http\": invalid syntax 6 1\n")
    }
}
