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

    /// Live cells are counted incrementally rather than by scanning the heap,
    /// so the count must always equal allocations minus reclaimed cells, and
    /// the byte estimate must survive in-place slice stores.
    @Test func heapStatisticsStayConsistentAcrossCollectionsAndSliceStores() throws {
        for (threshold, rounds) in [(1, 30), (7, 200), (64, 500), (100_000, 300)] {
            let source = GoSourceFile(
                path: "main.go",
                text: """
                    package main
                    import "fmt"
                    import "runtime"
                    func fill(count int) []string {
                        items := []string{}
                        for index := 0; index < count; index++ {
                            items = append(items, "item")
                        }
                        for index := 0; index < count; index++ {
                            items[index] = items[index] + "-longer-text"
                        }
                        return items
                    }
                    func main() {
                        kept := fill(\(rounds))
                        for round := 0; round < 5; round++ {
                            garbage := fill(\(rounds))
                            garbage[0] = "x"
                        }
                        runtime.GC()
                        fmt.Println(len(kept), kept[\(rounds - 1)])
                    }
                    """)
            let executable = try GoCompiler.compile(sources: [source])
            var output = ""
            let statistics = try GoVirtualMachine(
                maximumInstructions: 10_000_000,
                garbageCollectionThreshold: threshold
            ).runWithStatistics(executable) { output += $0 }

            #expect(output == "\(rounds) item-longer-text\n")
            #expect(
                statistics.liveHeapCells
                    == statistics.heapAllocations - statistics.reclaimedHeapCells)
            #expect(statistics.liveHeapCells > 0)
            // One live slice of `rounds` 16-byte strings (48 estimated bytes
            // each, in a backing array of at most twice that capacity) plus
            // bookkeeping; an estimate that drifted with every in-place store
            // would leave these bounds.
            #expect(statistics.liveHeapBytes >= rounds * 48)
            #expect(statistics.liveHeapBytes < rounds * 48 * 4 + 8_192)
        }
    }

    /// A call-heavy loop over a large live slice must not pay for a full
    /// collection every fixed number of allocations: the trigger scales with
    /// the heap that survived the last collection.
    @Test func collectionCadenceScalesWithTheLiveHeap() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                import "strings"
                func width(line string) int {
                    return len(line)
                }
                func main() {
                    lines := strings.Split(strings.Repeat("some line of text\\n", 20000), "\\n")
                    total := 0
                    for index := 0; index < len(lines); index++ {
                        total = total + width(lines[index])
                    }
                    fmt.Println(total)
                }
                """)
        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        let statistics = try GoVirtualMachine(maximumInstructions: 10_000_000)
            .runWithStatistics(executable) { output += $0 }

        #expect(output == "340000\n")
        #expect(statistics.heapAllocations > 20_000)
        #expect(statistics.garbageCollections >= 1)
        #expect(statistics.garbageCollections <= 12)
    }

    /// Near its ceiling the heap is collected at the fixed threshold again, so
    /// garbage cannot exhaust a small heap between scaled collections.
    @Test func smallHeapIsStillCollectedPromptly() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    kept := make([]int, 64)
                    for round := 0; round < 3000; round++ {
                        garbage := make([]int, 4)
                        garbage[0] = round
                        kept[round-(round/64)*64] = garbage[0]
                    }
                    fmt.Println(kept[63])
                }
                """)
        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        let statistics = try GoVirtualMachine(
            garbageCollectionThreshold: 16,
            resourceLimits: GoRuntimeResourceLimits(maximumHeapCells: 96)
        ).runWithStatistics(executable) { output += $0 }

        #expect(output == "2943\n")
        #expect(statistics.garbageCollections > 50)
    }
}
