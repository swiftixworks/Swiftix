/// The blanks around binary operators, and the parentheses `gofmt` drops.
///
/// `operatorSource` below was formatted by the `gofmt` of Go 1.24.5, and
/// `operatorExpected` is its output, copied without change: the test requires
/// Swiftix `gofmt` to print the same bytes. The file covers each rule of
/// Go's printer: the precedence mix at depth 1, the nesting that calls,
/// indexes, lists of values, and operands of another precedence add,
/// parentheses that take a level back, operators that would run into a unary
/// operator, compound assignment, and the `:` of a slice expression.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go gofmt operator spacing")
struct GoOperatorSpacingTests: GoTestHarness {

    private func format(_ text: String) throws -> String {
        try GoFormatter.format(GoSourceFile(path: "main.go", text: text))
    }

    /// The body of `func main` after formatting, without its indentation.
    private func formatted(_ statements: String) throws -> [Substring] {
        let text = try format("package main\n\nfunc main() {\n" + statements + "\n}\n")
        return text.split(separator: "\n").dropFirst(2).dropLast().map { $0.dropFirst() }
    }

    @Test func theOutputIsWhatGofmtPrints() throws {
        let actual = try format(operatorSource).split(
            separator: "\n", omittingEmptySubsequences: false)
        let wanted = operatorExpected.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(actual.count == wanted.count)
        for (number, pair) in zip(actual, wanted).enumerated() {
            #expect(pair.0 == pair.1, "line \(number + 1)")
        }
    }

    @Test func formattingAgainChangesNothing() throws {
        let once = try format(operatorSource)
        #expect(try format(once) == once)
        #expect(try format(operatorExpected) == operatorExpected)
    }

