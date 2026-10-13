/// How `gofmt` writes labels, jumps, and type switches, and what `gofmt -r`
/// rewrites in them.
///
/// Each `Expected` string below is what the `gofmt` of Go 1.24.5 printed for
/// the `Source` above it, copied without change; the tests require Swiftix
/// `gofmt` to print the same bytes, and to leave that output as it is when
/// formatting it again. `rewrites` holds rules and, for each, the lines of
/// `rewriteSource` that the `gofmt -r` of Go 1.24.5 changes, with what it
/// makes of them: a label is an identifier a rule renames, the operand of a
/// type switch is an expression like any other, and the types of its
/// clauses are matched as Go's tree has them.
///
/// To add a case, format the source with Go and paste both texts.

@testable import SwiftixGo
import Testing

@Suite("Go gofmt of labels, jumps, and type switches")
struct GoControlFlowGofmtTests {

    /// Compares line by line, so a failure shows the one line that differs.
    private func expectGofmt(_ source: String, _ expected: String) throws {
        let formatted = try GoFormatter.format(GoSourceFile(path: "main.go", text: source))
        let actual = formatted.split(separator: "\n", omittingEmptySubsequences: false)
        let wanted = expected.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(actual.count == wanted.count)
        for (number, pair) in zip(actual, wanted).enumerated() {
            #expect(pair.0 == pair.1, "line \(number + 1)")
        }
        // What Go's printer wrote, it writes again.
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: expected)) == expected)
    }

    /// A label has a line of its own, one level out from the statement it
    /// names, wherever the source put it; `goto`, `break`, and `continue` keep
    /// one blank before their label; a `select` without clauses stays on its
    /// line; and the header and the clauses of a type switch are spaced like
    /// those of any switch.
    @Test func labelsAndJumps() throws {
        try expectGofmt(labelsAndJumpsSource, labelsAndJumpsExpected)
    }

    /// A comment before a label keeps the indentation of the statements, one
    /// beside a label stays on its line, an empty line after a label is kept,
    /// and the empty statement a label names is written out. A function whose
    /// body has a label does not stay on one line.
    @Test func labelsBesideCommentsAndEmptyStatements() throws {
        try expectGofmt(labelsBesideCommentsAndEmptyStatementsSource, labelsBesideCommentsAndEmptyStatementsExpected)
    }

    /// The types of a clause: pointers, slices, maps, channels of each
    /// direction, function and interface types, with the line breaks and the
    /// comments the source has among them; and `range` over an integer.
    @Test func typeSwitchClauses() throws {
        try expectGofmt(typeSwitchClausesSource, typeSwitchClausesExpected)
    }

    /// A file with a mistake in its labels or jumps is one `gofmt` formats:
    /// Go's `gofmt` does not check them, and neither does this one.
    @Test func whatTheCompilerRefusesIsStillFormatted() throws {
        try expectGofmt(uncheckedSource, uncheckedExpected)
    }

    @Test(arguments: rewrites.indices)
    func theRuleRewritesWhatGofmtRewrites(index: Int) throws {
        let (rule, changes) = Self.rewrites[index]
        var expected = rewriteSource.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for (line, text) in changes { expected[line - 1] = text }
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(path: "main.go", text: rewriteSource), rule: rule)
        let actual = try GoFormatter.format(rewritten)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(actual.count == expected.count, "\(rule)")
        for (number, pair) in zip(actual, expected).enumerated() {
            #expect(pair.0 == pair.1, "\(rule), line \(number + 1)")
        }
    }

    /// Rules and the lines of `rewriteSource` each changes, by line number.
    static let rewrites: [(rule: String, changes: [Int: String])] = [
        ("outer -> loop", [12: "loop:", 17: "\t\t\tcontinue loop", 20: "\t\t\tbreak loop", 22: "\t\t\tgoto loop"]),
        ("get(a, b) -> a[b]", [14: "\t\tswitch v := m[\"a\"].(type) {"]),
        ("T -> U", [5: "type U struct{ n int }", 15: "\t\tcase int, U:", 28: "\tcase *U:"]),
        ("fmt.Stringer -> Stringer", [21: "\t\tcase Stringer:"]),
        ("a[b:len(a)] -> a[b:]", [19: "\t\t\tfmt.Println(v[0:])"]),
        ("len(m) -> size", [13: "\tfor i := 0; i < size; i++ {", 19: "\t\t\tfmt.Println(v[0:size])", 31: "\tcase size > 0:"]),
        ("[]int -> []T", [18: "\t\tcase []T:"]),
        ("nil -> none", [23: "\t\tcase none:"]),
        ("m[\"a\"] -> first", [11: "\tvar x any = first"]),
    ]
}

