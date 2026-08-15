/// Go process ABI tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go process ABI")
struct GoProcessABITests: GoTestHarness {

    @Test func processABIExposesArgumentsAtoiAndExitWithoutRunningDefers() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: """
                    package main
                    import "fmt"
                    import "os"
                    import "strconv"
                    func main() {
                        defer fmt.Println("deferred")
                        code, err := strconv.Atoi(os.Args[1])
                        if err != nil {
                            os.Exit(2)
                        }
                        fmt.Println(os.Args[0], os.Args[2])
                        os.Exit(code)
                    }
                    """)
        ])
        var output = ""

        let exitCode = try GoVirtualMachine().run(
            executable,
            arguments: ["abi-demo", "7", "payload"]
        ) { output += $0 }

        #expect(exitCode == 7)
        #expect(output == "abi-demo payload\n")
        #expect(!output.contains("deferred"))
    }
}
