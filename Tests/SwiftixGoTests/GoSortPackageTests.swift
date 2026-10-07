/// Go `sort.Strings`, `sort.Ints`, and `strconv.Itoa`: native semantics, type
/// checking, `go`/`defer` wrappers, and resource boundaries.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go sort package and strconv.Itoa")
struct GoSortPackageTests: GoTestHarness {

    @Test func sortStringsOrdersByBytesInPlace() throws {
        let output = try runGoMain(
            """
            words := []string{"pear", "apple", "fig", "Zed", "é", "z", "", "apple"}
            alias := words
            sort.Strings(words)
            fmt.Println(strings.Join(alias, ","), len(words))
            marks := []string{"\\u00e9", "e\\u0301", "f"}
            sort.Strings(marks)
            fmt.Println(len(marks[0]), marks[1], len(marks[2]))
            """,
            imports: ["fmt", "sort", "strings"])

        // Go compares bytes: decomposed "e\u{301}" (0x65 ...) sorts before "f",
        // and precomposed "é" (0xC3 ...) after it, although Swift's canonical
        // ordering treats the two spellings as equal.
        #expect(output == ",Zed,apple,apple,fig,pear,z,é 8\n3 f 2\n")
    }

    @Test func sortIntsOrdersNumerically() throws {
        let output = try runGoMain(
            """
            numbers := []int{5, -1, 3, 0, -9223372036854775807, 3}
            sort.Ints(numbers)
            fmt.Println(numbers)
            var empty []int
            sort.Ints(empty)
            sort.Ints([]int{})
            one := []int{7}
            sort.Ints(one)
            fmt.Println(len(empty), one)
            """,
            imports: ["fmt", "sort"])

        #expect(output == "[-9223372036854775807 -1 0 3 3 5]\n0 [7]\n")
    }

