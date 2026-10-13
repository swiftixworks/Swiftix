/// Programs whose output was produced by Go itself.
///
/// Each `expected` string below is what `go run` of Go 1.24.5 printed for the
/// `source` above it, copied without change except that a space ending a line
/// is written as an escape; the tests require Swiftix Go to print the same
/// bytes. Go prints the address of a pointer, which differs between runs and
/// between the two implementations, so addresses are masked on both sides
/// before comparing.
///
/// To add a case, run the program with Go and paste both texts.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go conformance")
struct GoConformanceTests {

    /// Compiles and runs a whole `package main` and returns its output with
    /// every address replaced by `0xADDR`.
    private func run(_ source: String) throws -> [Substring] {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: source)
        ])
        var output = ""
        try GoVirtualMachine(maximumInstructions: 10_000_000).run(executable) { output += $0 }
        return lines(output)
    }

    private func lines(_ text: String) -> [Substring] {
        text.replacing(/0x[0-9a-f]{9,}/, with: "0xADDR")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Compares line by line, so a failure shows the one line that differs.
    private func expectSameOutput(_ source: String, _ expected: String) throws {
        let actual = try run(source)
        let wanted = lines(expected)
        #expect(actual.count == wanted.count)
        for (number, pair) in zip(actual, wanted).enumerated() {
            #expect(pair.0 == pair.1, "line \(number + 1)")
        }
    }

    @Test func verbsFlagsAndMarkers() throws {
        try expectSameOutput(verbsFlagsAndMarkersSource, verbsFlagsAndMarkersExpected)
    }

    @Test func typesNilsPointersAndMaps() throws {
        try expectSameOutput(typesNilsPointersAndMapsSource, typesNilsPointersAndMapsExpected)
    }

    @Test func argumentIndexesSprintAndCounts() throws {
        try expectSameOutput(argumentIndexesSprintAndCountsSource, argumentIndexesSprintAndCountsExpected)
    }

    @Test func methodsAtEveryDepth() throws {
        try expectSameOutput(methodsAtEveryDepthSource, methodsAtEveryDepthExpected)
    }

    @Test func nilReceiversAndPanickingMethods() throws {
        try expectSameOutput(nilReceiversAndPanickingMethodsSource, nilReceiversAndPanickingMethodsExpected)
    }

    @Test func valuesInInterfaces() throws {
        try expectSameOutput(valuesInInterfacesSource, valuesInInterfacesExpected)
    }

    @Test func assertionsToInterfaces() throws {
        try expectSameOutput(assertionsToInterfacesSource, assertionsToInterfacesExpected)
    }

    @Test func interfaceMethodsWithSeveralResults() throws {
        try expectSameOutput(interfaceMethodsWithSeveralResultsSource, interfaceMethodsWithSeveralResultsExpected)
    }

    @Test func variadicInterfaceMethodsAndFinalPanic() throws {
        try expectSameOutput(variadicInterfaceMethodsAndFinalPanicSource, variadicInterfaceMethodsAndFinalPanicExpected)
    }

    @Test func errorIdentityWrappingIsAndAs() throws {
        try expectSameOutput(errorIdentityWrappingIsAndAsSource, errorIdentityWrappingIsAndAsExpected)
    }

    @Test func variadicFunctionsAndSpreads() throws {
        try expectSameOutput(variadicFunctionsAndSpreadsSource, variadicFunctionsAndSpreadsExpected)
    }

    @Test func ifAndSwitchInitializers() throws {
        try expectSameOutput(ifAndSwitchInitializersSource, ifAndSwitchInitializersExpected)
    }

    @Test func runTimeErrorsAreRecoverablePanics() throws {
        try expectSameOutput(runTimeErrorsAreRecoverablePanicsSource, runTimeErrorsAreRecoverablePanicsExpected)
    }

    @Test func compositeLiteralsAndTheirAddresses() throws {
        try expectSameOutput(compositeLiteralsAndTheirAddressesSource, compositeLiteralsAndTheirAddressesExpected)
    }

    @Test func parallelAssignmentAndSeveralNames() throws {
        try expectSameOutput(parallelAssignmentAndSeveralNamesSource, parallelAssignmentAndSeveralNamesExpected)
    }

    @Test func eachIterationHasItsOwnVariables() throws {
        try expectSameOutput(eachIterationHasItsOwnVariablesSource, eachIterationHasItsOwnVariablesExpected)
    }

    @Test func groupedDeclarationsAndIota() throws {
        try expectSameOutput(groupedDeclarationsAndIotaSource, groupedDeclarationsAndIotaExpected)
    }

    @Test func importNamesAndTheProgramsOwnNames() throws {
        try expectSameOutput(importNamesAndTheProgramsOwnNamesSource, importNamesAndTheProgramsOwnNamesExpected)
    }

    @Test func importNamesAtTheEdges() throws {
        try expectSameOutput(importNamesAtTheEdgesSource, importNamesAtTheEdgesExpected)
    }

    @Test func typesDeclaredInFunctions() throws {
        try expectSameOutput(typesDeclaredInFunctionsSource, typesDeclaredInFunctionsExpected)
    }

    @Test func localTypesInAssertions() throws {
        try expectSameOutput(localTypesInAssertionsSource, localTypesInAssertionsExpected)
    }
}

private let verbsFlagsAndMarkersSource = #"""
package main

import "errors"
import "fmt"

type point struct {
	x    int
	name string
}

type pair struct {
	first  point
	second []int
}

var errBoom = errors.New("boom")

func main() {
	fmt.Println(fmt.Sprintf("%d|%5d|%-5d|%05d|%+d|% d", 42, 42, 42, 42, 42, 42))
	fmt.Println(fmt.Sprintf("%d %d %v %+v", -7, 0, -7, 7))
	fmt.Println(fmt.Sprintf("%05d|%+05d|% 05d|%-05d|", -42, 42, 42, 42))
	fmt.Println(fmt.Sprintf("%.3d|%8.3d|%-8.3d|%08.3d|", 7, 7, 7, 7))
	fmt.Println(fmt.Sprintf("[%.0d][%3.0d][%.0d]", 0, 0, 5))
	fmt.Println(fmt.Sprintf("%x %X %#x %#X %08x %#08x", 255, 255, 255, 255, 255, 255))
	fmt.Println(fmt.Sprintf("%x %#x %d", -255, -255, -9223372036854775807-1))
	fmt.Println(fmt.Sprintf("%b %o %#o %O %#b %8b|", 10, 10, 10, 10, 10, 5))
	fmt.Println(fmt.Sprintf("%c%c|%3c|%-3c|%q %q %+q", 72, 19990, 65, 65, 65, 10, 233))
	fmt.Println(fmt.Sprintf("%U %#U %U %.6U", 65, 65, 128512, 65))
	fmt.Println(fmt.Sprintf("%c|%c", -1, 1114112))
	fmt.Println(fmt.Sprintf("%08U|%-8U|%#x|%#o|%+x|% x|%+c|%05c", 65, 65, 0, 0, 255, 255, 65, 65))
	fmt.Println(fmt.Sprintf("%+.3d|% .3d|%+5.2d|%-+6d|%- 6d|%+-6d|", 7, 7, 7, 7, 7, 7))
	fmt.Println(fmt.Sprintf("%3q|%-5q|%05q|%#q|%#U|%#U", 65, 65, 65, 65, 10, 233))

	data := []byte("hi")
	numbers := []int{104, 105}
	fmt.Println(fmt.Sprintf("%v %d %s %x %X %q %c", data, data, data, data, data, data, data))
	fmt.Println(fmt.Sprintf("%v %x %c", numbers, numbers, numbers))
	fmt.Println(fmt.Sprintf("% x|%# x|%#x|%.1x|%5s|%-5s|", data, data, data, data, data, data))
	var none []byte
	fmt.Println(fmt.Sprintf("[%s][%x][%q]", none, none, none))
	fmt.Println(fmt.Sprintf("%s %x", data[1:], []byte{0, 171, 255}))
	fmt.Println(fmt.Sprintf("%3d|%03d|%-3d|%+d|%o|%b", data, data, data, data, data, data))
	fmt.Println(fmt.Sprintf("%8x|%-8x|%08x|% X|%#X|%.0x|", data, data, data, data, data, data))

	fmt.Println(fmt.Sprintf("%s|%10s|%-10s|%.2s|%v|%6v|", "hello", "hello", "hello", "hello", "hi", "ab"))
	fmt.Println(fmt.Sprintf("%x|%X|% x|%#x|%.2x|[%5x]|[%x]", "hello", "hello", "hello", "hello", "hello", "", ""))
	fmt.Println(fmt.Sprintf("%05s|%-05s|%05t", "ab", "ab", true))
	fmt.Println(fmt.Sprintf("%q %q %q", "a\tb\"c\n", "\x00\x7f", "é世"))
	fmt.Println(fmt.Sprintf("%+q %#q %#q %8q|%.2q", "é", "hi", "a`b", "x", "hello"))
	fmt.Println(fmt.Sprintf("%5s|%-4s|%.1s|%3c|", "世界", "é", "世界", 19990))
	fmt.Println(fmt.Sprintf("%t %v %5t|%-6t|", true, false, true, false))
	fmt.Println(fmt.Sprintf("100%% %5% %d%%", 7))
	fmt.Println(fmt.Sprintf("%8x|%-8x|%08x|% X|%# X|%#.1x|%+q|%#+q|%-8q|", "ab", "ab", "ab", "ab", "ab", "ab", "aé\x01", "é", "x"))
	fmt.Println(fmt.Sprintf("%q|%q|%q|%+q", "\u2028\ufeff", "\u00a0\u00ad", "😀\U0010ffff", "😀"))
	fmt.Println(fmt.Sprintf("%.0s|%.10s|%2.1s|%-2.1s|%c", "abc", "abc", "abc", "abc", 233))

	fmt.Println(fmt.Sprintf("%v %d %3d %x %s", []int{1, 2, 3}, []int{1, 2, 3}, []int{1, 2, 3}, []int{10, 255}, []int{7}))
	fmt.Println(fmt.Sprintf("%s %q %v %5s|", []string{"a", "b"}, []string{"a", "b"}, []string{}, []string{"ab"}))
	fmt.Println(fmt.Sprintf("%v %+v %d %s", point{x: 1, name: "a"}, point{x: 1, name: "a"}, point{x: 1, name: "a"}, point{x: 1, name: "a"}))
	fmt.Println(fmt.Sprintf("%v|%+v", pair{first: point{x: 2, name: "b"}, second: []int{3, 4}}, pair{first: point{x: 2, name: "b"}, second: []int{3, 4}}))
	fmt.Println(fmt.Sprintf("%v %d %x", map[string]int{"a": 1, "b": 20}, map[string]int{"k": 7}, map[int]string{255: "hi"}))
	fmt.Println(fmt.Sprintf("%v %t %v", [][]int{[]int{1}, []int{2, 3}}, []bool{true, false}, [2]int{4, 5}))
	fmt.Println(fmt.Sprintf("%5v|%-5v|%05v|%x|%X|%q", []int{1, 22}, []int{1, 22}, []int{1, 22}, []string{"a", "bc"}, point{x: 255, name: "z"}, point{x: 65, name: "z"}))
	fmt.Println(fmt.Sprintf("%v %v %s %d", []bool{}, [0]int{}, []string{"x", ""}, [][]int{[]int{}, []int{1}}))

	var noError error
	var boxed any = 12
	fmt.Println(fmt.Sprintf("%v|%s|%q|%x|%10v|%-6s|", errBoom, errBoom, errBoom, errBoom, errBoom, errBoom))
	fmt.Println(fmt.Sprintf("%d %t", errBoom, errBoom))
	fmt.Println(fmt.Sprintf("%v|%6v|%s|%d|%+v", noError, noError, noError, nil, nil))
	fmt.Println(fmt.Sprintf("%v %d %05d %s", boxed, boxed, boxed, boxed))
	wrapped := fmt.Errorf("open %s: %w (try %d)", "/data", errBoom, 2)
	fmt.Println(wrapped.Error(), wrapped != nil, wrapped)
	fmt.Println(fmt.Sprintf("%w", errBoom), fmt.Errorf("plain").Error())
	fmt.Println(fmt.Sprintf("%+v|%.2v|%.2s|%X|%+q|%5q|", errBoom, errBoom, errBoom, errBoom, errBoom, errBoom))

	fmt.Println(fmt.Sprintf("%d %s %t %z %f %!", "hi", 5, 1, 1, 3, 1))
	fmt.Println(fmt.Sprintf("%d %x %c", true, false, true))
	fmt.Println(fmt.Sprintf("%d %d|%s", 1))
	fmt.Println(fmt.Sprintf("%d", 1, 2))
	fmt.Println(fmt.Sprintf("hi", "x", 3, true, nil, errBoom))
	fmt.Println(fmt.Sprintf("100%"))
	fmt.Println(fmt.Sprintf("%5"))
	fmt.Println(fmt.Sprintf("%-"))
	fmt.Println(fmt.Sprintf("%."))
	fmt.Println(fmt.Sprintf("%5.d|%.d|%5.s|%+s|% s|%#s|%0s|", 0, 3, "abc", "p", "q", "r", "s"))
	fmt.Println(fmt.Sprintf("%é %世 %d", 1, 2, 3))
	fmt.Println(fmt.Sprintf("%t %s %q %x %U", 5, true, true, true, "a"))
	fmt.Println(fmt.Sprintf("%c %b %o %U %O", "a", "a", "a", true, "a"))

	fmt.Println(fmt.Sprintf("%*d|%-*d|%.*s|%*.*s|", 5, 42, 5, 42, 2, "hello", 6, 3, "hello"))
	fmt.Println(fmt.Sprintf("%*d|%.*d|", -5, 42, -1, 7))
	fmt.Println(fmt.Sprintf("%*d", "x", 42))
	fmt.Println(fmt.Sprintf("%.*d", "x", 42))
	fmt.Println(fmt.Sprintf("%*d"))
	fmt.Println(fmt.Sprintf("%*d", 1000001, 3))
	fmt.Println(fmt.Sprintf("%0*d|%-0*d|%*s|%.*x|", 5, 42, 5, 42, -4, "ab", 1, "abc"))
	fmt.Println(fmt.Sprintf("%*", 3), fmt.Sprintf("%.*", 3), fmt.Sprintf("%*.*d", 4))
}
"""#

private let verbsFlagsAndMarkersExpected = #"""
42|   42|42   |00042|+42| 42
-7 0 -7 7
-0042|+0042| 0042|42   |
007|     007|007     |     007|
[][   ][5]
ff FF 0xff 0XFF 000000ff 0x000000ff
-ff -0xff -9223372036854775808
1010 12 012 0o12 0b1010      101|
H世|  A|A  |'A' '\n' '\u00e9'
U+0041 U+0041 'A' U+1F600 U+000041
�|�
  U+0041|U+0041  |0x0|0|+ff| ff|A|0000A
