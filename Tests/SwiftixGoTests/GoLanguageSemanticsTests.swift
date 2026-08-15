/// Go language semantics tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go language semantics")
struct GoLanguageSemanticsTests: GoTestHarness {

    @Test func logicalOperatorsShortCircuit() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    zero := 0
                    if false && (1 / zero > 0) {
                        fmt.Println("unreachable")
                    }
                    if true || (1 / zero > 0) {
                        fmt.Println("short circuit")
                    }
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "short circuit\n")
    }

    @Test func namedStructsSupportZeroValuesLiteralsFieldsAndCopySemantics() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                type Inner struct {
                    Count int
                }

                type Point struct {
                    X int
                    Label string
                    Inner Inner
                }

                func bump(point Point) Point {
                    point.X++
                    point.Inner.Count = point.Inner.Count + 2
                    return point
                }

                func main() {
                    var zero Point
                    point := Point{X: 2, Label: "go", Inner: Inner{Count: 3}}
                    copy := point
                    copy.X = 5
                    point = bump(point)
                    fmt.Println(
                        zero.X,
                        zero.Label == "",
                        point.X,
                        point.Label,
                        point.Inner.Count,
                        copy.X,
                        copy.Inner.Count,
                        point,
                    )
                }
                """)

        let file = try GoParser.parse(source)
        #expect(file.typeDeclarations.map(\.name) == ["Inner", "Point"])
        let typed = try GoTypeChecker.check([file])
        #expect(typed.typeDefinitions.keys.sorted() == ["Inner", "Point"])
        let formatted = try GoFormatter.format(source)
        #expect(formatted.contains("type Point struct {"))
        #expect(formatted.contains("Point{X: 2, Label: \"go\", Inner: Inner{Count: 3}}"))
        #expect(
            try GoFormatter.format(GoSourceFile(path: source.path, text: formatted)) == formatted)

        let executable = try GoCompiler.compile(sources: [source])
        let decoded = try GoExecutableImage.decode(GoExecutableImage.encode(executable))
        #expect(decoded == executable)

        var output = ""
        try GoVirtualMachine().run(decoded) { output += $0 }
        #expect(output == "0 true 3 go 5 5 3 {3 go {5}}\n")
    }

    @Test func pointersAndMethodsPreserveIdentityAndReceiverSemantics() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                type Counter struct { Value int }

                func (counter *Counter) Add(delta int) {
                    counter.Value = counter.Value + delta
                }

                func (counter Counter) Read() int {
                    return counter.Value
                }

                func set(value *int) {
                    *value = 9
                }

                func main() {
                    var empty *int
                    fmt.Println(empty == nil)
                    counter := Counter{Value: 1}
                    counter.Add(2)
                    pointer := &counter
                    pointer.Add(3)
                    fmt.Println(counter.Read(), pointer.Read())

                    value := 1
                    set(&value)
                    field := &counter.Value
                    *field = 10
                    fmt.Println(value, counter.Value)
                }
                """)

        let formatted = try GoFormatter.format(source)
        #expect(formatted.contains("func (counter *Counter) Add(delta int)"))
        #expect(formatted.contains("pointer := &counter"))
        #expect(formatted.contains("*field = 10"))
        #expect(
            try GoFormatter.format(GoSourceFile(path: source.path, text: formatted)) == formatted)

        let executable = try GoCompiler.compile(sources: [source])
        let decoded = try GoExecutableImage.decode(GoExecutableImage.encode(executable))
        var output = ""
        try GoVirtualMachine().run(decoded) { output += $0 }

        #expect(output == "true\n6 6\n9 10\n")
    }

    @Test func arraysSlicesAndStringsFollowGoContainerSemantics() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func main() {
                    array := [3]int{1, 2}
                    copy := array
                    copy[0] = 9
                    slice := array[1:3]
                    slice[0] = 7
                    slice = append(slice, 8)
                    fmt.Println(array, copy, slice, len(slice), cap(slice))

                    made := make([]int, 2, 4)
                    made[0] = 4
                    made = append(made, 6)
                    pointer := &made[1]
                    *pointer = 5
                    fmt.Println(made, len(made), cap(made))

                    var empty []int
                    empty = append(empty, 1)
                    fmt.Println(empty, len(empty), cap(empty))

                    text := "hé"
                    fmt.Println(len(text), text[0], text[:1])
                }
                """)

        let formatted = try GoFormatter.format(source)
        #expect(formatted.contains("[3]int{1, 2}"))
        #expect(formatted.contains("make([]int, 2, 4)"))
        #expect(formatted.contains("text[:1]"))
        #expect(
            try GoFormatter.format(GoSourceFile(path: source.path, text: formatted)) == formatted)

        let executable = try GoCompiler.compile(sources: [source])
        let decoded = try GoExecutableImage.decode(GoExecutableImage.encode(executable))
        var output = ""
        try GoVirtualMachine().run(decoded) { output += $0 }

        #expect(output == "[1 7 0] [9 2 0] [7 0 8] 3 4\n[4 5 6] 3 4\n[1] 1 1\n3 104 h\n")
    }

    @Test func threeClauseForRunsPostOnContinueAndSupportsBreak() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    sum := 0
                    for index := 0; index < 10; index++ {
                        if index == 2 { continue }
                        if index == 6 { break }
                        sum = sum + index
                    }
                    fmt.Println("sum", sum)

                    count := 3
                    for ; count > 0; count-- {
                        fmt.Print(count)
                    }
                    fmt.Println()
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "sum 13\n321\n")
    }

    @Test func expressionAndExpressionlessSwitchSelectOneCase() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    value := 3
                    switch value {
                    default:
                        fmt.Println("default")
                    case 1:
                        fmt.Println("one")
                    case 2, 3:
                        fmt.Println("two or three")
                    }
                    switch {
                    case value < 0:
                        fmt.Println("negative")
                    case value == 3:
                        fmt.Println("three")
                    default:
                        fmt.Println("other")
                    }
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "two or three\nthree\n")
    }

    @Test func forRangeIteratesSliceArrayAndString() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tnums := []int{10, 20, 30}\n\tsum := 0\n\tfor i, v := range nums {\n\t\tsum = sum + v\n\t\tfmt.Print(i)\n\t}\n\tfmt.Println(sum)\n\tarr := [3]string{\"a\", \"b\", \"c\"}\n\tfor _, s := range arr {\n\t\tfmt.Print(s)\n\t}\n\tfmt.Println(\"\")\n\tfor i := range nums {\n\t\tfmt.Print(i)\n\t}\n\tfmt.Println(\"\")\n\tcount := 0\n\tfor range nums {\n\t\tcount = count + 1\n\t}\n\tfmt.Println(count)\n\tfor i, r := range \"A界\" {\n\t\tfmt.Println(i, r)\n\t}\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "01260\nabc\n012\n3\n0 65\n1 30028\n")
    }

    @Test func forRangeBreakAndContinueWork() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tdata := []int{1, 2, 3, 4, 5}\n\tfor _, v := range data {\n\t\tif v == 4 {\n\t\t\tbreak\n\t\t}\n\t\tif v == 2 {\n\t\t\tcontinue\n\t\t}\n\t\tfmt.Println(v)\n\t}\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "1\n3\n")
    }

    @Test func deferExecutesInLIFOOrderOnReturn() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tfmt.Print(\"start \")\n\tdefer fmt.Println(\"third\")\n\tdefer fmt.Println(\"second\")\n\tdefer fmt.Println(\"first\")\n\tfmt.Print(\"end \")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "start end first\nsecond\nthird\n")
    }

    @Test func deferEvaluatesArgumentsImmediately() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tx := 1\n\tdefer fmt.Println(x)\n\tx = 2\n\tfmt.Println(x)\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "2\n1\n")
    }

    @Test func panicTerminatesAndRunsDefers() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tdefer fmt.Println(\"deferred\")\n\tfmt.Println(\"before\")\n\tpanic(\"oops\")\n\tfmt.Println(\"after\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        let error: GoRuntimeError?
        do {
            try GoVirtualMachine().run(executable) { output += $0 }
            error = nil
        } catch let e as GoRuntimeError {
            error = e
        }

        #expect(output == "before\ndeferred\n")
        #expect(error == .panicError("oops"))
    }

    @Test func interfaceSatisfactionAndMethodDispatch() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\ntype Speaker interface {\n\tSpeak() string\n}\ntype Dog struct {\n\tName string\n}\nfunc (d Dog) Speak() string {\n\treturn d.Name + \" says woof\"\n}\ntype Cat struct{}\nfunc (c Cat) Speak() string {\n\treturn \"meow\"\n}\nfunc greet(s Speaker) {\n\tfmt.Println(s.Speak())\n}\nfunc main() {\n\tgreet(Dog{Name: \"Rex\"})\n\tgreet(Cat{})\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "Rex says woof\nmeow\n")
    }

    @Test func mapLiteralIndexingAndDelete() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nfunc main() {\n\tm := map[string]int{\"a\": 1, \"b\": 2, \"c\": 3}\n\tfmt.Println(m[\"a\"], m[\"b\"], len(m))\n\tm[\"d\"] = 4\n\tfmt.Println(m[\"d\"], len(m))\n\tdelete(m, \"b\")\n\tfmt.Println(len(m))\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "1 2 3\n4 4\n3\n")
    }

    @Test func namedResultsAndBareReturnUseLiveResultVariables() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func result() (number int, text string) {
                    number = 7
                    text = "ready"
                    return
                }

                func main() {
                    number, text := result()
                    fmt.Println(number, text)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "7 ready\n")
    }

    @Test func recoverStopsCrossFramePanicAfterAllRequiredDefers() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func fail() {
                    defer fmt.Println("fail defer")
                    panic("boom")
                }

                func wrapper() {
                    defer fmt.Println("wrapper defer")
                    defer func() {
                        value := recover()
                        if value != nil {
                            fmt.Println("recovered", value)
                        }
                    }()
                    fail()
                    fmt.Println("unreachable")
                }

                func main() {
                    wrapper()
                    fmt.Println("continued")
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "fail defer\nrecovered boom\nwrapper defer\ncontinued\n")
    }

    @Test func mapsShareStorageReturnZeroAndRangeOverKeysAndValues() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func add(m map[string]int) {
                    m["b"] = 2
                }

                func main() {
                    values := map[string]int{"a": 1}
                    alias := values
                    add(alias)
                    fmt.Println(values["missing"], len(values))
                    var empty map[string]int
                    fmt.Println(empty["missing"], len(empty))
                    delete(empty, "missing")
                    total := 0
                    for key, value := range values {
                        fmt.Print(key)
                        total = total + value
                    }
                    fmt.Println(total)
                    numbers := map[int]string{1: "one"}
                    present, ok := numbers[1]
                    missing, found := numbers[2]
                    fmt.Println(present, ok, missing, found)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "0 2\n0 0\nab3\none true  false\n")
    }

    @Test func interfaceAssertionsAndBuiltinErrorFollowCommaOkSemantics() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                type problem struct { Message string }
                func (p problem) Error() string { return p.Message }

                func inspect(err error) {
                    concrete, ok := err.(problem)
                    fmt.Println(concrete.Message, ok)
                    _, wrong := err.(string)
                    fmt.Println(wrong)
                }

                func main() {
                    inspect(problem{Message: "broken"})
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "broken true\nfalse\n")
    }

    @Test func switchBreakAndLoopContinueUseNearestTargets() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    total := 0
                    for index := 0; index < 5; index++ {
                        switch index {
                        case 1, 3:
                            continue
                        case 4:
                            break
                            total = 1000
                        }
                        total = total + index
                    }
                    fmt.Println(total)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "6\n")
    }
}
