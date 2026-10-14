/// The expressions of `GoSingleEvaluationTests`, `GoFullSliceTests`,
/// `GoInterfaceComparisonTests`, and `GoVariadicLiteralCallTests` seen by
/// every pass: through an aliased import and across two packages of one
/// module, with a type declared in a function and an alias, inside literals
/// that use the variables of the function around them, and through `gofmt`.
///
/// What the module prints is what Go 1.24.5 prints for it, and what `gofmt`
/// writes is what Go's `gofmt` writes.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go expressions through every pass")
struct GoExpressionPassTests {
    /// What the module `example/m` made of `files` prints: each file belongs
    /// to the package its directory names.
    private func runModule(_ files: [(path: String, text: String)]) throws -> String {
        var sources: [String: [GoSourceFile]] = [:]
        for file in files {
            let directory = file.path.split(separator: "/").dropLast().joined(separator: "/")
            sources[directory.isEmpty ? "example/m" : "example/m/" + directory, default: []]
                .append(GoSourceFile(path: "/m/" + file.path, text: file.text))
        }
        let executable = try GoCompiler.compile(
            packages: sources.keys.sorted().map {
                GoPackageSource(importPath: $0, sources: sources[$0] ?? [])
            },
            root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

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

    /// A target with calls, a full slice, an interface compared with a value
    /// of a library type, and a variadic literal that is deferred, in a
    /// package that imports `fmt` as `f` and another of the module.
    @Test func theExpressionsWorkAcrossPackages() throws {
        let output = try runModule([("lib/lib.go", passLibrary), ("main.go", passMain)])
        #expect(output == passOutput)
    }

    /// Go's printer puts blanks around the colons of a full slice when an
    /// index is an operation, and only at the outermost level.
    @Test func gofmtLaysOutTheExpressionsAsGoDoes() throws {
        try expectGofmt(passGofmtSource, passGofmtExpected)
    }

    /// A rewrite rule matches and writes the third index.
    @Test func aRewriteRuleKnowsTheThirdIndex() throws {
        let source = GoSourceFile(path: "main.go", text: passRewriteSource)
        #expect(
            try GoSourceRewriter.rewrite(source, rule: "a[b:c:d] -> a[b:d]").text
                == passRewriteSource.replacingOccurrences("s[0:1:2]", "s[0:2]"))
        #expect(
            try GoSourceRewriter.rewrite(source, rule: "a[b:c] -> a[b:c:c]").text
                == passRewriteSource.replacingOccurrences("s[1:2]", "s[1:2:2]"))
    }
}

extension String {
    /// `self` with every `target` replaced by `replacement`, without
    /// Foundation.
    fileprivate func replacingOccurrences(_ target: String, _ replacement: String) -> String {
        split(separator: target, omittingEmptySubsequences: false)
            .joined(separator: replacement)
    }
}

private let passLibrary = #"""
package lib

type Box struct{ N int }

type Code int

var calls int

func Next() *Box { calls++; return &shared }

var shared Box

func Calls() int { return calls }

func Window(s []int, n int) []int { return s[:n:n] }

func Is(v any, c Code) bool { return v == c }

func Sum(xs ...int) int {
	t := 0
	for _, x := range xs {
		t += x
	}
	return t
}
"""# + "\n"

private let passMain = #"""
package main

import (
	f "fmt"
	"example/m/lib"
)

type alias = lib.Box

func main() {
	type local struct{ n int }
	ls := []local{{1}, {2}}
	idx := 0
	pick := func() int { idx++; return idx - 1 }
	ls[pick()].n += 10
	ls[pick()].n++
	lib.Next().N += 5
	lib.Next().N--
	var al *alias = lib.Next()
	al.N *= 3
	f.Println(ls, *lib.Next(), lib.Calls(), idx)
	w := lib.Window([]int{1, 2, 3, 4}, 2)
	w = append(w, 9)
	f.Println(w, len(w), cap(w))
	var v any = lib.Code(3)
	f.Println(lib.Is(v, 3), v == lib.Code(3), v == 3, v == local{1})
	var lv any = local{1}
	f.Println(lv == local{1}, lv == alias{1})
	total := 0
	add := func() {
		m := map[string]int{}
		key := func() string { total++; return "k" }
		m[key()] += 2
		m[key()] <<= 3
		f.Println(m, total)
	}
	add()
	defer func(xs ...int) { f.Println("deferred", xs, lib.Sum(xs...), total) }(1, 2, 3)
	arr := [4]int{1, 2, 3, 4}
	g := func() []int { return arr[1:2:3] }
	f.Println(g(), cap(g()))
	switch v {
	case lib.Code(2):
		f.Println("two")
	case lib.Code(3):
		f.Println("three")
	}
}
"""# + "\n"

private let passOutput = #"""
[{11} {3}] {12} 4 2
[1 2 9] 3 4
true true false false
true false
map[k:16] 2
[2] 2
three
deferred [1 2 3] 6 2
"""# + "\n"

private let passGofmtSource = #"""
package main

import "fmt"

func main() {
	s := []int{1, 2, 3, 4,5}
	a := [5]int{}
	i, j, k := 1, 2, 3
	_ = s[ 1 : 2 : 3 ]
	_ = s[i+1:j+1:k+1]
	_ = s[:j:k]
	_ = s[:j+1:k]
	_ = a[0 : 1:2]
	_ = (&a)[i:j:k]
	_ = s[i:j:k][0:1:1]
	fmt.Println(s[1:j*2:len(s)], s[i : j : k])
	f(s[0:1:1], s[i+1:j+2:k+2])
	m := map[int]int{}
	m[ g(i) ]+=1
	m[g(i)] ++
	if x:=[]any{1}; x[0]==1 { fmt.Println(x[0] != 2) }
}

func f(a, b []int) {}
func g(x int) int { return x }
"""# + "\n"

private let passGofmtExpected = #"""
package main

import "fmt"

func main() {
	s := []int{1, 2, 3, 4, 5}
	a := [5]int{}
	i, j, k := 1, 2, 3
	_ = s[1:2:3]
	_ = s[i+1 : j+1 : k+1]
	_ = s[:j:k]
	_ = s[: j+1 : k]
	_ = a[0:1:2]
	_ = (&a)[i:j:k]
	_ = s[i:j:k][0:1:1]
	fmt.Println(s[1:j*2:len(s)], s[i:j:k])
	f(s[0:1:1], s[i+1:j+2:k+2])
	m := map[int]int{}
	m[g(i)] += 1
	m[g(i)]++
	if x := []any{1}; x[0] == 1 {
		fmt.Println(x[0] != 2)
	}
}

func f(a, b []int) {}
func g(x int) int  { return x }
"""# + "\n"

private let passRewriteSource = #"""
package main

func main() {
	s := []int{1, 2, 3}
	_ = s[0:1:2]
	_ = s[1:2]
}
"""# + "\n"