+007| 007|  +07|+7    | 7    |+7    |
'A'|'A'  |00'A'|'A'|U+000A|U+00E9 'é'
[104 105] [104 105] hi 6869 6869 "hi" [h i]
[104 105] [68 69] [h i]
68 69|0x68 0x69|0x6869|68|   hi|hi   |
[][][""]
i 00abff
[104 105]|[104 105]|[104 105]|[+104 +105]|[150 151]|[1101000 1101001]
    6869|6869    |00006869|68 69|0X6869||
hello|     hello|hello     |he|hi|    ab|
68656c6c6f|68656C6C6F|68 65 6c 6c 6f|0x68656c6c6f|6865|[     ]|[]
000ab|ab   |0true
"a\tb\"c\n" "\x00\x7f" "é世"
"\u00e9" `hi` "a`b"      "x"|"he"
   世界|é   |世|  世|
true false  true|false |
100% % 7%
    6162|6162    |00006162|61 62|0X61 0X62|0x61|"a\u00e9\x01"|`é`|"x"     |
"\u2028\ufeff"|"\u00a0\u00ad"|"😀\U0010ffff"|"\U0001f600"
|abc| a|a |é
[1 2 3] [1 2 3] [  1   2   3] [a ff] [%!s(int=7)]
[a b] ["a" "b"] [] [   ab]|
{1 a} {x:1 name:a} {1 %!d(string=a)} {%!s(int=1) a}
{{2 b} [3 4]}|{first:{x:2 name:b} second:[3 4]}
map[a:1 b:20] map[%!d(string=k):7] map[ff:6869]
[[1] [2 3]] [true false] [4 5]
[    1    22]|[1     22   ]|[00001 00022]|[61 6263]|{FF 7A}|{'A' "z"}
[] [] [x ] [[] [1]]
boom|boom|"boom"|626f6f6d|      boom|boom  |
&{%!d(string=boom)} &{%!t(string=boom)}
<nil>| <nil>|%!s(<nil>)|%!d(<nil>)|<nil>
12 12 00012 %!s(int=12)
open /data: boom (try 2) true open /data: boom (try 2)
%!w(*errors.errorString=&{boom}) plain
boom|bo|bo|626F6F6D|"boom"|"boom"|
%!d(string=hi) %!s(int=5) %!t(int=1) %!z(int=1) %!f(int=3) %!!(int=1)
%!d(bool=true) %!x(bool=false) %!c(bool=true)
1 %!d(MISSING)|%!s(MISSING)
1%!(EXTRA int=2)
hi%!(EXTRA string=x, int=3, bool=true, <nil>, *errors.errorString=boom)
100%!(NOVERB)
%!(NOVERB)
%!(NOVERB)
%!.(MISSING)
     |3|     |p|q|r|s|
%!é(int=1) %!世(int=2) 3
%!t(int=5) %!s(bool=true) %!q(bool=true) %!x(bool=true) %!U(string=a)
%!c(string=a) %!b(string=a) %!o(string=a) %!U(bool=true) %!O(string=a)
   42|42   |he|   hel|
42   |%!(BADPREC)7|
%!(BADWIDTH)42
%!(BADPREC)42
%!(BADWIDTH)%!d(MISSING)
%!(BADWIDTH)3
00042|42   |ab  |61|
%!(NOVERB) %!(NOVERB) %!(BADPREC)%!d(MISSING)

"""#

private let typesNilsPointersAndMapsSource = #"""
package main

import "errors"
import "fmt"

type point struct {
	x    int
	name string
}

type pair struct {
	first  point
	second []int
	third  map[string]int
	fourth *point
	raw    []byte
	flag   bool
	any    any
	err    error
	b      byte
}

type level int

type label string

type buffer []byte

type table map[string]int

type grid [2]point

var errBoom = errors.New("boom")

func main() {
	var nilInts []int
	var nilMap map[string]int
	var nilPoint *point
	var nilBytes []byte
	var nilErr error
	var nilAny any
	p := point{x: 1, name: "a"}
	ptr := &p
	numbers := []int{3, 1, 2}
	data := []byte("hi")
	var letter byte = 65
	ages := map[string]int{"zed": 26, "amy": 1, "bob": 2}
	byNumber := map[int]string{30: "c", -1: "a", 2: "b"}
	flags := map[bool]int{true: 1, false: 0}
	var lvl level = 3
	lbl := label("tag")
	buf := buffer([]byte("xy"))
	tbl := table{"k": 1}
	var g grid
	g[1].x = 9
	var whole pair
	whole.first = p
	whole.second = numbers
	whole.b = 7

	fmt.Println(nilInts, nilMap, nilPoint, nilBytes, nilErr, nilAny)
	fmt.Println(p, ptr == nil, numbers, data, letter, ages, byNumber, flags)
	fmt.Println(lvl, lbl, buf, tbl, g, whole)
	fmt.Print(1, 2, "a", "b", 3, 4, "c", 5, true, false, "\n")
	fmt.Print("x", 1, 2, nilInts, numbers, "y", p, lvl, lbl, "\n")
	fmt.Print(lbl, lbl, 1, lbl, "\n")

	fmt.Println(fmt.Sprintf("%v|%d|%s|%x|%q", nilInts, nilInts, nilInts, nilInts, nilInts))
	fmt.Println(fmt.Sprintf("%v|%d|%s|%x|%q", nilBytes, nilBytes, nilBytes, nilBytes, nilBytes))
	fmt.Println(fmt.Sprintf("%v|%d|%s", nilMap, nilMap, nilMap))
	fmt.Println(fmt.Sprintf("%v|%d|%s|%+v", nilPoint, nilPoint, nilPoint, nilPoint))
	fmt.Println(fmt.Sprintf("%v|%d|%s|%+v", nilErr, nilErr, nilAny, nilAny))
	fmt.Println(fmt.Sprintf("%v|%+v|%d|%s", whole, whole, whole.b, whole.raw))

	fmt.Println(fmt.Sprintf("%T|%T|%T|%T|%T|%T", 1, "a", true, letter, nilInts, nilMap))
	fmt.Println(fmt.Sprintf("%T|%T|%T|%T|%T|%T", p, ptr, nilPoint, numbers, data, ages))
	fmt.Println(fmt.Sprintf("%T|%T|%T|%T|%T|%T", lvl, lbl, buf, tbl, g, whole))
	fmt.Println(fmt.Sprintf("%T|%T|%T|%T|%10T|%-8T|%.3T|", nilErr, nilAny, errBoom, nil, 1, "a", true))
	fmt.Println(fmt.Sprintf("%T|%T|%T", [][]string{}, map[int][]byte{}, [3]bool{}))

	fmt.Println(fmt.Sprintf("%#v|%#v|%#v|%#v|%#v", 1, "a\n", true, letter, -5))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v|%#v", nilInts, nilMap, nilPoint, nilBytes))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v", nilErr, nilAny, errBoom))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v", p, numbers, data))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v", ages, byNumber, flags))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v|%#v|%#v", lvl, lbl, buf, tbl, g))
	fmt.Println(fmt.Sprintf("%#v", whole))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v", []string{"a", "b"}, [2]bool{true, false}, []point{p}))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v", []any{1, "a", nil}, map[string]any{"k": 1}, [][]int{[]int{1}, nil}))
	fmt.Println(fmt.Sprintf("%#v|%#v|%#v", []error{errBoom, nil}, []byte{}, []int{}))

	fmt.Println(fmt.Sprintf("%v|%+v|%s|%d", ptr, ptr, ptr, ptr))
	fmt.Println(fmt.Sprintf("%v|%v|%v", &numbers, &ages, &g))
	fmt.Println(fmt.Sprintf("%#v|%#v", ptr, &numbers))

	fmt.Println(fmt.Sprintf("%v %d %s %x %X %q %c %U", letter, letter, letter, letter, letter, letter, letter, letter))
	fmt.Println(fmt.Sprintf("%v %d %s %x %q", lvl, lvl, lvl, lbl, lbl))
	fmt.Println(fmt.Sprintf("%v %s %x %q %d", buf, buf, buf, buf, buf))
	fmt.Println(fmt.Sprintf("%s %d %t", []byte("a"), "x", data))
	fmt.Println(fmt.Sprintf("%d|%s", 1, 2, letter, lvl, lbl, data, numbers, p, ptr == nil, nilInts, nilMap, errBoom, nil))
	fmt.Println(fmt.Sprintf("%z %z %z %z %z", letter, lvl, numbers, p, nilInts))
	fmt.Println(fmt.Sprintf("%p|%p|%p|%p", 5, "a", nil, nilPoint), fmt.Sprintf("%p", nilInts), fmt.Sprintf("%p", nilMap))
	fmt.Println(fmt.Sprintf("%v|%s|%d", []*point{nil}, []error{nil}, []any{nil, 1, "a", true}))
	fmt.Println(fmt.Sprintf("%5v|%-5v|%05v", ages, flags, byNumber))
	fmt.Println(fmt.Sprintf("%v %v", map[point]int{point{x: 2, name: "b"}: 1, point{x: 1, name: "z"}: 2, point{x: 1, name: "a"}: 3}, map[[2]int]string{[2]int{2, 1}: "x", [2]int{1, 9}: "y"}))
}
"""#

private let typesNilsPointersAndMapsExpected = #"""
[] map[] <nil> [] <nil> <nil>
{1 a} false [3 1 2] [104 105] 65 map[amy:1 bob:2 zed:26] map[-1:a 2:b 30:c] map[false:0 true:1]
3 tag [120 121] map[k:1] [{0 } {9 }] {{1 a} [3 1 2] map[] <nil> [] false <nil> <nil> 7}
1 2ab3 4c5 true false
x1 2 [] [3 1 2]y{1 a} 3tag
tagtag1tag
[]|[]|[]|[]|[]
[]|[]|||""
map[]|map[]|map[]
<nil>|0|%!s(*main.point=<nil>)|<nil>
<nil>|%!d(<nil>)|%!s(<nil>)|<nil>
{{1 a} [3 1 2] map[] <nil> [] false <nil> <nil> 7}|{first:{x:1 name:a} second:[3 1 2] third:map[] fourth:<nil> raw:[] flag:false any:<nil> err:<nil> b:7}|7|
int|string|bool|uint8|[]int|map[string]int
main.point|*main.point|*main.point|[]int|[]uint8|map[string]int
main.level|main.label|main.buffer|main.table|main.grid|main.pair
<nil>|<nil>|*errors.errorString|<nil>|       int|string  |boo|
[][]string|map[int][]uint8|[3]bool
1|"a\n"|true|0x41|-5
[]int(nil)|map[string]int(nil)|(*main.point)(nil)|[]byte(nil)
<nil>|<nil>|&errors.errorString{s:"boom"}
main.point{x:1, name:"a"}|[]int{3, 1, 2}|[]byte{0x68, 0x69}
map[string]int{"amy":1, "bob":2, "zed":26}|map[int]string{-1:"a", 2:"b", 30:"c"}|map[bool]int{false:0, true:1}
3|"tag"|main.buffer{0x78, 0x79}|main.table{"k":1}|main.grid{main.point{x:0, name:""}, main.point{x:9, name:""}}
main.pair{first:main.point{x:1, name:"a"}, second:[]int{3, 1, 2}, third:map[string]int(nil), fourth:(*main.point)(nil), raw:[]uint8(nil), flag:false, any:interface {}(nil), err:error(nil), b:0x7}
[]string{"a", "b"}|[2]bool{true, false}|[]main.point{main.point{x:1, name:"a"}}
[]interface {}{1, "a", interface {}(nil)}|map[string]interface {}{"k":1}|[][]int{[]int{1}, []int(nil)}
[]error{(*errors.errorString)(0x1003051c0), error(nil)}|[]byte{}|[]int{}
&{1 a}|&{x:1 name:a}|&{%!s(int=1) a}|&{1 %!d(string=a)}
&[3 1 2]|&map[amy:1 bob:2 zed:26]|&[{0 } {9 }]
&main.point{x:1, name:"a"}|&[]int{3, 1, 2}
65 65 %!s(uint8=65) 41 41 'A' A U+0041
3 3 %!s(main.level=3) 746167 "tag"
[120 121] xy 7879 "xy" [120 121]
a %!d(string=x) [%!t(uint8=104) %!t(uint8=105)]
1|%!s(int=2)%!(EXTRA uint8=65, main.level=3, main.label=tag, []uint8=[104 105], []int=[3 1 2], main.point={1 a}, bool=false, []int=[], map[string]int=map[], *errors.errorString=boom, <nil>)
%!z(uint8=65) %!z(main.level=3) [%!z(int=3) %!z(int=1) %!z(int=2)] {%!z(int=1) %!z(string=a)} []
%!p(int=5)|%!p(string=a)|%!p(<nil>)|0x0 0x0 0x0
[<nil>]|[<nil>]|[<nil> 1 %!d(string=a) %!d(bool=true)]
map[  amy:    1   bob:    2   zed:   26]|map[false:0     true :1    ]|map[-0001:0000a 00002:0000b 00030:0000c]
map[{1 a}:3 {1 z}:2 {2 b}:1] map[[1 9]:y [2 1]:x]

