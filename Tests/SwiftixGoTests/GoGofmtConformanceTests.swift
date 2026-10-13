/// Sources whose formatting was produced by Go's own `gofmt`.
///
/// Each `Expected` string below is what the `gofmt` of Go 1.24.5 printed for
/// the `Source` above it, copied without change; the tests require Swiftix
/// `gofmt` to print the same bytes, and to leave that output as it is when
/// formatting it again. Together they cover what Go's printer does beyond
/// spacing tokens: the columns of struct fields, trailing comments, one-line
/// functions, and the values of composite literal elements; the functions,
/// structs, and interfaces it keeps on one line; and the line breaks inside
/// a statement that it keeps, with their indentation.
///
/// To add a case, format the source with Go and paste both texts.

import SwiftixGo
import Testing

@Suite("Go gofmt conformance")
struct GoGofmtConformanceTests {

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

    @Test func columnsOfFieldsAndComments() throws {
        try expectGofmt(columnsOfFieldsAndCommentsSource, columnsOfFieldsAndCommentsExpected)
    }

    @Test func bodiesThatStayOnOneLine() throws {
        try expectGofmt(bodiesThatStayOnOneLineSource, bodiesThatStayOnOneLineExpected)
    }

    @Test func lineBreaksInsideStatements() throws {
        try expectGofmt(lineBreaksInsideStatementsSource, lineBreaksInsideStatementsExpected)
    }

    @Test func commentsBesideCodeAndInLists() throws {
        try expectGofmt(commentsBesideCodeAndInListsSource, commentsBesideCodeAndInListsExpected)
    }

    @Test func listsParametersAndChains() throws {
        try expectGofmt(listsParametersAndChainsSource, listsParametersAndChainsExpected)
    }

    @Test func blockEdgesCallbacksAndSelect() throws {
        try expectGofmt(blockEdgesCallbacksAndSelectSource, blockEdgesCallbacksAndSelectExpected)
    }

    @Test func elementSizesAndFinalCommas() throws {
        try expectGofmt(elementSizesAndFinalCommasSource, elementSizesAndFinalCommasExpected)
    }

    @Test func declarationGroups() throws {
        try expectGofmt(declarationGroupsSource, declarationGroupsExpected)
    }

    @Test func commentsInDeclarationGroups() throws {
        try expectGofmt(commentsInDeclarationGroupsSource, commentsInDeclarationGroupsExpected)
    }

    @Test func unusualDeclarationGroups() throws {
        try expectGofmt(unusualDeclarationGroupsSource, unusualDeclarationGroupsExpected)
    }
}

private let columnsOfFieldsAndCommentsSource = #"""
package main

type one struct {
	name string
}

type two struct {
	a int
	bbb string // second
	cc []*two
	// a comment line
	dddddd map[string]int

	e int
	ff bool // flag
	g int // gee
}

type iface interface {
	Area() int
	Perimeter(scale int) (int, error) // p
	Name() string // n
}

func f() {
	x := 1 // one
	yy := 22 // two
	zzz := 333
	w := 4 // four
	if x > 0 { // cond
		y := 2 // inner
		zzzz := 3 // inner2
	}
	switch x {
	case 1: // one
		foo() // f
	case 100000: // big
		bar()
	}
	// standalone
	a := 1 // a
}

var g1 = 1 // g one
var gg2 = 22 // g two
const c = 3 // c

"""#

private let columnsOfFieldsAndCommentsExpected = #"""
package main

type one struct {
	name string
}

type two struct {
	a   int
	bbb string // second
	cc  []*two
	// a comment line
	dddddd map[string]int

	e  int
	ff bool // flag
	g  int  // gee
}

type iface interface {
	Area() int
	Perimeter(scale int) (int, error) // p
	Name() string                     // n
}

func f() {
	x := 1   // one
	yy := 22 // two
	zzz := 333
	w := 4     // four
	if x > 0 { // cond
		y := 2    // inner
		zzzz := 3 // inner2
	}
	switch x {
	case 1: // one
		foo() // f
	case 100000: // big
		bar()
	}
	// standalone
	a := 1 // a
}

