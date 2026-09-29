/// Go string byte indexing, slicing, and range iteration over UTF-8 text.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go string indexing")
struct GoStringIndexingTests: GoTestHarness {

    private func run(_ body: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "fmt"
                func main() {
                \(body)
                }
                """)
        ])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    @Test func indexingAndSlicingUseByteOffsets() throws {
        let output = try run("""
            s := "aé😀z"
            fmt.Println(len(s), s[0], s[1], s[2], s[3], s[7])
            fmt.Println(s[1:3], s[3:7], s[7:], s[:1], s[8:] == "")
            """)

        #expect(output == "8 97 195 169 240 122\né 😀 z a true\n")
    }

    @Test func slicingInsideACharacterDecodesItsBytesAsReplacement() throws {
        let output = try run("""
            s := "é"
            fmt.Println(s[0:1] == "\\u00e9", len(s[0:1]), len(s[1:2]))
            """)

        #expect(output == "false 3 3\n")
    }

    @Test func outOfRangeIndexAndSliceFail() throws {
        #expect(throws: GoRuntimeError.indexOutOfRange) {
            try run("""
                s := "ab"
                i := 2
                fmt.Println(s[i])
                """)
        }
        #expect(throws: GoRuntimeError.invalidSliceBounds) {
            try run("""
                s := "ab"
                i := 3
                fmt.Println(s[1:i])
                """)
        }
    }

    @Test func rangeYieldsByteOffsetsAndCodePoints() throws {
        let output = try run("""
            for i, c := range "aé😀" {
                fmt.Println(i, c)
            }
            """)

        #expect(output == "0 97\n1 233\n3 128512\n")
    }
}
