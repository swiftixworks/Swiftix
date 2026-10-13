/// Embedded fields, struct tags, and raw strings as Go's own `gofmt` lays
/// them out.
///
/// Each `Expected` string below is what the `gofmt` of Go 1.24.5 printed for
/// the `Source` above it, copied without change; the tests require Swiftix
/// `gofmt` to print the same bytes, and to leave that output as it is when
/// formatting it again. The rewrite rules were run through `gofmt -r` of the
/// same release.
///
/// To add a case, format the source with Go and paste both texts.

@testable import SwiftixGo
import Testing

@Suite("Go gofmt of embedding, tags, and raw strings")
struct GoEmbeddingGofmtTests {

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

    /// An embedded field has no name: alone on its line it is no part of a
    /// column, and before a comment its type stands in the column of names.
    @Test func embeddedFieldsStandInTheColumnOfNames() throws {
        try expectGofmt(embeddedFieldsStandInTheColumnOfNamesSource, embeddedFieldsStandInTheColumnOfNamesExpected)
    }

    /// In a `type` group, in the struct type of a field, and in the type of
    /// a variable; after a field whose type spans lines the columns start over.
    @Test func embeddedFieldsInGroupsAndInTypesWrittenInPlace() throws {
        try expectGofmt(embeddedFieldsInGroupsAndInTypesWrittenInPlaceSource, embeddedFieldsInGroupsAndInTypesWrittenInPlaceExpected)
    }

    /// A tag follows its type in a column of its own, where the comment of a
    /// field without a tag stands; the tag of an embedded field stands in the
    /// column of types; and a field with a tag does not stay on the line of
    /// `struct{`.
    @Test func tagsAreAColumnAfterTheTypes() throws {
        try expectGofmt(tagsAreAColumnAfterTheTypesSource, tagsAreAColumnAfterTheTypesExpected)
    }

    /// After a name, a pointer, a slice, a map, a function, a channel, an
    /// array, and a struct or interface written in place, where the tag after
    /// the closing brace is aligned with nothing.
    @Test func tagsAfterEveryKindOfType() throws {
        try expectGofmt(tagsAfterEveryKindOfTypeSource, tagsAfterEveryKindOfTypeExpected)
    }

    /// What is between the back quotes is not touched, the lines inside it
    /// neither; a raw string that spans lines ends the columns of its line and
    /// of the line after it.
    @Test func rawStringsAreKeptAsTheyAreWritten() throws {
        try expectGofmt(rawStringsAreKeptAsTheyAreWrittenSource, rawStringsAreKeptAsTheyAreWrittenExpected)
    }

    /// As an argument, an element, a key, a case, an operand, and the
    /// value of a specification; a function whose body holds one does not stay
    /// on one line.
    @Test func rawStringsOfSeveralLinesInEveryPlace() throws {
        try expectGofmt(rawStringsOfSeveralLinesInEveryPlaceSource, rawStringsOfSeveralLinesInEveryPlaceExpected)
    }

    /// An embedded interface is a line of the interface, or the one entry
    /// of an interface that stays on its line.
    @Test func embeddedInterfaces() throws {
        try expectGofmt(embeddedInterfacesSource, embeddedInterfacesExpected)
    }