var g1 = 1   // g one
var gg2 = 22 // g two
const c = 3  // c

"""#

private let bodiesThatStayOnOneLineSource = #"""
package main

type a interface{ Area() int }
type b interface{ Perimeter(scale int, other string) (int, error) }
type c interface{ Area() int; Name() string }
type d struct{ x int }
type e struct{ x int; y int }
type f struct{ veryLongFieldNameThatGoesOnAndOn map[string][]*someOtherLongTypeName }
type g struct {
}
type h struct{}
type i interface { Area() int }
type j struct { x int }

func main() {}
func one() int { return 1 }
func twoStatements() int { x := 1; return x }
func withIf(x int) int { if x > 0 { return 1 }; return 0 }
func longOne(parameterNumberOne int, parameterNumberTwo int) int { return parameterNumberOne + parameterNumberTwo*2 }
func longTwo(parameterNumberOne int, parameterNumberTwo int) int { return parameterNumberOne + parameterNumberTwo*20 }
func six() { a(); b(); c(); d(); e(); f() }
func five() { a(); b(); c(); d(); e() }
func empty() {
}
func split() { return
}
func (n *node) name() string { return n.label }

func outer() {
	defer func() { recover() }()
	go func(x int) { use(x) }(1)
	defer func() {}()
	if x { y() }
	for i := 0; i < 3; i++ { z() }
}

func afterComment() {} // trailing
func x1() int { return 1 } // one
func x22() string { return "" } // two

"""#

private let bodiesThatStayOnOneLineExpected = #"""
package main

type a interface{ Area() int }
type b interface {
	Perimeter(scale int, other string) (int, error)
}
type c interface {
	Area() int
	Name() string
}
type d struct{ x int }
type e struct {
	x int
	y int
}
type f struct {
	veryLongFieldNameThatGoesOnAndOn map[string][]*someOtherLongTypeName
}
type g struct {
}
type h struct{}
type i interface{ Area() int }
type j struct{ x int }

func main()              {}
func one() int           { return 1 }
func twoStatements() int { x := 1; return x }
func withIf(x int) int {
	if x > 0 {
		return 1
	}
	return 0
}
func longOne(parameterNumberOne int, parameterNumberTwo int) int {
	return parameterNumberOne + parameterNumberTwo*2
}
func longTwo(parameterNumberOne int, parameterNumberTwo int) int {
	return parameterNumberOne + parameterNumberTwo*20
}
func six() {
	a()
	b()
	c()
	d()
	e()
	f()
}
func five() { a(); b(); c(); d(); e() }
func empty() {
}
func split() {
	return
}
func (n *node) name() string { return n.label }

func outer() {
	defer func() { recover() }()
	go func(x int) { use(x) }(1)
	defer func() {}()
	if x {
		y()
	}
	for i := 0; i < 3; i++ {
		z()
	}
}

func afterComment() {}            // trailing
func x1() int       { return 1 }  // one
func x22() string   { return "" } // two

"""#

private let lineBreaksInsideStatementsSource = #"""
package main

func main() {
	x := a +
	b +
	c
	y := a +
	b*
	c
	z := a + b +
	c + d
	w := f(a,
	b)
	v := f(
	a,
	b,
	)
	u := f(a, g(b,
	c), d)
	t := f(a +
	b, c)
	s := []string{"a", "b",
	"c", "d"}
	r := []string{
	"a",
	"b",
	}
	q := map[string]int{
	"a": 1,
	"bcd": 2,
	"efghij": 3,
	}
	p := map[string]int{"a": 1,
	"bcd": 2}
	o := point{
	X: 1,
	LongName: 2,
	}
	n := point{X: 1,
	Y: 2}
	m := []point{
	point{X: 1},
	point{X: 2, Y: 3},
	}
	l := f(a, b,

	c)
	if a &&
	b {
	}
	if a ||
	b &&
	c {
	}
	for i := 0; i < n &&
	j > 0; i++ {
	}
	return a +
	b
	k := x.f(a).
	g(b)
	fmt.Println("total: " +
	text, a,
	b)
	ch <- a +
	b
	a, b = c +
	d, e
	a, b = c,
	d
	x = list[a +
	b]
	x = f(a)(b,
	c)
	x += a +
	b
	x = (a +
	b) * c
	x = a * (b +
	c)
	x = -(a +
	b)
	s2 := "a" +
	"b" +
	"c"
	out = out + inverse + shortcutKeys[i] + normal + " " +
	fit(shortcutLabels[i], cell-len(shortcutKeys[i])-1)
}

