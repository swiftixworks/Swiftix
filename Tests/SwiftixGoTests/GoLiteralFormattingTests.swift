/// How `gofmt` lays out composite literals and struct types written in
/// expressions, and what `gofmt -r` makes of them.
///
/// Each `Expected` string below is what the `gofmt` of Go 1.24.5 printed for
/// the `Source` above it, copied without change; the tests require Swiftix
/// `gofmt` to print the same bytes, and to leave that output as it is when
/// formatting it again. The rules are those of `GoRewriteRuleTests`, on a
/// source of literals: for each, the lines the `gofmt -r` of Go 1.24.5
/// changes, with what it makes of them.
///
/// To add a case, format the source with Go and paste both texts.

@testable import SwiftixGo
import Testing

@Suite("Go gofmt of composite literals")
struct GoLiteralFormattingTests {

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

    /// Literals that leave their element types out, struct types written in
    /// place, and types in parentheses, from source without any layout.
    @Test func elidedTypesAndStructTypes() throws {
        try expectGofmt(elidedTypesAndStructTypesSource, elidedTypesAndStructTypesExpected)
    }

    /// A struct type as a parameter, a result, and a field: on one line when it
    /// has one field, and otherwise a block inside the signature, which goes on
    /// after it.
    @Test func structTypesInSignatures() throws {
        try expectGofmt(structTypesInSignaturesSource, structTypesInSignaturesExpected)
    }

    /// Tables: a slice of a struct type with a literal on each line, maps whose
    /// values are a column, nested lists, and literals in the headers of
    /// statements.
    @Test func tablesOfCases() throws {
        try expectGofmt(tablesOfCasesSource, tablesOfCasesExpected)
    }

    /// The same tables with every blank and all indentation removed.
    @Test func tablesWithoutLayout() throws {
        try expectGofmt(tablesWithoutLayoutSource, tablesWithoutLayoutExpected)
    }

    /// The empty struct, literals of pointer and function elements, `[...]T`,
    /// indexes, `new`, `make`, and conversions to types in parentheses.
    @Test func typesInExpressions() throws {
        try expectGofmt(typesInExpressionsSource, typesInExpressionsExpected)
    }

