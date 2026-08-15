/// EventLoop fairness for CPU-bound Go guest execution.

import Testing
import Swiftix
@testable import SwiftixGoRuntime

@Suite("Go VM instruction quantum")
struct GoSchedulingQuantumTests {
    @Test func readyEventLoopWorkRunsBeforeGuestConsumesAnotherQuantum() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [
                        .push(.string("guest")),
                        .print(argumentCount: 1, newline: false),
                        .return,
                    ]),
            ])
        let loop = EventLoop()
        var schedulerRan = false
        var schedulerRanBeforeOutput = false
        loop.post { schedulerRan = true }

        try GoVirtualMachine(instructionQuantum: 1).run(
            executable,
            eventLoop: loop
        ) { _ in
            schedulerRanBeforeOutput = schedulerRan
        }

        #expect(schedulerRan)
        #expect(schedulerRanBeforeOutput)
    }

    @Test func processHostedGuestGivesReadyKernelWorkATurn() {
        var instructions = (0..<4_096).map { GoInstruction.jump($0 + 1) }
        instructions += [
            .push(.string("guest")),
            .print(argumentCount: 1, newline: false),
            .return,
        ]
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [GoBytecodeFunction(name: "main",
                                            localCount: 0,
                                            instructions: instructions)])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Capture {
            var schedulerRan = false
            var schedulerRanBeforeOutput = false
        }
        let capture = Capture()

        kernel.spawn("go-quantum") { context in
            _ = try? GoVirtualMachine(instructionQuantum: 4_096).run(
                executable,
                eventLoop: loop,
                processContext: context
            ) { _ in
                capture.schedulerRanBeforeOutput = capture.schedulerRan
            }
        }
        loop.post { capture.schedulerRan = true }
        loop.runUntilIdle()

        #expect(capture.schedulerRan)
        #expect(capture.schedulerRanBeforeOutput)
    }

    @Test func busyGuestRunQueueCannotStarveReadyHostWork() throws {
        let mainWork = (1...32).map { GoInstruction.jump($0 + 1) }
        let workerWork = (0..<100).map { GoInstruction.jump($0 + 1) }
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.spawn("worker", argumentCount: 0)]
                        + mainWork
                        + [.push(.string("guest")),
                           .print(argumentCount: 1, newline: false),
                           .return]),
                GoBytecodeFunction(name: "worker",
                                   localCount: 0,
                                   instructions: workerWork + [.return]),
            ])
        let loop = EventLoop()
        var schedulerRan = false
        var schedulerRanBeforeOutput = false
        loop.post { schedulerRan = true }

        try GoVirtualMachine(instructionQuantum: 4).run(
            executable,
            eventLoop: loop
        ) { _ in
            schedulerRanBeforeOutput = schedulerRan
        }

        #expect(schedulerRan)
        #expect(schedulerRanBeforeOutput)
    }
}