"""#

private let lineBreaksInsideStatementsExpected = #"""
package main

func main() {
	x := a +
		b +
		c
	y := a +
		b*
			c
	z := a + b +
		c + d
	w := f(a,
		b)
	v := f(
		a,
		b,
	)
	u := f(a, g(b,
		c), d)
	t := f(a+
		b, c)
	s := []string{"a", "b",
		"c", "d"}
	r := []string{
		"a",
		"b",
	}
	q := map[string]int{
		"a":      1,
		"bcd":    2,
		"efghij": 3,
	}
	p := map[string]int{"a": 1,
		"bcd": 2}
	o := point{
		X:        1,
		LongName: 2,
	}
	n := point{X: 1,
		Y: 2}
	m := []point{
		point{X: 1},
		point{X: 2, Y: 3},
	}
	l := f(a, b,

		c)
	if a &&
		b {
	}
	if a ||
		b &&
			c {
	}
	for i := 0; i < n &&
		j > 0; i++ {
	}
	return a +
		b
	k := x.f(a).
		g(b)
	fmt.Println("total: "+
		text, a,
		b)
	ch <- a +
		b
	a, b = c+
		d, e
	a, b = c,
		d
	x = list[a+
		b]
	x = f(a)(b,
		c)
	x += a +
		b
	x = (a +
		b) * c
	x = a * (b +
		c)
	x = -(a +
		b)
	s2 := "a" +
		"b" +
		"c"
	out = out + inverse + shortcutKeys[i] + normal + " " +
		fit(shortcutLabels[i], cell-len(shortcutKeys[i])-1)
}

"""#

private let commentsBesideCodeAndInListsSource = #"""
package main

import "fmt"

// doc comment
type config struct {
	name string // the name

	// grouped
	host string
	port int
	tags []string // tags
	next *config
	// trailing group
	a int // one
	bb int // two

	ccc int // three
}

type shape interface {
	// Area returns the area.
	Area() int // area
	Perimeter() int

	Name() string // name
}

var table = map[string]int{
	"one": 1, // first
	"three": 3,
	"seventeen": 17, // big

	"x": 0,
}

func f() int { return 1 } // one
func gg() {} // two

func h() { // open
	x := []int{
		1, // one
		22, // two
		333,
	}
	y := point{
		X: 1, // x
		LongName: 2, // long
		Z: []int{
			1,
			2,
		},
		W: 3,
	}
	call(a, // first
		b) // second
	z := a + // plus
		b
	if x == nil { // nil
		return
	} else if y.X > 0 { // positive
		return
	} else { // otherwise
		return
	}
	for i := 0; i < 3; i++ { // loop
	}
	switch { // sw
	case a: // a
	case bb: // bb
		f() // call
		gg() // other
	default: // d
	}
	/* block */ x = nil
	x = nil /* tail */
	fmt.Println(x, y, z) // done
} // end

// last comment

"""#

private let commentsBesideCodeAndInListsExpected = #"""
package main

import "fmt"

// doc comment
type config struct {
	name string // the name

	// grouped
	host string
	port int
	tags []string // tags
	next *config
	// trailing group
	a  int // one
	bb int // two

	ccc int // three
}

type shape interface {
	// Area returns the area.
	Area() int // area
	Perimeter() int

	Name() string // name
}

