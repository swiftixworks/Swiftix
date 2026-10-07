/// Integer literal forms: decimal, hexadecimal, octal (`0o` and legacy leading
/// zero), binary, and `_` digit separators.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go integer literals")
struct GoIntegerLiteralTests: GoTestHarness {

    @Test func everyBaseDenotesItsValue() throws {
        let output = try runGoMain(
            """
            var b byte = 0xff
            fmt.Println(0x1f, 0X1F, 0o644, 0O17, 0644, 0b101, 0B11, 0, 00, 007, 1_000_000, 0x_ff, 0b1111_0000, b)
            fmt.Println(0x7fffffffffffffff, mode&0o111, table[0x1])
            """,
            declarations: "const mode = 0755\nvar table = [2]int{0b10, 0o10}")
        #expect(output == "31 31 420 15 420 5 3 0 0 7 1000000 255 240 255\n9223372036854775807 73 8\n")
    }

    @Test func malformedLiteralsAreDiagnosed() {
        #expect(goMainDiagnostic("x := 08\nfmt.Println(x)") == "invalid digit '8' in octal literal")
        #expect(goMainDiagnostic("x := 0o8\nfmt.Println(x)") == "invalid digit '8' in octal literal")
        #expect(goMainDiagnostic("x := 0b12\nfmt.Println(x)") == "invalid digit '2' in binary literal")
        #expect(goMainDiagnostic("x := 0xg\nfmt.Println(x)") == "invalid digit 'g' in hexadecimal literal")
        #expect(goMainDiagnostic("x := 12ab\nfmt.Println(x)") == "invalid digit 'a' in decimal literal")
        #expect(goMainDiagnostic("x := 0x\nfmt.Println(x)") == "hexadecimal literal has no digits")
        #expect(goMainDiagnostic("x := 0b\nfmt.Println(x)") == "binary literal has no digits")
        #expect(goMainDiagnostic("x := 1__0\nfmt.Println(x)") == "'_' must separate successive digits")
        #expect(goMainDiagnostic("x := 10_\nfmt.Println(x)") == "'_' must separate successive digits")
    }

    @Test func literalsBeyondInt64AreRejected() {
        #expect(
            goMainDiagnostic("x := 9223372036854775808\nfmt.Println(x)")
                == "integer literal overflows int64")
        #expect(
            goMainDiagnostic("x := 0x8000000000000000\nfmt.Println(x)")
                == "integer literal overflows int64")
        #expect(
            goMainDiagnostic("x := 0xfffffffffffffffffffffffffffffffff\nfmt.Println(x)")
                == "integer literal overflows int64")
        #expect(
            goMainDiagnostic("var b byte = 0x100\nfmt.Println(b)")?.contains("256") == true)
    }

    @Test func gofmtPreservesTheWrittenBase() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nconst mode=0o644\nfunc main(){x:=0x1F|0b1_0\ny:=0644\nprintln(x,y,1_000)}\n")
        let formatted = try GoFormatter.format(source)
        #expect(
            formatted
                == "package main\n\nconst mode = 0o644\n\nfunc main() {\n\tx := 0x1F | 0b1_0\n\ty := 0644\n\tprintln(x, y, 1_000)\n}\n")
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: formatted)) == formatted)
    }
}