    /// Rules that match literals, each against what Go's `gofmt -r` prints:
    /// a literal is matched with its type, a struct or a function type
    /// written out included, and one that leaves its type out is no literal
    /// of the type its place gives it.
    @Test(arguments: rules.indices)
    func theRuleRewritesWhatGofmtRewrites(index: Int) throws {
        let (rule, changes) = Self.rules[index]
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
    static let rules: [(rule: String, changes: [Int: String])] = [
        ("sum(a, b) -> sum(b, a)", [21: "\tps := []*point{{1, 2}, {sum(2, 1), 4}}", 22: "\tq := struct{ a int }{sum(2, 1)}"]),
        ("1 -> one", [7: "var grid = [][]int{{one, 2}, {3, 4}}", 9: "var named = map[string]point{\"a\": {one, 2}, \"b\": {X: 3}}", 14: "}{{\"a\", one}, {\"b\", 2}}", 16: "var anything = []interface{}{one, struct{}{}, []func(){nil}}", 21: "\tps := []*point{{one, 2}, {sum(one, 2), 4}}", 22: "\tq := struct{ a int }{sum(one, 2)}", 23: "\tarr := [...]int{one, 2, 3}", 25: "\tfmt.Println(ps, q, arr, p, min(one, 2), grid, named, table, anything)"]),
        ("point -> pt", [5: "type pt struct{ X, Y int }", 9: "var named = map[string]pt{\"a\": {1, 2}, \"b\": {X: 3}}", 21: "\tps := []*pt{{1, 2}, {sum(1, 2), 4}}"]),
        ("X -> Z", [5: "type point struct{ Z, Y int }", 9: "var named = map[string]point{\"a\": {1, 2}, \"b\": {Z: 3}}"]),
        ("[]int{a, b} -> []int{b, a}", [:]),
        ("point{a, b} -> point{b, a}", [:]),
        ("struct{ a int }{b} -> b", [22: "\tq := sum(1, 2)"]),
        ("struct{ a int }{a} -> a", [:]),
        ("[]func(){nil} -> nil", [16: "var anything = []interface{}{1, struct{}{}, nil}"]),
        ("struct{}{} -> 0", [16: "var anything = []interface{}{1, 0, []func(){nil}}"]),
        ("[]interface{}{a, b, c} -> []interface{}{c, b, a}", [16: "var anything = []interface{}{[]func(){nil}, struct{}{}, 1}"]),
        ("[...]int{a, b, c} -> [3]int{c, b, a}", [23: "\tarr := [3]int{3, 2, 1}"]),
        ("min(a, b) -> max(b, a)", [25: "\tfmt.Println(ps, q, arr, p, max(2, 1), grid, named, table, anything)"]),
        ("new(int) -> new(string)", [24: "\tp := new(string)"]),
        ("[]*point{a, b} -> []*point{b, a}", [21: "\tps := []*point{{sum(1, 2), 4}, {1, 2}}"]),
        ("map[string]point{a: b, c: d} -> map[string]point{c: d, a: b}", [9: "var named = map[string]point{\"b\": {X: 3}, \"a\": {1, 2}}"]),
    ]
}

private let rewriteSource = #"""
package main

import "fmt"

type point struct{ X, Y int }

var grid = [][]int{{1, 2}, {3, 4}}

var named = map[string]point{"a": {1, 2}, "b": {X: 3}}

var table = []struct {
	name string
	n    int
}{{"a", 1}, {"b", 2}}

var anything = []interface{}{1, struct{}{}, []func(){nil}}

func sum(a, b int) int { return a + b }

func main() {
	ps := []*point{{1, 2}, {sum(1, 2), 4}}
	q := struct{ a int }{sum(1, 2)}
	arr := [...]int{1, 2, 3}
	p := new(int)
	fmt.Println(ps, q, arr, p, min(1, 2), grid, named, table, anything)
}

"""#

private let elidedTypesAndStructTypesSource = #"""
package main

import "fmt"

type point struct{ X, Y int }
type line struct{ A, B point }

var origin = struct{ x, y int }{0,0}

var table = []struct{name string; n int; want bool}{
{"a",1,true},
{"bb",22,false},
{name:"ccc",want:true},
}

var grid = [][]int{{1,2},{3,4},
{5,6}}

var names = map[string]point{"a":{1,2},"bb":{3,4}}

var byPoint = map[point]string{{1,2}:"a",{3,4}:"b"}

var ptrs = []*point{{1,2},{X:3,Y:4}}

var sparse = [...]string{2:"two",5:"five"}
var keyed = []int{2:5,7}

var set = map[string]struct{}{"a":{},"b":{}}

func main() {
ps := []point{{1,2},{3,4}}
ls := []line{{point{1,2},point{3,4}},{A:point{5,6}}}
p := struct{a int}{1}
q := struct{a int; b string}{a:1,b:"x"}
r := &struct{ a,b int }{1,2}
e := struct{}{}
ch := make(chan struct{},1)
ch<-struct{}{}
x := new(int)
y := new(struct{a int})
m := min(1,2)+max(3,4,5)
clear(names)
c := (chan int)(nil)
f := (func())(nil)
g := (func(int,string) (bool,error))(nil)
h := (<-chan int)(nil)
b := ([]byte)("abc")
pa := &[3]int{1,2,3}
fmt.Println(ps,ls,p,q,r,e,x,y,m,c,f==nil,g==nil,h,b,pa[1],len(pa),pa[0:2])
for _,tt := range []struct{in string; out int}{{"a",1},{"b",2}} {
fmt.Println(tt.in,tt.out)
}
nested := map[string][]struct{a,b int}{
"x":{{1,2},{3,4}},
"long key":{
{5,6},
},
}
fmt.Println(nested)
var anon struct{
a int
bb string // comment
ccc []struct{ x int }
}
fmt.Println(anon)
fn(struct{a int}{1},[]point{{1,2}})
}

func fn(s struct{a int}, ps []point) struct{ok bool} {
return struct{ok bool}{len(ps)>s.a}
}

"""#

private let elidedTypesAndStructTypesExpected = #"""
package main

import "fmt"

type point struct{ X, Y int }
type line struct{ A, B point }

var origin = struct{ x, y int }{0, 0}

var table = []struct {
	name string
	n    int
	want bool
}{
	{"a", 1, true},
	{"bb", 22, false},
	{name: "ccc", want: true},
}

var grid = [][]int{{1, 2}, {3, 4},
	{5, 6}}

var names = map[string]point{"a": {1, 2}, "bb": {3, 4}}

var byPoint = map[point]string{{1, 2}: "a", {3, 4}: "b"}

var ptrs = []*point{{1, 2}, {X: 3, Y: 4}}

var sparse = [...]string{2: "two", 5: "five"}
var keyed = []int{2: 5, 7}

var set = map[string]struct{}{"a": {}, "b": {}}

func main() {
	ps := []point{{1, 2}, {3, 4}}
	ls := []line{{point{1, 2}, point{3, 4}}, {A: point{5, 6}}}
	p := struct{ a int }{1}
	q := struct {
		a int
		b string
	}{a: 1, b: "x"}
	r := &struct{ a, b int }{1, 2}
	e := struct{}{}
	ch := make(chan struct{}, 1)
	ch <- struct{}{}
	x := new(int)
	y := new(struct{ a int })
	m := min(1, 2) + max(3, 4, 5)
	clear(names)
	c := (chan int)(nil)
	f := (func())(nil)
	g := (func(int, string) (bool, error))(nil)
	h := (<-chan int)(nil)
	b := ([]byte)("abc")
	pa := &[3]int{1, 2, 3}
	fmt.Println(ps, ls, p, q, r, e, x, y, m, c, f == nil, g == nil, h, b, pa[1], len(pa), pa[0:2])
	for _, tt := range []struct {
		in  string
		out int
	}{{"a", 1}, {"b", 2}} {
		fmt.Println(tt.in, tt.out)
	}
	nested := map[string][]struct{ a, b int }{
		"x": {{1, 2}, {3, 4}},
		"long key": {
			{5, 6},
		},
	}
	fmt.Println(nested)
	var anon struct {
		a   int
		bb  string // comment
		ccc []struct{ x int }
	}
	fmt.Println(anon)
	fn(struct{ a int }{1}, []point{{1, 2}})
}

func fn(s struct{ a int }, ps []point) struct{ ok bool } {
	return struct{ ok bool }{len(ps) > s.a}
}

"""#

private let structTypesInSignaturesSource = #"""
package main

func fn(s struct{a int}, ps []int) struct{ok bool} {
return struct{ok bool}{}
}

func gn(s struct{a int; b string}) (r struct{x,y int}, err error) {
return
}

func (t T) m(v struct{}) struct{} { return v }

type T struct {
f func(struct{a int}) struct{b int}
g struct{ a int }
h struct{a int; b string}
i []struct{a int}
j map[string]struct{}
k chan struct{}
}

var v struct{a int}
var w = func(p struct{ a int }) {}

"""#

private let structTypesInSignaturesExpected = #"""
package main

func fn(s struct{ a int }, ps []int) struct{ ok bool } {
	return struct{ ok bool }{}
}

func gn(s struct {
	a int
	b string
}) (r struct{ x, y int }, err error) {
	return
}

func (t T) m(v struct{}) struct{} { return v }

type T struct {
	f func(struct{ a int }) struct{ b int }
	g struct{ a int }
	h struct {
		a int
		b string
	}
	i []struct{ a int }
	j map[string]struct{}
	k chan struct{}
}

var v struct{ a int }
var w = func(p struct{ a int }) {}

"""#

private let tablesOfCasesSource = #"""
package main

import "fmt"

type point struct{ X, Y int }

type options struct {
	name string
	limits map[string]int
	hooks []func(int) int
	inner struct{ a, b int }
}

var tests = []struct {
	name    string
	input   []int
	want int
	wantErr bool
}{
	{"empty", nil, 0, false},
	{"one", []int{1}, 1, false},
	{
		name: "many",
		input: []int{1, 2, 3},
		want: 6,
	},
	{name: "negative", input: []int{-1}, wantErr: true},
	// a comment between elements
	{
		"multi",
		[]int{
			1, 2,
			3,
		},
		6, false, // trailing
	},
}

var matrix = [3][3]int{
	{1, 0, 0},
	{0, 1, 0},
	{0, 0, 1},
}

var colors = map[string]struct{ r, g, b int }{
	"red": {255, 0, 0},
	"green": {0, 255, 0},
	"a longer name": {r: 1, g: 2, b: 3},
	"blue": {b: 255},
}

var routes = map[string]map[string][]string{
	"GET": {
		"/": {"index"},
		"/users": {"list", "auth"},
	},
	"POST": {"/users": {"create"}},
}

var ptrs = []*point{{1, 2}, {X: 3}, nil, &point{4, 5}}

var opts = options{
	name: "x",
	limits: map[string]int{"a": 1, "bb": 2},
	hooks: []func(int) int{
		func(n int) int { return n + 1 },
		func(n int) int {
			return n * 2
		},
	},
	inner: struct{ a, b int }{1, 2},
}

var sparse = [...]string{
	0: "zero",
	10: "ten",
	100: "hundred",
}

var wide = [][]string{{"a", "b"}, {"c"},
	{"d", "e", "f"}}

func main() {
	for _, tt := range tests {
		fmt.Println(tt.name, tt.input, tt.want, tt.wantErr)
	}
	x := []struct{ a, b int }{{1, 2}, {3, 4}}
	y := [][]point{{{1, 2}, {3, 4}}, {{5, 6}}}
	z := map[point][]point{{1, 2}: {{3, 4}}, {5, 6}: nil}
	w := struct {
		a int
		bb string
	}{
		a: 1,
		bb: "two",
	}
	v := &struct{ name string }{name: "v"}
	u := []interface{}{struct{}{}, struct{ a int }{1}, []int{}, map[string]int{}}
	fmt.Println(x, y, z, w, v, u, matrix, colors, routes, ptrs, opts, sparse, wide)
	call(struct{ a int }{1}, []point{{1, 2}}, map[string][]int{
		"k": {1, 2},
	})
	if p := (point{1, 2}); p.X == 1 {
		fmt.Println(p)
	}
	switch q := (struct{ a int }{1}); q.a {
	case 1:
		fmt.Println(q)
	}
	for i, e := range []struct{ a int }{{1}, {2}} {
		fmt.Println(i, e)
	}
	for _, e := range []struct {
		a int
		b string
	}{{1, "x"}} {
		fmt.Println(e)
	}
}

func call(a struct{ a int }, b []point, c map[string][]int) {}

"""#

private let tablesOfCasesExpected = #"""
package main

import "fmt"

type point struct{ X, Y int }

type options struct {
	name   string
	limits map[string]int
	hooks  []func(int) int
	inner  struct{ a, b int }
}

var tests = []struct {
	name    string
	input   []int
	want    int
	wantErr bool
}{
	{"empty", nil, 0, false},
	{"one", []int{1}, 1, false},
	{
		name:  "many",
		input: []int{1, 2, 3},
		want:  6,
	},
	{name: "negative", input: []int{-1}, wantErr: true},
	// a comment between elements
	{
		"multi",
		[]int{
			1, 2,
			3,
		},
		6, false, // trailing
	},
}

var matrix = [3][3]int{
	{1, 0, 0},
	{0, 1, 0},
	{0, 0, 1},
}

var colors = map[string]struct{ r, g, b int }{
	"red":           {255, 0, 0},
	"green":         {0, 255, 0},
	"a longer name": {r: 1, g: 2, b: 3},
	"blue":          {b: 255},
}

var routes = map[string]map[string][]string{
	"GET": {
		"/":      {"index"},
		"/users": {"list", "auth"},
	},
	"POST": {"/users": {"create"}},
}

var ptrs = []*point{{1, 2}, {X: 3}, nil, &point{4, 5}}

var opts = options{
	name:   "x",
	limits: map[string]int{"a": 1, "bb": 2},
	hooks: []func(int) int{
		func(n int) int { return n + 1 },
		func(n int) int {
			return n * 2
		},
	},
	inner: struct{ a, b int }{1, 2},
}

var sparse = [...]string{
	0:   "zero",
	10:  "ten",
	100: "hundred",
}

var wide = [][]string{{"a", "b"}, {"c"},
	{"d", "e", "f"}}

func main() {
	for _, tt := range tests {
		fmt.Println(tt.name, tt.input, tt.want, tt.wantErr)
	}
	x := []struct{ a, b int }{{1, 2}, {3, 4}}
	y := [][]point{{{1, 2}, {3, 4}}, {{5, 6}}}
	z := map[point][]point{{1, 2}: {{3, 4}}, {5, 6}: nil}
	w := struct {
		a  int
		bb string
	}{
		a:  1,
		bb: "two",
	}
	v := &struct{ name string }{name: "v"}
	u := []interface{}{struct{}{}, struct{ a int }{1}, []int{}, map[string]int{}}
	fmt.Println(x, y, z, w, v, u, matrix, colors, routes, ptrs, opts, sparse, wide)
	call(struct{ a int }{1}, []point{{1, 2}}, map[string][]int{
		"k": {1, 2},
	})
	if p := (point{1, 2}); p.X == 1 {
		fmt.Println(p)
	}
	switch q := (struct{ a int }{1}); q.a {
	case 1:
		fmt.Println(q)
	}
	for i, e := range []struct{ a int }{{1}, {2}} {
		fmt.Println(i, e)
	}
	for _, e := range []struct {
		a int
		b string
	}{{1, "x"}} {
		fmt.Println(e)
	}
}

func call(a struct{ a int }, b []point, c map[string][]int) {}

"""#

private let tablesWithoutLayoutSource = #"""
package main

import "fmt"

type point struct{ X,Y int }

type options struct {
name string
limits map[string]int
hooks []func(int) int
inner struct{ a,b int }
}

var tests = []struct {
name    string
input   []int
want int
wantErr bool
}{
{"empty", nil, 0, false},
{"one", []int{1}, 1, false},
{
name: "many",
input:[]int{1,2,3},
want:6,
},
{name: "negative", input: []int{-1}, wantErr: true},
// a comment between elements
{
"multi",
[]int{
1,2,
3,
},
6,false,// trailing
},
}

var matrix = [3][3]int{
{1,0,0},
{0,1,0},
{0,0,1},
}

var colors = map[string]struct{ r,g,b int }{
"red": {255, 0, 0},
"green": {0, 255, 0},
"a longer name": {r: 1, g: 2, b: 3},
"blue": {b: 255},
}

var routes = map[string]map[string][]string{
"GET": {
"/": {"index"},
"/users": {"list", "auth"},
},
"POST": {"/users": {"create"}},
}

var ptrs = []*point{{1,2},{X:3},nil,&point{4,5}}

var opts = options{
name: "x",
limits: map[string]int{"a": 1, "bb": 2},
hooks:[]func(int) int{
func(n int) int { return n + 1 },
func(n int) int {
return n * 2
},
},
inner:struct{ a,b int }{1,2},
}

var sparse = [...]string{
0: "zero",
10: "ten",
100: "hundred",
}

var wide = [][]string{{"a", "b"}, {"c"},
{"d", "e", "f"}}

func main() {
for _,tt := range tests {
fmt.Println(tt.name,tt.input,tt.want,tt.wantErr)
}
x := []struct{ a,b int }{{1,2},{3,4}}
y := [][]point{{{1,2},{3,4}},{{5,6}}}
z := map[point][]point{{1,2}: {{3,4}},{5,6}: nil}
w := struct {
a int
bb string
}{
a:1,
bb: "two",
}
v := &struct{ name string }{name: "v"}
u := []interface{}{struct{}{},struct{ a int }{1},[]int{},map[string]int{}}
fmt.Println(x,y,z,w,v,u,matrix,colors,routes,ptrs,opts,sparse,wide)
call(struct{ a int }{1},[]point{{1,2}},map[string][]int{
"k": {1, 2},
})
if p := (point{1,2}); p.X == 1 {
fmt.Println(p)
}
switch q := (struct{ a int }{1}); q.a {
case 1:
fmt.Println(q)
}
for i,e := range []struct{ a int }{{1},{2}} {
fmt.Println(i,e)
}
for _,e := range []struct {
a int
b string
}{{1, "x"}} {
fmt.Println(e)
}
}

func call(a struct{ a int },b []point,c map[string][]int) {}

"""#

private let tablesWithoutLayoutExpected = #"""
package main

import "fmt"

type point struct{ X, Y int }

type options struct {
	name   string
	limits map[string]int
	hooks  []func(int) int
	inner  struct{ a, b int }
}

var tests = []struct {
	name    string
	input   []int
	want    int
	wantErr bool
}{
	{"empty", nil, 0, false},
	{"one", []int{1}, 1, false},
	{
		name:  "many",
		input: []int{1, 2, 3},
		want:  6,
	},
	{name: "negative", input: []int{-1}, wantErr: true},
	// a comment between elements
	{
		"multi",
		[]int{
			1, 2,
			3,
		},
		6, false, // trailing
	},
}

var matrix = [3][3]int{
	{1, 0, 0},
	{0, 1, 0},
	{0, 0, 1},
}

var colors = map[string]struct{ r, g, b int }{
	"red":           {255, 0, 0},
	"green":         {0, 255, 0},
	"a longer name": {r: 1, g: 2, b: 3},
	"blue":          {b: 255},
}

var routes = map[string]map[string][]string{
	"GET": {
		"/":      {"index"},
		"/users": {"list", "auth"},
	},
	"POST": {"/users": {"create"}},
}

var ptrs = []*point{{1, 2}, {X: 3}, nil, &point{4, 5}}

var opts = options{
	name:   "x",
	limits: map[string]int{"a": 1, "bb": 2},
	hooks: []func(int) int{
		func(n int) int { return n + 1 },
		func(n int) int {
			return n * 2
		},
	},
	inner: struct{ a, b int }{1, 2},
}

var sparse = [...]string{
	0:   "zero",
	10:  "ten",
	100: "hundred",
}

var wide = [][]string{{"a", "b"}, {"c"},
	{"d", "e", "f"}}

func main() {
	for _, tt := range tests {
		fmt.Println(tt.name, tt.input, tt.want, tt.wantErr)
	}
	x := []struct{ a, b int }{{1, 2}, {3, 4}}
	y := [][]point{{{1, 2}, {3, 4}}, {{5, 6}}}
	z := map[point][]point{{1, 2}: {{3, 4}}, {5, 6}: nil}
	w := struct {
		a  int
		bb string
	}{
		a:  1,
		bb: "two",
	}
	v := &struct{ name string }{name: "v"}
	u := []interface{}{struct{}{}, struct{ a int }{1}, []int{}, map[string]int{}}
	fmt.Println(x, y, z, w, v, u, matrix, colors, routes, ptrs, opts, sparse, wide)
	call(struct{ a int }{1}, []point{{1, 2}}, map[string][]int{
		"k": {1, 2},
	})
	if p := (point{1, 2}); p.X == 1 {
		fmt.Println(p)
	}
	switch q := (struct{ a int }{1}); q.a {
	case 1:
		fmt.Println(q)
	}
	for i, e := range []struct{ a int }{{1}, {2}} {
		fmt.Println(i, e)
	}
	for _, e := range []struct {
		a int
		b string
	}{{1, "x"}} {
		fmt.Println(e)
	}
}

func call(a struct{ a int }, b []point, c map[string][]int) {}

"""#

private let typesInExpressionsSource = #"""
package main

import "fmt"

type T struct{ a int }

var a = struct{}{}
var b = []struct{}{{}, {}}
var c = map[string]struct{}{"x": {}}
var d = [2]struct{ x int }{{1}, {2}}
var e = struct{ f func() }{func() {}}
var f = struct{ f func() int }{func() int { return 1 }}
var g = []struct {
	f func()
	n int
}{{func() {}, 1}, {nil, 2}}
var h = map[struct{ a, b int }]string{{1, 2}: "x"}
var i = [...]int{1, 2, 3}
var j = [...]struct{ a int }{{1}}
var k = &[]int{1}
var l = *&struct{ a int }{1}
var m = struct {
	a int // first
	// between
	bcd string /* tail */
}{}
var n = (struct{ a int }{1}).a
var o = struct{ a int }{1}.a
var p = []T{{1}, T{2}}
var q = map[T]T{{1}: {2}, T{3}: T{4}}
var r = []*T{{1}, &T{2}}
var s = [][]int{{}, {1}, nil}
var t = new(struct{ a int })
var u = make([]struct{ a int }, 2)
var v = make(map[string]struct{})
var w = make(chan struct{}, 1)
var x = (*struct{ a int })(nil)
var y = (func())(nil)
var z = (func(int, string) (bool, error))(nil)
var aa = (chan<- int)(nil)
var ab = (<-chan int)(nil)
var ac = ([]byte)("x")
var ad = (map[string]int)(nil)
var ae = (*T)(nil)
var af = (T)(T{1})
var ag = min(1, 2) + max(3, 4)
var ah = []int{2: 5, 7}
var ai = []string{1: "a", 3: "b"}
var aj = map[string][]struct {
	a int
	b []string
}{"k": {{1, []string{"x"}}}}

func main() {
	clear(v)
	fmt.Println(a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y == nil, z == nil, aa, ab, ac, ad, ae, af, ag, ah, ai, aj)
	var arr [3]int
	ptr := &arr
	ptr[0] = 1
	fmt.Println(ptr[0], len(ptr), ptr[1:])
	for i, v := range ptr {
		fmt.Println(i, v)
	}
	type local struct{ a int }
	fmt.Println([]local{{1}, {2}}, map[string]local{"a": {1}})
	fn := func(v struct{ a int }) struct{ b int } { return struct{ b int }{v.a} }
	fmt.Println(fn(struct{ a int }{1}))
	ch := make(chan struct{ id int }, 1)
	ch <- struct{ id int }{1}
	go func() { ch <- struct{ id int }{2} }()
	defer clear(c)
	x := new(int)
	*x = 2
}

"""#

private let typesInExpressionsExpected = #"""
package main

import "fmt"

type T struct{ a int }

var a = struct{}{}
var b = []struct{}{{}, {}}
var c = map[string]struct{}{"x": {}}
var d = [2]struct{ x int }{{1}, {2}}
var e = struct{ f func() }{func() {}}
var f = struct{ f func() int }{func() int { return 1 }}
var g = []struct {
	f func()
	n int
}{{func() {}, 1}, {nil, 2}}
var h = map[struct{ a, b int }]string{{1, 2}: "x"}
var i = [...]int{1, 2, 3}
var j = [...]struct{ a int }{{1}}
var k = &[]int{1}
var l = *&struct{ a int }{1}
var m = struct {
	a int // first
	// between
	bcd string /* tail */
}{}
var n = (struct{ a int }{1}).a
var o = struct{ a int }{1}.a
var p = []T{{1}, T{2}}
var q = map[T]T{{1}: {2}, T{3}: T{4}}
var r = []*T{{1}, &T{2}}
var s = [][]int{{}, {1}, nil}
var t = new(struct{ a int })
var u = make([]struct{ a int }, 2)
var v = make(map[string]struct{})
var w = make(chan struct{}, 1)
var x = (*struct{ a int })(nil)
var y = (func())(nil)
var z = (func(int, string) (bool, error))(nil)
var aa = (chan<- int)(nil)
var ab = (<-chan int)(nil)
var ac = ([]byte)("x")
var ad = (map[string]int)(nil)
var ae = (*T)(nil)
var af = (T)(T{1})
var ag = min(1, 2) + max(3, 4)
var ah = []int{2: 5, 7}
var ai = []string{1: "a", 3: "b"}
var aj = map[string][]struct {
	a int
	b []string
}{"k": {{1, []string{"x"}}}}

func main() {
	clear(v)
	fmt.Println(a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y == nil, z == nil, aa, ab, ac, ad, ae, af, ag, ah, ai, aj)
	var arr [3]int
	ptr := &arr
	ptr[0] = 1
	fmt.Println(ptr[0], len(ptr), ptr[1:])
	for i, v := range ptr {
		fmt.Println(i, v)
	}
	type local struct{ a int }
	fmt.Println([]local{{1}, {2}}, map[string]local{"a": {1}})
	fn := func(v struct{ a int }) struct{ b int } { return struct{ b int }{v.a} }
	fmt.Println(fn(struct{ a int }{1}))
	ch := make(chan struct{ id int }, 1)
	ch <- struct{ id int }{1}
	go func() { ch <- struct{ id int }{2} }()
	defer clear(c)
	x := new(int)
	*x = 2
}

"""#
