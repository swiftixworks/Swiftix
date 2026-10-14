/// The sized integer types: `int8` to `int64`, `uint`, `uint8` to `uint64`,
/// `uintptr`, and `rune`, which is `int32`.
///
/// A VM value is one `Int64` whatever the type, so the compiler chooses the
/// operation for each operator from the static type and brings every result
/// back into the range of its type. A `uint64` with its high bit set is held
/// as a negative `Int64`, and is divided, compared, shifted, and printed by
/// operations that read it as unsigned. See `GoNumericKind`.
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

@Suite("Go sized integer types")
struct GoSizedIntegerTests: GoTestHarness {

    /// Two's complement at 8, 16, 32, and 64 bits, signed and unsigned: a
    /// result that leaves the range of its type comes back into it.
    @Test func arithmeticWrapsAtTheWidthOfTheType() throws {
        #expect(
            try runGoMain(
                """
                var a int8 = 127
                a++
                var b int16 = -32768
                b--
                var c int32 = 2147483647
                c += 2
                var d int64 = 9223372036854775807
                d++
                fmt.Println(a, b, c, d)
                var e uint8 = 0
                e--
                var f uint16 = 65535
                f += 2
                var g uint32 = 4000000000
                g += g
                var h uint64 = 18446744073709551615
                h++
                var i uint = 0
                i--
                var j uintptr = 1
                j -= 2
                fmt.Println(e, f, g, h, i, j)
                var k int8 = 100
                var l int16 = 300
                var m int32 = 100000
                var n uint16 = 300
                var o uint32 = 100000
                fmt.Println(k*k, l*l, m*m, n*n, o*o, k*3, -k-k, k-l8(), int8(-128)/minusOne())
                """,
                declarations: """
                    func l8() int8       { return -100 }
                    func minusOne() int8 { return -1 }
                    """)
                == """
                -128 32767 -2147483647 -9223372036854775808
                255 1 3705032704 0 18446744073709551615 18446744073709551615
                16 24464 1410065408 24464 1410065408 44 56 -56 -128

                """)
        #expect(
            try runGoMain(
                """
                var a int8 = -128
                var b int16 = -32768
                var c int32 = -2147483648
                var d int64 = -9223372036854775808
                fmt.Println(-a, -b, -c, -d, a/-1, b/-1, c/-1, d/-1, a%-1, d%-1)
                fmt.Println(^a, ^b, ^c, ^d)
                var e uint8 = 1
                var f uint16 = 1
                var g uint32 = 1
                var h uint64 = 1
                fmt.Println(-e, -f, -g, -h, ^e, ^f, ^g, ^h, e&^1, h&^1)
                """)
                == """
                -128 -32768 -2147483648 -9223372036854775808 -128 -32768 -2147483648 -9223372036854775808 0 0
                127 32767 2147483647 9223372036854775807
                255 65535 4294967295 18446744073709551615 254 65534 4294967294 18446744073709551614 0 0

                """)
    }

    /// A `uint64`, `uint`, or `uintptr` with its high bit set divides, takes a
    /// remainder, compares, shifts right, and prints as the large number it is.
    @Test func unsignedSixtyFourBitsAreUnsigned() throws {
        #expect(
            try runGoMain(
                #"""
                var x uint64 = 1<<64 - 1
                var y uint64 = 1 << 63
                fmt.Println(x, y, x/3, x%10, x/y, y/x, x>y, y<x, x>=x, x<=y, x == y, x != y)
                fmt.Println(x>>1, x>>63, x>>64, y>>62, x<<1, y<<1, y+y, x*x, x-y)
                var u uint = 1 << 63
                var p uintptr = 1<<64 - 2
                fmt.Println(u, u/2, u>1, u>>60, p, p%7, p>u2(), p/u3())
                var half uint64 = 9223372036854775807
                fmt.Println(half+1 > half, half+1 == y, (half+2)/2, (half+2)%1000)
                fmt.Printf("%d %x %X %o %b\n", x, x, y, y, y)
                fmt.Printf("%v %#v %08d|%-22d|%22d|\n", x, x, uint64(7), y, y)
                """#,
                declarations: """
                    func u2() uintptr { return 5 }
                    func u3() uintptr { return 1 << 62 }
                    """)
                == """
                18446744073709551615 9223372036854775808 6148914691236517205 5 1 0 true true true false false true
                9223372036854775807 1 0 2 18446744073709551614 0 0 1 9223372036854775807
                9223372036854775808 4611686018427387904 true 8 18446744073709551614 0 true 3
                true true 4611686018427387904 809
                18446744073709551615 ffffffffffffffff 8000000000000000 1000000000000000000000 1000000000000000000000000000000000000000000000000000000000000000
                18446744073709551615 0xffffffffffffffff 00000007|9223372036854775808   |   9223372036854775808|

                """)
        #expect(
            try runGoMain(
                """
                var zero uint64
                defer func() { fmt.Println(recover()) }()
                fmt.Println(uint64(1<<63) / zero)
                """)
                == "runtime error: integer divide by zero\n")
        #expect(
            try runGoMain(
                """
                var zero uint
                defer func() { fmt.Println(recover()) }()
                fmt.Println(uint(1<<63) % zero)
                """)
                == "runtime error: integer divide by zero\n")
    }

    /// A shift count is an integer of any type. A count as wide as the type or
    /// wider shifts every bit out; a negative one of a signed type panics.
    @Test func shiftsTakeACountOfAnyIntegerType() throws {
        #expect(
            try runGoMain(
                """
                var a int8 = 1
                var b uint8 = 1
                var c int32 = 1
                var d uint64 = 1
                var n8 uint8 = 7
                var n64 uint64 = 63
                var n int = 3
                var big uint64 = 1 << 63
                fmt.Println(a<<n8, b<<n8, c<<n8, d<<n64, a<<n, b<<8, c<<31, c<<32, d<<64)
                fmt.Println(a>>n, int8(-128)>>n8, int8(-128)>>100, b>>n, d<<n64>>n64, d<<n64>>62)
                fmt.Println(d<<big, d>>big, c<<big, int32(-5)>>big, uint32(5)>>big)
                var x uint32 = 0xdeadbeef
                fmt.Println(x<<4, x>>4, x<<16|x>>16, x&0xff, x|1, x^x, x&^0xf)
                var s int16 = -1
                defer func() { fmt.Println(recover()) }()
                fmt.Println(c << s)
                """)
                == """
                -128 128 128 9223372036854775808 8 0 -2147483648 0 0
                0 -1 -1 0 1 2
                0 0 0 -1 0
                3940282096 233495534 3203391149 239 3735928559 0 3735928544
                runtime error: negative shift amount

                """)
    }

    /// A conversion between integer types keeps the low bits and extends the
    /// sign of a signed source.
    @Test func conversionsTruncateAndExtend() throws {
        #expect(
            try runGoMain(
                """
                var i int = -1
                var big int = 0x1234567890abcdef
                fmt.Println(int8(i), uint8(i), int16(i), uint16(i), int32(i), uint32(i), int64(i), uint64(i), uint(i), uintptr(i))
                fmt.Println(int8(big), uint8(big), int16(big), uint16(big), int32(big), uint32(big), int64(big), uint64(big))
                var a int8 = -2
                var b uint8 = 254
                var c uint64 = 1<<64 - 2
                fmt.Println(int(a), uint16(a), uint32(a), uint64(a), int64(a), int(b), int8(b), int16(b), uint64(b))
                fmt.Println(int(c), int8(c), int32(c), uint32(c), int64(c), uint8(c), uint(c))
                var r rune = 'x'
                var w uint16 = 0xffff
                fmt.Println(int(r), byte(r), rune(w), int16(w), int32(w), rune(b), int64(int8(w)))
                """)
                == """
                -1 255 -1 65535 -1 4294967295 -1 18446744073709551615 18446744073709551615 18446744073709551615
                -17 239 -12817 52719 -1867788817 2427178479 1311768467294899695 1311768467294899695
                -2 65534 4294967294 18446744073709551614 -2 254 -2 254 254
                -2 -2 -2 4294967294 -2 254 18446744073709551614
                120 120 65535 -1 65535 254 -1

                """)
    }

    /// `rune` is another name for `int32`. A rune literal is a constant whose
    /// default type is `rune`, a `range` over a string yields runes, and a string
    /// converts to and from a slice of them.
    @Test func runesAreInt32() throws {
        #expect(
            try runGoMain(
                #"""
                x := 'a'
                var r rune = 'é'
                var i int32 = r
                y := 'a' + 1
                const z = 'z'
                fmt.Printf("%T %T %T %T %T\n", x, r, y, z, 'x'-'a')
                fmt.Println(x, r, i, y, z, string(x), string(r), string(y), string(rune(0x4e16)), r == i)
                for i, c := range "héy, 世界" {
                    fmt.Printf("%d:%c:%d:%T ", i, c, c, c)
                }
                fmt.Println()
                runes := []rune("héllo, 世界")
                runes[0] = 'J'
                fmt.Println(len(runes), runes, string(runes), string(runes[7:]), string([]rune{}), len([]rune("")))
                fmt.Println(string([]rune{72, 105, 0x1F600, -1, 0xD800, 0x110000}))
                var s []rune
                for _, c := range "abc" {
                    s = append(s, c-32)
                }
                fmt.Println(string(s), s, string(s[1]), []int32("ab"), []byte("é"))
                fmt.Printf("%c %q %U %#U %x %d %v\n", r, r, r, r, r, r, r)
                """#)
                == "int32 int32 int32 int32 int32\n97 233 233 98 122 a é b 世 true\n0:h:104:int32 1:é:233:int32 3:y:121:int32 4:,:44:int32 5: :32:int32 6:世:19990:int32 9:界:30028:int32 \n9 [74 233 108 108 111 44 32 19990 30028] Jéllo, 世界 世界  0\nHi😀���\nABC [65 66 67] B [97 98] [195 169]\né 'é' U+00E9 U+00E9 'é' e9 233 233\n")
    }

    /// An untyped constant takes the type of the variable, operand, or
    /// parameter it meets, when it is a value of that type.
    @Test func constantsAdoptTheTypeTheyFit() throws {
        #expect(
            try runGoMain(
                """
                var a int8 = -128
                var b uint8 = 255
                var c uint16 = 0xffff
                var d int64 = -1 << 63
                var e uint64 = 1<<64 - 1
                var f uint32 = 'a'
                var g int16 = 'a' * 100
                const big = 1 << 100
                var h uint64 = big >> 40
                var i = big / (1 << 70)
                fmt.Println(a, b, c, d, e, f, g, h, i)
                fmt.Println(a+1, b-1, c/2, d+1, e-1, e == 1<<64-1, d < 0, takes(7), takes('a'), max64)
                x := []int16{1, -2, 300}
                m := map[uint8]int32{'a': 1 << 20, 255: -1}
                fmt.Println(x, m, len(x), m['a'])
                """,
                declarations: """
                    const max64 uint64 = 1<<64 - 1

                    func takes(v int32) int32 { return v * 2 }
                    """)
                == """
                -128 255 65535 -9223372036854775808 18446744073709551615 97 9700 1152921504606846976 1073741824
                -127 254 32767 -9223372036854775807 18446744073709551614 true true 14 194 18446744073709551615
                [1 -2 300] map[97:1048576 255:-1] 3 1048576

                """)
        #expect(
            try runGoMain(
                #"""
                fmt.Println(big>>98, huge/big>>98, mask, mask == 1<<63, uint64(mask), small, small+1)
                fmt.Printf("%T %T %T %T\n", mask, small, typed, typed+1)
                """#,
                declarations: """
                    const (
                        big        = 1 << 100
                        huge       = big * big
                        mask       = uint64(1) << 63
                        small      = 7
                        typed int8 = small * 2
                    )
                    """)
                == """
                4 4 9223372036854775808 true 9223372036854775808 7 8
                uint64 int int8 int8

                """)
        #expect(
            goMainDiagnostic(
                """
                var b int8 = 300
                fmt.Println(b)
                """)
                == "cannot use 300 (untyped int constant) as int8 value in variable declaration (overflows)")
        #expect(
            goMainDiagnostic(
                """
                var b uint16 = -1
                fmt.Println(b)
                """)
                == "cannot use -1 (untyped int constant) as uint16 value in variable declaration (overflows)")
        #expect(
            goMainDiagnostic(
                """
                var b uint64 = 1 << 64
                fmt.Println(b)
                """)
                == "cannot use 1 << 64 (untyped int constant 18446744073709551616) as uint64 value in variable declaration (overflows)")
        #expect(
            goMainDiagnostic(
                """
                x := 1 << 64
                fmt.Println(x)
                """)
                == "cannot use 1 << 64 (untyped int constant 18446744073709551616) as int value in assignment (overflows)")
        #expect(
            goMainDiagnostic(
                """
                var x int16 = 5
                x += 70000
                fmt.Println(x)
                """)
                == "70000 (untyped int constant) overflows int16")
        #expect(
            goMainDiagnostic("fmt.Println([]uint8{1, 256})")
                == "cannot use 256 (untyped int constant) as byte value in array or slice literal (overflows)")
        #expect(
            goMainDiagnostic(
                """
                const c int8 = 100
                fmt.Println(c * 2)
                """)
                == "c * 2 (constant 200 of type int8) overflows int8")
        #expect(
            goMainDiagnostic(
                """
                const k uint = 3
                fmt.Println(-k)
                """)
                == "-k (constant -3 of type uint) overflows uint")
        #expect(
            goMainDiagnostic("fmt.Println(int8(-129))")
                == "constant -129 overflows int8")
        #expect(
            goMainDiagnostic(
                """
                var x int32 = 5
                fmt.Println(x / 0)
                """)
                == "invalid operation: division by zero")
        #expect(
            goMainDiagnostic("fmt.Println(f(1 << 40))", declarations: "func f(v int32) int32 { return v }")
                == "cannot use 1 << 40 (untyped int constant 1099511627776) as int32 value in argument to f (overflows)")
    }

    /// Two integer types are two types: an operator takes operands of one,
    /// and a value of one is not assigned where another is wanted.
    @Test func typesDoNotMixWithoutAConversion() throws {
        #expect(
            goMainDiagnostic(
                """
                var a int = 1
                var b int32 = 2
                fmt.Println(a + b)
                """)
                == "invalid operation: a + b (mismatched types int and int32)")
        #expect(
            goMainDiagnostic(
                """
                var a int64 = 1
                var b int = 2
                fmt.Println(a == b)
                """)
                == "invalid operation: a == b (mismatched types int64 and int)")
        #expect(
            goMainDiagnostic(
                """
                var a uint8 = 1
                var b uint16 = 2
                fmt.Println(a | b)
                """)
                == "invalid operation: a | b (mismatched types byte and uint16)")
        #expect(
            goMainDiagnostic("fmt.Println(int32(1) + int64(2))")
                == "invalid operation: int32(1) + int64(2) (mismatched types int32 and int64)")
        #expect(
            goMainDiagnostic(
                """
                var r rune = 'a'
                var i int = r
                fmt.Println(i)
                """)
                == "cannot use r (variable of type int32) as int value in variable declaration")
        #expect(
            goMainDiagnostic(
                """
                for _, r := range "ab" {
                    var x int = r
                    fmt.Println(x)
                }
                """)
                == "cannot use r (variable of type int32) as int value in variable declaration")
        #expect(
            goMainDiagnostic(
                """
                var n int = 4
                fmt.Println(f(n))
                """,
                declarations: "func f(v int32) int32 { return v }")
                == "cannot use n (variable of type int) as int32 value in argument to f")
        #expect(
            goMainDiagnostic(
                """
                var i int64 = 3
                fmt.Println(f(i))
                """,
                declarations: """
                    type ID int64

                    func f(id ID) ID { return id }
                    """)
                == "cannot use i (variable of type int64) as ID value in argument to f")
        #expect(
            goMainDiagnostic(
                """
                var p uintptr = 5
                var u uint = p
                fmt.Println(u)
                """)
                == "cannot use p (variable of type uintptr) as uint value in variable declaration")
        #expect(
            try runGoMain(
                """
                var a int = 1
                var b int32 = 2
                var c uint8 = 3
                var d ID = 4
                fmt.Println(a+int(b), int32(a)+b, int(c)+a, ID(a)+d, int64(d)+int64(b), uint8(b)+c)
                """,
                declarations: "type ID int64")
                == "3 3 4 5 6 5\n")
    }

    /// In a shift that is no constant, an untyped constant on the left has
    /// the type the shift is used at: `1 << n` assigned to a `uint64` shifts a
    /// `uint64`.
    @Test func anUntypedShiftTakesTheTypeItIsUsedAt() throws {
        #expect(
            try runGoMain(
                #"""
                n := 63
                var a uint64 = 1 << n
                var b uint8 = 1 << (n - 56)
                var c uint8 = 1 << (n - 55)
                var d int8 = 1 << (n - 56)
                var mask uint64
                mask |= 1 << n
                mask |= 1<<n>>1 | 1<<3
                x := uint64(1 << n)
                y := 1 << (n - 60)
                var z uint32 = 1<<n | 1<<(n-40) + 1
                fmt.Println(a, b, c, d, mask, x, y, z, takes(1<<n), a&(1<<n) != 0, a == 1<<n)
                fmt.Printf("%T %T %T\n", y, 1<<n, 'a'<<n)
                """#,
                declarations: "func takes(v uint64) uint64 { return v }")
                == """
                9223372036854775808 128 0 -128 13835058055282163720 9223372036854775808 8 8388609 9223372036854775808 true true
                int int int32

                """)
    }

    /// An index, a slice bound, a length for `make`, and a shift count are an
    /// integer of any type.
    @Test func indexesLengthsAndSizesAreAnyInteger() throws {
        #expect(
            try runGoMain(
                """
                s := []string{"a", "b", "c", "d"}
                var i uint8 = 1
                var j int64 = 3
                var k uint64 = 2
                var r rune = 0
                text := "hello"
                fmt.Println(s[i], s[j], s[k], s[r], s[i:j], s[:k], s[k:], text[i], text[i:j], text[r])
                made := make([]int32, i, j)
                made[r] = 7
                m := make(map[uint16]bool, k)
                m[5] = true
                ch := make(chan int64, j)
                ch <- -5
                fmt.Println(made, len(made), cap(made), m, <-ch, cap(ch))
                var arr [4]uint16
                arr[k] = 65535
                arr[i]++
                arr[j] = arr[k] + 2
                fmt.Println(arr, len(arr))
                """)
                == """
                b d c a [b c] [a b] [c d] 101 el 104
                [7] 1 3 map[5:true] -5 3
                [0 1 65535 1] 4

                """)
    }

    /// Every verb for an integer, for each type: alone, in a struct, a slice,
    /// and a map, and behind an interface.
    @Test func fmtPrintsEachTypeAsGoDoes() throws {
        #expect(
            try runGoMain(
                #"""
                var a int8 = -5
                var b int16 = -300
                var c int32 = 65
                var d int64 = -1 << 40
                var e uint = 7
                var f uint8 = 200
                var g uint16 = 60000
                var h uint32 = 1 << 31
                var i uint64 = 1 << 63
                var j uintptr = 255
                fmt.Println(a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%d %d %d %d %d %d %d %d %d %d\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%v %v %v %v %v %v %v %v %v %v\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%T %T %T %T %T %T %T %T %T %T\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%x %x %x %x %x %x %x %x %x %x\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%X %X %X %X %X %X %X %X %X %X\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%o %o %o %o %o %o %o %o %o %o\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%b %b %b %b %b %b %b %b %b %b\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%c %c %c %c %q %q %q %U %U %U\n", c, g, f, j, c, f, g, c, g, i)
                fmt.Printf("%#v %#v %#v %#v %#v %#v %#v %#v %#v %#v\n", a, b, c, d, e, f, g, h, i, j)
                fmt.Printf("%5d|%-5d|%05d|%+d|% d|%#x|%#o|%08b|%3c|%x\n", a, b, c, d, e, f, g, f, c, -a)
                fmt.Printf("%s %t %e\n", c, i, a)
                """#)
                == #"""
                -5 -300 65 -1099511627776 7 200 60000 2147483648 9223372036854775808 255
                -5 -300 65 -1099511627776 7 200 60000 2147483648 9223372036854775808 255
                -5 -300 65 -1099511627776 7 200 60000 2147483648 9223372036854775808 255
                int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr
                -5 -12c 41 -10000000000 7 c8 ea60 80000000 8000000000000000 ff
                -5 -12C 41 -10000000000 7 C8 EA60 80000000 8000000000000000 FF
                -5 -454 101 -20000000000000 7 310 165140 20000000000 1000000000000000000000 377
                -101 -100101100 1000001 -10000000000000000000000000000000000000000 111 11001000 1110101001100000 10000000000000000000000000000000 1000000000000000000000000000000000000000000000000000000000000000 11111111
                A  È ÿ 'A' 'È' '\uea60' U+0041 U+EA60 U+8000000000000000
                -5 -300 65 -1099511627776 0x7 0xc8 0xea60 0x80000000 0x8000000000000000 0xff
                   -5|-300 |00065|-1099511627776| 7|0xc8|0165140|11001000|  A|5
                %!s(int32=65) %!t(uint64=9223372036854775808) %!e(int8=-5)

                """#)
        #expect(
            try runGoMain(
                #"""
                p := point{-1, 2, 1 << 63, 'x'}
                s := []int16{1, -2, 3}
                u := []uint64{1 << 63, 2}
                r := []rune("hé")
                m := map[int8]uint16{-1: 1, 5: 65535, -128: 7}
                big := map[uint64]string{1 << 63: "big", 1: "one", 1<<64 - 1: "max"}
                levels := map[Level]ID{High: -9, Low: 3}
                fmt.Println(p, s, u, r, m, big, levels, &p, [2]uint8{250, 251})
                fmt.Printf("%v %+v %#v\n", p, p, p)
                fmt.Printf("%v %#v %x %d\n", s, s, s, u)
                fmt.Printf("%v %#v\n", m, m)
                fmt.Printf("%v %d %x %#v\n", levels, levels, big, big)
                var values []any = []any{int8(-1), uint8(2), int16(-3), uint16(4), int32(-5), uint32(6), int64(-7), uint64(1 << 63), uint(9), uintptr(10), 'a', Low, ID(12)}
                for _, v := range values {
                    fmt.Printf("%v:%T:%d ", v, v, v)
                }
                fmt.Println()
                fmt.Println(values...)
                fmt.Println(fmt.Sprint(int8(1), uint64(2), "a", 'b', int32(3)), fmt.Sprintf("%3d|%-3d|", int8(5), uint16(6)))
                """#,
                declarations: """
                    type Level uint8
                    type ID int64

                    const (
                        Low Level = iota
                        Mid
                        High
                    )

                    type point struct {
                        X int8
                        Y uint32
                        Z uint64
                        R rune
                    }
                    """)
                == "{-1 2 9223372036854775808 120} [1 -2 3] [9223372036854775808 2] [104 233] map[-128:7 -1:1 5:65535] map[1:one 9223372036854775808:big 18446744073709551615:max] map[0:3 2:-9] &{-1 2 9223372036854775808 120} [250 251]\n{-1 2 9223372036854775808 120} {X:-1 Y:2 Z:9223372036854775808 R:120} main.point{X:-1, Y:0x2, Z:0x8000000000000000, R:120}\n[1 -2 3] []int16{1, -2, 3} [1 -2 3] [9223372036854775808 2]\nmap[-128:7 -1:1 5:65535] map[int8]uint16{-128:0x7, -1:0x1, 5:0xffff}\nmap[0:3 2:-9] map[0:3 2:-9] map[1:6f6e65 8000000000000000:626967 ffffffffffffffff:6d6178] map[uint64]string{0x1:\"one\", 0x8000000000000000:\"big\", 0xffffffffffffffff:\"max\"}\n-1:int8:-1 2:uint8:2 -3:int16:-3 4:uint16:4 -5:int32:-5 6:uint32:6 -7:int64:-7 9223372036854775808:uint64:9223372036854775808 9:uint:9 10:uintptr:10 97:int32:97 0:main.Level:0 12:main.ID:12 \n-1 2 -3 4 -5 6 -7 9223372036854775808 9 10 97 0 12\n1 2a98 3   5|6  |\n")
    }

    /// A value held by an interface is of its own type: it asserts as that
    /// type and no other, and two interface values are equal when both the types
    /// and the values are.
    @Test func interfaceValuesKeepTheType() throws {
        #expect(
            try runGoMain(
                """
                var a any = int32(5)
                var b any = int32(5)
                var c any = int64(5)
                var d any = 5
                var e any = uint8(5)
                var f any = 'a'
                var g any = uint64(1 << 63)
                var f2 any = int32(97)
                var f3 any = 97
                var g2 any = uint64(1 << 63)
                fmt.Println(a == b, a == c, a == d, c == d, e == a, f == f2, f == f3, g == g2)
                v, ok := a.(int32)
                _, isInt := a.(int)
                _, isInt64 := a.(int64)
                r, isRune := f.(rune)
                u := g.(uint64)
                fmt.Println(v, ok, isInt, isInt64, r, isRune, u, u > 1)
                keys := map[any]string{int8(1): "int8", int16(1): "int16", 1: "int", uint8(1): "uint8", int32(1): "int32"}
                fmt.Println(len(keys))
                defer func() { fmt.Println(recover()) }()
                fmt.Println(a.(uint32))
                """)
                == """
                true false false false false true false true
                5 true false false 97 true 9223372036854775808 true
                5
                interface conversion: interface {} is int32, not uint32

                """)
        #expect(
            try runGoMain(
                """
                defer func() { fmt.Println(recover()) }()
                var v any = uint64(1<<64 - 1)
                panic(v)
                """)
                == "18446744073709551615\n")
    }

    /// A type defined as a sized integer has its arithmetic and its width, and
    /// methods and constants of its own.
    @Test func namedTypesHaveMethodsAndConstants() throws {
        #expect(
            try runGoMain(
                #"""
                var l Level = High
                l++
                wide := Level(250)
                fmt.Println(Low, Mid, High, l, wide+10, l.next(), Low.String(), l > High, uint8(l))
                fmt.Printf("%v %d %s %T %x %#v\n", Mid, Mid, Mid, Mid, High, High)
                var id ID = 1 << 62
                id *= 2
                c := counter(65534)
                c.bump()
                c.bump()
                fmt.Println(id, id.half(), ID(-7)/2, c, flagA|flagC, flagB<<1, ^flagA, flagC&^flagA, mask)
                fmt.Printf("%T %T %T %d\n", id, c, flagA, []Level{Low, High})
                levels := map[Level]int{Low: 1, High: 3}
                for _, level := range []Level{Low, Mid, High} {
                    fmt.Print(level, levels[level], " ")
                }
                fmt.Println()
                """#,
                declarations: """
                    type Level uint8
                    type ID int64
                    type counter uint16
                    type flags uint32

                    const (
                        Low Level = iota
                        Mid
                        High
                    )

                    const (
                        flagA flags = 1 << iota
                        flagB
                        flagC
                        mask = flagA | flagB | flagC
                    )

                    func (l Level) String() string {
                        switch l {
                        case Low:
                            return "low"
                        case Mid:
                            return "mid"
                        case High:
                            return "high"
                        }
                        return "level"
                    }

                    func (l Level) next() Level { return l + 1 }
                    func (id ID) half() ID       { return id / 2 }
                    func (c *counter) bump()     { *c++ }
                    """)
                == "low mid high level level level low true 3\nmid 1 mid main.Level 68696768 0x2\n-9223372036854775808 -4611686018427387904 -3 0 5 4 4294967294 4 7\nmain.ID main.counter main.flags [0 2]\nlow 1 mid 0 high 3 \n")
    }

    /// Through parameters and results, struct fields, pointers, channels,
    /// closures, and types declared in a function.
    @Test func sizedIntegersGoWhereverAValueGoes() throws {
        #expect(
            try runGoMain(
                #"""
                type pair struct {
                    lo uint8
                    hi int64
                }
                type small int8
                p := pair{255, -1}
                q := &p
                q.lo++
                q.hi <<= 62
                var s small = 127
                s++
                total := uint16(65530)
                add := func(n uint16) uint16 {
                    total += n
                    return total
                }
                ch := make(chan uint64, 1)
                go func() { ch <- 1 << 63 }()
                quotient, remainder := divide(1<<64-1, 10)
                ptr := &total
                *ptr += 3
                fmt.Println(p, *q, s, add(4), add(4), <-ch, quotient, remainder, total, sum(1, 2, 250, 5))
                fmt.Printf("%T %T %v\n", p, s, swap(-1, 2))
                var grid [2][2]int16
                grid[1][0] = -32768
                grid[1][0]--
                fmt.Println(grid, abs(-128), abs(-5), clamp(300), clamp(-3))
                """#,
                declarations: """
                    type both struct {
                        a int32
                        b uint32
                    }

                    func divide(a, b uint64) (uint64, uint64) { return a / b, a % b }
                    func swap(a int32, b uint32) both           { return both{int32(b), uint32(a)} }

                    func sum(values ...uint8) uint8 {
                        var total uint8
                        for _, v := range values {
                            total += v
                        }
                        return total
                    }

                    func abs(v int8) int8 {
                        if v < 0 {
                            return -v
                        }
                        return v
                    }

                    func clamp(v int) uint8 {
                        if v < 0 {
                            return 0
                        }
                        if v > 255 {
                            return 255
                        }
                        return uint8(v)
                    }
                    """)
                == """
                {0 -4611686018427387904} {0 -4611686018427387904} -128 1 5 9223372036854775808 1844674407370955161 5 5 2
                main.pair main.small {2 4294967295}
                [[0 0] [32767 0]] -128 5 255 0

                """)
    }

    /// Programs of the kind the types are for: FNV-1a over 32 and 64 bits, a
    /// linear congruential generator, and a checksum that relies on wraparound.
    @Test func hashesAndChecksumsComputeAsInGo() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(fnv32("hello"), fnv64("hello"), fnv64(""), adler("Wikipedia"))
                var seed uint64 = 42
                var draws []uint32
                for i := 0; i < 4; i++ {
                    seed = seed*6364136223846793005 + 1442695040888963407
                    draws = append(draws, uint32(seed>>33))
                }
                fmt.Println(seed, draws, rotl(0x80000001, 1), rotl(1, 31), bits(0xf0f0f0f0f0f0f0f0))
                """,
                declarations: """
                    const (
                        offset32 uint32 = 2166136261
                        prime32  uint32 = 16777619
                        offset64 uint64 = 14695981039346656037
                        prime64  uint64 = 1099511628211
                    )

                    func fnv32(s string) uint32 {
                        h := offset32
                        for i := 0; i < len(s); i++ {
                            h ^= uint32(s[i])
                            h *= prime32
                        }
                        return h
                    }

                    func fnv64(s string) uint64 {
                        h := offset64
                        for i := 0; i < len(s); i++ {
                            h ^= uint64(s[i])
                            h *= prime64
                        }
                        return h
                    }

                    func adler(s string) uint32 {
                        var a, b uint32 = 1, 0
                        for _, c := range []byte(s) {
                            a = (a + uint32(c)) % 65521
                            b = (b + a) % 65521
                        }
                        return b<<16 | a
                    }

                    func rotl(x uint32, k uint) uint32 { return x<<k | x>>(32-k) }

                    func bits(x uint64) int {
                        n := 0
                        for x != 0 {
                            x &= x - 1
                            n++
                        }
                        return n
                    }
                    """)
                == """
                1335831723 11831194018420276491 14695981039346656037 300286872
                11628791489956661374 [1220265334 484179026 886563538 1353769503] 3 2147483648 32

                """)
    }

    /// The constants of `math`, and the functions of `strconv`, `unicode`,
    /// `unicode/utf8`, and `strings` that take or give a sized integer or a rune.
    @Test func theLibraryTakesAndGivesTheTypes() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(math.MaxInt8, math.MinInt8, math.MaxInt16, math.MinInt16, math.MaxInt32, math.MinInt32, math.MaxInt64, math.MinInt64)
                fmt.Println(math.MaxUint8, math.MaxUint16, math.MaxUint32, uint64(math.MaxUint64), math.MaxInt, math.MinInt, uint(math.MaxUint))
                var a int8 = math.MaxInt8
                var b uint64 = math.MaxUint64
                var c int32 = math.MinInt32
                fmt.Println(a, b, c, b == math.MaxUint64, math.MaxUint32+1, math.MaxInt64-math.MaxInt32)
                fmt.Printf("%T %T\n", math.MaxInt8, math.MaxUint32)
                """#,
                imports: ["fmt", "math"])
                == """
                127 -128 32767 -32768 2147483647 -2147483648 9223372036854775807 -9223372036854775808
                255 65535 4294967295 18446744073709551615 9223372036854775807 -9223372036854775808 18446744073709551615
                127 18446744073709551615 -2147483648 true 4294967296 9223372034707292160
                int int

                """)
        #expect(
            goMainDiagnostic("fmt.Println(math.MaxUint64)", imports: ["fmt", "math"])
                == "cannot use math.MaxUint64 (untyped int constant 18446744073709551615) as int value in argument to fmt.Println (overflows)")
        #expect(
            try runGoMain(
                #"""
                for _, s := range []string{"42", "-42", "+7", "0x1f", "0b101", "017", "1_000", "9223372036854775807", "9223372036854775808", "-9223372036854775809", "", "abc", " 1", "0x", "1__0", "-", "128", "ff"} {
                    for _, base := range []int{0, 10, 16, 2} {
                        v, err := strconv.ParseInt(s, base, 64)
                        fmt.Print(v, " ", err, "; ")
                    }
                    v8, err := strconv.ParseInt(s, 10, 8)
                    u, uerr := strconv.ParseUint(s, 0, 64)
                    u8, u8err := strconv.ParseUint(s, 10, 8)
                    fmt.Println(v8, err, u, uerr, u8, u8err)
                }
                _, err := strconv.ParseInt("1", 1, 64)
                _, err2 := strconv.ParseInt("1", 10, 65)
                _, err3 := strconv.ParseUint("18446744073709551616", 10, 64)
                top, err4 := strconv.ParseUint("18446744073709551615", 10, 0)
                fmt.Println(err, err2, err3, top, err4)
                fmt.Println(strconv.FormatInt(-255, 16), strconv.FormatInt(math.MinInt64, 2), strconv.FormatInt(35, 36), strconv.FormatUint(math.MaxUint64, 10), strconv.FormatUint(1<<63, 16))
                n, _ := strconv.ParseInt("-12", 10, 64)
                fmt.Printf("%T %v\n", n, n+1)
                """#,
                imports: ["fmt", "math", "strconv"])
                == """
                42 <nil>; 42 <nil>; 66 <nil>; 0 strconv.ParseInt: parsing "42": invalid syntax; 42 <nil> 42 <nil> 42 <nil>
                -42 <nil>; -42 <nil>; -66 <nil>; 0 strconv.ParseInt: parsing "-42": invalid syntax; -42 <nil> 0 strconv.ParseUint: parsing "-42": invalid syntax 0 strconv.ParseUint: parsing "-42": invalid syntax
                7 <nil>; 7 <nil>; 7 <nil>; 0 strconv.ParseInt: parsing "+7": invalid syntax; 7 <nil> 0 strconv.ParseUint: parsing "+7": invalid syntax 0 strconv.ParseUint: parsing "+7": invalid syntax
                31 <nil>; 0 strconv.ParseInt: parsing "0x1f": invalid syntax; 0 strconv.ParseInt: parsing "0x1f": invalid syntax; 0 strconv.ParseInt: parsing "0x1f": invalid syntax; 0 strconv.ParseInt: parsing "0x1f": invalid syntax 31 <nil> 0 strconv.ParseUint: parsing "0x1f": invalid syntax
                5 <nil>; 0 strconv.ParseInt: parsing "0b101": invalid syntax; 45313 <nil>; 0 strconv.ParseInt: parsing "0b101": invalid syntax; 0 strconv.ParseInt: parsing "0b101": invalid syntax 5 <nil> 0 strconv.ParseUint: parsing "0b101": invalid syntax
                15 <nil>; 17 <nil>; 23 <nil>; 0 strconv.ParseInt: parsing "017": invalid syntax; 17 <nil> 15 <nil> 17 <nil>
                1000 <nil>; 0 strconv.ParseInt: parsing "1_000": invalid syntax; 0 strconv.ParseInt: parsing "1_000": invalid syntax; 0 strconv.ParseInt: parsing "1_000": invalid syntax; 0 strconv.ParseInt: parsing "1_000": invalid syntax 1000 <nil> 0 strconv.ParseUint: parsing "1_000": invalid syntax
                9223372036854775807 <nil>; 9223372036854775807 <nil>; 9223372036854775807 strconv.ParseInt: parsing "9223372036854775807": value out of range; 0 strconv.ParseInt: parsing "9223372036854775807": invalid syntax; 127 strconv.ParseInt: parsing "9223372036854775807": value out of range 9223372036854775807 <nil> 255 strconv.ParseUint: parsing "9223372036854775807": value out of range
                9223372036854775807 strconv.ParseInt: parsing "9223372036854775808": value out of range; 9223372036854775807 strconv.ParseInt: parsing "9223372036854775808": value out of range; 9223372036854775807 strconv.ParseInt: parsing "9223372036854775808": value out of range; 0 strconv.ParseInt: parsing "9223372036854775808": invalid syntax; 127 strconv.ParseInt: parsing "9223372036854775808": value out of range 9223372036854775808 <nil> 255 strconv.ParseUint: parsing "9223372036854775808": value out of range
                -9223372036854775808 strconv.ParseInt: parsing "-9223372036854775809": value out of range; -9223372036854775808 strconv.ParseInt: parsing "-9223372036854775809": value out of range; -9223372036854775808 strconv.ParseInt: parsing "-9223372036854775809": value out of range; 0 strconv.ParseInt: parsing "-9223372036854775809": invalid syntax; -128 strconv.ParseInt: parsing "-9223372036854775809": value out of range 0 strconv.ParseUint: parsing "-9223372036854775809": invalid syntax 0 strconv.ParseUint: parsing "-9223372036854775809": invalid syntax
                0 strconv.ParseInt: parsing "": invalid syntax; 0 strconv.ParseInt: parsing "": invalid syntax; 0 strconv.ParseInt: parsing "": invalid syntax; 0 strconv.ParseInt: parsing "": invalid syntax; 0 strconv.ParseInt: parsing "": invalid syntax 0 strconv.ParseUint: parsing "": invalid syntax 0 strconv.ParseUint: parsing "": invalid syntax
                0 strconv.ParseInt: parsing "abc": invalid syntax; 0 strconv.ParseInt: parsing "abc": invalid syntax; 2748 <nil>; 0 strconv.ParseInt: parsing "abc": invalid syntax; 0 strconv.ParseInt: parsing "abc": invalid syntax 0 strconv.ParseUint: parsing "abc": invalid syntax 0 strconv.ParseUint: parsing "abc": invalid syntax
                0 strconv.ParseInt: parsing " 1": invalid syntax; 0 strconv.ParseInt: parsing " 1": invalid syntax; 0 strconv.ParseInt: parsing " 1": invalid syntax; 0 strconv.ParseInt: parsing " 1": invalid syntax; 0 strconv.ParseInt: parsing " 1": invalid syntax 0 strconv.ParseUint: parsing " 1": invalid syntax 0 strconv.ParseUint: parsing " 1": invalid syntax
                0 strconv.ParseInt: parsing "0x": invalid syntax; 0 strconv.ParseInt: parsing "0x": invalid syntax; 0 strconv.ParseInt: parsing "0x": invalid syntax; 0 strconv.ParseInt: parsing "0x": invalid syntax; 0 strconv.ParseInt: parsing "0x": invalid syntax 0 strconv.ParseUint: parsing "0x": invalid syntax 0 strconv.ParseUint: parsing "0x": invalid syntax
                0 strconv.ParseInt: parsing "1__0": invalid syntax; 0 strconv.ParseInt: parsing "1__0": invalid syntax; 0 strconv.ParseInt: parsing "1__0": invalid syntax; 0 strconv.ParseInt: parsing "1__0": invalid syntax; 0 strconv.ParseInt: parsing "1__0": invalid syntax 0 strconv.ParseUint: parsing "1__0": invalid syntax 0 strconv.ParseUint: parsing "1__0": invalid syntax
                0 strconv.ParseInt: parsing "-": invalid syntax; 0 strconv.ParseInt: parsing "-": invalid syntax; 0 strconv.ParseInt: parsing "-": invalid syntax; 0 strconv.ParseInt: parsing "-": invalid syntax; 0 strconv.ParseInt: parsing "-": invalid syntax 0 strconv.ParseUint: parsing "-": invalid syntax 0 strconv.ParseUint: parsing "-": invalid syntax
                128 <nil>; 128 <nil>; 296 <nil>; 0 strconv.ParseInt: parsing "128": invalid syntax; 127 strconv.ParseInt: parsing "128": value out of range 128 <nil> 128 <nil>
                0 strconv.ParseInt: parsing "ff": invalid syntax; 0 strconv.ParseInt: parsing "ff": invalid syntax; 255 <nil>; 0 strconv.ParseInt: parsing "ff": invalid syntax; 0 strconv.ParseInt: parsing "ff": invalid syntax 0 strconv.ParseUint: parsing "ff": invalid syntax 0 strconv.ParseUint: parsing "ff": invalid syntax
                strconv.ParseInt: parsing "1": invalid base 1 strconv.ParseInt: parsing "1": invalid bit size 65 strconv.ParseUint: parsing "18446744073709551616": value out of range 18446744073709551615 <nil>
                -ff -1000000000000000000000000000000000000000000000000000000000000000 z 18446744073709551615 8000000000000000
                int64 -11

                """)
        #expect(
            try runGoMain(
                """
                for _, r := range "aZ9 é世Σσǅ٣_ß" {
                    fmt.Print(unicode.IsLetter(r), unicode.IsDigit(r), unicode.IsSpace(r), unicode.IsUpper(r), unicode.IsLower(r), string(unicode.ToUpper(r)), string(unicode.ToLower(r)), " ")
                }
                fmt.Println()
                fmt.Println(unicode.IsLetter(-1), unicode.IsDigit(0x10FFFF+1), unicode.ToUpper(-5), unicode.IsSpace(0x85), unicode.IsSpace(0x3000), unicode.MaxRune, unicode.ReplacementChar)
                s := "héllo, 世界!"
                fmt.Println(utf8.RuneCountInString(s), len(s), utf8.ValidString(s), utf8.RuneLen('a'), utf8.RuneLen('é'), utf8.RuneLen('世'), utf8.RuneLen(0x1F600), utf8.RuneLen(-1), utf8.RuneLen(0xD800))
                for len(s) > 0 {
                    r, size := utf8.DecodeRuneInString(s)
                    fmt.Print(string(r), size, " ")
                    s = s[size:]
                }
                r, size := utf8.DecodeRuneInString("")
                fmt.Println(r, size, r == utf8.RuneError, utf8.UTFMax, utf8.RuneError, utf8.MaxRune, utf8.RuneSelf)
                buf := make([]byte, 4)
                for _, r := range []rune{'a', 'é', '世', 0x1F600, -1, 0xD800} {
                    n := utf8.EncodeRune(buf, r)
                    fmt.Print(n, buf[:n], " ")
                }
                fmt.Println()
                fmt.Println(strings.ContainsRune("héllo", 'é'), strings.ContainsRune("hello", 'é'), strings.IndexRune("chicken", 'k'), strings.IndexRune("héllo", 'l'), strings.IndexRune("abc", 'x'), strings.IndexRune("abc", -1), strings.IndexByte("golang", 'l'), strings.IndexByte("golang", 'x'), strings.IndexByte("héllo", 'l'))
                defer func() { fmt.Println(recover()) }()
                fmt.Println(utf8.EncodeRune(buf[:1], '世'))
                """,
                imports: ["fmt", "strings", "unicode", "unicode/utf8"])
                == "true false false false trueAa true false false true falseZz false true false false false99 false false true false false   true false false false trueÉé true false false false false世世 true false false true falseΣσ true false false false trueΣσ true false false false falseǄǆ false true false false false٣٣ false false false false false__ true false false false trueßß \nfalse false -5 true true 1114111 65533\n10 15 true 1 2 3 4 -1 -1\nh1 é2 l1 l1 o1 ,1  1 世3 界3 !1 65533 0 true 4 65533 1114111 128\n1 [97] 2 [195 169] 3 [228 184 150] 4 [240 159 152 128] 3 [239 191 189] 3 [239 191 189] \ntrue false 4 3 -1 -1 2 -1 3\nruntime error: index out of range [2] with length 1\n")
    }

    /// Through an import with a name of its own, a type alias, and a second
    /// package: sized types and their methods, typed constants, and untyped ones
    /// that are larger than any type until they are used.
    @Test func typesAndConstantsCrossPackages() throws {
        let main = #"""
            package main

            import (
                f "fmt"

                "example/m/lib"
            )

            type word = uint16

            func main() {
                var h lib.Hash = 14695981039346656037
                for _, c := range "héllo" {
                    h = lib.Mix(h, c)
                }
                lib.Counter += 2
                a, b := lib.Narrow(-129)
                var w word = 65535
                w++
                var top lib.Level = lib.High
                f.Println(h, lib.Counter, a, b, w, top, top.Next(), lib.Level(255).Next())
                f.Println(lib.Big>>60, lib.Max, lib.Max/3, lib.Seed, lib.Small*2, lib.Low, uint64(lib.Big>>7))
                f.Println(lib.KB, lib.MB, lib.GB, lib.TB, lib.PB, lib.EB, lib.ZB>>60, lib.YB>>70, lib.YB/lib.ZB)
                f.Printf("%T %T %T %T %T %T %T\n", h, lib.Seed, lib.Small, w, top, lib.Max, lib.KB)
                total := lib.Counter
                add := func(n uint16) { total += n }
                add(65535)
                f.Println(total, func() lib.Level { return top + lib.High }())
                var x uint8 = lib.KB >> 3
                var y = lib.Max - lib.Big>>7
                f.Println(x, y)
            }

            """#
        let library = #"""
            package lib

            type Level uint8
            type Hash = uint64
            type Char = rune

            const (
                Low Level = iota + 1
                High
            )

            const (
                Big          = 1 << 70
                Max   uint64 = 1<<64 - 1
                Seed         = 'x'
                Small int8   = -7
            )

            const (
                KB = 1 << (10 * (iota + 1))
                MB
                GB
                TB
                PB
                EB
                ZB
                YB
            )

            var Counter uint16 = 65535

            func (l Level) Next() Level { return l + 1 }

            func Mix(h Hash, c Char) Hash { return (h ^ Hash(c)) * 1099511628211 }

            func Narrow(v int64) (int8, uint8) { return int8(v), uint8(v) }

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
                803281756967761087 1 127 127 0 2 3 0
                1024 18446744073709551615 6148914691236517205 120 -14 1 9223372036854775808
                1024 1048576 1073741824 1099511627776 1125899906842624 1152921504606846976 1024 1024 1024
                uint64 int32 int8 uint16 lib.Level uint64 int
                0 4
                128 9223372036854775807

                """)
    }
}
