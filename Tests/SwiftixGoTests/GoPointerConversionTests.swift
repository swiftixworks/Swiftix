/// What Go's `flag` needs of the language, as Go has it: a pointer
/// converts to a pointer type that is not named when what the two point to
/// has one underlying type (`(*boolValue)(p)` for a `*bool`), `new` takes
/// every numeric type, and `os.Args` is a variable a program can assign and
/// write into.
///
/// What the program prints is what Go 1.24.5 printed for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go pointer conversions and os.Args")
struct GoPointerConversionTests {
    @Test func pointersConvertNewTakesNumbersAndArgsIsAVariable() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: source)
        ])
        var output = ""
        try GoVirtualMachine().run(executable, arguments: ["prog"]) { output += $0 }
        #expect(output == expected)
    }

    /// Reading `os.Args` is the instruction it always was.
    @Test func readingArgsCompilesAsBefore() throws {
        let executable = try GoTemporaryElimination.$isEnabled.withValue(false) {
            try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main() { fmt.Println(len(os.Args)) }\n")
            ])
        }
        let main = try #require(executable.functions.first { $0.name == "main" })
        #expect(main.instructions.contains(.osArgs))
        #expect(!main.instructions.contains { if case .call(GoOSArgs.setter, _) = $0 { return true }; return false })
    }
}

private let source = #"""
package main

import (
	"fmt"
	"os"
)

type celsius float64

func (c *celsius) String() string { return fmt.Sprintf("%.1fC", float64(*c)) }

type counter int

func (c *counter) inc() { *c++ }

type point struct{ x, y int }
type vec point

func main() {
	f := 21.5
	c := (*celsius)(&f)
	*c += 1
	fmt.Println(f, c.String())
	n := new(int64)
	*n = 1 << 40
	u := new(uint8)
	*u = 255
	*u++
	fl := new(float64)
	fmt.Println(*n, *u, *fl)
	i := 5
	(*counter)(&i).inc()
	fmt.Println(i)
	p := &point{1, 2}
	v := (*vec)(p)
	v.x = 10
	fmt.Println(*p, v.y)
	fmt.Println(len(os.Args) > 0)
	os.Args = []string{"a", "b"}
	os.Args[1] = "c"
	os.Args = append(os.Args, "d")
	fmt.Println(os.Args, len(os.Args))
}
"""#

private let expected = #"""
22.5 22.5C
1099511627776 0 0
6
{10 2} 2
true
[a c d] 3

"""#