"""#

private let argumentIndexesSprintAndCountsSource = #"""
package main

import "errors"
import "fmt"
import "os"

type point struct {
	x    int
	name string
}

func main() {
	fmt.Println(fmt.Sprintf("%[2]d %[1]d", 1, 2))
	fmt.Println(fmt.Sprintf("%[1]d %[1]x %[1]o %[1]q", 65))
	fmt.Println(fmt.Sprintf("%[3]*.[2]*[1]d|", 12, 4, 8))
	fmt.Println(fmt.Sprintf("%[2]*[1]d|%[1]*d|", 5, 3))
	fmt.Println(fmt.Sprintf("%d %d %[1]d %d", 1, 2, 3))
	fmt.Println(fmt.Sprintf("%[1]d", 5), fmt.Sprintf("%[2]d", 5), fmt.Sprintf("%[0]d", 5), fmt.Sprintf("%[-1]d", 5))
	fmt.Println(fmt.Sprintf("%[x]d", 5), fmt.Sprintf("%[1", 5), fmt.Sprintf("%[]d", 5), fmt.Sprintf("%[1]", 5))
	fmt.Println(fmt.Sprintf("%[1]2d", 5), fmt.Sprintf("%[1].2d", 5), fmt.Sprintf("%.[1]*d", 3, 7), fmt.Sprintf("%[2]d %d", 1, 2))
	fmt.Println(fmt.Sprintf("%[1]s %[1]q %[1]v %[2]T %[2]v", "a", point{x: 1, name: "b"}))
	fmt.Println(fmt.Sprintf("%[3]v %[1]v", 1, 2, 3, 4), fmt.Sprintf("%[1]d %d %d", 1, 2, 3), fmt.Sprintf("%[5]d", 1))
	fmt.Println(fmt.Sprintf("%[1]*d|%[2]*[1]d|%-[1]*d|", 3, 5))

	fmt.Println(fmt.Sprint("a", "b", 1, 2, "c", 3, true, nil, 4))
	fmt.Println(fmt.Sprint(), fmt.Sprint(1), fmt.Sprint("x"), fmt.Sprint(1, 2), fmt.Sprint(nil, nil), fmt.Sprint([]int{1}, []int{2}))
	fmt.Print(fmt.Sprintln("a", 1, true, nil, []string{"x"}, point{x: 2, name: "p"}))
	fmt.Print(fmt.Sprintln(), fmt.Sprintln("x"), fmt.Sprint(errors.New("e1"), errors.New("e2")), "\n")
	fmt.Println(len(fmt.Sprintln("ab", "cd")), len(fmt.Sprint("ab", "cd")), len(fmt.Sprint(1, 2)))

	n, err := fmt.Println("count me", 1)
	fmt.Println(n, err)
	n, err = fmt.Print("é\n")
	fmt.Println(n, err == nil)
	n, err = fmt.Printf("%05d|%s\n", 42, "x")
	fmt.Println(n, err)
	n, err = fmt.Fprintf(os.Stdout, "%v\n", []int{1, 2})
	fmt.Println(n, err)
	n, err = fmt.Fprintln(os.Stdout, "a", "b")
	fmt.Println(n, err)
	n, err = fmt.Fprint(os.Stdout, 1, 2, "x\n")
	fmt.Println(n, err)
	n, err = fmt.Print()
	fmt.Println(n, err)
	forwarded, forwardedErr := counted()
	fmt.Println(forwarded, forwardedErr)
}

func counted() (int, error) {
	return fmt.Println("forwarded")
}
"""#

private let argumentIndexesSprintAndCountsExpected = #"""
2 1
65 41 101 'A'
    0012|
  5|    3|
1 2 1 2
5 %!d(BADINDEX) %!d(BADINDEX) %!d(BADINDEX)
%!d(BADINDEX) %!(NOVERB) %!d(BADINDEX) %!(NOVERB)
%!d(BADINDEX) %!d(BADINDEX) 007 2 %!d(MISSING)
a "a" a main.point {1 b}
3 1 1 2 3 %!d(BADINDEX)
  5|    3|5  |
ab1 2c3 true <nil> 4
 1 x 1 2 <nil> <nil> [1] [2]
a 1 true <nil> [x] {2 p}

x
e1 e2
6 4 3
count me 1
11 <nil>
é
3 true
00042|x
8 <nil>
[1 2]
6 <nil>
a b
4 <nil>
1 2x
5 <nil>
0 <nil>
forwarded
10 <nil>

"""#

private let methodsAtEveryDepthSource = #"""
package main

import "errors"
import "fmt"
import "os"

type celsius int

func (c celsius) String() string {
	return fmt.Sprintf("%d°C", int(c))
}

type point struct {
	x int
	y int
}

func (p point) String() string {
	return fmt.Sprintf("(%d,%d)", p.x, p.y)
}

type failure struct {
	code   int
	reason string
}

func (f failure) Error() string {
	return fmt.Sprintf("failure %d: %s", f.code, f.reason)
}

type ptrErr struct {
	msg string
}

func (e *ptrErr) Error() string {
	return "ptr: " + e.msg
}

type both struct {
	n int
}

func (b both) Error() string {
	return "error wins"
}

func (b both) String() string {
	return "string loses"
}

type counter struct {
	n int
}

func (c *counter) String() string {
	return fmt.Sprintf("counter(%d)", c.n)
}

type plain struct {
	a int
	s celsius
}

type shape interface{ Area() int }

type square struct {
	side int
}

func (s *square) Area() int {
	return s.side * s.side
}

func (s *square) String() string {
	return "square"
}

type report struct {
	Temp   celsius
	hidden celsius
	At     point
	Err    error
	inner  []celsius
	Open   []celsius
}

type noisy int

var calls int

func (n noisy) String() string {
	calls = calls + 1
	return fmt.Sprintf("noisy%d#%d", int(n), calls)
}

type odd int

func (o odd) String(extra int) string {
	return "never"
}

func find(code int) error {
	if code == 0 {
		return nil
	}
	return failure{code: code, reason: "nope"}
}

func broken() error {
	var e ptrErr
	e.msg = "boom"
	return &e
}

func typedNil() error {
	var e *ptrErr
	return e
}

func describe(v any) string {
	return fmt.Sprintf("%v/%T", v, v)
}

func main() {
	var c celsius = 21
	p := point{x: 1, y: 2}
	f := failure{code: 7, reason: "bad"}
	var pe ptrErr
	pe.msg = "boom"
	b := both{n: 1}
	var cnt counter
	cnt.n = 5
	fmt.Println(c, p, f, &pe, b, &cnt, cnt)
	fmt.Println(fmt.Sprintf("%v|%s|%d|%q|%x|%5v|%T", c, c, c, c, c, c, c))
	fmt.Println(fmt.Sprintf("%v|%+v|%s|%d|%#v|%T", p, p, p, p, p, p))
	fmt.Println(fmt.Sprintf("%v|%s|%d|%q|%T|%#v", f, f, f, f, f, f))
	fmt.Println(fmt.Sprintf("%v|%s|%T", &pe, &pe, &pe), fmt.Sprintf("%v|%d", pe, pe))
	fmt.Println(fmt.Sprintf("%v|%s|%v|%T|%T", &cnt, &cnt, cnt, &cnt, cnt))
	fmt.Println(fmt.Sprintf("%v %s", b, b))
	err := find(3)
	fmt.Println(err, fmt.Sprintf("%v|%s|%q|%d", err, err, err, err), find(0))
	e2 := broken()
	fmt.Println(e2, e2.Error(), fmt.Sprintf("[%v] [%10s] [%-12v] %T", e2, e2, e2, e2))
	e3 := typedNil()
	fmt.Println(e3 == nil, e3 != nil, fmt.Sprintf("%T", e3))
	var any1 any = c
	var any2 any = p
	fmt.Println(any1, any2, fmt.Sprintf("%v %v %d", any1, any2, any1))
	fmt.Print(c, c, p, "x", f, "\n")
	fmt.Println(fmt.Sprint(c, p), fmt.Sprintln(c, f))
	fmt.Println(fmt.Sprintf("%z|%z|%!|", c, p, f), fmt.Sprintf("%d", c, p))
	fmt.Println(fmt.Errorf("wrap: %w", err), fmt.Errorf("wrap: %v", f), errors.New("x"))
	fmt.Printf("%v %s\n", c, p)
	fmt.Fprintln(os.Stdout, c, p, f)
	fmt.Println(describe(c), describe(p), describe(&cnt), describe(5), describe("s"), describe(nil), describe([]int{1}))
	var sq square
	sq.side = 3
	var sh shape = &sq
	fmt.Println(sh.Area(), sh, fmt.Sprintf("%v %T", sh, sh))
	values := []any{c, p, f, &cnt, 1, "s", nil}
	for _, v := range values {
		fmt.Print(describe(v), " ")
	}
	fmt.Println()
	fmt.Println([]celsius{1, 2}, map[string]celsius{"a": 3}, plain{a: 1, s: 30}, []point{p}, []error{err, nil, errors.New("n")})
	fmt.Println(fmt.Sprintf("%v|%s|%d|%q|%x", []celsius{1, 2}, []celsius{1, 2}, []celsius{1, 2}, []celsius{7}, []celsius{8}))
	rep := report{Temp: 1, hidden: 2, At: p, Err: err, inner: []celsius{3}, Open: []celsius{4}}
	fmt.Println(rep)
	fmt.Println(fmt.Sprintf("%+v|%s", rep, rep))
	fmt.Println([]*counter{&cnt}, map[celsius]point{5: p}, [2]celsius{6, 7}, []any{c, p, 1})
	fmt.Println(fmt.Sprintf("%d %d %x", noisy(1), noisy(2), noisy(3)), calls)
	fmt.Println(fmt.Sprintf("%v %v %s %d %q", noisy(1), noisy(2), noisy(3), noisy(4), noisy(5)), calls)
	padded := fmt.Sprintf("%5v|%-12v|", noisy(9), noisy(10))
	fmt.Println(padded, calls)
	fmt.Println([]noisy{7, 8}, map[noisy]noisy{1: 2})
	fmt.Println(calls)
	fmt.Println(odd(3), fmt.Sprintf("%v %s", odd(4), odd(5)))
	fmt.Println(fmt.Sprintf("%v %v", &p, &f), fmt.Sprintf("%s", []*point{&p}) != "")
	got, ok := any1.(celsius)
	fmt.Println(got, ok)
	asInt, isInt := any1.(int)
	fmt.Println(asInt, isInt)
	asPoint, isPoint := any2.(point)
	fmt.Println(asPoint, isPoint, asPoint.x)
	asErr, isFailure := err.(failure)
	fmt.Println(asErr.code, isFailure)
	asPtr, isPtr := e2.(*ptrErr)
	fmt.Println(asPtr.msg, isPtr)
	var list any = []int{1, 2}
	ints, isList := list.([]int)
	fmt.Println(ints, isList, len(ints))
	words, isWords := list.([]string)
	fmt.Println(words, isWords)
	var m any = map[string]int{"a": 1}
	table, isTable := m.(map[string]int)
	fmt.Println(table, isTable)
}
"""#

private let methodsAtEveryDepthExpected = #"""
21°C (1,2) failure 7: bad ptr: boom error wins counter(5) {5}
21°C|21°C|21|"21°C"|3231c2b043| 21°C|main.celsius
(1,2)|(1,2)|(1,2)|{1 2}|main.point{x:1, y:2}|main.point
failure 7: bad|failure 7: bad|{7 %!d(string=bad)}|"failure 7: bad"|main.failure|main.failure{code:7, reason:"bad"}
ptr: boom|ptr: boom|*main.ptrErr {boom}|{%!d(string=boom)}
counter(5)|counter(5)|{5}|*main.counter|main.counter
error wins error wins
failure 3: nope failure 3: nope|failure 3: nope|"failure 3: nope"|{3 %!d(string=nope)} <nil>
ptr: boom ptr: boom [ptr: boom] [ ptr: boom] [ptr: boom   ] *main.ptrErr
false true *main.ptrErr
21°C (1,2) 21°C (1,2) 21
21°C 21°C (1,2)xfailure 7: bad
21°C (1,2) 21°C failure 7: bad