    /// A rule renames an embedded field with its type, since the two are
    /// one identifier, and leaves a tag and what a raw string holds alone.
    @Test(arguments: rewriteCases.indices)
    func aRewriteRuleSeesEmbeddedFieldsTagsAndRawStrings(index: Int) throws {
        let (rule, changes) = rewriteCases[index]
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
}

/// Rules and the lines of `rewriteSource` each changes, by line number.
private let rewriteCases: [(rule: String, changes: [Int: String])] = [
    ("base -> root", [8: "type root struct {", 12: "func (b root) get() int { return b.id }", 15: "\troot       // the base", 29: "\td := derived{root: root{1}, name: usage}", 30: "\tfmt.Println(d.get()+0, d.root.get(), len(`x`+usage))"]),
    ("a + 0 -> a", [30: "\tfmt.Println(d.get(), d.base.get(), len(`x`+usage))"]),
    ("a.get() -> a.id", [30: "\tfmt.Println(d.id+0, d.base.id, len(`x`+usage))"]),
    ("len(a) -> size(a)", [30: "\tfmt.Println(d.get()+0, d.base.get(), size(`x`+usage))"]),
]

private let rewriteSource = #"""
package main

import (
	"fmt"
	"sync"
)

type base struct {
	id int `json:"id"`
}

func (b base) get() int { return b.id }

type derived struct {
	base       // the base
	sync.Mutex `json:"-"`
	name       string
}

type getter interface {
	fmt.Stringer
	get() int
}

const usage = `get(1)
	base`

func main() {
	d := derived{base: base{1}, name: usage}
	fmt.Println(d.get()+0, d.base.get(), len(`x`+usage))
}

"""#

private let embeddedFieldsStandInTheColumnOfNamesSource = #"""
package main

import ("fmt"; "sync")

type base struct{id int}
type derived struct {
base
   name string
}
type withComments struct {
	sync.Mutex // guards m
	m map[string]int // the data
	*base
	longFieldName int // long
	fmt.Stringer
	x, y int
}
type onlyEmbedded struct {
	base
	*derived
	sync.WaitGroup
}
type one struct{ base }
type onePtr struct{ *base }
type oneQualified struct{ sync.Mutex }
type two struct { base; n int }
type mixed struct {
	a int

	base // trailing

	// leading comment
	*derived
	bb string
}
func main() {
	d := derived{base{1}, "x"}
	e := derived{base: base{1}, name: "x"}
	var s struct { sync.Mutex; n int }
	var t struct {
		sync.Mutex
		count int // hits
	}
	type local struct { base; *derived
	}
	fmt.Println(d, e, s.n, t.count, local{})
}

"""#

private let embeddedFieldsStandInTheColumnOfNamesExpected = #"""
package main

import (
	"fmt"
	"sync"
)

type base struct{ id int }
type derived struct {
	base
	name string
}
type withComments struct {
	sync.Mutex                // guards m
	m          map[string]int // the data
	*base
	longFieldName int // long
	fmt.Stringer
	x, y int
}
type onlyEmbedded struct {
	base
	*derived
	sync.WaitGroup
}
type one struct{ base }
type onePtr struct{ *base }
type oneQualified struct{ sync.Mutex }
type two struct {
	base
	n int
}
type mixed struct {
	a int

	base // trailing

	// leading comment
	*derived
	bb string
}

func main() {
	d := derived{base{1}, "x"}
	e := derived{base: base{1}, name: "x"}
	var s struct {
		sync.Mutex
		n int
	}
	var t struct {
		sync.Mutex
		count int // hits
	}
	type local struct {
		base
		*derived
	}
	fmt.Println(d, e, s.n, t.count, local{})
}

"""#

private let embeddedFieldsInGroupsAndInTypesWrittenInPlaceSource = #"""
package main

import ("io"; "sync")

type (
	base struct{ id int }
	pair struct { base; other *base }
	wide struct {
		sync.Mutex
		// about m
		m map[string]int
		*base // why
		io.Reader // r
		io.Writer `w` // w
		n int `n`
	}
)
type deep struct {
	a struct {
		base
		x int // x
	}
	b struct{ base }
	c struct { *base; sync.Mutex } // c
	base    // own
	sync.WaitGroup    // wg
}
type generic struct {
	*deep
	_ int
	_, _ string // pad
}
func (d deep) get() base { return d.base }
func main() {
	var x struct{ base; sync.Mutex }
	y := &pair{base{1}, nil}
	z := wide{base: &base{2}, n: 1}
	_, _, _ = x, y, z
}

"""#

private let embeddedFieldsInGroupsAndInTypesWrittenInPlaceExpected = #"""
package main

import (
	"io"
	"sync"
)

type (
	base struct{ id int }
	pair struct {
		base
		other *base
	}
	wide struct {
		sync.Mutex
		// about m
		m         map[string]int
		*base         // why
		io.Reader     // r
		io.Writer `w` // w
		n         int `n`
	}
)
type deep struct {
	a struct {
		base
		x int // x
	}
	b struct{ base }
	c struct {
		*base
		sync.Mutex
	} // c
	base           // own
	sync.WaitGroup // wg
}
type generic struct {
	*deep
	_    int
	_, _ string // pad
}

func (d deep) get() base { return d.base }
func main() {
	var x struct {
		base
		sync.Mutex
	}
	y := &pair{base{1}, nil}
	z := wide{base: &base{2}, n: 1}
	_, _, _ = x, y, z
}

"""#

private let tagsAreAColumnAfterTheTypesSource = #"""
package main

type rec struct {
	Name string `json:"name"`
	Age int "json:\"age\""
	Address string `json:"address,omitempty"` // where
	untagged bool
	Count int // comment only
	a, b int `x:"1"`
}
type embeddedTags struct {
	rec `json:"rec"`
	*other `json:"other"` // ptr
	LongerName string `json:"n"`
	x int
}
type other struct { V int `v:"1"` }
type some struct {
	A int
	B string `json:"b"`
	C bool
	DD []byte `json:"dd"`
	E map[string]int `json:"e"`


	F func(int) string `json:"-"` // f
	G chan int // g
	H int `h` // h
}
type single struct{ Name string `json:"name"` }
func main() {
	var v struct { X int `x` ; Y string `y`
	}
	_ = v
}

"""#

private let tagsAreAColumnAfterTheTypesExpected = #"""
package main

type rec struct {
	Name     string `json:"name"`
	Age      int    "json:\"age\""
	Address  string `json:"address,omitempty"` // where
	untagged bool
	Count    int // comment only
	a, b     int `x:"1"`
}
type embeddedTags struct {
	rec        `json:"rec"`
	*other     `json:"other"` // ptr
	LongerName string         `json:"n"`
	x          int
}
type other struct {
	V int `v:"1"`
}
type some struct {
	A  int
	B  string `json:"b"`
	C  bool
	DD []byte         `json:"dd"`
	E  map[string]int `json:"e"`

	F func(int) string `json:"-"` // f
	G chan int         // g
	H int              `h` // h
}
type single struct {
	Name string `json:"name"`
}

func main() {
	var v struct {
		X int    `x`
		Y string `y`
	}
	_ = v
}

"""#

private let tagsAfterEveryKindOfTypeSource = #"""
package main

import "sync"

type A struct {
	// doc
	ID int64s `json:"id" db:"id"` // primary
	Name, Alias string `json:"name"`
	sync.Mutex `json:"-"`
	Ptr *A `json:"ptr,omitempty"`
	List []*A
	M map[string][]int "m" // quoted
	Fn func(a, b int) (int, error) `fn`
	Ch chan struct{} `ch`
	Arr [4]byte `arr`
	Nested struct {
		X int `x`
		YY string `yy`
	} `nested`
	Iface interface{ M() } `iface`
	Any interface{} `any`
	Empty struct{} `empty`
	B bool `b`
}
type int64s int
type B struct { A `a`; *sync.WaitGroup "wg" }
type C struct {
	X int `raw
tag` // multi
	Y int `y`
	ZZ int `zz`
}
type (
	D struct { F int `f` }
	E struct {
		G int `g`
	}
)
func f() {
	var v struct{ B int "b" }
	_ = v
}
func main() {}

"""#

private let tagsAfterEveryKindOfTypeExpected = #"""
package main

import "sync"

type A struct {
	// doc
	ID          int64s `json:"id" db:"id"` // primary
	Name, Alias string `json:"name"`
	sync.Mutex  `json:"-"`
	Ptr         *A `json:"ptr,omitempty"`
	List        []*A
	M           map[string][]int            "m" // quoted
	Fn          func(a, b int) (int, error) `fn`
	Ch          chan struct{}               `ch`
	Arr         [4]byte                     `arr`
	Nested      struct {
		X  int    `x`
		YY string `yy`
	} `nested`
	Iface interface{ M() } `iface`
	Any   interface{}      `any`
	Empty struct{}         `empty`
	B     bool             `b`
}
type int64s int
type B struct {
	A               `a`
	*sync.WaitGroup "wg"
}
type C struct {
	X int `raw
tag` // multi
	Y  int `y`
	ZZ int `zz`
}
type (
	D struct {
		F int `f`
	}
	E struct {
		G int `g`
	}
)

func f() {
	var v struct {
		B int "b"
	}
	_ = v
}
func main() {}

"""#

private let rawStringsAreKeptAsTheyAreWrittenSource = #"""
package main

import "fmt"

const usage = `usage:
	tool   [flags]
  -v   verbose
`
const ( a = `x`; bb =    `y
z` // c
ccc = 3 // d
)
var table = []string{`one`,   `two
  three`, "four"}
var m = map[string]string{
	`k`: `v`,
	`longer`:   `multi
line`,
	"z": "z", // end
}
func main() {
	fmt.Println(`a` +   `b`, usage, a, bb, table, m)
	fmt.Printf(`%d
`,   1)
	s := `x
		y` +  "z"
	fmt.Println(s, len(`
`), f(`a
b`, 2))
	if s == `q` { fmt.Println(`r`) }
	x := []string{
		`a`,
		`b
c`,
	}
	_ = x
}
func f(s string, n int) string { return `[`+s+`]` }

"""#

private let rawStringsAreKeptAsTheyAreWrittenExpected = #"""
package main

import "fmt"

const usage = `usage:
	tool   [flags]
  -v   verbose
`
const (
	a  = `x`
	bb = `y
z` // c
	ccc = 3 // d
)

var table = []string{`one`, `two
  three`, "four"}
var m = map[string]string{
	`k`: `v`,
	`longer`: `multi
line`,
	"z": "z", // end
}

func main() {
	fmt.Println(`a`+`b`, usage, a, bb, table, m)
	fmt.Printf(`%d
`, 1)
	s := `x
		y` + "z"
	fmt.Println(s, len(`
`), f(`a
b`, 2))
	if s == `q` {
		fmt.Println(`r`)
	}
	x := []string{
		`a`,
		`b
c`,
	}
	_ = x
}
func f(s string, n int) string { return `[` + s + `]` }

"""#

private let rawStringsOfSeveralLinesInEveryPlaceSource = #"""
package main

import ("fmt"; "strings")

var q = strings.TrimSpace(`
SELECT *
  FROM t
`)
func one() string { return `a
b` }
func two() string { return `ab` }
type t struct { s string; n int }
func main() {
	w := 1 // c0
	x := `a
b` // c1
	y := 2 // c2
	zz := 3 // c3
	tests := []t{
		t{`a`, 1},
		t{`multi
line`, 2},
		t{`c`,    3}, // last
	}
	m := map[string]int{
		`one`: 1,
		`twenty
two`: 22,
		`three`: 3,
		`f`: 4,
	}
	fmt.Println(w, x, y, zz, tests, m,
		`tail
end`)
	fmt.Println(strings.Repeat(`ab
`, 2) + `c`, len(`x`), `
`[0])
	var (
		a = `1`
		bbb = `2
3`
		cc = 4
		d = 5
	)
	_, _, _, _ = a, bbb, cc, d
	switch x {
	case `a
b`:
		fmt.Println(`yes`)
	case `x`, `y`:
	}
	for _, s := range []string{`p`, `q`} { fmt.Print(s) }
	if x == `a
b` && y == 2 { fmt.Println() }
	fmt.Printf(`%s %d
`, x,
		y)
	go func() { fmt.Println(`in
closure`) }()
	s := []string{`a
b`,
		`c`}
	_ = s
	_ = `	tab	inside	` + "\t"
	_ = `x` // trailing
	_ = `
` // after multi
}

"""#

private let rawStringsOfSeveralLinesInEveryPlaceExpected = #"""
package main

import (
	"fmt"
	"strings"
)

var q = strings.TrimSpace(`
SELECT *
  FROM t
`)

func one() string {
	return `a
b`
}
func two() string { return `ab` }

type t struct {
	s string
	n int
}

func main() {
	w := 1 // c0
	x := `a
b` // c1
	y := 2  // c2
	zz := 3 // c3
	tests := []t{
		t{`a`, 1},
		t{`multi
line`, 2},
		t{`c`, 3}, // last
	}
	m := map[string]int{
		`one`: 1,
		`twenty
two`: 22,
		`three`: 3,
		`f`:     4,
	}
	fmt.Println(w, x, y, zz, tests, m,
		`tail
end`)
	fmt.Println(strings.Repeat(`ab
`, 2)+`c`, len(`x`), `
`[0])
	var (
		a   = `1`
		bbb = `2
3`
		cc = 4
		d  = 5
	)
	_, _, _, _ = a, bbb, cc, d
	switch x {
	case `a
b`:
		fmt.Println(`yes`)
	case `x`, `y`:
	}
	for _, s := range []string{`p`, `q`} {
		fmt.Print(s)
	}
	if x == `a
b` && y == 2 {
		fmt.Println()
	}
	fmt.Printf(`%s %d
`, x,
		y)
	go func() {
		fmt.Println(`in
closure`)
	}()
	s := []string{`a
b`,
		`c`}
	_ = s
	_ = `	tab	inside	` + "\t"
	_ = `x` // trailing
	_ = `
` // after multi
}

"""#

private let embeddedInterfacesSource = #"""
package main

import "fmt"

type I interface{ M() }
type J interface {
I
   N() int
}
type K interface { I; J; fmt.Stringer }
type L interface{ error }
type M interface {
	// doc
	I // trailing
	fmt.Stringer

	Close() error // c
	error
}
func main() {
	var x interface { I; N() int }
	var y interface{ J }
	_, _ = x, y
}

"""#

private let embeddedInterfacesExpected = #"""
package main

import "fmt"

type I interface{ M() }
type J interface {
	I
	N() int
}
type K interface {
	I
	J
	fmt.Stringer
}
type L interface{ error }
type M interface {
	// doc
	I // trailing
	fmt.Stringer

	Close() error // c
	error
}

func main() {
	var x interface {
		I
		N() int
	}
	var y interface{ J }
	_, _ = x, y
}

"""#
