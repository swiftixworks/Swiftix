/// The builtins `print` and `println`, which write to standard error as
/// Go's runtime writes: numbers in decimal, a float with seven digits and
/// an exponent, and the operands of `println` with spaces between them.
///
/// What the program prints is what Go 1.24.5 printed for it, and each
/// error is Go's first.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go print and println")
struct GoBuiltinPrintTests {
    @Test func operandsArePrintedAsGosRuntimePrintsThem() throws {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == expected)
    }

    @Test func operandsThatCannotBePrintedAreRefused() {
        #expect(diagnostic("println(nil)") == "main.go:4:10: use of untyped nil in argument to built-in println")
        #expect(diagnostic("type T struct{ a int }; println(T{})") == "main.go:4:33: illegal types for operand: print\n\tT")
        #expect(diagnostic("println([2]int{})") == "main.go:4:9: illegal types for operand: print\n\t[2]int")
        #expect(diagnostic("println(1 << 70)") == "main.go:4:10: cannot use 1 << 70 (untyped int constant 1180591620717411303424) as int value in argument to built-in println (overflows)")
        #expect(diagnostic("println(1.5, 1e400)") == "main.go:4:15: cannot use 1e400 (untyped float constant 1e+400) as float64 value in argument to built-in println (overflows)")
    }

    private func diagnostic(_ body: String) -> String {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(path: "main.go", text: "package main\n\nfunc main() {\n\t\(body)\n}\n")
            ])
            return "compiled"
        } catch {
            return String(describing: error)
        }
    }
}

private let source = #"""
package main

import "errors"

type T struct{ a int }

func main() {
	var p *int
	var e error = errors.New("boom")
	var any1 any = 7
	println("hi", 42, -3, 1.5, -0.25, 1e100, true, false, 'x', byte(200), uint64(1<<63), int8(-5), float32(2.5))
	print("no", "spaces", 1, 2, "\n")
	println(p == nil, nil == e, len("abc"))
	println()
	println(e != nil, any1 != nil)
	var f float64
	println(f, -f, 1/f, -1/f, f/f)
}
"""#

private let expected = #"""
hi 42 -3 +1.500000e+000 -2.500000e-001 +1.000000e+100 true false 120 200 9223372036854775808 -5 +2.500000e+000
nospaces12
true false 3

true true
+0.000000e+000 -0.000000e+000 +Inf -Inf NaN

"""#