    @Test func precedenceShowsAtDepthOne() throws {
        #expect(
            try formatted("x = a+b\nx = a*b\nx = a+b*c\nx = a*b+c*d\nx = a|b&c\nx = a<<2+b")
                == ["x = a + b", "x = a * b", "x = a + b*c", "x = a*b + c*d", "x = a | b&c", "x = a<<2 + b"])
        // Comparisons and logical operators always have blanks, and what
        // they compare is one level deeper.
        #expect(
            try formatted("ok = a+b<c*d\nok = a<b&&c>d||e==f\nok = !ok&&a+1>b")
                == ["ok = a+b < c*d", "ok = a < b && c > d || e == f", "ok = !ok && a+1 > b"])
    }

    @Test func nestingJoinsOperatorsToTheirOperands() throws {
        // One argument keeps the depth; several add a level, as an index does.
        #expect(
            try formatted("x = f(a+b)\nx = f(a+b,c)\nx = f(f(a+b),c)\nx = list[i+1]\nx = f(a+b)+c")
                == ["x = f(a + b)", "x = f(a+b, c)", "x = f(f(a+b), c)", "x = list[i+1]", "x = f(a+b) + c"])
        // Several values on both sides of an assignment add one too.
        #expect(
            try formatted("x, y = y+1, x*2\nx, y := a+b, c*d\nx = a+b\nlist[i+1]++")
                == ["x, y = y+1, x*2", "x, y := a+b, c*d", "x = a + b", "list[i+1]++"])
        // A compound assignment holds only its right side.
        #expect(
            try formatted("x += a*b\nx += a+b*c\nx <<= a+1\nlist[i+1] += a*b")
                == ["x += a * b", "x += a + b*c", "x <<= a + 1", "list[i+1] += a * b"])
    }

    @Test func parenthesesTakeOneLevelBack() throws {
        #expect(
            try formatted("x = (a+b)*c\nx = a*(b+c*d)\nx = f((a+b)*c,d)\nx = f((a+b),c)\nx = -(a+b)")
                == ["x = (a + b) * c", "x = a * (b + c*d)", "x = f((a+b)*c, d)", "x = f((a + b), c)", "x = -(a + b)"])
    }

    @Test func anOperatorKeepsClearOfAUnaryOne() throws {
        #expect(
            try formatted(
                "x = f(a- -b,c)\nx = f(a+ +b,c)\nx = f(a/ *p,c)\nx = f(a& &b,c)\nx = f(a& ^b,c)\nx = f(a+ -b,c)\nx = f(a*-b,c)")
                == [
                    "x = f(a - -b, c)", "x = f(a + +b, c)", "x = f(a / *p, c)",
                    "x = f(a & &b, c)", "x = f(a & ^b, c)", "x = f(a+-b, c)", "x = f(a*-b, c)",
                ])
    }

    @Test func theColonOfASliceHasBlanksBesideABinaryBound() throws {
        #expect(
            try formatted(
                "y = list[a:b]\ny = list[a+1:b]\ny = list[a:b+1]\ny = list[a+1:]\ny = list[:b-1]\ny = f(list[a+1:b],c)\ny = list[(a+1):b]")
                == [
                    "y = list[a:b]", "y = list[a+1 : b]", "y = list[a : b+1]", "y = list[a+1:]",
                    "y = list[:b-1]", "y = f(list[a+1:b], c)", "y = list[(a + 1):b]",
                ])
        // Inside a literal the colon of a slice is not the colon of a key.
        #expect(
            try formatted(
                "z := []string{text[1:2], text[a+1:b]}\nw := map[string]string{\"k\": text[1:]}")
                == ["z := []string{text[1:2], text[a+1 : b]}", "w := map[string]string{\"k\": text[1:]}"])
    }

    @Test func parenthesesThatSayNothingAreDropped() throws {
        #expect(
            try formatted(
                "x = ((a+b))*c\nx = f((a),((b)))\nif (a > b) {\n}\nfor (i < n) {\n}\nswitch (a) {\n}\nfor _, v := range (list) {\n}")
                == [
                    "x = (a + b) * c", "x = f((a), (b))", "if a > b {", "}", "for i < n {", "}",
                    "switch a {", "}", "for _, v := range list {", "}",
                ])
        // Not where they keep a literal's brace from opening the block, and
        // not around a part of the condition.
        #expect(
            try formatted(
                "if (p == point{X: 1}) {\n}\nif (a+b) > c {\n}\nif (f(point{X: 1}.X)) > 0 {\n}")
                == [
                    "if (p == point{X: 1}) {", "}", "if (a + b) > c {", "}",
                    "if (f(point{X: 1}.X)) > 0 {", "}",
                ])
    }

    @Test func theParserReportsItsParentheses() throws {
        let text = "package main\nfunc main() {\n\tx = ((a + b)) * f(c)\n}\n"
        let parsed = try GoParser.parseRecordingParentheses(
            GoSourceFile(path: "main.go", text: text))
        let bytes = Array(text.utf8)

        // One pair around `a + b`, by the offset of its operator, and a
        // second pair that is redundant. The parentheses of the call are not
        // parentheses around an expression.
        #expect(parsed.parentheses.pairs.count == 1)
        let pair = try #require(parsed.parentheses.pairs.first)
        #expect(bytes[pair.key] == UInt8(ascii: "+"))
        #expect(bytes[pair.value.open] == UInt8(ascii: "("))
        #expect(bytes[pair.value.close] == UInt8(ascii: ")"))
        #expect(pair.value.close - pair.value.open == "(a + b".utf8.count)
        #expect(parsed.parentheses.redundant.count == 2)
        #expect(try GoParser.parse(GoSourceFile(path: "main.go", text: text)) == parsed.file)
    }

    @Test func aFormattedProgramMeansTheSame() throws {
        let source = """
            package main
            import "fmt"
            func main() {
            a, b, c := 7, 3, 2
            list := []int{10, 20, 30, 40}
            fmt.Println(a+b*c, (a+b)*c, a- -b, a*-b, a<<1+b, a|b&c, a&^b)
            fmt.Println(list[a-b*c:], list[b-c:a-b], ((a+b))*c, a+b > c*b && a-b < c)
            if (a > b) {
            a, b = b+1, a*2
            list[c-1] += a*b
            }
            fmt.Println(a, b, list)
            }

            """
        let once = try format(source)
        func output(_ text: String) throws -> String {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(path: "main.go", text: text)
            ])
            var output = ""
            try GoVirtualMachine().run(executable) { output += $0 }
            return output
        }

        #expect(try output(once) == output(source))
        #expect(once.contains("fmt.Println(a+b*c, (a+b)*c, a - -b, a*-b, a<<1+b, a|b&c, a&^b)"))
        #expect(once.contains("if a > b {"))
    }
}

private let operatorSource = #"""
package main

import "fmt"

type point struct {
	X int
}

var g1 = a+b*c
var g2 = (a+b)*c
var g3, g4 = a+b, c*d

func f(values ...int) int {
	return 0
}

