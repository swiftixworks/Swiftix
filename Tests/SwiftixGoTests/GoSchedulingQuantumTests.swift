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

    /// A goroutine that parks on the instruction a quantum ends on must be
    /// recorded as parked before the quantum's event-loop turn can wake it.
    @Test func parkingOnAQuantumBoundaryIsSafeForEveryAlignment() throws {
        for padding in 0..<6 {
            for quantum in 1...8 {
                var instructions = (0..<padding).map { GoInstruction.jump($0 + 1) }
                instructions += [
                    .push(.int(0)),
                    .timeSleep,
                    .push(.int(0)),
                    .timeAfter,
                    .push(.int(0)),
                    .receiveChannel(commaOK: false),
                    .store(0),
                    .push(.string("woke")),
                    .print(argumentCount: 1, newline: false),
                    .return,
                ]
                let executable = GoExecutable(
                    entryPoint: "main",
                    functions: [
                        GoBytecodeFunction(name: "main", localCount: 1, instructions: instructions)
                    ])
                var output = ""
                try GoVirtualMachine(instructionQuantum: quantum).run(executable) { output += $0 }
                #expect(output == "woke", "padding \(padding), quantum \(quantum)")
            }
        }
    }
}
