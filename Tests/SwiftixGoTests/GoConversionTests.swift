/// Go conversions `T(x)` among `int`, `byte`, `string`, `[]byte`, and named
/// types, including the UTF-8 repair rule of `string([]byte)`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go conversions")
struct GoConversionTests: GoTestHarness {

    @Test func integerConversionsTruncateToBytes() throws {
        let output = try runGoMain("""
            x := 300
            y := -1
            var b byte = 200
            fmt.Println(byte(x), uint8(x), byte(y), byte(x + 212), int(b) + 100, int(byte(x)) + 1000)
            fmt.Println(byte(65), int(7), byte(b), uint8(b) + 100, int(x) == x, bool(x > 1))
            """)

        #expect(output == "44 44 255 0 300 1044\n65 7 200 44 true true\n")
    }

    @Test func stringAndByteSliceConversionsUseUTF8Bytes() throws {
        let output = try runGoMain("""
            b := []byte("héllo")
            fmt.Println(len(b), b[0], b[1], b[2], string(b) == "héllo", string(b[:1]), string(b[3:]))
            b[0] = 72
            copyOfB := []byte(string(b))
            copyOfB[0] = 74
            fmt.Println(string(b), string(copyOfB), len([]byte("")), string([]byte{}) == "")
            var none []byte
            fmt.Println(string(none) == "", len([]byte("😀")), string([]byte{240, 159, 152, 128}))
            """)

        #expect(output == "6 104 195 169 true h llo\nHéllo Jéllo 0 true\ntrue 4 😀\n")
    }

    @Test func invalidUTF8IsRepairedWhenConvertingBytesToString() throws {
        // Guest strings are always valid UTF-8, so `string(b)` replaces each
        // invalid sequence with U+FFFD (3 bytes) instead of keeping the bytes.
        let output = try runGoMain("""
            b := []byte("héllo")
            b[1] = 255
            s := string(b)
            fmt.Println(len(s), s == "h\\uFFFD\\uFFFDllo", s[0], s[1], s[2], s[3])
            fmt.Println(len(string(b[:2])), string(b[2:3]) == "\\uFFFD")
            """)

        #expect(output == "10 true 104 239 191 189\n4 true\n")
    }

    @Test func integersConvertToTheirCodePoint() throws {
        let output = try runGoMain("""
            s := "é"
            code := 233
            wide := 128512
            invalid := 1114112
            surrogate := 55296
            negative := -1
            fmt.Println(string(65), string(code), string(wide), string(s[0]) == "\\u00c3", len(string(s[0])))
            fmt.Println(string(invalid) == "\\uFFFD", string(surrogate) == "\\uFFFD", string(negative) == "\\uFFFD")
            """)

        #expect(output == "A é 😀 true 2\ntrue true true\n")
    }

    @Test func namedTypesConvertToAndFromTheirUnderlyingType() throws {
        let output = try runGoMain(
            """
            c := Celsius(21)
            n := Name("ada")
            ids := IDs([]int{3, 4})
            raw := []int(ids)
            raw[0] = 9
            d := Digit(300 + int(c))
            fmt.Println(c + 1, int(c) + 2, string(n) + "!", Name("x" + string(n)), ids[0], len(raw), d)
            fmt.Println(string(Bytes("ok")), len(Bytes(n)), Celsius(d) + 1000, Name(Bytes("hi")))
            """,
            declarations: """
                type Celsius int
                type Name string
                type IDs []int
                type Digit byte
                type Bytes []byte
                """)

        #expect(output == "22 23 ada! xada 9 2 65\nok 3 1065 hi\n")
    }