var table = map[string]int{
	"one":       1, // first
	"three":     3,
	"seventeen": 17, // big

	"x": 0,
}

func f() int { return 1 } // one
func gg()    {}           // two

func h() { // open
	x := []int{
		1,  // one
		22, // two
		333,
	}
	y := point{
		X:        1, // x
		LongName: 2, // long
		Z: []int{
			1,
			2,
		},
		W: 3,
	}
	call(a, // first
		b) // second
	z := a + // plus
		b
	if x == nil { // nil
		return
	} else if y.X > 0 { // positive
		return
	} else { // otherwise
		return
	}
	for i := 0; i < 3; i++ { // loop
	}
	switch { // sw
	case a: // a
	case bb: // bb
		f()  // call
		gg() // other
	default: // d
	}
	/* block */ x = nil
	x = nil              /* tail */
	fmt.Println(x, y, z) // done
} // end

// last comment

"""#

private let listsParametersAndChainsSource = #"""
package main

func params(a int,
b string,
c []int) int {
return a
}
func params2(
a int,
b string,
) (int, error) {
return a, nil
}
func exactly100(aaaaaaaaaaaaaaaaaaaaaaaaaaa int, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb int) int { return aaaaaaaaaaaaaaaaaaaaaaaaaaa + 1 }
func over100(aaaaaaaaaaaaaaaaaaaaaaaaaaaa int, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb int) int { return aaaaaaaaaaaaaaaaaaaaaaaaaaaa + 1 }
func a1() int { return 1 }

func b2() int { return 2 }
func c3() {
x()
}
func d4() int { return 4 }
func (r *recv) method() int { return r.x }
func main() {
v := call(
a,
b)
w := call(a,
b,
)
x := call(nested(
1,
2,
), other(3,
4))
y := []int{1, 2,
3, 4,
5}
z := [][]int{
[]int{1, 2},
[]int{3,
4},
[]int{
5,
},
}
m := map[string]map[string]int{
"a": map[string]int{"x": 1},
"bbbb": map[string]int{
"y": 2,
"zzz": 3,
},
"cc": nil,
}
q := a +
b -
c*d +
e
r := a &&
(b ||
c) &&
d
s := list[i +
1]
t := obj.
first().
second(a,
b).
third
u :=
value
u, w =
1,
2
if cond(a,
b) {
}
if x := call(a,
b); x {
}
for _, item := range build(a,
b) {
}
switch a {
case 1,
2,
3:
case 4, 5,
6:
}
return a,
b
go run(a,
b)
defer func() { done(a, b) }()
defer func() {
done(a,
b)
}()
str := "a" + "b" +
"c" + "d" +
"e"
callWithLiteral(point{
X: 1,
Y: 2,
}, 3)
callWithLiteral(point{X: 1,
Y: 2}, 3)
e := &point{
X: a +
b,
Y: f(c,
d),
}
}

"""#

private let listsParametersAndChainsExpected = #"""
package main

func params(a int,
	b string,
	c []int) int {
	return a
}
func params2(
	a int,
	b string,
) (int, error) {
	return a, nil
}
func exactly100(aaaaaaaaaaaaaaaaaaaaaaaaaaa int, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb int) int {
	return aaaaaaaaaaaaaaaaaaaaaaaaaaa + 1
}
func over100(aaaaaaaaaaaaaaaaaaaaaaaaaaaa int, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb int) int {
	return aaaaaaaaaaaaaaaaaaaaaaaaaaaa + 1
}
func a1() int { return 1 }