private let labelsAndJumpsSource = #"""
package main

import "fmt"

type T struct{}

func main() {
	var x any = 1
outer:   for i := 0; i < 3; i++ {
inner:
		for j := 0; j < 3; j++ {
			if j == 1 { continue   outer }
			if i == 2 { break outer }
			fmt.Println(i, j)
			goto   inner2
			inner2: fmt.Println("x")
			break inner
		}
	}
	switch   v:=x.(type){
	case   int ,string:
		fmt.Println(v)
	case nil  :
	case *T,[ ]int , map[string]int,chan  int,<-chan int, chan<- int:
	case func( int )  int:
	case interface{ M( ) }  , error:
	case struct{}, struct{ x int }:
	case fmt.Stringer:
	default  :
	}
	switch   x .( type ) {
	}
	switch y:=x ; z := y.(type) {
	case int: _ = z
	}
	switch x := x.(type) { case int: _ = x; case string: _ = x }
	switch {
	case true: fallthrough
	case false:
		fmt.Println()
		fallthrough
	default:
	}
L1: { }
L2:
	select { }
L3: switch { }
	{
	L4: for { break L4 }
	}
	if true {
		L5:
		for { continue L5 }
	}
	switch {
	case true:
		L6: for { break L6 }
		L7:
	}
	for range 10 { }
	for i:=range  10 { _ = i }
	for i:=range  len("abc")+1 { _ = i }
	func() {
		L8:
			for { break L8 }
	}()
L9: x = 2; goto L9
L10:
	// comment
	x = 3
L11: // trailing
	x = 4
	goto L10
	goto L11
end:
}

"""#

private let labelsAndJumpsExpected = #"""
package main

import "fmt"

type T struct{}

func main() {
	var x any = 1
outer:
	for i := 0; i < 3; i++ {
	inner:
		for j := 0; j < 3; j++ {
			if j == 1 {
				continue outer
			}
			if i == 2 {
				break outer
			}
			fmt.Println(i, j)
			goto inner2
		inner2:
			fmt.Println("x")
			break inner
		}
	}
	switch v := x.(type) {
	case int, string:
		fmt.Println(v)
	case nil:
	case *T, []int, map[string]int, chan int, <-chan int, chan<- int:
	case func(int) int:
	case interface{ M() }, error:
	case struct{}, struct{ x int }:
	case fmt.Stringer:
	default:
	}
	switch x.(type) {
	}
	switch y := x; z := y.(type) {
	case int:
		_ = z
	}
	switch x := x.(type) {
	case int:
		_ = x
	case string:
		_ = x
	}
	switch {
	case true:
		fallthrough
	case false:
		fmt.Println()
		fallthrough
	default:
	}
L1:
	{
	}
L2:
	select {}
L3:
	switch {
	}
	{
	L4:
		for {
			break L4
		}
	}
	if true {
	L5:
		for {
			continue L5
		}
	}
	switch {
	case true:
	L6:
		for {
			break L6
		}
	L7:
	}
	for range 10 {
	}
	for i := range 10 {
		_ = i
	}
	for i := range len("abc") + 1 {
		_ = i
	}
	func() {
	L8:
		for {
			break L8
		}
	}()
L9:
	x = 2
	goto L9
L10:
	// comment
	x = 3
L11: // trailing
	x = 4
	goto L10
	goto L11
end:
}

"""#

private let labelsBesideCommentsAndEmptyStatementsSource = #"""
package main

func main() {
	x := 1
	// before label
L:
	for {
		break L
	}

	// before label, after blank

M: /* block */ for {
		break M
	}
N: x = 2 // trailing after statement
	goto N
O:

	x = 3
	goto O
	if x > 0 {
	P: ; x = 4
	Q: }
	switch x {
	case 1:
		R: ;
	case 2:
		// c
		S: x++
	}
	select {
	case <-ch:
	T: x++
	default:
	}
	var f = func() {
	U: for { continue U }
	}
	for {
		for {
V: W: x = 1
		}
	}
	s := []func(){
		func() {
		X: goto X
		},
	}
	longlabelname: x = 5
	a: x = 6
End:
	// last comment
}

func g() {
A:
}

func h() { goto B; B: }