func main() {
	x := a+b
	x = a*b
	x = a+b*c
	x = a*b+c
	x = a*b+c*d
	x = a+b+c
	x = a*b*c
	x = a+b-c*d/e
	x = (a+b)*c
	x = (a+b)*(c-d)
	x = a*(b+c)
	x = a*(b+c*d)
	x = (a*b+c)*d
	x = ((a+b))*c
	x = -a+b
	x = a+ -b
	x = a- -b
	x = a*-b
	x = a/ *p
	x = a& &b
	x = a&^b
	x = a& ^b
	x = a+ +b
	x = a<<2
	x = a<<2+b
	x = a|b&c
	x = a|b|c
	x = a&b|c&d
	x = a^b
	x = a%b+c
	x = a<<b>>c
	ok := a+b<c*d
	ok = a<b&&c>d||e==f
	ok = a+b==c&&d*e!=f
	ok = !ok&&a+1>b
	ok = a<b==true
	x = f(a+b)
	x = f(a+b,c)
	x = f(a*b,c+d)
	x = f(a+b*c)
	x = f(a+b*c,d)
	x = f(f(a+b),c)
	x = f(f(a+b,c))
	x = f(a,f(b+c))
	x = f((a+b),c)
	x = f((a+b)*c,d)
	x = f(a<b,c)
	x = f(a+b)+c
	x = f(a+b,c)+d*e
	x = list[i+1]
	x = list[i+1]+list[i*2]
	x = list[f(a+b)]
	x = list[f(a+b,c)]
	x = grid[i+1][j*2]
	x = m[k+"x"]
	y := list[a+1:]
	y = list[:b-1]
	y = list[a:b]
	y = list[a+1:b]
	y = list[a:b+1]
	y = list[a+1:b*2]
	y = list[f(a):b]
	y = list[len(list)-1:]
	y = list[(a+1):b]
	y = f2(list[a+1:b],c)
	z := f(list[a+1:b])
	s := text[i+1:len(text)-1]
	x += a*b
	x += a+b*c
	x -= a*b+c
	x <<= a+1
	x |= a&b
	list[i+1] += a*b
	list[i+1] = a+b
	list[i+1]++
	p.X++
	x, y2 := a+b, c*d
	x, y2 = y2+1, x*2
	x, y2 = y2, x
	a, b = f(a+b), f(c*d,e)
	if a+b > c {
	}
	if a+b*c > d {
	}
	if x := a+b; x > c*d {
	}
	if (a+b) > c {
	}
	for i := 0; i < n-1; i++ {
	}
	for i := a+1; i < len(list)-1; i += 2 {
	}
	for i, j := 0, len(list)-1; i < j; i, j = i+1, j-1 {
	}
	for _, v := range list[a+1:] {
	}
	switch a+b {
	case c+d, e*f:
	}
	switch x := a*b; x+1 {
	case a+b*c:
	}
	q := point{X: a+b}
	r := []int{a+b, c*d, e+f*g}
	t := map[string]int{"a"+"b": c*d}
	u := &point{X: a*b+c}
	w := []int{f(a+b,c)}
	fmt.Println(a+b)
	fmt.Println(a+b, c*d)
	fmt.Println("total: "+text, a+1)
	fmt.Println(q, r, t, u, w, y, z, s, ok)
	ch <- a+b
	ch <- a+b*c
	v := <-ch+1
	go f(a+b)
	defer f(a+b, c*d)
	c2 := int(a+b)
	c3 := string(text[i+1])
	c4 := []byte(text+"x")
	c5 := len(list)+1
	c6 := len(list)*2+1
	c7 := -(a+b)
	c8 := f(-(a+b), c)
	c9 := *p+1
	c10 := *p*2
	c11 := f(*p+1, c)
	c12 := value.(int)+1
	c13 := f(value.(int)+1, c)
	c14 := p.X+1
	c15 := f(p.X+1, c)
	c16 := a+b+c*d+e
	c17 := a*b+c*d+e*f
	c18 := a+b*c+d
	c19 := (a+b*c)+d
	c20 := a+(b*c+d)
	c21 := a*b*(c+d)
	c22 := a/b*c
	c23 := a-b-c
	c24 := a+f(b*c, d)+e
	c25 := f(a)(b+c)
	return a+b
	return a+b, c*d
	return f(a+b, c), a*b+c
}

func parens() {
	if (a > b) {
	}
	if ((a > b)) {
	}
	if (a > b) && (c > d) {
	}
	if (a+b) > c {
	}
	if x := (a+b); (x > c) {
	}
	for (i < n) {
	}
	for i := 0; (i < n); i++ {
	}
	for _, v := range (list) {
	}
	switch (a+b) {
	case (c):
	}
	switch x := 1; (x) {
	}
	x = ((a))
	x = (((a+b)))*c
	x = f((a), ((b)))
	x = (f)(a)
	x = (a)
	x = -(a)
	x = -((a+b))
	y = (list)[1:]
	if (list[0] == []int{1}[0]) {
	}
	if (f(point{X: 1}.X)) > 0 {
	}
	return (a+b)
	return (a), (b*c)
}

"""#

private let operatorExpected = #"""
package main

import "fmt"

type point struct {
	X int
}

var g1 = a + b*c
var g2 = (a + b) * c
var g3, g4 = a + b, c * d

func f(values ...int) int {
	return 0
}

