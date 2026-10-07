/// Go bitwise integer operators: parsing and precedence, run-time semantics,
/// diagnostics, and the reserved native calls they lower to.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go bitwise operators")
struct GoBitwiseOperatorTests: GoTestHarness {

    @Test func operatorsComputeGoResults() throws {
        let output = try runGoMain("""
            a := 12
            b := 10
            fmt.Println(a & b, a | b, a ^ b, a &^ b, a << 2, a >> 1, ^a, ^0)
            fmt.Println(-8 >> 1, -1 & 255, 1 << 62, a&1 == 0, a|1 != a)
            p := &a
            fmt.Println(*p & 4, *p&^4)
            """)

        #expect(output == "8 14 6 4 48 6 -13 -1\n-4 255 4611686018427387904 true true\n4 8\n")
    }

    @Test func precedenceFollowsGo() throws {
        // `* / % << >> & &^` bind tighter than `+ - | ^`, which bind tighter
        // than comparisons.
        let output = try runGoMain("""
            fmt.Println(1 | 2 & 3, 1 + 2 << 3, 1 << 2 + 3, 6 ^ 3 & 5, 7 &^ 2 | 8)
            fmt.Println(1 | 2 == 3, 8 >> 1 * 2, 2 * 8 >> 1, -1 ^ 1, ^1 + 1, 1 - ^1)
            x := 1 |
                2 |
                4
            fmt.Println(x)
            """)

        #expect(output == "3 17 7 7 13\ntrue 8 8 -2 -1 3\n7\n")
    }

    @Test func oversizedShiftCountsShiftEveryBitOut() throws {
        let output = try runGoMain("""
            big := 64
            huge := 9223372036854775807
            one := 1
            negative := -5
            fmt.Println(one << big, one << huge, one >> big, negative >> big, negative >> huge)
            fmt.Println(one << 63, negative << 63, negative >> 63)
            """)

        #expect(output == "0 0 0 -1 -1\n-9223372036854775808 -9223372036854775808 -1\n")
    }

    @Test func negativeShiftCountPanicsAtRunTime() {
        for shift in ["<<", ">>"] {
            #expect(throws: GoRuntimeError.panicError("runtime error: negative shift amount")) {
                try runGoMain("""
                    count := -1
                    fmt.Println(1 \(shift) count)
                    """)
            }
        }
    }

    @Test func operatorsReuseTheExistingTokenAndExpressionShapes() throws {
        // No token or AST case was added: operators are identifier tokens
        // spelled like the operator, and call nodes with a reserved callee.
        let tokens = try GoLexer.tokenize(
            GoSourceFile(path: "a.go", text: "a | b ^ c &^ d << e >> f & g |\nh"))
        #expect(tokens.map(\.kind) == [
            .identifier("a"), .identifier("|"), .identifier("b"), .identifier("^"),
            .identifier("c"), .identifier("&^"), .identifier("d"), .identifier("<<"),
            .identifier("e"), .identifier(">>"), .identifier("f"), .ampersand,
            .identifier("g"), .identifier("|"), .identifier("h"), .semicolon, .eof,
        ])

        let file = try GoParser.parse(
            GoSourceFile(path: "a.go", text: "package p\nfunc f() { x = a | ^b }\n"))
        guard case .assignment(_, let expression, _) = try #require(file.functions[0].body.statements.first),
            case .call(.identifier("$bits.or", _), let operands, _) = expression,
            operands.count == 2,
            case .identifier("a", _) = operands[0],
            case .call(.identifier("$bits.not", _), let inner, _) = operands[1],
            case .identifier("b", _)? = inner.first
        else {
            Issue.record("unexpected shape for a | ^b")
            return
        }
    }

    @Test func invalidOperandsAreDiagnosed() {
        #expect(goMainDiagnostic("fmt.Println(\"a\" | 1)") == "operator | requires integer operands")
        #expect(goMainDiagnostic("fmt.Println(true & false)") == "operator & requires integer operands")
        #expect(goMainDiagnostic("fmt.Println(1 << \"2\")") == "operator << requires integer operands")
        #expect(goMainDiagnostic("fmt.Println(^true)") == "operator ^ not defined on bool")
        #expect(goMainDiagnostic("fmt.Println(1 << -1)") == "invalid negative shift count -1")
        #expect(
            goMainDiagnostic("s := \"a\"\ni := 1\nfmt.Println(s[0] | i)")
                == "mismatched types byte and int")
        #expect(goMainDiagnostic("a := 1\na | 2") == "expression evaluated but not used")
        #expect(goMainDiagnostic("a := 1\nfmt.Println(a |)") == "expected expression")
        #expect(goMainDiagnostic("var | int") == "expected name in declaration")
    }

    @Test func operatorsLowerToReservedNativeCallsWithoutChangingTheImageFormat() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource("a := 6\nfmt.Println(a&3, a|3, a^3, a&^3, a<<3, a>>3, ^a)"))
        ])
        let calls = executable.functions.flatMap(\.instructions).compactMap { instruction in
            if case .call(let name, let argumentCount) = instruction {
                return "\(name)/\(argumentCount)"
            }
            return nil
        }

        #expect(calls == [
            "$bits.and/2", "$bits.or/2", "$bits.xor/2", "$bits.andNot/2",
            "$bits.shl/2", "$bits.shr/2", "$bits.not/1",
        ])
        #expect(executable.functions.map(\.name) == ["main"])
        let image = try GoExecutableImage.encode(executable)
        #expect(try GoExecutableImage.decode(image) == executable)
        #expect(GoExecutableImage.formatVersion == 10)
    }

    @Test func nativeCallsValidateTheirOperands() throws {
        func run(_ instructions: [GoInstruction]) throws {
            try GoVirtualMachine().run(
                GoExecutable(
                    entryPoint: "main",
                    functions: [
                        GoBytecodeFunction(name: "main", localCount: 0, instructions: instructions)
                    ])
            ) { _ in }
        }
        #expect(
            throws: GoRuntimeError.argumentCountMismatch(
                function: "$bits.and", expected: 2, actual: 1)
        ) {
            try run([.push(.int(1)), .call("$bits.and", argumentCount: 1), .return])
        }
        #expect(throws: GoRuntimeError.typeMismatch) {
            try run([
                .push(.int(1)), .push(.string("x")), .call("$bits.or", argumentCount: 2), .return,
            ])
        }
        #expect(throws: GoRuntimeError.stackUnderflow) {
            try run([.call("$bits.not", argumentCount: 1), .return])
        }
        #expect(throws: GoRuntimeError.missingFunction("$bits.unknown")) {
            try run([.call("$bits.unknown", argumentCount: 0), .return])
        }
    }
}