"""#

private let labelsBesideCommentsAndEmptyStatementsExpected = #"""
package main

func main() {
	x := 1
	// before label
L:
	for {
		break L
	}

	// before label, after blank

M: /* block */
	for {
		break M
	}
N:
	x = 2 // trailing after statement
	goto N
O:

	x = 3
	goto O
	if x > 0 {
	P:
		;
		x = 4
	Q:
	}
	switch x {
	case 1:
	R:
		;
	case 2:
		// c
	S:
		x++
	}
	select {
	case <-ch:
	T:
		x++
	default:
	}
	var f = func() {
	U:
		for {
			continue U
		}
	}
	for {
		for {
		V:
		W:
			x = 1
		}
	}
	s := []func(){
		func() {
		X:
			goto X
		},
	}
longlabelname:
	x = 5
a:
	x = 6
End:
	// last comment
}

func g() {
A:
}

func h() {
	goto B
B:
}

"""#

private let typeSwitchClausesSource = #"""
package main

import "fmt"

type T struct{ n int }

func f(x any, c chan int) int {
	switch v := x.( type ) { // guard
	case int,
		string:
		fmt.Println(v)
	case *T, []*T,
		map[string][]int: // types
		return 1
	case func(a int, b string) (int, error), func():
	case interface {
		M()
	}:
	case interface{}, any:
	case chan<- int, <-chan *T, chan chan int:
	case [3]int, [][]string, *[]int, **T:

	default:
		// nothing
	}
	switch x := (x).(type) {
	case nil: return 0
	case error: _ = x
	}
	switch   t  :=  x.(type) ; {
	}
	switch a:=1; b := x.(type) {
	case bool: _, _ = a, b
	}
	if v, ok := x.(int); ok { return v }
loop: for {
		select {
		case v:=<-c: if v > 0 { continue loop }
			break loop
		default: goto done
		}
	}
done: return 0
}

func g() { for i := range 10 { if i%2==0 { continue }; fmt.Println(i) } }
func h(n int) { for range n*2+1 { } }

"""#

private let typeSwitchClausesExpected = #"""
package main

import "fmt"

type T struct{ n int }

func f(x any, c chan int) int {
	switch v := x.(type) { // guard
	case int,
		string:
		fmt.Println(v)
	case *T, []*T,
		map[string][]int: // types
		return 1
	case func(a int, b string) (int, error), func():
	case interface {
		M()
	}:
	case interface{}, any:
	case chan<- int, <-chan *T, chan chan int:
	case [3]int, [][]string, *[]int, **T:

	default:
		// nothing
	}
	switch x := (x).(type) {
	case nil:
		return 0
	case error:
		_ = x
	}
	switch t := x.(type); {
	}
	switch a := 1; b := x.(type) {
	case bool:
		_, _ = a, b
	}
	if v, ok := x.(int); ok {
		return v
	}
loop:
	for {
		select {
		case v := <-c:
			if v > 0 {
				continue loop
			}
			break loop
		default:
			goto done
		}
	}
done:
	return 0
}

func g() {
	for i := range 10 {
		if i%2 == 0 {
			continue
		}
		fmt.Println(i)
	}
}
func h(n int) {
	for range n*2 + 1 {
	}
}

"""#

private let uncheckedSource = #"""
package main

func main() {
L: for {
break M
}
goto N
x := 1
N:
fallthrough
continue
switch x := x.(type) {
case int: fallthrough
}
_ = x.(type)
}

"""#

private let uncheckedExpected = #"""
package main

func main() {
L:
	for {
		break M
	}
	goto N
	x := 1
N:
	fallthrough
	continue
	switch x := x.(type) {
	case int:
		fallthrough
	}
	_ = x.(type)
}

"""#

private let rewriteSource = #"""
package main

import "fmt"

type T struct{ n int }

func get(m map[string]any, k string) any { return m[k] }

func main() {
	m := map[string]any{"a": 1}
	var x any = m["a"]
outer:
	for i := 0; i < len(m); i++ {
		switch v := get(m, "a").(type) {
		case int, T:
			fmt.Println(v, x)
			continue outer
		case []int:
			fmt.Println(v[0:len(v)])
			break outer
		case fmt.Stringer:
			goto outer
		case nil:
			fallthrough2()
		}
	}
	switch x.(type) {
	case *T:
	}
	switch {
	case len(m) > 0:
		fallthrough
	default:
	}
}

func fallthrough2() {}

"""#
