/// Go runtime resource limits tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go runtime resource limits")
struct GoResourceLimitTests: GoTestHarness {

    @Test func recursiveCallsRespectCallStackLimit() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                func recurse() { recurse() }
                func main() { recurse() }
                """)
        let executable = try GoCompiler.compile(sources: [source])

        #expect(throws: GoRuntimeError.callStackLimitExceeded) {
            try GoVirtualMachine(maximumCallDepth: 8).run(executable) { _ in }
        }
    }

    @Test func infiniteLoopRespectsInstructionLimit() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                func main() { for {} }
                """)
        let executable = try GoCompiler.compile(sources: [source])

        #expect(throws: GoRuntimeError.instructionLimitExceeded) {
            try GoVirtualMachine(maximumInstructions: 32).run(executable) { _ in }
        }
    }

    @Test func dynamicCollectionAndHeapBudgetsFailWithTypedErrors() {
        let oversizedSlice = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [
                        .push(.int(0)), .push(.int(0)), .push(.int(9)),
                        .allocateSlice, .return,
                    ])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("slice elements")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumCollectionElements: 8)
            ).run(oversizedSlice) { _ in }
        }

        let allocation = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.push(.int(0)), .makeSlice(elementCount: 0), .return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("heap cells")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumHeapCells: 0)
            ).run(allocation) { _ in }
        }

        let map = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.makeMap(entryCount: 2), .return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("map entries")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumMapEntries: 1)
            ).run(map) { _ in }
        }
    }

    @Test func goroutineFrameTimerAndHandleBudgetsAreEnforced() {
        let spawning = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.spawn("worker", argumentCount: 0), .return]),
                GoBytecodeFunction(
                    name: "worker",
                    localCount: 0,
                    instructions: [.return]),
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("goroutines")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumGoroutines: 1)
            ).run(spawning) { _ in }
        }

        let largeFrame = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(name: "main", localCount: 2, instructions: [.return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("live frame locals")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumLiveFrameLocals: 1)
            ).run(largeFrame) { _ in }
        }

        let sleeping = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.push(.int(1)), .timeSleep, .return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("timers")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumTimers: 0)
            ).run(sleeping) { _ in }
        }

        let timerChannel = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.push(.int(1)), .timeAfter, .return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("runtime handles")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumRuntimeHandles: 0)
            ).run(timerChannel) { _ in }
        }
    }

    @Test func heapByteBudgetIsEnforcedBeforeAllocation() {
        let allocation = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.push(.int(0)), .makeSlice(elementCount: 0), .return])
            ])

        #expect(throws: GoRuntimeError.resourceLimitExceeded("heap bytes")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumHeapBytes: 31)
            ).run(allocation) { _ in }
        }
    }

    @Test func pointerDepthAndDeferredCallBudgetsAreEnforced() {
        let deepPointer = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 1,
                    instructions: [
                        .addressLocal(index: 0, fieldPath: ["value"]),
                        .return,
                    ])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("pointer depth")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumPointerDepth: 0)
            ).run(deepPointer) { _ in }
        }

        let deferredCall = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.deferCall("cleanup", argumentCount: 0), .return]),
                GoBytecodeFunction(
                    name: "cleanup",
                    localCount: 0,
                    instructions: [.return]),
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("deferred calls")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumRuntimeHandles: 0)
            ).run(deferredCall) { _ in }
        }
    }

    @Test func outputAndArgumentBudgetsRejectBeforeConsumerSideEffects() {
        let printing = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [
                        .push(.string("four")),
                        .print(argumentCount: 1, newline: false),
                        .return,
                    ])
            ])
        var output = ""
        #expect(throws: GoRuntimeError.resourceLimitExceeded("output bytes")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumOutputBytes: 3)
            ).run(printing) { output += $0 }
        }
        #expect(output.isEmpty)

        let returning = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(name: "main", localCount: 0, instructions: [.return])
            ])
        #expect(throws: GoRuntimeError.resourceLimitExceeded("process argument bytes")) {
            try GoVirtualMachine(
                resourceLimits: GoRuntimeResourceLimits(maximumInputBytes: 3)
            ).run(returning, arguments: ["four"]) { _ in }
        }
    }

    @Test func readInputBudgetBoundsVFSReads() {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [
                        .push(.string("cat")),
                        .push(.string("")),
                        .push(.string("/large")),
                        .makeSlice(elementCount: 1),
                        .readInput,
                        .return,
                    ])
            ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var runtimeError: GoRuntimeError?
        kernel.spawn("go-input-limit") { context in
            Self.write(context, path: "/large", contents: "four")
            do {
                try GoVirtualMachine(
                    resourceLimits: GoRuntimeResourceLimits(maximumInputBytes: 3)
                ).run(
                    executable,
                    eventLoop: loop,
                    processContext: context
                ) { _ in }
            } catch let error as GoRuntimeError {
                runtimeError = error
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        #expect(runtimeError == .resourceLimitExceeded("input bytes"))
    }
}
