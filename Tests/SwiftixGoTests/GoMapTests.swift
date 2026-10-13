/// Go maps: lookup, insertion order, deletion, key kinds, heap accounting, and
/// the entry limit. The storage is hash-indexed, so these also pin the
/// behavior a linear scan used to give for free.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go maps")
struct GoMapTests: GoTestHarness {

    @Test func iterationFollowsInsertionOrderAcrossDeletes() throws {
        let output = try runGoMain(
            """
            ages := map[string]int{"carol": 3, "alice": 1, "bob": 2}
            ages["dave"] = 4
            ages["alice"] = 10
            delete(ages, "bob")
            ages["bob"] = 20
            delete(ages, "missing")
            for name, age := range ages {
                fmt.Println(name, age)
            }
            fmt.Println(len(ages), ages)
            """)

        // An update keeps the key's position; a deleted key that is set again
        // moves to the end. Printing sorts by key, as Go's `fmt` does.
        #expect(
            output == """
                carol 3
                alice 10
                dave 4
                bob 20
                4 map[alice:10 bob:20 carol:3 dave:4]

                """)
    }

    @Test func lookupReportsPresenceAndZeroValues() throws {
        let output = try runGoMain(
            """
            counts := make(map[string]int)
            counts["a"] = 0
            first, hasFirst := counts["a"]
            second, hasSecond := counts["b"]
            fmt.Println(first, hasFirst, second, hasSecond, counts["c"], len(counts))
            var empty map[string]int
            value, found := empty["a"]
            fmt.Println(value, found, len(empty))
            delete(empty, "a")
            """)

        #expect(output == "0 true 0 false 0 1\n0 false 0\n")
    }

    @Test func keysOfEveryComparableKindStayDistinct() throws {
        let output = try runGoMain(
            """
            numbers := map[int]string{}
            numbers[-1] = "minus"
            numbers[0] = "zero"
            numbers[9223372036854775807] = "max"
            fmt.Println(numbers[-1], numbers[0], numbers[9223372036854775807], len(numbers))

            flags := map[bool]int{true: 1, false: 2}
            fmt.Println(flags[true], flags[false])

            points := map[point]string{}
            points[point{x: 1, y: 2}] = "a"
            points[point{x: 2, y: 1}] = "b"
            points[point{x: 1, y: 2}] = "c"
            fmt.Println(points[point{x: 1, y: 2}], points[point{x: 2, y: 1}], len(points))

            bytes := map[byte]int{}
            text := "abca"
            for i := 0; i < len(text); i++ {
                bytes[text[i]]++
            }
            fmt.Println(bytes[text[0]], len(bytes))
            """,
            declarations: """
                type point struct {
                    x int
                    y int
                }
                """)

        #expect(output == "minus zero max 3\n1 2\nc b 2\n2 3\n")
    }

    @Test func mapsShareStorageThroughHandles() throws {
        let output = try runGoMain(
            """
            first := map[string]int{"a": 1}
            second := first
            second["b"] = 2
            delete(first, "a")
            fill(first)
            fmt.Println(len(first), len(second), second["c"], first["b"])
            """,
            declarations: """
                func fill(target map[string]int) {
                    target["c"] = 3
                }
                """)

        #expect(output == "2 2 3 2\n")
    }

    @Test func manyKeysSurviveInterleavedInsertsAndDeletes() throws {
        let output = try runGoMain(
            """
            table := make(map[int]int)
            for i := 0; i < 3000; i++ {
                table[i] = i * 2
            }
            for i := 0; i < 3000; i += 3 {
                delete(table, i)
            }
            for i := 0; i < 3000; i += 6 {
                table[i] = -i
            }
            sum := 0
            missing := 0
            for i := 0; i < 3000; i++ {
                value, ok := table[i]
                if ok {
                    sum += value
                } else {
                    missing++
                }
            }
            order := 0
            last := -1
            for key := range table {
                if key%6 != 0 && key < last {
                    order++
                }
                if key%6 != 0 {
                    last = key
                }
            }
            fmt.Println(len(table), sum, missing, order)
            """,
            machine: GoVirtualMachine(maximumInstructions: 10_000_000))

        // 2000 keys survive the first delete pass with value 2i, 500 are
        // re-added with value -i, and 500 stay deleted.
        var sum = 0
        for i in 0..<3000 where i % 3 != 0 { sum += i * 2 }
        for i in stride(from: 0, to: 3000, by: 6) { sum -= i }
        #expect(output == "2500 \(sum) 500 0\n")
    }

    @Test func deletedEntriesReturnTheirHeapBytes() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    table := make(map[int]string)
                    for round := 0; round < 40; round++ {
                        for i := 0; i < 200; i++ {
                            table[i] = "0123456789012345678901234567890123456789"
                        }
                        for i := 0; i < 200; i++ {
                            delete(table, i)
                        }
                    }
                    runtime.GC()
                    fmt.Println(len(table))
                    """,
                    imports: ["fmt", "runtime"]))
        ])
        var output = ""
        // 200 live entries need roughly 24 KiB; 8,000 leaked ones would need
        // about 1 MiB and exceed this heap.
        let statistics = try GoVirtualMachine(
            maximumInstructions: 10_000_000,
            resourceLimits: GoRuntimeResourceLimits(maximumHeapBytes: 128 * 1024)
        ).runWithStatistics(executable) { output += $0 }

        #expect(output == "0\n")
        #expect(statistics.liveHeapBytes < 4 * 1024)
    }

    @Test func entryLimitCountsLiveKeysOnly() throws {
        let machine = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(maximumMapEntries: 2))

        let reused = try runGoMain(
            """
            table := map[int]int{1: 1, 2: 2}
            table[1] = 10
            delete(table, 2)
            table[3] = 3
            fmt.Println(len(table), table[1], table[3])
            """,
            machine: machine)
        #expect(reused == "2 10 3\n")

        #expect(throws: GoRuntimeError.resourceLimitExceeded("map entries")) {
            _ = try runGoMain(
                """
                table := map[int]int{1: 1, 2: 2}
                table[3] = 3
                """,
                machine: machine)
        }
    }

    @Test func storageKeepsItsValueSemantics() {
        var storage = GoMapStorage(entries: [
            (key: .string("a"), value: .int(1)),
            (key: .string("b"), value: .int(2)),
            (key: .string("a"), value: .int(3)),
        ])
        #expect(storage.count == 2)
        #expect(storage.get(.string("a")) == .int(3))

        let snapshot = storage
        storage.delete(.string("a"))
        storage.set(.string("c"), .int(4))
        storage.set(.string("a"), .int(5))

        #expect(snapshot.entries.map(\.key) == [.string("a"), .string("b")])
        #expect(storage.entries.map(\.key) == [.string("b"), .string("c"), .string("a")])
        #expect(storage.get(.string("missing")) == nil)
        #expect(storage != snapshot)

        // Equality is by live entries in order, however they were reached.
        var rebuilt = GoMapStorage()
        rebuilt.set(.string("x"), .int(0))
        rebuilt.set(.string("b"), .int(2))
        rebuilt.set(.string("c"), .int(4))
        rebuilt.set(.string("a"), .int(5))
        rebuilt.delete(.string("x"))
        #expect(rebuilt == storage)

        storage.entries = [(key: .int(1), value: .bool(true))]
        #expect(storage.count == 1)
        #expect(storage.get(.int(1)) == .bool(true))
        #expect(storage.get(.string("b")) == nil)
    }

    @Test func storageStaysConsistentUnderRandomOperations() {
        // A linear association list is the model the hash index must match.
        var generator = SplitMix64(state: 0x5357_4946_5449_5802)
        var storage = GoMapStorage()
        var model: [(key: GoValue, value: GoValue)] = []

        for step in 0..<6_000 {
            let key: GoValue =
                generator.next() % 3 == 0
                ? .string("k\(generator.next() % 64)")
                : .int(Int64(generator.next() % 96))
            if generator.next() % 4 == 0 {
                storage.delete(key)
                model.removeAll { $0.key == key }
            } else {
                let value = GoValue.int(Int64(step))
                storage.set(key, value)
                if let index = model.firstIndex(where: { $0.key == key }) {
                    model[index].value = value
                } else {
                    model.append((key: key, value: value))
                }
            }
            #expect(storage.count == model.count)
        }

        #expect(storage.entries.map(\.key) == model.map(\.key))
        #expect(storage.entries.map(\.value) == model.map(\.value))
        for entry in model {
            #expect(storage.get(entry.key) == entry.value)
        }
    }
}

/// Deterministic generator for the model test; no wall-clock or system seed.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