%!z(main.celsius=21)|{%!z(int=1) %!z(int=2)}|{%!!(int=7) %!!(string=bad)}| 21%!(EXTRA main.point=(1,2))
wrap: failure 3: nope wrap: failure 7: bad x
21°C (1,2)
21°C (1,2) failure 7: bad
21°C/main.celsius (1,2)/main.point counter(5)/*main.counter 5/int s/string <nil>/<nil> [1]/[]int
9 square square *main.square
21°C/main.celsius (1,2)/main.point failure 7: bad/main.failure counter(5)/*main.counter 1/int s/string <nil>/<nil>\#u{20}
[1°C 2°C] map[a:3°C] {1 30} [(1,2)] [failure 3: nope <nil> n]
[1°C 2°C]|[1°C 2°C]|[1 2]|["7°C"]|[38c2b043]
{1°C 2 (1,2) failure 3: nope [3] [4°C]}
{Temp:1°C hidden:2 At:(1,2) Err:failure 3: nope inner:[3] Open:[4°C]}|{1°C %!s(main.celsius=2) (1,2) failure 3: nope [%!s(main.celsius=3)] [4°C]}
[counter(5)] map[5°C:(1,2)] [6°C 7°C] [21°C (1,2) 1]
1 2 6e6f697379332331 1
noisy1#2 noisy2#3 noisy3#4 4 "noisy5#5" 5
noisy9#6|noisy10#7   | 7
[noisy7#8 noisy8#9] map[noisy1#10:noisy2#11]
11
3 4 %!s(main.odd=5)
(1,2) failure 7: bad true
21°C true
0 false
(1,2) true 1
3 true
boom true
[1 2] true 2
[] false
map[a:1] true

"""#

private let nilReceiversAndPanickingMethodsSource = #"""
package main

import "errors"
import "fmt"

type node struct {
	name string
}

func (n *node) String() string {
	if n == nil {
		return "nil node"
	}
	return "node " + n.name
}

type leaf struct {
	name string
}

func (l *leaf) String() string {
	return "leaf " + l.name
}

type plain struct {
	name string
}

func (p plain) String() string {
	return "plain " + p.name
}

type list []int

func (l list) String() string {
	return "list of " + fmt.Sprint(len(l))
}

type index map[string]int

func (i index) String() string {
	return "index of " + fmt.Sprint(len(i))
}

type fault struct {
	code int
}

func (f *fault) Error() string {
	if f == nil {
		return "no fault"
	}
	return "fault " + fmt.Sprint(f.code)
}

type angry struct {
	level int
}

func (a angry) String() string {
	if a.level > 1 {
		panic(errors.New("too angry"))
	}
	if a.level > 0 {
		panic("angry")
	}
	return "calm"
}

type broken struct {
	code int
}

func (b broken) Error() string {
	panic("broken " + fmt.Sprint(b.code))
}

type Holder struct {
	Node  *node
	Leaf  *leaf
	Plain *plain
	List  list
	Mood  angry
}

func main() {
	var n *node
	var l *leaf
	var p *plain
	var items list
	var words index
	var f *fault
	present := node{name: "a"}

	fmt.Println(n, &present, l, p, items, words, f)
	fmt.Printf("%v|%s|%q|%x|%d\n", n, n, n, n, 7)
	fmt.Printf("%v|%s|%q|%10v|%-10s|\n", l, l, l, l, l)
	fmt.Printf("%v|%s|%q|%10v|\n", p, p, p, p)
	fmt.Printf("%v|%s|%5v|%+v|%#v\n", items, items, words, words, items)
	fmt.Printf("%v|%s|%q\n", f, f, f)
	fmt.Println(fmt.Sprint(n, l), fmt.Sprintf("%v %v", p, f))

	fmt.Println(angry{level: 0}, angry{level: 1}, angry{level: 2})
	fmt.Printf("%s|%q|%8v|%x|%d\n", angry{level: 1}, angry{level: 1}, angry{level: 1}, angry{level: 1}, angry{level: 1})
	fmt.Printf("%v|%s\n", broken{code: 3}, broken{code: 4})
	fmt.Println([]angry{angry{level: 0}, angry{level: 1}}, map[string]angry{"a": angry{level: 2}})

	h := Holder{Node: n, Leaf: l, Plain: p, List: items, Mood: angry{level: 1}}
	fmt.Println(h)
	fmt.Printf("%v|%+v\n", h, h)
	fmt.Println([]*node{n, &present}, []*leaf{l}, []*plain{p})
	fmt.Println("done")
}
"""#

private let nilReceiversAndPanickingMethodsExpected = #"""
nil node node a <nil> <nil> list of 0 index of 0 no fault
nil node|nil node|"nil node"|6e696c206e6f6465|7
<nil>|<nil>|<nil>|<nil>|<nil>|
<nil>|<nil>|<nil>|<nil>|
list of 0|list of 0|index of 0|index of 0|main.list(nil)
no fault|no fault|"no fault"
nil node <nil> <nil> no fault
calm %!v(PANIC=String method: angry) %!v(PANIC=String method: too angry)
%!s(PANIC=String method: angry)|%!q(PANIC=String method: angry)|%!v(PANIC=String method: angry)|%!x(PANIC=String method: angry)|{1}
%!v(PANIC=Error method: broken 3)|%!s(PANIC=Error method: broken 4)
[calm %!v(PANIC=String method: angry)] map[a:%!v(PANIC=String method: too angry)]
{nil node <nil> <nil> list of 0 %!v(PANIC=String method: angry)}
{nil node <nil> <nil> list of 0 %!v(PANIC=String method: angry)}|{Node:nil node Leaf:<nil> Plain:<nil> List:list of 0 Mood:%!v(PANIC=String method: angry)}
[nil node node a] [<nil>] [<nil>]
done

"""#

private let valuesInInterfacesSource = #"""
package main

import "fmt"

type ptrErr struct {
	msg string
}

func (e *ptrErr) Error() string {
	return "ptr: " + e.msg
}

type celsius int

func (c celsius) String() string {
	return "hot"
}

type shape interface{ Area() int }

type stringer interface{ String() string }

type square struct {
	side int
}

func (s *square) Area() int {
	return s.side * s.side
}

func fail() error {
	var e ptrErr
	e.msg = "x"
	return &e
}

func none() error {
	var e *ptrErr
	return e
}

func main() {
	err := fail()
	fmt.Println(err.Error())
	fmt.Println(err)
	fmt.Println(none() == nil)
	var s stringer = celsius(3)
	fmt.Println(s.String(), s)
	var sq square
	sq.side = 3
	var sh shape = &sq
	fmt.Println(sh.Area())
	var boxed any = celsius(4)
	c, ok := boxed.(celsius)
	fmt.Println(c, ok, boxed)
	n, isInt := boxed.(int)
	fmt.Println(n, isInt)
	var five any = 5
	fmt.Println(five != nil)
	values := []any{1, "a", celsius(2), nil, &sq}
	for _, v := range values {
		fmt.Printf("%T ", v)
	}
	fmt.Println()
}
"""#

private let valuesInInterfacesExpected = #"""
ptr: x
ptr: x
false
hot hot
9
hot true hot
0 false
true
int string main.celsius <nil> *main.square\#u{20}

"""#

private let assertionsToInterfacesSource = #"""
package main

import "errors"
import "fmt"

type namer interface {
	name() string
}

type sizer interface {
	size() int
}

type both interface {
	name() string
	size() int
}

type resizer interface {
	resize(int) (int, bool)
}

type file struct {
	label string
	bytes int
}

func (f file) name() string {
	return f.label
}

func (f *file) size() int {
	return f.bytes
}

func (f *file) resize(to int) (int, bool) {
	old := f.bytes
	f.bytes = to
	return old, to > old
}

type tag string

func (t tag) name() string {
	return "tag " + string(t)
}

type failure struct {
	code int
}

func (f failure) Error() string {
	return "failure " + fmt.Sprint(f.code)
}

func describe(value interface{}) string {
	text := ""
	n, isNamer := value.(namer)
	if isNamer {
		text += "namer(" + n.name() + ") "
	}
	s, isSizer := value.(sizer)
	if isSizer {
		text += "sizer(" + fmt.Sprint(s.size()) + ") "
	}
	b, isBoth := value.(both)
	if isBoth {
		text += "both(" + b.name() + "," + fmt.Sprint(b.size()) + ") "
	}
	_, isResizer := value.(resizer)
	if isResizer {
		text += "resizer "
	}
	e, isError := value.(error)
	if isError {
		text += "error(" + e.Error() + ") "
	}
	_, isAny := value.(interface{})
	if isAny {
		text += "any"
	}
	return text
}

func mustName(value interface{}) string {
	defer func() {
		fmt.Println("recovered:", recover())
	}()
	return value.(namer).name()
}

func main() {
	f := file{label: "a.txt", bytes: 3}
	fmt.Println(describe(f))
	fmt.Println(describe(&f))
	fmt.Println(describe(tag("x")))
	fmt.Println(describe(7))
	fmt.Println(describe("text"))
	fmt.Println(describe(nil))
	fmt.Println(describe(failure{code: 2}))
	fmt.Println(describe(errors.New("plain")))
	fmt.Println(describe(fmt.Errorf("wrap: %w", errors.New("inner"))))

	var n namer = &f
	r, ok := n.(resizer)
	fmt.Println(ok)
	old, grew := r.resize(10)
	fmt.Println(old, grew, n.(sizer).size())
	_, isFile := n.(*file)
	_, isValue := n.(file)
	fmt.Println(isFile, isValue)

	fmt.Println(mustName(tag("y")))
	fmt.Println(mustName(42))
	fmt.Println(mustName(nil))
	var err error = failure{code: 9}
	fmt.Println(mustName(err))
}
"""#

private let assertionsToInterfacesExpected = #"""
namer(a.txt) any
namer(a.txt) sizer(3) both(a.txt,3) resizer any
namer(tag x) any
any
any

error(failure 2) any
error(plain) any
error(wrap: inner) any
true
3 true 10
true false
recovered: <nil>
tag y
recovered: interface conversion: int is not main.namer: missing method name

recovered: interface conversion: interface is nil, not main.namer

recovered: interface conversion: main.failure is not main.namer: missing method name


"""#

private let interfaceMethodsWithSeveralResultsSource = #"""
package main

import "errors"
import "fmt"

type store interface {
	get(string) (string, bool)
	put(string, string) (int, error)
	stats() (int, int, int)
}

type memory struct {
	values map[string]string
	writes int
}

func (m *memory) get(key string) (string, bool) {
	value, ok := m.values[key]
	return value, ok
}

func (m *memory) put(key string, value string) (int, error) {
	if key == "" {
		return 0, errors.New("empty key")
	}
	m.values[key] = value
	m.writes++
	return len(value), nil
}

func (m *memory) stats() (int, int, int) {
	return len(m.values), m.writes, 0
}

func lookup(s store, key string) (string, bool) {
	return s.get(key)
}

func main() {
	backing := memory{values: map[string]string{}, writes: 0}
	var s store = &backing
	n, err := s.put("a", "alpha")
	fmt.Println(n, err)
	n, err = s.put("", "x")
	fmt.Println(n, err)
	value, ok := s.get("a")
	fmt.Println(value, ok)
	value, ok = lookup(s, "missing")
	fmt.Println(value == "", ok)
	keys, writes, misses := s.stats()
	fmt.Println(keys, writes, misses)
}
"""#

private let interfaceMethodsWithSeveralResultsExpected = #"""
5 <nil>
0 empty key
alpha true
true false
1 1 0

"""#

private let variadicInterfaceMethodsAndFinalPanicSource = #"""
package main

import "fmt"

type summer interface {
	sum(int, ...int) (int, int)
}

type strict interface {
	sum(int, []int) (int, int)
}

type adder struct {
	base int
}

func (a adder) sum(first int, values ...int) (int, int) {
	total := a.base + first
	for _, value := range values {
		total += value
	}
	return total, len(values)
}

func fail(code int) int {
	if code > 0 {
		panic("positive")
	}
	panic(fmt.Sprintf("code %d", code))
}

func main() {
	defer func() {
		fmt.Println("recovered", recover())
	}()
	var s summer = adder{base: 10}
	total, count := s.sum(1)
	fmt.Println(total, count)
	total, count = s.sum(1, 2, 3)
	fmt.Println(total, count)
	total, count = s.sum(1, []int{4, 5}...)
	fmt.Println(total, count)
	var value interface{} = adder{base: 1}
	_, isSummer := value.(summer)
	_, isStrict := value.(strict)
	fmt.Println(isSummer, isStrict)
	fmt.Println(fail(0))
}
"""#

private let variadicInterfaceMethodsAndFinalPanicExpected = #"""
11 0
16 2
20 2
true false
recovered code 0

"""#

private let errorIdentityWrappingIsAndAsSource = #"""
package main

import "errors"
import "fmt"
import "io"

var errNotFound = errors.New("not found")
var errOther = errors.New("not found")

type codeErr struct {
	code int
}

func (e codeErr) Error() string {
	return fmt.Sprintf("code %d", e.code)
}

type pathErr struct {
	op    string
	inner error
}

func (e *pathErr) Error() string {
	return e.op + ": " + e.inner.Error()
}

func (e *pathErr) Unwrap() error {
	return e.inner
}

type always struct {
	tag string
}

func (a always) Error() string {
	return "always " + a.tag
}

func (a always) Is(target error) bool {
	return target == errOther
}

type multi struct {
	all []error
}

func (m multi) Error() string {
	return "multi"
}

func (m multi) Unwrap() []error {
	return m.all
}

type temporary interface{ Temporary() bool }

type flaky struct {
	n int
}

func (f flaky) Error() string {
	return "flaky"
}

func (f flaky) Temporary() bool {
	return f.n > 0
}

func lookup(key string) error {
	if key == "" {
		return errNotFound
	}
	return nil
}

func load(key string) error {
	err := lookup(key)
	if err != nil {
		return fmt.Errorf("load %q: %w", key, err)
	}
	return nil
}

func main() {
	a := errors.New("same")
	b := errors.New("same")
	c := a
	fmt.Println(a == b, a == c, a != b, errNotFound == errOther, errNotFound == errNotFound)
	fmt.Println(a, a.Error(), fmt.Sprintf("%v|%s|%q|%T|%#v", a, a, a, a, a))
	fmt.Println(fmt.Sprintf("%d|%x|%5v|%-6s|", a, a, a, a))

	e1 := fmt.Errorf("plain %d", 1)
	e2 := fmt.Errorf("plain %d", 1)
	fmt.Println(e1, e1 == e2, fmt.Sprintf("%T", e1), errors.Unwrap(e1) == nil)

	w := load("")
	fmt.Println(w, fmt.Sprintf("%T", w), errors.Unwrap(w) == errNotFound, errors.Unwrap(errors.Unwrap(w)) == nil)
	fmt.Println(errors.Is(w, errNotFound), errors.Is(w, errOther), errors.Is(w, w), errors.Is(nil, errNotFound), errors.Is(w, nil), errors.Is(nil, nil))
	ww := fmt.Errorf("outer: %w", w)
	fmt.Println(ww, errors.Is(ww, errNotFound), errors.Unwrap(ww) == w, fmt.Sprintf("%v|%+v|%s", ww, ww, ww))
	fmt.Println(fmt.Sprintf("%#v", w) != "", fmt.Sprintf("%d", w) != "")

	both := fmt.Errorf("two: %w and %w", errNotFound, a)
	fmt.Println(both, fmt.Sprintf("%T", both), errors.Unwrap(both) == nil, errors.Is(both, errNotFound), errors.Is(both, a), errors.Is(both, b))
	reordered := fmt.Errorf("%[2]w then %[1]w", a, errNotFound)
	fmt.Println(reordered, errors.Is(reordered, a), errors.Is(reordered, errNotFound), fmt.Sprintf("%T", reordered))
	notAnError := fmt.Errorf("value %w", 5)
	fmt.Println(notAnError, fmt.Sprintf("%T", notAnError), errors.Unwrap(notAnError) == nil)
	mixed := fmt.Errorf("%w %w", 5, a)
	fmt.Println(mixed, fmt.Sprintf("%T", mixed), errors.Is(mixed, a))
	nilWrap := fmt.Errorf("nil: %w", nil)
	fmt.Println(nilWrap, fmt.Sprintf("%T", nilWrap), errors.Unwrap(nilWrap) == nil)
	fmt.Println(fmt.Sprintf("%w", a), fmt.Sprintf("%w", 5), fmt.Sprintf("%w", nil))

	var pe pathErr
	pe.op = "open"
	pe.inner = errNotFound
	var chain error = &pe
	fmt.Println(chain, errors.Unwrap(chain) == errNotFound, errors.Is(chain, errNotFound), errors.Is(chain, a))
	deep := fmt.Errorf("deep: %w", chain)
	fmt.Println(deep, errors.Is(deep, errNotFound), errors.Unwrap(errors.Unwrap(deep)) == errNotFound)

	var ce error = codeErr{code: 7}
	wrappedCode := fmt.Errorf("wrapped: %w", ce)
	fmt.Println(errors.Is(wrappedCode, codeErr{code: 7}), errors.Is(wrappedCode, codeErr{code: 8}), errors.Is(ce, ce))
	var target codeErr
	fmt.Println(errors.As(wrappedCode, &target), target.code, target)
	var missing codeErr
	fmt.Println(errors.As(w, &missing), missing.code)
	var found *pathErr
	fmt.Println(errors.As(deep, &found), found.op, found == &pe)
	var notThere *pathErr
	fmt.Println(errors.As(w, &notThere), notThere == nil)

	var al error = always{tag: "x"}
	fmt.Println(errors.Is(al, errOther), errors.Is(al, errNotFound), errors.Is(fmt.Errorf("w: %w", al), errOther))
	var m error = multi{all: []error{a, nil, w}}
	fmt.Println(errors.Is(m, a), errors.Is(m, errNotFound), errors.Is(m, b), errors.Unwrap(m) == nil)
	var asCode codeErr
	fmt.Println(errors.As(multi{all: []error{a, wrappedCode}}, &asCode), asCode.code)

	var temp temporary
	var fl error = flaky{n: 1}
	fmt.Println(errors.As(fmt.Errorf("x: %w", fl), &temp), temp.Temporary(), errors.As(w, &temp))
	var anyErr error
	fmt.Println(errors.As(w, &anyErr), anyErr == w)

	fmt.Println(errors.Is(io.EOF, io.EOF), errors.Is(fmt.Errorf("read: %w", io.EOF), io.EOF), errors.Unwrap(io.EOF) == nil)
	fmt.Println(errors.Is(a, b), errors.Is(a, a), errors.Unwrap(nil) == nil)
	list := []error{a, w, nil, ce}
	fmt.Println(list, fmt.Sprintf("%v|%s|%q", list, list, list))
}
"""#

private let errorIdentityWrappingIsAndAsExpected = #"""
false true true false true
same same same|same|"same"|*errors.errorString|&errors.errorString{s:"same"}
&{%!d(string=same)}|73616d65| same|same  |
plain 1 false *errors.errorString true
load "": not found *fmt.wrapError true true
true false true false false true
outer: load "": not found true true outer: load "": not found|outer: load "": not found|outer: load "": not found
true true
two: not found and same *fmt.wrapErrors true true true false
not found then same true true *fmt.wrapErrors
value %!w(int=5) *fmt.wrapError true
%!w(int=5) same *fmt.wrapErrors true
nil: %!w(<nil>) *fmt.wrapError true
%!w(*errors.errorString=&{same}) %!w(int=5) %!w(<nil>)
open: not found true true false
deep: open: not found true true
true false true
true 7 code 7
false 0
true open true
false true
true false true
true true false true
true 7
true true false
true true
true true true
false true true
[same load "": not found <nil> code 7] [same load "": not found <nil> code 7]|[same load "": not found <nil> code 7]|["same" "load \"\": not found" <nil> "code 7"]

"""#

private let variadicFunctionsAndSpreadsSource = #"""
package main

import "errors"
import "fmt"
import "strings"

func sum(values ...int) int {
	total := 0
	for _, value := range values {
		total += value
	}
	return total
}

func join(separator string, parts ...string) string {
	return strings.Join(parts, separator)
}

func describe(label string, values ...any) string {
	text := label + ":"
	for i := 0; i < len(values); i++ {
		text += fmt.Sprintf(" %v/%T", values[i], values[i])
	}
	return text
}

func shape(values ...int) string {
	return fmt.Sprintf("%d %d %v %t", len(values), cap(values), values, values == nil)
}

func first(values ...string) (string, int) {
	if len(values) == 0 {
		return "", 0
	}
	return values[0], len(values)
}

func mutate(values ...int) {
	if len(values) > 0 {
		values[0] = 99
	}
}

type logger struct {
	prefix string
	lines  []string
}

func (l *logger) logf(format string, args ...any) {
	l.lines = append(l.lines, l.prefix+fmt.Sprintf(format, args...))
}

func (l logger) count(extra ...int) int {
	return len(l.lines) + len(extra)
}

func wrap(err error, context ...string) error {
	if len(context) == 0 {
		return err
	}
	return fmt.Errorf("%s: %w", strings.Join(context, "/"), err)
}

func bytes(prefix string, data ...byte) []byte {
	return append([]byte(prefix), data...)
}

func main() {
	fmt.Println(sum(), sum(1), sum(1, 2, 3), sum([]int{4, 5, 6}...))
	numbers := []int{7, 8}
	fmt.Println(sum(numbers...), sum(numbers[:1]...), sum(append(numbers, 9)...))
	fmt.Println(join(","), join(",", "a"), join("-", "a", "b", "c"), join("+", []string{"x", "y"}...))
	fmt.Println(describe("none"), describe("mixed", 1, "a", true, nil, 2), describe("slice", numbers))
	fmt.Println(describe("spread", []any{1, "b"}...))
	fmt.Println(shape(), shape(1, 2), shape(numbers...))
	var empty []int
	fmt.Println(shape(empty...), shape([]int{}...))
	head, count := first("a", "b")
	fmt.Println(head, count)
	head, count = first()
	fmt.Println(head == "", count)
	mutate(numbers...)
	fmt.Println(numbers)
	mutate(1, 2)
	var log logger
	log.prefix = "> "
	log.logf("plain")
	log.logf("%d-%s", 1, "x")
	log.logf("%v %v %v", []any{1, 2, 3}...)
	fmt.Println(log.lines, log.count(), log.count(1, 2))
	base := errors.New("base")
	fmt.Println(wrap(base), wrap(base, "a"), wrap(base, "a", "b"), errors.Is(wrap(base, "x"), base))
	fmt.Println(string(bytes("ab")), string(bytes("ab", 99, 100)), string(bytes("", []byte("xyz")...)))
	fmt.Println(fmt.Sprintf("%d %d", []any{1, 2}...), fmt.Sprint([]any{"a", 1}...), fmt.Sprintln([]any{"b", 2}...))
	args := []any{"x", 3}
	fmt.Printf("%s=%d\n", args...)
	fmt.Println(args...)
}
"""#

private let variadicFunctionsAndSpreadsExpected = #"""
0 1 6 15
15 7 24
 a a-b-c x+y
none: mixed: 1/int a/string true/bool <nil>/<nil> 2/int slice: [7 8]/[]int
spread: 1/int b/string
0 0 [] true 2 2 [1 2] false 2 2 [7 8] false
0 0 [] true 0 0 [] false
a 2
true 0
[99 8]
[> plain > 1-x > 1 2 3] 3 5
base a: base a/b: base true
ab abcd xyz
1 2 a1 b 2

x=3
x 3

"""#

private let ifAndSwitchInitializersSource = #"""
package main

import "errors"
import "fmt"
import "strconv"

type store struct {
	values map[string]int
}

func (s *store) get(key string) (int, bool) {
	value, ok := s.values[key]
	return value, ok
}

func parse(text string) (int, error) {
	n, err := strconv.Atoi(text)
	if err != nil {
		return 0, errors.New("bad number " + text)
	}
	return n, nil
}

func classify(n int) string {
	if half := n / 2; half > 10 {
		return "large"
	} else if half > 2 {
		return "medium"
	} else {
		return "small " + strconv.Itoa(half)
	}
}

func sign(n int) string {
	switch abs := n * n; {
	case n < 0:
		return "negative " + strconv.Itoa(abs)
	case n == 0:
		return "zero"
	default:
		return "positive " + strconv.Itoa(abs)
	}
}

func grade(score int) string {
	switch band := score / 10; band {
	case 10, 9:
		return "A"
	case 8:
		return "B"
	default:
		return "C"
	}
}

func firstEven(values []int) int {
	found := -1
	for index, value := range values {
		if rest := value % 2; rest != 0 {
			continue
		}
		if double := value * 2; double > 100 {
			break
		}
		found = index
		switch quarter := value / 4; quarter {
		case 0:
			continue
		}
		break
	}
	return found
}

func main() {
	s := store{values: map[string]int{"a": 1, "b": 2}}
	if value, ok := s.get("a"); ok {
		fmt.Println("a =", value)
	}
	if _, ok := s.get("z"); !ok {
		fmt.Println("no z")
	}
	if n, err := parse("42"); err != nil {
		fmt.Println("error", err)
	} else if n > 40 {
		fmt.Println("big", n)
	} else {
		fmt.Println("small", n)
	}
	if _, err := parse("x1"); err != nil {
		fmt.Println("error:", err)
	}
	err := errors.New("outer")
	if err := errors.New("inner"); err != nil {
		fmt.Println(err)
	}
	fmt.Println(err)

	var value interface{} = 7
	if number, ok := value.(int); ok && number > 5 {
		fmt.Println("int", number)
	}
	if text, ok := value.(string); ok {
		fmt.Println("string", text)
	} else if number, ok := value.(int); ok {
		fmt.Println("still int", number, text == "")
	}

	total := 0
	if total = total + 5; total > 3 {
		fmt.Println("assigned", total)
	}
	if total++; total == 6 {
		fmt.Println("incremented", total)
	}
	if fmt.Println("called"); total > 0 {
		fmt.Println("after call")
	}
	if x := 1; x > 0 {
		if x := x + 1; x > 1 {
			if x := x + 1; x > 2 {
				fmt.Println("nested", x)
			}
			fmt.Println("middle", x)
		}
		fmt.Println("outer", x)
	}

	fmt.Println(classify(30), classify(8), classify(3))
	fmt.Println(sign(-3), sign(0), sign(4))
	fmt.Println(grade(100), grade(95), grade(85), grade(10))
	fmt.Println(firstEven([]int{1, 3, 2, 8}), firstEven([]int{7, 60, 4}), firstEven([]int{9, 6}), firstEven([]int{1}))

	m := map[string][]int{"k": []int{4, 5}}
	if list, ok := m["k"]; ok && len(list) > 1 {
		fmt.Println(list[1], len(list))
	}
	for i := 0; i < 3; i++ {
		if square := i * i; square%2 == 0 {
			fmt.Println("even square", square)
		}
	}
}
"""#

private let ifAndSwitchInitializersExpected = #"""
a = 1
no z
big 42
error: bad number x1
inner
outer
int 7
still int 7 true
assigned 5
incremented 6
called
after call
nested 3
middle 2
outer 1
large medium small 1
negative 9 zero positive 16
A A B C
3 -1 1 -1
5 2
even square 0
even square 4

"""#

private let runTimeErrorsAreRecoverablePanicsSource = #"""
package main

import "errors"
import "fmt"
import "strings"

type node struct {
	name string
	next *node
}

func (n node) label() string {
	return "label " + n.name
}

type namer interface {
	label() string
}

type series struct {
	values []int
}

func (s series) String() string {
	return fmt.Sprint(s.values[5])
}

func report(name string) {
	r := recover()
	if r == nil {
		fmt.Println(name, "-> no panic")
		return
	}
	if err, ok := r.(error); ok {
		fmt.Printf("%s -> %v | %s | %T | %q\n", name, r, err.Error(), r, r)
	} else {
		fmt.Printf("%s -> %v | not an error | %T\n", name, r, r)
	}
}

func indexSlice(values []int, i int) int {
	defer report("index slice")
	return values[i]
}

func indexArray(i int) int {
	defer report("index array")
	values := [3]int{1, 2, 3}
	return values[i]
}

func indexString(text string, i int) byte {
	defer report("index string")
	return text[i]
}

func storeSlice(values []int, i int) {
	defer report("store slice")
	values[i] = 9
}

func sliceHigh(values []int, low int, high int) []int {
	defer report("slice bounds")
	return values[low:high]
}

func sliceFrom(values []int, low int) []int {
	defer report("slice from")
	return values[low:]
}

func sliceString(text string, low int, high int) string {
	defer report("slice string")
	return text[low:high]
}

func divide(a int, b int) int {
	defer report("divide")
	return a / b
}

func remainder(a int, b int) int {
	defer report("remainder")
	return a % b
}

func readField(n *node) string {
	defer report("nil field read")
	return n.name
}

func writeField(n *node) {
	defer report("nil field write")
	n.name = "x"
}

func chase(n *node) string {
	defer report("nil chain")
	return n.next.next.name
}

func valueMethod(n *node) string {
	defer report("nil value method")
	return n.label()
}

func nilInterface(n namer) string {
	defer report("nil interface")
	return n.label()
}

func nilInInterface(pointer *node) string {
	defer report("nil in interface")
	var n namer = pointer
	return n.label()
}

func nilMap(key string) {
	defer report("nil map")
	var m map[string]int
	m[key] = 1
}

func assertInt(value interface{}) int {
	defer report("assertion")
	return value.(int)
}

func assertNamer(value interface{}) string {
	defer report("interface assertion")
	return value.(namer).label()
}

func shift(count int) int {
	defer report("shift")
	return 1 << count
}

func allocate(n int) int {
	defer report("make")
	return len(make([]int, n))
}

func closedSend() {
	defer report("send on closed")
	ch := make(chan int, 1)
	close(ch)
	ch <- 1
}

func closeTwice() {
	defer report("close twice")
	ch := make(chan int)
	close(ch)
	close(ch)
}

func closeNil() {
	defer report("close nil")
	var ch chan int
	close(ch)
}

func repeat(n int) string {
	defer report("repeat")
	return strings.Repeat("ab", n)
}

func explicit(code int) {
	defer report("explicit")
	if code == 1 {
		panic("text")
	}
	if code == 2 {
		panic(errors.New("made error"))
	}
	if code == 3 {
		panic(fmt.Errorf("wrapped: %w", errors.New("inner")))
	}
	panic(code)
}

func none() int {
	defer report("none")
	return 1
}

func ordered() {
	defer fmt.Println("deferred first, runs last")
	defer report("ordered")
	defer fmt.Println("deferred last, runs first")
	var values []int
	fmt.Println(values[0])
}

func cleanup(stage string) {
	fmt.Println("cleanup", stage)
}

func inner(values []int) int {
	defer cleanup("inner")
	return values[len(values)]
}

func outer() (result int) {
	defer report("outer")
	defer cleanup("outer")
	result = inner([]int{1, 2})
	return result + 1
}

func worker(done chan string, values []int, i int) {
	defer finish(done)
	done <- fmt.Sprint(values[i])
}

func finish(done chan string) {
	if r := recover(); r != nil {
		done <- fmt.Sprint("worker recovered: ", r)
	}
}

func repanic() {
	defer report("repanic")
	defer raise()
	var m map[int]int
	m[1] = 1
}

func raise() {
	if r := recover(); r != nil {
		panic(fmt.Sprint("again: ", r))
	}
}

func compare(values []int) {
	defer report("compare")
	defer same(values)
	fmt.Println(values[4])
}

func same(values []int) {
	first := recover()
	second := capture(values)
	third := capture(values[:1])
	fmt.Println(first == second, first == third, first != nil)
	panic(first)
}

func capture(values []int) (r interface{}) {
	defer grab(values)
	return nil
}

func grab(values []int) {
	recover()
}

func main() {
	values := []int{1, 2, 3}
	fmt.Println(indexSlice(values, 3), indexSlice(values, -1), indexSlice(nil, 0), indexSlice(values, 2))
	fmt.Println(indexArray(5), indexString("héllo", 9))
	storeSlice(values, 7)
	fmt.Println(sliceHigh(values, 1, 5), sliceHigh(values, 2, 1), sliceHigh(values[:1], 0, 3), sliceHigh(values, -1, 2))
	fmt.Println(sliceFrom(values, 4), sliceString("hello", 2, 9), sliceString("hello", 4, 2))
	fmt.Println(divide(7, 0), remainder(7, 0), divide(7, 2))
	head := node{name: "a", next: nil}
	fmt.Println(readField(nil), chase(&head) == "")
	writeField(nil)
	fmt.Println(valueMethod(nil), nilInterface(nil), nilInInterface(nil))
	nilMap("k")
	fmt.Println(assertInt("text"), assertInt(nil), assertInt(4), assertNamer(7))
	fmt.Println(shift(-1), allocate(-5))
	closedSend()
	closeTwice()
	closeNil()
	fmt.Println(repeat(-1) == "")
	explicit(1)
	explicit(2)
	explicit(3)
	explicit(4)
	fmt.Println(none())
	ordered()
	fmt.Println(outer())
	done := make(chan string)
	go worker(done, values, 1)
	fmt.Println(<-done)
	go worker(done, values, 8)
	fmt.Println(<-done)
	repanic()
	compare(values)
	fmt.Println(series{values: values})
	fmt.Printf("%v|%s|%d\n", series{values: nil}, series{values: values}, 3)
	fmt.Println("still running")
}
"""#

private let runTimeErrorsAreRecoverablePanicsExpected = #"""
index slice -> runtime error: index out of range [3] with length 3 | runtime error: index out of range [3] with length 3 | runtime.boundsError | "runtime error: index out of range [3] with length 3"
index slice -> runtime error: index out of range [-1] | runtime error: index out of range [-1] | runtime.boundsError | "runtime error: index out of range [-1]"
index slice -> runtime error: index out of range [0] with length 0 | runtime error: index out of range [0] with length 0 | runtime.boundsError | "runtime error: index out of range [0] with length 0"
index slice -> no panic
0 0 0 3
index array -> runtime error: index out of range [5] with length 3 | runtime error: index out of range [5] with length 3 | runtime.boundsError | "runtime error: index out of range [5] with length 3"
index string -> runtime error: index out of range [9] with length 6 | runtime error: index out of range [9] with length 6 | runtime.boundsError | "runtime error: index out of range [9] with length 6"
0 0
store slice -> runtime error: index out of range [7] with length 3 | runtime error: index out of range [7] with length 3 | runtime.boundsError | "runtime error: index out of range [7] with length 3"
slice bounds -> runtime error: slice bounds out of range [:5] with capacity 3 | runtime error: slice bounds out of range [:5] with capacity 3 | runtime.boundsError | "runtime error: slice bounds out of range [:5] with capacity 3"
slice bounds -> runtime error: slice bounds out of range [2:1] | runtime error: slice bounds out of range [2:1] | runtime.boundsError | "runtime error: slice bounds out of range [2:1]"
slice bounds -> no panic
slice bounds -> runtime error: slice bounds out of range [-1:] | runtime error: slice bounds out of range [-1:] | runtime.boundsError | "runtime error: slice bounds out of range [-1:]"
[] [] [1 2 3] []
slice from -> runtime error: slice bounds out of range [4:3] | runtime error: slice bounds out of range [4:3] | runtime.boundsError | "runtime error: slice bounds out of range [4:3]"
slice string -> runtime error: slice bounds out of range [:9] with length 5 | runtime error: slice bounds out of range [:9] with length 5 | runtime.boundsError | "runtime error: slice bounds out of range [:9] with length 5"
slice string -> runtime error: slice bounds out of range [4:2] | runtime error: slice bounds out of range [4:2] | runtime.boundsError | "runtime error: slice bounds out of range [4:2]"
[]\#u{20}\#u{20}
divide -> runtime error: integer divide by zero | runtime error: integer divide by zero | runtime.errorString | "runtime error: integer divide by zero"
remainder -> runtime error: integer divide by zero | runtime error: integer divide by zero | runtime.errorString | "runtime error: integer divide by zero"
divide -> no panic
0 0 3
nil field read -> runtime error: invalid memory address or nil pointer dereference | runtime error: invalid memory address or nil pointer dereference | runtime.errorString | "runtime error: invalid memory address or nil pointer dereference"
nil chain -> runtime error: invalid memory address or nil pointer dereference | runtime error: invalid memory address or nil pointer dereference | runtime.errorString | "runtime error: invalid memory address or nil pointer dereference"
 true
nil field write -> runtime error: invalid memory address or nil pointer dereference | runtime error: invalid memory address or nil pointer dereference | runtime.errorString | "runtime error: invalid memory address or nil pointer dereference"
nil value method -> runtime error: invalid memory address or nil pointer dereference | runtime error: invalid memory address or nil pointer dereference | runtime.errorString | "runtime error: invalid memory address or nil pointer dereference"
nil interface -> runtime error: invalid memory address or nil pointer dereference | runtime error: invalid memory address or nil pointer dereference | runtime.errorString | "runtime error: invalid memory address or nil pointer dereference"
nil in interface -> runtime error: invalid memory address or nil pointer dereference | runtime error: invalid memory address or nil pointer dereference | runtime.errorString | "runtime error: invalid memory address or nil pointer dereference"
\#u{20}\#u{20}
nil map -> assignment to entry in nil map | assignment to entry in nil map | runtime.plainError | "assignment to entry in nil map"
assertion -> interface conversion: interface {} is string, not int | interface conversion: interface {} is string, not int | *runtime.TypeAssertionError | "interface conversion: interface {} is string, not int"
assertion -> interface conversion: interface {} is nil, not int | interface conversion: interface {} is nil, not int | *runtime.TypeAssertionError | "interface conversion: interface {} is nil, not int"
assertion -> no panic
interface assertion -> interface conversion: int is not main.namer: missing method label | interface conversion: int is not main.namer: missing method label | *runtime.TypeAssertionError | "interface conversion: int is not main.namer: missing method label"
0 0 4\#u{20}
shift -> runtime error: negative shift amount | runtime error: negative shift amount | runtime.errorString | "runtime error: negative shift amount"
make -> runtime error: makeslice: len out of range | runtime error: makeslice: len out of range | runtime.errorString | "runtime error: makeslice: len out of range"
0 0
send on closed -> send on closed channel | send on closed channel | runtime.plainError | "send on closed channel"
close twice -> close of closed channel | close of closed channel | runtime.plainError | "close of closed channel"
close nil -> close of nil channel | close of nil channel | runtime.plainError | "close of nil channel"
repeat -> strings: negative Repeat count | not an error | string
true
explicit -> text | not an error | string
explicit -> made error | made error | *errors.errorString | "made error"
explicit -> wrapped: inner | wrapped: inner | *fmt.wrapError | "wrapped: inner"
explicit -> 4 | not an error | int
none -> no panic
1
deferred last, runs first
ordered -> runtime error: index out of range [0] with length 0 | runtime error: index out of range [0] with length 0 | runtime.boundsError | "runtime error: index out of range [0] with length 0"
deferred first, runs last
cleanup inner
cleanup outer
outer -> runtime error: index out of range [2] with length 2 | runtime error: index out of range [2] with length 2 | runtime.boundsError | "runtime error: index out of range [2] with length 2"
0
2
worker recovered: runtime error: index out of range [8] with length 3
repanic -> again: assignment to entry in nil map | not an error | string
false false true
compare -> runtime error: index out of range [4] with length 3 | runtime error: index out of range [4] with length 3 | runtime.boundsError | "runtime error: index out of range [4] with length 3"
%!v(PANIC=String method: runtime error: index out of range [5] with length 3)
%!v(PANIC=String method: runtime error: index out of range [5] with length 0)|%!s(PANIC=String method: runtime error: index out of range [5] with length 3)|3
still running

"""#

private let compositeLiteralsAndTheirAddressesSource = #"""
package main

import "errors"
import "fmt"

type point struct {
	X int
	Y int
}

type node struct {
	name string
	next *node
	tags []string
	meta map[string]int
	at   point
	ok   bool
	err  error
}

func (n *node) rename(name string) *node {
	n.name = name
	return n
}

func (n node) label() string {
	return "<" + n.name + ">"
}

type server struct {
	name    string
	clients map[string]*client
	limit   int
}

type client struct {
	id     int
	server *server
}

func newServer(name string) *server {
	return &server{name: name, clients: map[string]*client{}, limit: 2}
}

func (s *server) connect(key string) *client {
	c := &client{id: len(s.clients) + 1, server: s}
	s.clients[key] = c
	return c
}

type failure struct {
	code int
}

func (f *failure) Error() string {
	return "failure " + fmt.Sprint(f.code)
}

func check(code int) error {
	if code > 0 {
		return &failure{code: code}
	}
	return nil
}

func chain(names []string) *node {
	var head *node
	for i := len(names) - 1; i >= 0; i-- {
		head = &node{name: names[i], next: head}
	}
	return head
}

func main() {
	zero := point{}
	var empty node = node{}
	fmt.Println(zero, zero == point{}, empty.name == "", empty.next == nil, empty.tags == nil, empty.meta == nil, empty.at, empty.ok, empty.err)
	fmt.Printf("%v %+v %#v\n", point{}, point{X: 1}, point{Y: 2})

	p := &point{X: 1, Y: 2}
	q := &point{X: 1, Y: 2}
	fmt.Println(p, *p, p.X+p.Y, p == q, *p == *q, p == p)
	p.X = 10
	q.Y++
	fmt.Println(*p, *q, (&point{X: 3, Y: 4}).X, *(&point{}))
	fmt.Printf("%v %+v %T %T\n", p, q, p, &node{})

	n := &node{name: "a", tags: []string{"x"}, meta: map[string]int{"k": 1}, at: point{X: 5}}
	n.next = &node{name: "b"}
	n.next.next = &node{}
	fmt.Println(n.name, n.next.name, n.next.next.name == "", n.next.next.next == nil, n.tags, n.meta, n.at)
	fmt.Println(n.rename("c").label(), (&node{name: "d"}).label(), (&node{}).rename("e").name)

	var list []*point
	for i := 0; i < 3; i++ {
		list = append(list, &point{X: i, Y: i * i})
	}
	list[0].X = 100
	fmt.Println(*list[0], *list[1], *list[2], list[0] == list[1], len(list))

	table := []*point{&point{X: 1}, &point{Y: 2}, &point{}}
	lookup := map[string]*point{"a": &point{X: 7}, "b": &point{}}
	lookup["a"].Y = 8
	fmt.Println(*table[0], *table[1], *table[2], *lookup["a"], *lookup["b"], len(lookup))

	numbers := &[]int{1, 2, 3}
	counts := &map[string]int{"a": 1}
	array := &[3]int{4, 5}
	*numbers = append(*numbers, 4)
	(*counts)["b"] = 2
	(*array)[2] = 6
	fmt.Println(*numbers, len(*numbers), *counts, *array, len(*array))

	head := chain([]string{"x", "y", "z"})
	for cursor := head; cursor != nil; cursor = cursor.next {
		fmt.Print(cursor.name, " ")
	}
	fmt.Println()

	s := newServer("main")
	first := s.connect("a")
	second := s.connect("b")
	fmt.Println(s.name, len(s.clients), first.id, second.id, first.server == second.server, s.clients["a"] == first, s.limit)

	err := check(3)
	var target *failure
	fmt.Println(err, check(0) == nil, errors.As(err, &target), target.code, err == check(3))

	var holder interface{} = &point{X: 9}
	held, isPointer := holder.(*point)
	_, isValue := holder.(point)
	fmt.Println(held.X, isPointer, isValue)
	fmt.Println([]point{point{}, point{X: 1}}, map[string]point{"z": point{}}, [2]point{})
}
"""#

private let compositeLiteralsAndTheirAddressesExpected = #"""
{0 0} true true true true true {0 0} false <nil>
{0 0} {X:1 Y:0} main.point{X:0, Y:2}
&{1 2} {1 2} 3 false true true
{10 2} {1 3} 3 {0 0}
&{10 2} &{X:1 Y:3} *main.point *main.node
a b true true [x] map[k:1] {5 0}
<c> <d> e
{100 0} {1 1} {2 4} false 3
{1 0} {0 2} {0 0} {7 8} {0 0} 2
[1 2 3 4] 4 map[a:1 b:2] [4 5 6] 3
x y z\#u{20}
main 2 1 2 true true 2
failure 3 true true 3 false
9 true false
[{0 0} {1 0}] map[z:{0 0}] [{0 0} {0 0}]

"""#

private let parallelAssignmentAndSeveralNamesSource = #"""
package main

import "errors"
import "fmt"
import "strconv"

type pair struct {
	left  int
	right int
}

type holder struct {
	values []int
	names  map[string]int
	next   *holder
}

var first, second int
var alpha, beta = 10, "b"
var typed, also int = 3, 4

const big, small = 100, 1

func two() (int, error) {
	return 2, errors.New("e")
}

func divmod(a int, b int) (int, int) {
	return a / b, a % b
}

func fib(n int) int {
	a, b := 0, 1
	for i := 0; i < n; i++ {
		a, b = b, a+b
	}
	return a
}

func reverse(values []int) {
	for i, j := 0, len(values)-1; i < j; i, j = i+1, j-1 {
		values[i], values[j] = values[j], values[i]
	}
}

func gcd(a int, b int) int {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

func main() {
	fmt.Println(first, second, alpha, beta, typed, also, big, small)
	first, second = 1, 2
	first, second = second, first
	fmt.Println(first, second)

	a, b := 1, "x"
	a, b = a+1, b+"y"
	c, d, e := a*2, len(b), b == "xy"
	fmt.Println(a, b, c, d, e)

	x, y := 3, 4
	x, y = y, x
	x, y, z := y, x, x+y
	fmt.Println(x, y, z)

	var m, n int
	var s, t = "s", 5
	var u, v byte = 1, 2
	var q, err = two()
	var w, ok = map[string]int{"k": 9}["k"]
	fmt.Println(m, n, s, t, u, v, q, err, w, ok)
	fmt.Printf("%T %T %T %T\n", u, t, s, err)

	_ = x
	_, _ = y, z
	n, _ = two()
	_, err = strconv.Atoi("12")
	fmt.Println(n, err)

	list := []int{1, 2, 3, 4, 5}
	reverse(list)
	list[0], list[4] = list[4], list[0]
	fmt.Println(list, fib(10), gcd(84, 36))

	i := 0
	i, list[i] = 2, 99
	fmt.Println(i, list)
	list, list[0] = []int{7, 8}, 55
	fmt.Println(list)

	p := pair{left: 1, right: 2}
	p.left, p.right = p.right, p.left
	h := &holder{values: []int{1, 2}, names: map[string]int{"a": 1}}
	h.values[0], h.values[1] = h.values[1], h.values[0]
	h.names["a"], h.names["b"] = 5, h.names["a"]
	h.next, h.values = &holder{values: []int{9}}, h.values[:1]
	fmt.Println(p, h.values, h.names, h.next.values)

	pointer := &p
	other := &pair{left: 7, right: 8}
	pointer, pointer.left = other, 100
	fmt.Println(p, *pointer, *other)

	array := [3]int{1, 2, 3}
	array[0], array[2] = array[2], array[0]
	k := 1
	k, array[k] = 2, 50
	fmt.Println(array, k)

	quotient, rest := divmod(17, 5)
	quotient, extra := quotient+1, rest*2
	var iface interface{}
	var problem error
	iface, problem = 5, errors.New("typed")
	text, number := "v", 1
	iface, text = text, strconv.Itoa(number)
	fmt.Println(quotient, rest, extra, iface, problem, text)
	fmt.Printf("%T %v\n", iface, problem == nil)

	if lo, hi := 1, 9; lo < hi {
		lo, hi = hi, lo
		fmt.Println(lo, hi)
	}
	switch lo, hi := divmod(9, 2); {
	case lo > hi:
		fmt.Println("more", lo, hi)
	}
}
"""#

private let parallelAssignmentAndSeveralNamesExpected = #"""
0 0 10 b 3 4 100 1
2 1
2 xy 4 2 true
3 4 7
0 0 s 5 1 2 2 e 9 true
uint8 int string *errors.errorString
2 <nil>
[1 4 3 2 5] 55 12
2 [99 4 3 2 5]
[7 8]
{2 1} [2] map[a:5 b:1] [9]
{100 1} {7 8} {7 8}
[3 50 1] 2
4 2 4 v typed 1
string false
9 1
more 4 1

"""#

private let eachIterationHasItsOwnVariablesSource = #"""
package main

import "fmt"

type node struct {
	id   int
	next *node
}

type registry struct {
	items []*counter
}

type counter struct {
	n int
}

func (c *counter) join(r *registry) {
	r.items = append(r.items, c)
}

func (c *counter) bump() {
	c.n++
}

type wrapper struct {
	inner counter
}

func show(label string, pointers []*int) {
	fmt.Print(label)
	for _, p := range pointers {
		fmt.Print(" ", *p)
	}
	fmt.Println()
}

func two(i int) (int, bool) {
	return i * 3, i%2 == 0
}

func main() {
	var declared []*int
	for i := 0; i < 3; i++ {
		x := i * 10
		declared = append(declared, &x)
	}
	show("declared in body:", declared)
	*declared[0] = 99
	show("after a store:", declared)

	var counters []*int
	for i := 0; i < 3; i++ {
		counters = append(counters, &i)
	}
	show("loop variable:", counters)

	var pairs []*int
	for i, j := 0, 10; i < 3; i, j = i+1, j-1 {
		pairs = append(pairs, &i, &j)
	}
	show("two loop variables:", pairs)

	source := []int{7, 8, 9}
	var ranged []*int
	var indexes []*int
	for index, value := range source {
		ranged = append(ranged, &value)
		indexes = append(indexes, &index)
	}
	show("range values:", ranged)
	show("range indexes:", indexes)

	var nodes []*node
	for i := 0; i < 3; i++ {
		n := node{id: i}
		if len(nodes) > 0 {
			n.next = nodes[len(nodes)-1]
		}
		nodes = append(nodes, &n)
	}
	fmt.Println(nodes[0].id, nodes[1].id, nodes[2].id, nodes[0] == nodes[1], nodes[2].next.next.id, nodes[0].next == nil)

	var vars []*int
	for i := 0; i < 3; i++ {
		var zero int
		zero += i
		vars = append(vars, &zero)
	}
	show("var in body:", vars)

	r := registry{}
	for i := 0; i < 3; i++ {
		c := counter{n: i}
		c.join(&r)
		c.bump()
	}
	fmt.Println(len(r.items), r.items[0].n, r.items[1].n, r.items[2].n)

	var slices [][]int
	for i := 0; i < 3; i++ {
		buffer := [2]int{i, i * 2}
		slices = append(slices, buffer[:])
	}
	fmt.Println(slices)

	var results []*int
	var flags []*bool
	for i := 0; i < 3; i++ {
		tripled, even := two(i)
		a, b := tripled+1, !even
		results = append(results, &tripled, &a)
		flags = append(flags, &even, &b)
	}
	show("call results:", results)
	fmt.Println(*flags[0], *flags[1], *flags[2], *flags[3], len(flags))

	var kept []*int
	for i := 0; i < 6; i++ {
		if i%2 == 1 {
			continue
		}
		kept = append(kept, &i)
	}
	show("with continue:", kept)

	var nested []*int
	for i := 0; i < 2; i++ {
		for j := 0; j < 2; j++ {
			cell := i*10 + j
			nested = append(nested, &cell)
		}
	}
	show("nested:", nested)

	total := 0
	for i := 0; i < 4; i++ {
		step := i * 2
		total += step
	}
	fmt.Println(total)

	var wrapped []*counter
	for i := 0; i < 2; i++ {
		w := wrapper{inner: counter{n: i}}
		w.inner.bump()
		wrapped = append(wrapped, &w.inner)
	}
	fmt.Println(wrapped[0].n, wrapped[1].n)

	var last *int
	for i := 0; i < 3; i++ {
		last = &i
		*last += 10
	}
	fmt.Println(*last)

	ch := make(chan int, 3)
	ch <- 1
	ch <- 2
	close(ch)
	var received []*int
	for v := range ch {
		received = append(received, &v)
	}
	show("channel:", received)
}
"""#

private let eachIterationHasItsOwnVariablesExpected = #"""
declared in body: 0 10 20
after a store: 99 10 20
loop variable: 0 1 2
two loop variables: 0 10 1 9 2 8
range values: 7 8 9
range indexes: 0 1 2
0 1 2 false 0 true
var in body: 0 1 2
3 1 2 3
[[0 0] [1 2] [2 4]]
call results: 0 1 3 4 6 7
true false false true 6
with continue: 0 2 4
nested: 0 1 10 11
12
1 2
10
channel: 1 2

"""#

private let groupedDeclarationsAndIotaSource = #"""
package main

import (
	"errors"
	"fmt"
	"strings"
)

type (
	color int
	point struct {
		X int
		Y int
	}
	shape interface {
		area() int
	}
)

const (
	red color = iota
	green
	blue
)

const (
	_  = iota
	kb = 1 << (10 * iota)
	mb
	gb
)

const (
	a, b = iota, iota * 10
	c, d
	e, f
)

const (
	first  = "one"
	second = len(first)
	third
)

const single = iota

var (
	origin    point
	names     = []string{"red", "green", "blue"}
	width, _  = 80, 24
	total     int
	errClosed     = errors.New("closed")
	limit     int = kb / 2
)

func (c color) String() string {
	return names[c]
}

func (p point) area() int {
	return p.X * p.Y
}

func main() {
	const (
		small = iota + 1
		medium
		large
	)
	var (
		s     shape = point{X: 2, Y: 3}
		label       = strings.ToUpper("ok")
		n, m  int
		x, y  = 1, "y"
	)
	const local = iota
	fmt.Println(red, green, blue, kb, mb, gb)
	fmt.Println(a, b, c, d, e, f, first, second, third, single)
	fmt.Println(origin, names, width, total, errClosed, limit)
	fmt.Println(small, medium, large, s.area(), label, n, m, x, y, local)
	fmt.Printf("%T %T %v %d\n", blue, kb, blue, blue)
}
"""#

private let groupedDeclarationsAndIotaExpected = #"""
red green blue 1024 1048576 1073741824
0 0 1 10 2 20 one 3 3 0
{0 0} [red green blue] 80 0 closed 512
1 2 3 6 OK 0 0 1 y 0
main.color int blue 2

"""#

private let importNamesAndTheProgramsOwnNamesSource = #"""
package main

import (
	"errors"
	f "fmt"
	str "strings"
	_ "sort"
	conv "strconv"
	stdtime "time"
)

type point struct {
	X int
	Y int
}

// A program's own names may be those of packages it calls something else.
func describe(strings []string, time int) string {
	fmt := str.Join(strings, "+")
	return f.Sprintf("%s@%d", fmt, time)
}

func elapsed(since stdtime.Time) bool {
	stdtime.Sleep(2 * stdtime.Millisecond)
	return stdtime.Since(since) >= 2*stdtime.Millisecond
}

func parse(text string) (int, error) {
	n, err := conv.Atoi(text)
	if err != nil {
		return 0, errors.New("bad number: " + text)
	}
	return n, nil
}

func main() {
	f.Println("alias", str.ToUpper("fmt"), str.Repeat("ab", 2))
	f.Println(describe([]string{"a", "b"}, 7))
	f.Println(elapsed(stdtime.Now()))
	n, err := parse("42")
	f.Println(n, err)
	n, err = parse("x")
	f.Println(n, err)

	// An alias is a name like any other: a block may declare it again.
	if n == 0 {
		str := "shadow"
		f.Println(str, len(str))
	}
	f.Println(str.Contains("shadow", "had"))

	conv := point{X: 3, Y: 4}
	f.Println(conv.X+conv.Y, conv)
	time := []int{1, 2, 3}
	f.Println(len(time), time)
	var started stdtime.Time = stdtime.Now()
	f.Printf("%v %T\n", elapsed(started), started)
	f.Printf("%T %v\n", conv, f.Sprint(conv))
}
"""#

private let importNamesAndTheProgramsOwnNamesExpected = #"""
alias FMT abab
a+b@7
true
42 <nil>
0 bad number: x
shadow 6
true
7 {3 4}
3 [1 2 3]
true time.Time
main.point {3 4}

"""#

private let importNamesAtTheEdgesSource = #"""
package main

import (
	. "fmt"
	web "net/http"
	"os"
	sys "os"
	strings "strings"
	sc "strconv"
	sorting "sort"
)

type item struct {
	Name string
}

var total int

func init() {
	type weight int
	total += int(weight(4))
}

func (i item) label() string {
	type tag struct {
		text string
	}
	return tag{text: "<" + i.Name + ">"}.text
}

// The names of parameters, results, and loop variables hide an import's.
func hidden(sc []string, sorting int) (sys string) {
	for strings := range sc {
		sys += Sprint(strings+sorting, ";")
	}
	return sys
}

func kinds(values []interface{}) string {
	type small int
	out := ""
	for _, v := range values {
		type small string
		if _, ok := v.(small); ok {
			out += "S"
		} else {
			out += "-"
		}
	}
	if _, ok := values[0].(small); ok {
		out += "I"
	}
	return out
}

func build() interface{} {
	type small int
	return small(5)
}

func collections() {
	type entry struct {
		Key   string
		Count int
	}
	list := make([]entry, 0)
	list = append(list, entry{Key: "a", Count: 1}, entry{"b", 2})
	byKey := map[string]*entry{}
	for i := range list {
		byKey[list[i].Key] = &list[i]
	}
	byKey["a"].Count += 10
	queue := make(chan entry, 1)
	queue <- list[0]
	got := <-queue
	var grid [2]entry
	grid[1] = got
	Println(list, len(byKey), got, grid)
	Printf("%T %T %T\n", list, byKey, grid)

	if len(list) == 2 {
		// A variable of an inner block takes the name back.
		entry := 3
		Println(entry + 1)
	}
	var last entry = list[1]
	Println(last.Key)
}

func handle(w web.ResponseWriter, r *web.Request) {
	total++
}

func main() {
	Println(strings.ToUpper("dot"), sc.Itoa(12)+"!", len(os.Args) == len(sys.Args))
	names := []string{"b", "a"}
	sorting.Strings(names)
	Println(names, hidden(names, 1), total)
	Println(item{Name: "x"}.label(), kinds([]interface{}{build(), "s", 1}))
	collections()
	Fprintln(sys.Stdout, "done")
}
"""#

private let importNamesAtTheEdgesExpected = #"""
DOT 12! true
[a b] 1;2; 4
<x> ---
[{a 11} {b 2}] 2 {a 11} [{ 0} {a 11}]
[]main.entry map[string]*main.entry [2]main.entry
4
b
done

"""#

private let typesDeclaredInFunctionsSource = #"""
package main

import (
	"errors"
	"fmt"
)

type point struct {
	X int
	Y int
}

type shape interface {
	Area() int
}

type square struct {
	Side int
}

func (s square) Area() int { return s.Side * s.Side }

// A type of the same name in another function is another type.
func first() interface{} {
	type pair struct {
		A int
		B string
	}
	return pair{A: 1, B: "one"}
}

func second() interface{} {
	type pair struct {
		Left  string
		Right string
	}
	return &pair{Left: "l", Right: "r"}
}

func total(values []int) int {
	type sum int
	var s sum
	for _, v := range values {
		s += sum(v)
	}
	return int(s)
}

func list() []string {
	type node struct {
		name string
		next *node
	}
	tail := &node{name: "c"}
	head := &node{name: "a", next: &node{name: "b", next: tail}}
	var names []string
	for n := head; n != nil; n = n.next {
		names = append(names, n.name)
	}
	return names
}

func scopes() {
	// A local type hides the package's type of that name from there on.
	p := point{X: 1, Y: 2}
	type point struct {
		Name string
	}
	q := point{Name: "local"}
	fmt.Println(p, q)
	fmt.Printf("%T %T\n", p, q)
	if p.X == 1 {
		type point int
		var r point = 7
		fmt.Printf("%v %T\n", r, r)
	}
	var s point
	s.Name = "again"
	fmt.Printf("%+v %T\n", s, s)
}

func grouped() {
	type (
		id    int
		names []string
		table map[string]id
		named interface {
			Area() int
		}
	)
	t := table{"a": 1, "b": 2}
	n := names{"x", "y"}
	var v named = square{Side: 3}
	fmt.Println(t["a"]+t["b"], len(n), n, v.Area())
	fmt.Printf("%T %T %T\n", t, n, id(3))
}

var steps int

func closures() int {
	type step int
	done := make(chan bool)
	defer func() {
		// The function's own type, not the one around it.
		type step struct {
			by int
		}
		steps += step{by: 2}.by
		fmt.Printf("%T %d\n", step{}, steps)
	}()
	go func(done chan bool) {
		type step string
		steps += len(step("abc"))
		done <- true
	}(done)
	<-done
	return steps + int(step(10))
}

func asserted(v interface{}) string {
	type pair struct {
		A int
		B string
	}
	if _, ok := v.(pair); ok {
		return "pair"
	}
	if s, ok := v.(shape); ok {
		return fmt.Sprint("shape ", s.Area())
	}
	return fmt.Sprintf("%T", v)
}

var failed error

func failing() {
	type failure struct {
		Code int
	}
	defer func() {
		if r := recover(); r != nil {
			failed = errors.New(fmt.Sprint("recovered: ", r))
		}
	}()
	panic(failure{Code: 3})
}

func main() {
	a, b := first(), second()
	fmt.Printf("%v %T\n", a, a)
	fmt.Printf("%v %T\n", b, b)
	fmt.Printf("%+v\n", a)
	fmt.Println(total([]int{1, 2, 3}), list())
	scopes()
	grouped()
	fmt.Println(closures())
	fmt.Println(asserted(a), asserted(square{Side: 2}), asserted(3))
	failing()
	fmt.Println(failed)
}
"""#

private let typesDeclaredInFunctionsExpected = #"""
{1 one} main.pair
&{l r} *main.pair
{A:1 B:one}
6 [a b c]
{1 2} {local}
main.point main.point
7 main.point
{Name:again} main.point
3 2 [x y] 9
main.table main.names main.id
main.step 5
13
main.pair shape 4 int
recovered: {3}

"""#

private let localTypesInAssertionsSource = #"""
package main

import (
	"fmt"
	"os"
)

type pair struct {
	Z int
}

func make1() interface{} {
	type pair struct {
		A int
	}
	return pair{A: 1}
}

func try(v interface{}) {
	defer func() {
		fmt.Println(recover())
	}()
	type pair struct {
		A int
	}
	p := v.(pair)
	fmt.Println("unreachable", p)
}

func outer(v interface{}) {
	defer func() {
		fmt.Println(recover())
	}()
	fmt.Println(v.(pair))
}

func pointers(v interface{}) {
	defer func() {
		fmt.Println(recover())
	}()
	type pair struct {
		A int
	}
	fmt.Println(v.(*pair))
}

func main() {
	type pair struct {
		A int
	}
	try(make1())
	outer(make1())
	pointers(&pair{A: 2})
	if _, ok := make1().(pair); !ok {
		fmt.Fprintln(os.Stdout, "not the same pair")
	}
}
"""#

private let localTypesInAssertionsExpected = #"""
interface conversion: interface {} is main.pair, not main.pair (types from different scopes)
interface conversion: interface {} is main.pair, not main.pair (types from different scopes)
interface conversion: interface {} is *main.pair, not *main.pair (types from different scopes)
not the same pair

"""#
