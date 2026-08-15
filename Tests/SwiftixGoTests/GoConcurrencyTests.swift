/// Go concurrency: goroutines, channels, select, sync tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go concurrency: goroutines, channels, select, sync")
struct GoConcurrencyTests: GoTestHarness {

    @Test func goroutinesTransferAcrossUnbufferedChannelAndObserveClose() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc produce(out chan int) {\n\tout <- 1\n\tout <- 2\n\tclose(out)\n}\nfunc main() {\n\tvalues := make(chan int)\n\tgo produce(values)\n\tfirst := <-values\n\tsecond, ok := <-values\n\tzero, open := <-values\n\tfmt.Println(first, second, ok, zero, open)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "1 2 true 0 false\n")
    }

    @Test func bufferedChannelReportsLengthCapacityAndRangesUntilClosed() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tvalues := make(chan int, 3)\n\tvalues <- 1\n\tvalues <- 2\n\tfmt.Println(len(values), cap(values))\n\tclose(values)\n\ttotal := 0\n\tfor value := range values {\n\t\ttotal = total + value\n\t}\n\tfmt.Println(total, len(values))\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "2 3\n3 0\n")
    }

    @Test func nilChannelBlocksAndRuntimeDetectsGlobalDeadlock() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc main() {\n\tvar values chan int\n\t<-values\n}\n")
        let executable = try GoCompiler.compile(sources: [source])

        #expect(throws: GoRuntimeError.deadlock) {
            try GoVirtualMachine().run(executable) { _ in }
        }
    }

    @Test func selectUsesDefaultWhenNoCommunicationIsReady() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tvalues := make(chan int)\n\tselect {\n\tcase <-values:\n\t\tfmt.Println(\"unexpected\")\n\tdefault:\n\t\tfmt.Println(\"default\")\n\t}\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "default\n")
    }

    @Test func closedChannelReceiveAndSendAreReadyInSelect() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc report() { fmt.Println(recover()) }\nfunc sendClosed(values chan int) {\n\tdefer report()\n\tselect {\n\tcase values <- 1:\n\tdefault:\n\t\tfmt.Println(\"unexpected default\")\n\t}\n}\nfunc main() {\n\tvalues := make(chan int)\n\tclose(values)\n\tselect {\n\tcase value, ok := <-values:\n\t\tfmt.Println(value, ok)\n\tdefault:\n\t\tfmt.Println(\"unexpected default\")\n\t}\n\tsendClosed(values)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "0 false\nsend on closed channel\n")
    }

    @Test func emptySelectBlocksForeverAndReportsDeadlock() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc main() { select {} }\n")
        let executable = try GoCompiler.compile(sources: [source])

        #expect(throws: GoRuntimeError.deadlock) {
            try GoVirtualMachine().run(executable) { _ in }
        }
    }

    @Test func blockingSelectPairsWithOrdinaryAndSelectSenders() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc relay(in chan int, out chan int) {\n\tselect {\n\tcase value := <-in:\n\t\tout <- value + 1\n\t}\n}\nfunc emit(out chan int) {\n\tselect {\n\tcase out <- 41:\n\t}\n}\nfunc main() {\n\tin := make(chan int)\n\tout := make(chan int)\n\tgo relay(in, out)\n\tgo emit(in)\n\tfmt.Println(<-out)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "42\n")
    }

    @Test func selectChoiceIsPseudoRandomAndReproducibleWithInjectedSeed() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tleft := make(chan int, 1)\n\tright := make(chan int, 1)\n\tleft <- 1\n\tright <- 2\n\tselect {\n\tcase value := <-left:\n\t\tfmt.Println(\"left\", value)\n\tcase value := <-right:\n\t\tfmt.Println(\"right\", value)\n\t}\n}\n")
        let executable = try GoCompiler.compile(sources: [source])

        func output(seed: UInt64) throws -> String {
            var result = ""
            try GoVirtualMachine(selectSeed: seed).run(executable) { result += $0 }
            return result
        }

        let first = try output(seed: 17)
        #expect(try output(seed: 17) == first)
        #expect(first == "left 1\n" || first == "right 2\n")
        #expect(try output(seed: 18) != first)
    }

    @Test func selectTimeoutRunsOnInjectedLogicalEventLoop() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"time\"\nfunc main() {\n\tvar never chan int\n\tselect {\n\tcase <-never:\n\t\tfmt.Println(\"unexpected\")\n\tcase <-time.After(5 * time.Millisecond):\n\t\tfmt.Println(\"timeout\")\n\t}\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        let loop = EventLoop()
        var output = ""
        try GoVirtualMachine().run(executable, eventLoop: loop) { output += $0 }

        #expect(output == "timeout\n")
        #expect(abs(loop.now - 0.005) < 0.000_000_001)
    }

    @Test func syncMutexAndWaitGroupCoordinateGoroutinesInFIFOOrder() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"sync\"\nvar mutex sync.Mutex\nvar workers sync.WaitGroup\nvar total int\nfunc add(value int) {\n\tmutex.Lock()\n\tfmt.Println(value)\n\ttotal = total + value\n\tmutex.Unlock()\n\tworkers.Done()\n}\nfunc main() {\n\tworkers.Add(3)\n\tgo add(1)\n\tgo add(2)\n\tgo add(3)\n\tworkers.Wait()\n\tfmt.Println(total)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "1\n2\n3\n6\n")
    }

    @Test func channelAndSyncMisusePanicsAreRecoverable() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"sync\"\nfunc report() { fmt.Println(recover()) }\nfunc closeNil() {\n\tdefer report()\n\tvar values chan int\n\tclose(values)\n}\nfunc closeTwice() {\n\tdefer report()\n\tvalues := make(chan int)\n\tclose(values)\n\tclose(values)\n}\nfunc unlock() {\n\tdefer report()\n\tvar mutex sync.Mutex\n\tmutex.Unlock()\n}\nfunc negative() {\n\tdefer report()\n\tvar group sync.WaitGroup\n\tgroup.Add(-1)\n}\nfunc main() {\n\tcloseNil()\n\tcloseTwice()\n\tunlock()\n\tnegative()\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "close of nil channel\nclose of closed channel\nsync: unlock of unlocked mutex\nsync: negative WaitGroup counter\n")
    }

    @Test func completedChildStillLetsBlockedMainDrivePendingTimer() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"time\"\nfunc finish() {}\nfunc main() {\n\tgo finish()\n\tselect {\n\tcase <-time.After(time.Millisecond):\n\t\tfmt.Println(\"resumed\")\n\t}\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "resumed\n")
    }

    @Test func returningMainTerminatesRemainingGoroutines() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc spin() { for {} }\nfunc main() {\n\tgo spin()\n\tfmt.Println(\"done\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine(maximumInstructions: 1_000).run(executable) { output += $0 }

        #expect(output == "done\n")
    }

    @Test func fanOutFanInWorkersProduceEveryResultDeterministically() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc worker(jobs <-chan int, results chan<- int, done chan<- bool) {\n\tfor value := range jobs {\n\t\tresults <- value * value\n\t}\n\tdone <- true\n}\nfunc main() {\n\tjobs := make(chan int, 4)\n\tresults := make(chan int, 4)\n\tdone := make(chan bool, 2)\n\tgo worker(jobs, results, done)\n\tgo worker(jobs, results, done)\n\tjobs <- 1\n\tjobs <- 2\n\tjobs <- 3\n\tjobs <- 4\n\tclose(jobs)\n\ttotal := 0\n\ti := 0\n\tfor i < 4 {\n\t\ttotal = total + <-results\n\t\ti++\n\t}\n\t<-done\n\t<-done\n\tfmt.Println(total)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "30\n")
    }

    @Test func closingChannelWakesBlockedSenderWithRecoverablePanic() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"time\"\nvar finished chan int\nfunc reportPanic() {\n\tfmt.Println(recover())\n\tfinished <- 1\n}\nfunc sender(values chan int) {\n\tdefer reportPanic()\n\tvalues <- 1\n}\nfunc closer(values chan int) {\n\t<-time.After(time.Millisecond)\n\tclose(values)\n}\nfunc main() {\n\tvalues := make(chan int)\n\tfinished = make(chan int)\n\tgo sender(values)\n\tgo closer(values)\n\t<-finished\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "send on closed channel\n")
    }

    @Test func waitGroupDoneAndMutexUnlockWorkAsDeferredPointerMethods() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"sync\"\nfunc work(group *sync.WaitGroup, mutex *sync.Mutex) {\n\tdefer group.Done()\n\tmutex.Lock()\n\tdefer mutex.Unlock()\n\tfmt.Println(\"work\")\n}\nfunc main() {\n\tvar group sync.WaitGroup\n\tvar mutex sync.Mutex\n\tgroup.Add(1)\n\tgo work(&group, &mutex)\n\tgroup.Wait()\n\tfmt.Println(\"done\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "work\ndone\n")
    }

    @Test func goStatementCanInvokeStandardLibraryFunction() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"time\"\nfunc main() {\n\tgo fmt.Println(\"child\")\n\t<-time.After(time.Millisecond)\n\tfmt.Println(\"main\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "child\nmain\n")
    }

    @Test func goStatementCanSpawnParameterizedFunctionLiteral() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tvalues := make(chan int)\n\tgo func(out chan int, value int) {\n\t\tout <- value\n\t}(values, 42)\n\tfmt.Println(<-values)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "42\n")
    }
}