func b2() int { return 2 }
func c3() {
	x()
}
func d4() int               { return 4 }
func (r *recv) method() int { return r.x }
func main() {
	v := call(
		a,
		b)
	w := call(a,
		b,
	)
	x := call(nested(
		1,
		2,
	), other(3,
		4))
	y := []int{1, 2,
		3, 4,
		5}
	z := [][]int{
		[]int{1, 2},
		[]int{3,
			4},
		[]int{
			5,
		},
	}
	m := map[string]map[string]int{
		"a": map[string]int{"x": 1},
		"bbbb": map[string]int{
			"y":   2,
			"zzz": 3,
		},
		"cc": nil,
	}
	q := a +
		b -
		c*d +
		e
	r := a &&
		(b ||
			c) &&
		d
	s := list[i+
		1]
	t := obj.
		first().
		second(a,
			b).
		third
	u :=
		value
	u, w =
		1,
		2
	if cond(a,
		b) {
	}
	if x := call(a,
		b); x {
	}
	for _, item := range build(a,
		b) {
	}
	switch a {
	case 1,
		2,
		3:
	case 4, 5,
		6:
	}
	return a,
		b
	go run(a,
		b)
	defer func() { done(a, b) }()
	defer func() {
		done(a,
			b)
	}()
	str := "a" + "b" +
		"c" + "d" +
		"e"
	callWithLiteral(point{
		X: 1,
		Y: 2,
	}, 3)
	callWithLiteral(point{X: 1,
		Y: 2}, 3)
	e := &point{
		X: a +
			b,
		Y: f(c,
			d),
	}
}

"""#

private let blockEdgesCallbacksAndSelectSource = #"""
package main

import "testing"

type point struct {

	X int


	Y int

}

func TestThing(t *testing.T) {

	t.Run("first", func(t *testing.T) {
		a := 1
		b := 2
		if a+b != 3 {
			t.Fatal("bad")
		}
	})
	t.Run("second", func(t *testing.T) { check(t) })
	t.Run("third",
		func(t *testing.T) {
			check(t)
		})


	x := 1

}

func literals() []point {
	list := []point{
		// first
		point{X: 1},
		// second

		point{X: 2}, // two
		point{
			X: 3, // three
			Y: 4,
		},
	}
	names := map[string][]int{
		"a": []int{1}, // one
		"bcd": []int{2, 3},
		// comment
		"e": nil,
	}
	return list
}

func control(a int, b int) int {
	if a > b {
		return a
	} else if a ==
		b {
		return 0
	}
	select {
	case v := <-ch: // got
		use(v)
	case ch2 <- 1:
	default:
	}
	for {
		break
	}
	for a < b {
		a++
	}
	for i := range list {
		use(i)
	}
	var total int // sum
	var count, size int = 1, 2 // pair
	const limit = 10 // max
	total += count * size
	go func() {
		work()
	}()
	return total
}

"""#

private let blockEdgesCallbacksAndSelectExpected = #"""
package main

import "testing"

type point struct {
	X int

	Y int
}

func TestThing(t *testing.T) {

	t.Run("first", func(t *testing.T) {
		a := 1
		b := 2
		if a+b != 3 {
			t.Fatal("bad")
		}
	})
	t.Run("second", func(t *testing.T) { check(t) })
	t.Run("third",
		func(t *testing.T) {
			check(t)
		})

	x := 1

}

func literals() []point {
	list := []point{
		// first
		point{X: 1},
		// second

		point{X: 2}, // two
		point{
			X: 3, // three
			Y: 4,
		},
	}
	names := map[string][]int{
		"a":   []int{1}, // one
		"bcd": []int{2, 3},
		// comment
		"e": nil,
	}
	return list
}

func control(a int, b int) int {
	if a > b {
		return a
	} else if a ==
		b {
		return 0
	}
	select {
	case v := <-ch: // got
		use(v)
	case ch2 <- 1:
	default:
	}
	for {
		break
	}
	for a < b {
		a++
	}
	for i := range list {
		use(i)
	}
	var total int              // sum
	var count, size int = 1, 2 // pair
	const limit = 10           // max
	total += count * size
	go func() {
		work()
	}()
	return total
}

"""#

private let elementSizesAndFinalCommasSource = #"""
package main

var short = 1 // s
func one() int { return 1 } // o
var longerName = 22 // l