    @Test func sortingASubSliceLeavesTheRestOfTheBackingArrayAlone() throws {
        let output = try runGoMain(
            """
            numbers := []int{9, 8, 7, 6, 5, 4}
            sort.Ints(numbers[1:4])
            fmt.Println(numbers)
            middle := numbers[2:5]
            sort.Ints(middle)
            fmt.Println(numbers, middle, len(middle), cap(middle))
            var grid [5]string
            grid[0] = "e"
            grid[1] = "d"
            grid[2] = "c"
            grid[3] = "b"
            grid[4] = "a"
            sort.Strings(grid[1:])
            fmt.Println(grid)
            words := make([]string, 2, 8)
            words[0] = "b"
            words[1] = "a"
            sort.Strings(words)
            words = append(words, "0")
            fmt.Println(words, cap(words))
            """,
            imports: ["fmt", "sort"])

        #expect(output == """
            [9 6 7 8 5 4]
            [9 6 5 7 8 4] [5 7 8] 3 4
            [e a b c d]
            [a b 0] 8

            """)
    }

    @Test func itoaFormatsDecimalIntegers() throws {
        let output = try runGoMain(
            """
            n := -42
            fmt.Println(strconv.Itoa(n) + "!", strconv.Itoa(0), len(strconv.Itoa(9223372036854775807)))
            back, err := strconv.Atoi(strconv.Itoa(n))
            fmt.Println(back == n, err == nil)
            """,
            imports: ["fmt", "strconv"])

        #expect(output == "-42! 0 19\ntrue true\n")
    }

    @Test func sortingRunsNativelyWithinASmallInstructionBudget() throws {
        // A guest-code sort of 4000 strings needs far more than 300
        // instructions; the native call costs one.
        let output = try runGoMain(
            """
            words := strings.Split(strings.Repeat("b,a,d,c,", 1000), ",")
            sort.Strings(words)
            fmt.Println(len(words), words[0] == "", words[1], words[1000], words[4000])
            """,
            imports: ["fmt", "sort", "strings"],
            machine: GoVirtualMachine(maximumInstructions: 300))

        #expect(output == "4001 true a a d\n")
    }

    @Test func goAndDeferCallNativesThroughSynthesizedWrappers() throws {
        let source = goMainSource(
            """
            numbers := []int{3, 1, 2}
            go sort.Ints(numbers)
            <-time.After(time.Millisecond)
            fmt.Println(numbers)
            fmt.Println(sorted([]string{"b", "c", "a"}))
            """,
            imports: ["fmt", "sort", "time"],
            declarations: """
                func sorted(words []string) []string {
                    defer sort.Strings(words)
                    words[0] = "z"
                    return words
                }
                """)
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "[1 2 3]\n[a c z]\n")
        let wrapper = try #require(
            executable.functions.first { $0.name == "$native.main.$sort.Ints.1" })
        #expect(wrapper.parameterCount == 1)
        #expect(wrapper.instructions == [.load(0), .call("$sort.Ints", argumentCount: 1), .return])
        #expect(executable.functions.contains { $0.name == "$native.main.$sort.Strings.1" })
    }

    @Test func importedPackagesKeepTheirOwnWrappersAndByteSignatures() throws {
        let library = try GoCompiler.compilePackage(sources: [
            GoSourceFile(
                path: "lib/lib.go",
                text: """
                    package lib
                    import "sort"
                    func Sorted(values []int) []int {
                        defer sort.Ints(values)
                        return values
                    }
                    func Lower(text string) byte { return text[0] | 32 }
                    func Count() int { return 41 }
                    func Text(raw []byte) string { return string(raw) }

                    """)
        ])
        let executable = try GoCompiler.compile(
            sources: [
                GoSourceFile(
                    path: "main.go",
                    text: """
                        package main
                        import "fmt"
                        import "sort"
                        import "example/lib"
                        func main() {
                            words := []string{"b", "a"}
                            defer fmt.Println(words)
                            defer sort.Strings(words)
                            var low byte = lib.Lower("Q")
                            fmt.Println(lib.Sorted([]int{2, 1}), low, low == 113, lib.Text([]byte{low, 33}))
                            total := lib.Count() + 1
                            fmt.Println(total, lib.Lower("Q") + 200, 200 + lib.Lower("Q"), -lib.Lower("Q"))
                        }

                        """)
            ],
            importedPackages: ["example/lib": library])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        // Byte results of imported functions still wrap modulo 256.
        #expect(output == "[1 2] 113 true q!\n42 57 57 143\n[a b]\n")
        let names = Set(executable.functions.map(\.name))
        #expect(names.contains("$native.lib.$sort.Ints.1"))
        #expect(names.contains("$native.main.$sort.Strings.1"))
        #expect(names.count == executable.functions.count)
    }

    @Test func typeCheckerEnforcesSignaturesAndImports() {
        let sort = ["fmt", "sort"]
        #expect(
            goMainDiagnostic("sort.Strings([]int{1})", imports: sort)
                == "cannot use []int as []string value")
        #expect(goMainDiagnostic("sort.Ints(\"x\")", imports: sort) == "cannot use string as []int value")
        #expect(
            goMainDiagnostic("sort.Ints([]byte{1})", imports: sort) == "cannot use []byte as []int value")
        #expect(
            goMainDiagnostic("sort.Ints()", imports: sort)
                == "wrong number of arguments in call to sort.Ints")
        #expect(
            goMainDiagnostic("x := sort.Ints([]int{1})\nfmt.Println(x)", imports: sort)
                == "no value used as value")
        #expect(
            goMainDiagnostic("sort.Float64s([]int{1})", imports: sort) == "undefined: sort.Float64s")
        #expect(goMainDiagnostic("sort.Ints([]int{1})") == "undefined: sort")
        #expect(
            goMainDiagnostic("fmt.Println(strconv.Itoa(\"1\"))", imports: ["fmt", "strconv"])
                == "cannot use string as int value")
        #expect(
            goMainDiagnostic("var n int = strconv.Itoa(1)\nfmt.Println(n)", imports: ["fmt", "strconv"])
                == "cannot use string as int value")
        #expect(
            goMainDiagnostic("a, b := strconv.Itoa(1)\nfmt.Println(a, b)", imports: ["fmt", "strconv"])
                == "assignment mismatch: 2 variables but function returns 1 values")
    }

    @Test func nativesValidateOperandsAndCollectionLimits() throws {
        func run(_ instructions: [GoInstruction]) throws {
            try GoVirtualMachine().run(
                GoExecutable(
                    entryPoint: "main",
                    functions: [
                        GoBytecodeFunction(name: "main", localCount: 0, instructions: instructions)
                    ])
            ) { _ in }
        }
        // A slice holding the wrong element type is rejected, not reordered.
        #expect(throws: GoRuntimeError.typeMismatch) {
            try run([
                .push(.int(0)), .push(.int(1)), .makeSlice(elementCount: 1),
                .call("$sort.Strings", argumentCount: 1), .return,
            ])
        }
        #expect(throws: GoRuntimeError.typeMismatch) {
            try run([.push(.string("x")), .call("$sort.Ints", argumentCount: 1), .return])
        }
        #expect(throws: GoRuntimeError.typeMismatch) {
            try run([.push(.string("1")), .call("$strconv.Itoa", argumentCount: 1), .return])
        }
        #expect(
            throws: GoRuntimeError.argumentCountMismatch(
                function: "$sort.Ints", expected: 1, actual: 2)
        ) {
            try run([
                .push(.nilValue), .push(.nilValue), .call("$sort.Ints", argumentCount: 2), .return,
            ])
        }
        // The slice a program sorts is itself bounded by the collection limit.
        #expect(throws: GoRuntimeError.resourceLimitExceeded("slice elements")) {
            try runGoMain(
                "words := strings.Split(\"i,h,g,f,e,d,c,b,a\", \",\")\nsort.Strings(words)",
                imports: ["sort", "strings"],
                machine: GoVirtualMachine(
                    resourceLimits: GoRuntimeResourceLimits(maximumCollectionElements: 8)))
        }
    }
}
