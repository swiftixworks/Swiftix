/// Go package initialization and linking tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go package initialization and linking")
struct GoPackageInitTests: GoTestHarness {

    @Test func packageGlobalsInitializeByDependencyBeforeOrderedInitFunctions() throws {
        let firstFile = GoSourceFile(
            path: "a.go",
            text: """
                package main
                import "fmt"

                var second = first + 1
                var first = mark(1)
                const step = 2

                func mark(value int) int {
                    fmt.Print(value)
                    return value
                }

                func init() {
                    fmt.Print("a")
                    second = second + step
                }
                """)
        let secondFile = GoSourceFile(
            path: "b.go",
            text: """
                package main
                import "fmt"

                var third = second + 1

                func init() {
                    fmt.Print("b")
                    third++
                }

                func main() {
                    fmt.Println(":", first, second, third)
                }
                """)

        let executable = try GoCompiler.compile(sources: [firstFile, secondFile])
        #expect(executable.globalCount == 4)
        #expect(executable.initializers == ["$package.init", "$init.0", "$init.1"])
        let decoded = try GoExecutableImage.decode(GoExecutableImage.encode(executable))
        #expect(decoded == executable)

        var output = ""
        try GoVirtualMachine().run(decoded) { output += $0 }
        #expect(output == "1ab: 1 4 4\n")
    }

    @Test func packageInitializationFollowsDependenciesThroughFunctionsAndMethods() throws {
        let source = GoSourceFile(
            path: "dependencies.go",
            text: """
                package main
                import "fmt"

                type First struct {}
                type Other struct {}

                var throughFunction = readLater()
                var throughMethod = First{}.Read()
                var later = 7
                var shadowed = readShadowed()

                func readLater() int {
                    return later
                }

                func (first First) Read() int {
                    return later + 1
                }

                func (other Other) Read() int {
                    return throughMethod
                }

                func readShadowed() int {
                    shadowed := 4
                    return shadowed
                }

                func main() {
                    fmt.Println(throughFunction, throughMethod, later, shadowed)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "7 8 7 4\n")
    }

    @Test func typeCheckerRejectsPackageInitializationCycles() throws {
        let source = GoSourceFile(
            path: "cycle.go",
            text: """
                package main
                var first = second + 1
                var second = first + 1
                func main() {}
                """)
        let file = try GoParser.parse(source)
        #expect(throws: GoDiagnostic.self) {
            try GoTypeChecker.check([file])
        }
    }

    @Test func compilerRejectsPackageInitializationCyclesThroughFunctions() throws {
        let source = GoSourceFile(
            path: "function-cycle.go",
            text: """
                package main
                var value = readValue()
                func readValue() int { return value }
                func main() {}
                """)

        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [source])
        }
    }

    @Test func singlePackageLinkerRejectsUnresolvedSymbolsAndGlobalSlots() {
        let unresolved = GoIRFunction(
            name: "main",
            registerCount: 0,
            operations: [.call(function: "missing", arguments: [], destinations: []), .return])
        #expect(throws: GoDiagnostic.self) {
            try GoSinglePackageLinker.link(
                entryPoint: "main",
                initializers: [],
                globalCount: 0,
                functions: [unresolved])
        }

        let invalidGlobal = GoIRFunction(
            name: "main",
            registerCount: 1,
            operations: [.loadGlobal(destination: 0, index: 1), .return])
        #expect(throws: GoDiagnostic.self) {
            try GoSinglePackageLinker.link(
                entryPoint: "main",
                initializers: [],
                globalCount: 1,
                functions: [invalidGlobal])
        }
    }

    @Test func localPackageImportAndCrossPackageCalls() throws {
        // Compile the "math" package
        let mathSource = GoSourceFile(
            path: "math/math.go",
            text: "package math\nfunc Add(a, b int) int {\n\treturn a + b\n}\nfunc Double(x int) int {\n\treturn x * 2\n}\n")
        let mathPkg = try GoCompiler.compilePackage(sources: [mathSource])

        // Compile main that imports math
        let mainSource = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"example/math\"\nimport \"fmt\"\nfunc main() {\n\tfmt.Println(math.Add(3, 4))\n\tfmt.Println(math.Double(5))\n}\n")
        let executable = try GoCompiler.compile(
            sources: [mainSource],
            importedPackages: ["math": mathPkg])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "7\n10\n")
    }
}