func main() {
	x := a + b
	x = a * b
	x = a + b*c
	x = a*b + c
	x = a*b + c*d
	x = a + b + c
	x = a * b * c
	x = a + b - c*d/e
	x = (a + b) * c
	x = (a + b) * (c - d)
	x = a * (b + c)
	x = a * (b + c*d)
	x = (a*b + c) * d
	x = (a + b) * c
	x = -a + b
	x = a + -b
	x = a - -b
	x = a * -b
	x = a / *p
	x = a & &b
	x = a &^ b
	x = a & ^b
	x = a + +b
	x = a << 2
	x = a<<2 + b
	x = a | b&c
	x = a | b | c
	x = a&b | c&d
	x = a ^ b
	x = a%b + c
	x = a << b >> c
	ok := a+b < c*d
	ok = a < b && c > d || e == f
	ok = a+b == c && d*e != f
	ok = !ok && a+1 > b
	ok = a < b == true
	x = f(a + b)
	x = f(a+b, c)
	x = f(a*b, c+d)
	x = f(a + b*c)
	x = f(a+b*c, d)
	x = f(f(a+b), c)
	x = f(f(a+b, c))
	x = f(a, f(b+c))
	x = f((a + b), c)
	x = f((a+b)*c, d)
	x = f(a < b, c)
	x = f(a+b) + c
	x = f(a+b, c) + d*e
	x = list[i+1]
	x = list[i+1] + list[i*2]
	x = list[f(a+b)]
	x = list[f(a+b, c)]
	x = grid[i+1][j*2]
	x = m[k+"x"]
	y := list[a+1:]
	y = list[:b-1]
	y = list[a:b]
	y = list[a+1 : b]
	y = list[a : b+1]
	y = list[a+1 : b*2]
	y = list[f(a):b]
	y = list[len(list)-1:]
	y = list[(a + 1):b]
	y = f2(list[a+1:b], c)
	z := f(list[a+1 : b])
	s := text[i+1 : len(text)-1]
	x += a * b
	x += a + b*c
	x -= a*b + c
	x <<= a + 1
	x |= a & b
	list[i+1] += a * b
	list[i+1] = a + b
	list[i+1]++
	p.X++
	x, y2 := a+b, c*d
	x, y2 = y2+1, x*2
	x, y2 = y2, x
	a, b = f(a+b), f(c*d, e)
	if a+b > c {
	}
	if a+b*c > d {
	}
	if x := a + b; x > c*d {
	}
	if (a + b) > c {
	}
	for i := 0; i < n-1; i++ {
	}
	for i := a + 1; i < len(list)-1; i += 2 {
	}
	for i, j := 0, len(list)-1; i < j; i, j = i+1, j-1 {
	}
	for _, v := range list[a+1:] {
	}
	switch a + b {
	case c + d, e * f:
	}
	switch x := a * b; x + 1 {
	case a + b*c:
	}
	q := point{X: a + b}
	r := []int{a + b, c * d, e + f*g}
	t := map[string]int{"a" + "b": c * d}
	u := &point{X: a*b + c}
	w := []int{f(a+b, c)}
	fmt.Println(a + b)
	fmt.Println(a+b, c*d)
	fmt.Println("total: "+text, a+1)
	fmt.Println(q, r, t, u, w, y, z, s, ok)
	ch <- a + b
	ch <- a + b*c
	v := <-ch + 1
	go f(a + b)
	defer f(a+b, c*d)
	c2 := int(a + b)
	c3 := string(text[i+1])
	c4 := []byte(text + "x")
	c5 := len(list) + 1
	c6 := len(list)*2 + 1
	c7 := -(a + b)
	c8 := f(-(a + b), c)
	c9 := *p + 1
	c10 := *p * 2
	c11 := f(*p+1, c)
	c12 := value.(int) + 1
	c13 := f(value.(int)+1, c)
	c14 := p.X + 1
	c15 := f(p.X+1, c)
	c16 := a + b + c*d + e
	c17 := a*b + c*d + e*f
	c18 := a + b*c + d
	c19 := (a + b*c) + d
	c20 := a + (b*c + d)
	c21 := a * b * (c + d)
	c22 := a / b * c
	c23 := a - b - c
	c24 := a + f(b*c, d) + e
	c25 := f(a)(b + c)
	return a + b
	return a + b, c * d
	return f(a+b, c), a*b + c
}

func parens() {
	if a > b {
	}
	if a > b {
	}
	if (a > b) && (c > d) {
	}
	if (a + b) > c {
	}
	if x := (a + b); x > c {
	}
	for i < n {
	}
	for i := 0; i < n; i++ {
	}
	for _, v := range list {
	}
	switch a + b {
	case (c):
	}
	switch x := 1; x {
	}
	x = (a)
	x = (a + b) * c
	x = f((a), (b))
	x = (f)(a)
	x = (a)
	x = -(a)
	x = -(a + b)
	y = (list)[1:]
	if list[0] == []int{1}[0] {
	}
	if (f(point{X: 1}.X)) > 0 {
	}
	return (a + b)
	return (a), (b * c)
}

"""#