func keys() {
	a := map[string]int{
		"k": 1,
		"a much much longer key that goes past forty characters wide": 2,
		"kk": 3,
		"another very long key that also goes past forty chars wide": 4,
		"z": 5,
	}
	b := map[string]int{
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 1,
		"b": 2,
		"cc": 3,
	}
	c := []int{1, 2,}
	d := f(a, b,)
	e := []int{
	}
	g := f(
	)
	h := f(
		a, b,
	)
	i := []string{

		"a",


		"b",

	}
	j := f(a +
		b,
		c)
	k := f(g(h(
		1,
	)))
	l := -(a +
		b)
	m := !(a &&
		b)
	n := x[f(a,
		b)]
	o := point{X: 1, Y: 2,
	}
	q := f(func() { work() }, func() {
		work()
	})
	r := f(a, b) + g(c,
		d) + h(e)
	s := a.b.c(d).e[f].g(
		h,
	)
	if a {
	} else if b {
	} else {
	}
	go func() {}()
	defer func() { a(); b() }()
	return
}

"""#

private let elementSizesAndFinalCommasExpected = #"""
package main

var short = 1       // s
func one() int      { return 1 } // o
var longerName = 22 // l

func keys() {
	a := map[string]int{
		"k": 1,
		"a much much longer key that goes past forty characters wide": 2,
		"kk": 3,
		"another very long key that also goes past forty chars wide": 4,
		"z": 5,
	}
	b := map[string]int{
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 1,
		"b":  2,
		"cc": 3,
	}
	c := []int{1, 2}
	d := f(a, b)
	e := []int{}
	g := f()
	h := f(
		a, b,
	)
	i := []string{

		"a",

		"b",
	}
	j := f(a+
		b,
		c)
	k := f(g(h(
		1,
	)))
	l := -(a +
		b)
	m := !(a &&
		b)
	n := x[f(a,
		b)]
	o := point{X: 1, Y: 2}
	q := f(func() { work() }, func() {
		work()
	})
	r := f(a, b) + g(c,
		d) + h(e)
	s := a.b.c(d).e[f].g(
		h,
	)
	if a {
	} else if b {
	} else {
	}
	go func() {}()
	defer func() { a(); b() }()
	return
}

"""#

private let declarationGroupsSource = #"""
package main

import (
"os"
"fmt" // printing
"strings"

"example/z"
"example/a"
// about errors
"errors"
"errors"
)
import ("io")
import (
)

var (

a int
bb string = "s"
ccc, d = 1, 2
e []int // list

f = 3 // three
gggg int // g
)

const (
x = 1
yy = 22 // two
zzz
)
const (
kb int = 1 << 10 // kilo
mb = kb * 1024 // mega
gb
tb = 4
)
const (
one = iota + 1
two
_
four
)
var (single = 1)
var ()
type (
point struct {
X int
}
list []int
m map[string]int // m
)
type (only int)

func main() {
var (
p = 1
qq string
)
const (
r = 2
)
fmt.Println(p, qq, r)
}

"""#

private let declarationGroupsExpected = #"""
package main

import (
	"fmt" // printing
	"os"
	"strings"

	"example/a"
	"example/z"
	// about errors
	"errors"
)
import (
	"io"
)
import ()

var (
	a      int
	bb     string = "s"
	ccc, d        = 1, 2
	e      []int  // list

	f    = 3 // three
	gggg int // g
)

const (
	x  = 1
	yy = 22 // two
	zzz
)
const (
	kb int = 1 << 10   // kilo
	mb     = kb * 1024 // mega
	gb
	tb = 4
)
const (
	one = iota + 1
	two
	_
	four
)

var (
	single = 1
)
var ()

type (
	point struct {
		X int
	}
	list []int
	m    map[string]int // m
)
type (
	only int
)

func main() {
	var (
		p  = 1
		qq string
	)
	const (
		r = 2
	)
	fmt.Println(p, qq, r)
}

"""#

private let commentsInDeclarationGroupsSource = #"""
package main