    @Test func invalidConversionsAreDiagnosed() {
        #expect(goMainDiagnostic("fmt.Println(int(\"x\"))") == "cannot convert string to type int")
        #expect(goMainDiagnostic("fmt.Println(string(true))") == "cannot convert bool to type string")
        #expect(goMainDiagnostic("fmt.Println([]byte(1))") == "cannot convert int to type []byte")
        #expect(goMainDiagnostic("fmt.Println([]int(\"x\"))") == "cannot convert string to type []int")
        #expect(goMainDiagnostic("fmt.Println(string([]int{1}))") == "cannot convert []int to type string")
        #expect(goMainDiagnostic("fmt.Println(byte(\"x\"))") == "cannot convert string to type byte")
        #expect(goMainDiagnostic("fmt.Println(bool(1))") == "cannot convert int to type bool")
        #expect(goMainDiagnostic("fmt.Println(byte(1, 2))") == "conversion to byte requires exactly one argument")
        #expect(goMainDiagnostic("fmt.Println(int())") == "conversion to int requires exactly one argument")
        #expect(goMainDiagnostic("fmt.Println(byte(256))") == "constant 256 overflows byte")
        #expect(goMainDiagnostic("fmt.Println(uint8(-1))") == "constant -1 overflows byte")
        #expect(goMainDiagnostic("x := 1\nint(x)") == "expression evaluated but not used")
        #expect(goMainDiagnostic("x := 1\ndefer byte(x)") == "expression in defer must be function call")
        #expect(goMainDiagnostic("x := 1\ngo int(x)") == "expression in go must be function call")
        #expect(
            goMainDiagnostic(
                "fmt.Println(B(A{1}))",
                declarations: "type A struct { X int }\ntype B struct { X int }")
                == "cannot convert A to type B")
        #expect(goMainDiagnostic("a, b := int(1)\nfmt.Println(a, b)") != nil)
    }

    @Test func aDeclarationNamedLikeATypeShadowsTheConversion() throws {
        // `string` here is a variable, so `string(1)` is not a conversion.
        #expect(goMainDiagnostic("string := 1\nfmt.Println(string(1))") == "undefined: string")
        #expect(
            try runGoMain("fmt.Println(byte(7))", declarations: "func byte(n int) int { return n + 1 }")
                == "8\n")
    }

    @Test func conversionsRespectResourceLimits() throws {
        let fewElements = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(maximumCollectionElements: 8))
        #expect(throws: GoRuntimeError.resourceLimitExceeded("slice elements")) {
            try runGoMain("fmt.Println(len([]byte(\"123456789\")))", machine: fewElements)
        }
        #expect(
            try runGoMain("fmt.Println(len([]byte(\"12345678\")))", machine: fewElements) == "8\n")

        // Each invalid byte repairs to a 3-byte replacement character, so the
        // result can be three times as long as the slice.
        let shortStrings = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(maximumStringBytes: 32))
        let invalid = "b := make([]byte, n)\nfor i := range b {\nb[i] = 255\n}\nfmt.Println(len(string(b)))"
        #expect(throws: GoRuntimeError.resourceLimitExceeded("string bytes")) {
            try runGoMain("n := 11\n" + invalid, machine: shortStrings)
        }
        #expect(try runGoMain("n := 10\n" + invalid, machine: shortStrings) == "30\n")
    }

    @Test func conversionNativesRejectMalformedOperands() throws {
        func run(_ instructions: [GoInstruction]) throws {
            try GoVirtualMachine().run(
                GoExecutable(
                    entryPoint: "main",
                    functions: [
                        GoBytecodeFunction(name: "main", localCount: 0, instructions: instructions)
                    ])
            ) { _ in }
        }
        for name in ["$conv.bytesToString", "$conv.stringToBytes", "$conv.runeToString"] {
            #expect(throws: GoRuntimeError.typeMismatch, "\(name)") {
                try run([.push(.bool(true)), .call(name, argumentCount: 1), .return])
            }
            #expect(
                throws: GoRuntimeError.argumentCountMismatch(function: name, expected: 1, actual: 0)
            ) {
                try run([.call(name, argumentCount: 0), .return])
            }
        }
        // A slice element outside 0...255 is not a byte.
        #expect(throws: GoRuntimeError.typeMismatch) {
            try run([
                .push(.int(0)), .push(.int(256)), .makeSlice(elementCount: 1),
                .call("$conv.bytesToString", argumentCount: 1), .return,
            ])
        }
    }
}
