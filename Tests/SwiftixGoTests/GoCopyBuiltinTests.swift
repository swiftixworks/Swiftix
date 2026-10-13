/// The Go builtin `copy`: element counts, overlapping ranges, string sources,
/// and type checking. It runs natively, one VM instruction whatever the length.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go copy builtin")
struct GoCopyBuiltinTests: GoTestHarness {

    @Test func copiesTheShorterOfTheTwoLengths() throws {
        let output = try runGoMain(
            """
            source := []int{1, 2, 3, 4, 5}
            short := make([]int, 3)
            long := make([]int, 7)
            fmt.Println(copy(short, source), short)
            fmt.Println(copy(long, source), long)
            var none []int
            fmt.Println(copy(none, source), copy(long, none), copy(short[:0], source), long)
            words := []string{"a", "b"}
            names := make([]string, 2)
            copy(names, words)
            words[0] = "changed"
            fmt.Println(names, words)
            """)

        #expect(
            output == """
                3 [1 2 3]
                5 [1 2 3 4 5 0 0]
                0 0 0 [1 2 3 4 5 0 0]
                [a b] [changed b]

                """)
    }

    @Test func overlappingRangesMoveLikeMemmove() throws {
        let output = try runGoMain(
            """
            forward := []int{1, 2, 3, 4, 5, 6}
            fmt.Println(copy(forward[2:], forward), forward)
            backward := []int{1, 2, 3, 4, 5, 6}
            fmt.Println(copy(backward, backward[2:]), backward)
            same := []int{7, 8, 9}
            fmt.Println(copy(same, same), same)
            """)

        #expect(output == "4 [1 2 1 2 3 4]\n4 [3 4 5 6 5 6]\n3 [7 8 9]\n")
    }

    @Test func aSubsliceIsFilledInItsSharedBackingArray() throws {
        let output = try runGoMain(
            """
            page := make([]byte, 8)
            header := page[:2]
            body := page[2:6]
            fmt.Println(copy(header, []byte{1, 2, 3}), copy(body, "data!"), copy(page[6:], "é"))
            fmt.Println(page, string(body), len(body), cap(body))
            grown := make([]byte, len(page)+2)
            copy(grown, page)
            copy(grown[len(page):], "ok")
            fmt.Println(string(grown[2:6]), string(grown[8:]), len(grown))
            """)

        // "é" is two bytes (195 169), so it fills the last two slots exactly.
        #expect(
            output == """
                2 4 2
                [1 2 100 97 116 97 195 169] data 4 6
                data ok 10

                """)
    }

    @Test func largeCopiesCostOneInstructionEach() throws {
        // 64 copies of 4096 elements would need far more than the budget if
        // each element were a guest loop iteration.
        let output = try runGoMain(
            """
            source := make([]byte, 4096)
            for i := 0; i < len(source); i += 512 {
                source[i] = byte(i / 512 + 1)
            }
            target := make([]byte, 4096)
            total := 0
            for round := 0; round < 64; round++ {
                total += copy(target, source)
            }
            fmt.Println(total, target[0], target[512], target[3584], target[4095])
            """,
            machine: GoVirtualMachine(maximumInstructions: 20_000))

        #expect(output == "262144 1 2 8 0\n")
    }

    @Test func copyIsTypeChecked() {
        #expect(goMainDiagnostic("copy([]int{1})") == "copy takes exactly two arguments")
        #expect(
            goMainDiagnostic("copy(1, []int{1})") == "first argument to copy must be slice")
        #expect(
            goMainDiagnostic("copy([]int{1}, []string{\"a\"})")
                == "cannot copy []string into []int")
        #expect(goMainDiagnostic("copy([]int{1}, \"text\")") == "cannot copy string into []int")
        #expect(goMainDiagnostic("copy([]byte{1}, 7)") == "cannot copy int into []byte")
        #expect(goMainDiagnostic("var text string = copy([]int{1}, []int{2})\nfmt.Println(text)") != nil)
        #expect(
            goMainDiagnostic(
                """
                buffer := make([]byte, 4)
                var written int = copy(buffer, "ab") + copy(buffer[2:], []byte("cd"))
                fmt.Println(written)
                """) == nil)
    }
}