// Imports.
import (
	// standard
	"os" // operating system
	"fmt"

	/* block */
	"strings"; "errors"
	"io" /* tail */
	"io"
	"bufio" // b
	"bufio"
)

// Variables.
var (
	// documented
	alpha = 1 // a

	// group two
	betaLongName string // b
	gamma, delta = 2, 3 // gd
	epsilon int = 4
	zeta = map[string]int{
		"k": 1,
		"long key": 2,
	}
	eta = 5 // after multi-line
	theta int
)

const (
	typed color = iota // zero
	untyped // one
	other = "s" // str
	plain
)

type (
	// doc
	a int // a
	bb struct{} // bb

	ccc []int
	dddd interface{ m() }
)

var x = 1
var (
	y = 2
)
const z = 3

func f() {
	var (
		local = 1 // l
		another string
	)
	const (
		one = iota
		two
	)
	use(local, another, one, two)
}

"""#

private let commentsInDeclarationGroupsExpected = #"""
package main

// Imports.
import (
	// standard
	"fmt"
	"os" // operating system

	/* block */
	"bufio" // b
	"errors"
	"io" /* tail */
	"strings"
)

// Variables.
var (
	// documented
	alpha = 1 // a

	// group two
	betaLongName string        // b
	gamma, delta        = 2, 3 // gd
	epsilon      int    = 4
	zeta                = map[string]int{
		"k":        1,
		"long key": 2,
	}
	eta   = 5 // after multi-line
	theta int
)

const (
	typed   color = iota // zero
	untyped              // one
	other   = "s"        // str
	plain
)

type (
	// doc
	a  int      // a
	bb struct{} // bb

	ccc  []int
	dddd interface{ m() }
)

var x = 1
var (
	y = 2
)

const z = 3

func f() {
	var (
		local   = 1 // l
		another string
	)
	const (
		one = iota
		two
	)
	use(local, another, one, two)
}

"""#

private let unusualDeclarationGroupsSource = #"""
package main
import("fmt")
import (

"os"

)
import "io"
import (
"b"
"a"
)
var(a=1;b=2)
var ( // why
c int

)
var (
// only a comment
)
var (
table = map[string]int{
"one": 1,
"three": 3,
}
short = 1
longer int = 2
list = []int{1, 2,
3}
after = 4
x, y int
z string = "s" // z
w = 5

q int = 6
r = 7

t = 8
)
const (
aa = 1 +
2
bb = iota // i
cc
dd int = 4
)
type (
one struct {
a int
bb string
}
two struct{ a int }
three interface {
m()
}
four int
)
func f() {
var (
a = 1
bb, cc = 2, 3
)
var (
only = 1
)
const (
k = iota
l
)
if a > 0 {
var (
d = 1
ee = 22
)
use(d, ee)
}
use(a, bb, cc, only, k, l)
}

"""#

private let unusualDeclarationGroupsExpected = #"""
package main

import (
	"fmt"
)
import (
	"os"
)
import "io"
import (
	"a"
	"b"
)

var (
	a = 1
	b = 2
)
var ( // why
	c int
)
var (
// only a comment
)
var (
	table = map[string]int{
		"one":   1,
		"three": 3,
	}
	short      = 1
	longer int = 2
	list       = []int{1, 2,
		3}
	after = 4
	x, y  int
	z     string = "s" // z
	w            = 5

	q int = 6
	r     = 7

	t = 8
)

const (
	aa = 1 +
		2
	bb = iota // i
	cc
	dd int = 4
)

type (
	one struct {
		a  int
		bb string
	}
	two   struct{ a int }
	three interface {
		m()
	}
	four int
)

func f() {
	var (
		a      = 1
		bb, cc = 2, 3
	)
	var (
		only = 1
	)
	const (
		k = iota
		l
	)
	if a > 0 {
		var (
			d  = 1
			ee = 22
		)
		use(d, ee)
	}
	use(a, bb, cc, only, k, l)
}

"""#
