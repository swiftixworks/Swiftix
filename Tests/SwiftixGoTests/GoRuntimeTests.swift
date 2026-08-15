/// Go runtime execution tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go runtime execution")
struct GoRuntimeTests: GoTestHarness {

    @Test func virtualMachineReportsDivisionByZero() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    zero := 0
                    fmt.Println(1 / zero)
                }
                """)
        let executable = try GoCompiler.compile(sources: [source])
        #expect(throws: GoRuntimeError.divisionByZero) {
            try GoVirtualMachine().run(executable) { _ in }
        }
    }

    @Test func virtualMachineValidatesFunctionCallContracts() {
        let argumentMismatch = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.call("value", argumentCount: 0), .return]),
                GoBytecodeFunction(
                    name: "value",
                    parameterCount: 1,
                    localCount: 1,
                    instructions: [.return]),
            ])
        #expect(
            throws: GoRuntimeError.argumentCountMismatch(
                function: "value",
                expected: 1,
                actual: 0)
        ) {
            try GoVirtualMachine().run(argumentMismatch) { _ in }
        }

        let missingReturn = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    returnCount: 1,
                    localCount: 0,
                    instructions: [])
            ])
        #expect(throws: GoRuntimeError.missingReturn("main")) {
            try GoVirtualMachine().run(missingReturn) { _ in }
        }
    }

    @Test func signedMinimumDivisionAndRemainderFollowGoSemantics() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [
                        .push(.int(Int64.min)), .push(.int(-1)), .divide,
                        .push(.int(Int64.min)), .push(.int(-1)), .remainder,
                        .print(argumentCount: 2, newline: true),
                        .return,
                    ])
            ])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "\(Int64.min) 0\n")
    }
}
