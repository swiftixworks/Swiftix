/// Go garbage collection tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go garbage collection")
struct GoGarbageCollectionTests: GoTestHarness {

    @Test func managedHeapMarksRuntimeRootsAndSweepsUnreachableBackingArrays() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"runtime\"\nfunc main() {\n\tkept := make(chan []int, 1)\n\tvalue := make([]int, 1)\n\tvalue[0] = 42\n\tkept <- value\n\ti := 0\n\tfor i < 40 {\n\t\tgarbage := make([]int, 8)\n\t\tgarbage[0] = i\n\t\ti++\n\t}\n\truntime.GC()\n\treceived := <-kept\n\tfmt.Println(received[0])\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        let loop = EventLoop()
        var output = ""
        let statistics = try GoVirtualMachine(garbageCollectionThreshold: 12)
            .runWithStatistics(executable, eventLoop: loop) { output += $0 }

        #expect(output == "42\n")
        #expect(statistics.garbageCollections > 1)
        #expect(statistics.reclaimedHeapCells > 0)
        #expect(statistics.liveHeapCells < statistics.heapAllocations)
        #expect(loop.now == 0)
    }

    @Test func garbageCollectionKeepsGlobalMapAndParkedGoroutineRootsAlive() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"runtime\"\nvar global []int\nfunc send(values chan []int, ready chan bool) {\n\tlocal := make([]int, 1)\n\tlocal[0] = 33\n\tready <- true\n\tvalues <- local\n}\nfunc main() {\n\tglobal = make([]int, 1)\n\tglobal[0] = 11\n\tmapped := make([]int, 1)\n\tmapped[0] = 22\n\titems := make(map[int][]int)\n\titems[1] = mapped\n\tvalues := make(chan []int)\n\tready := make(chan bool, 1)\n\tgo send(values, ready)\n\t<-ready\n\truntime.GC()\n\treceived := <-values\n\tfmt.Println(global[0], items[1][0], received[0])\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        let statistics = try GoVirtualMachine(garbageCollectionThreshold: 1_000)
            .runWithStatistics(executable) { output += $0 }

        #expect(output == "11 22 33\n")
        #expect(statistics.garbageCollections == 1)
    }
}
