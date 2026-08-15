/// Go executable image encoding tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go executable image encoding")
struct GoExecutableImageTests: GoTestHarness {

    @Test func executableImageRoundTripsDeterministically() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 2,
                    instructions: [
                        .push(.int(-42)), .push(.string("hello 世界")), .push(.bool(true)),
                        .load(0), .store(1), .negate, .not, .add, .subtract, .multiply,
                        .divide, .remainder, .equal, .notEqual, .less, .lessEqual,
                        .greater, .greaterEqual, .logicalAnd, .logicalOr,
                        .print(argumentCount: 2, newline: true),
                        .jump(0), .jumpIfFalse(1), .jumpIfTrue(2),
                        .call("helper", argumentCount: 0), .return, .returnValues(count: 1),
                    ]),
                GoBytecodeFunction(
                    name: "helper",
                    localCount: 0,
                    instructions: [.return]),
            ])

        let image = try GoExecutableImage.encode(executable)
        #expect(GoExecutableImage.recognizes(image))
        #expect(try GoExecutableImage.decode(image) == executable)
        #expect(try GoExecutableImage.encode(GoExecutableImage.decode(image)) == image)
    }

    @Test func executableImageRejectsCorruptionAndTrailingData() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(name: "main", localCount: 0, instructions: [.return])
            ])
        let image = try GoExecutableImage.encode(executable)

        #expect(throws: GoExecutableImageError.invalidMagic) {
            try GoExecutableImage.decode(Array(repeating: 0, count: 10))
        }
        #expect(throws: GoExecutableImageError.truncated) {
            try GoExecutableImage.decode(Array(image.dropLast()))
        }
        #expect(throws: GoExecutableImageError.trailingData) {
            try GoExecutableImage.decode(image + [0])
        }
        #expect(throws: GoExecutableImageError.missingEntryPoint("main")) {
            try GoExecutableImage.encode(GoExecutable(entryPoint: "main", functions: []))
        }
    }

    @Test func directBytecodeMetadataDefaultsRejectHostileCountsWithoutHostTrap() {
        let negative = GoBytecodeFunction(
            name: "main",
            localCount: -1,
            instructions: [.return])
        let enormous = GoBytecodeFunction(
            name: "main",
            localCount: Int.max,
            instructions: [.return])

        #expect(negative.rootLocalIndices.isEmpty)
        #expect(enormous.rootLocalIndices.isEmpty)
        #expect(throws: GoRuntimeError.invalidExecutable(
            "negative function count in main")) {
            try GoVirtualMachine().run(
                GoExecutable(entryPoint: "main", functions: [negative])) { _ in }
        }
        #expect(throws: GoRuntimeError.resourceLimitExceeded("total locals")) {
            try GoVirtualMachine().run(
                GoExecutable(entryPoint: "main", functions: [enormous])) { _ in }
        }
    }

    @Test func directExecutableIsValidatedBeforeRuntimeAllocation() {
        let invalidLocal = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.load(Int.max), .return])
            ])
        #expect(throws: GoRuntimeError.invalidExecutable(
            "invalid local index \(Int.max) in main")) {
            try GoVirtualMachine().run(invalidLocal) { _ in }
        }

        let overBudget = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.push(.int(1)), .return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("total instructions")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumTotalInstructions: 1)
            ).run(overBudget) { _ in }
        }
    }

    @Test func imageEncodingStopsAtMaximumSizeWithoutBuildingAnOversizedBuffer() {
        let payload = String(repeating: "x", count: 1_048_576)
        let functions = (0..<17).map { index in
            GoBytecodeFunction(
                name: index == 0 ? "main" : "unused.\(index)",
                localCount: 0,
                instructions: [.push(.string(payload)), .return])
        }
        let executable = GoExecutable(entryPoint: "main", functions: functions)

        #expect(throws: GoExecutableImageError.invalidCount) {
            try GoExecutableImage.encode(executable)
        }
    }

    @Test func shellRejectsNonExecutableAndCorruptGoImages() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc main() {}\n")
        let executable = try GoCompiler.compile(sources: [source])
        let corruptImage = Array(try GoExecutableImage.encode(executable).dropLast())

        let output = runShell(
            [
                "cd /images",
                "./not-executable",
                "echo first=$?",
                "./corrupt",
                "echo second=$?",
            ],
            seed: { context in
                _ = context.mkdir("/images")
                Self.writeBytes(context, path: "/images/not-executable", contents: corruptImage)
                Self.writeBytes(context, path: "/images/corrupt", contents: corruptImage)
                _ = context.chmod(
                    "/images/corrupt",
                    mode: [
                        .ownerRead, .ownerWrite, .ownerExecute,
                        .groupRead, .groupExecute,
                        .otherRead, .otherExecute,
                    ])
            })

        #expect(output.contains("./not-executable: permission denied"))
        #expect(output.contains("first=126"))
        #expect(output.contains("./corrupt: exec format error"))
        #expect(output.contains("second=126"))
    }
}
