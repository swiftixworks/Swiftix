/// Rewrite rules of `gofmt -r`: which identifiers of a pattern stand for any
/// expression, the order nested matches are rewritten in, and what an
/// identifier rule renames.
///
/// `cases` holds rules and, for each, the lines of `source` that the
/// `gofmt -r` of Go 1.24.5 changes, with what it makes of them, copied
/// without change; the test requires Swiftix `gofmt -r` to print the same
/// file. As in Go, an identifier of a rule is a wildcard when it is one
/// lower-case letter and matches itself otherwise; the operands of an
/// expression are rewritten before the expression is matched, so one rule
/// can apply at several depths; a rule from one identifier to another
/// renames the identifier wherever the file has it; and parentheses in a
/// pattern match parentheses, so `(a) -> a` removes every pair.
///
/// To add a case, run the rule with Go and paste the lines it changes.

@testable import SwiftixGo
import Testing

@Suite("gofmt rewrite rules")
struct GoRewriteRuleTests {

    @Test(arguments: cases.indices)
    func theRuleRewritesWhatGofmtRewrites(index: Int) throws {
        let (rule, changes) = Self.cases[index]
        var expected = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (line, text) in changes { expected[line - 1] = text }
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(path: "main.go", text: source), rule: rule)
        let actual = try GoFormatter.format(rewritten)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(actual.count == expected.count, "\(rule)")
        for (number, pair) in zip(actual, expected).enumerated() {
            #expect(pair.0 == pair.1, "\(rule), line \(number + 1)")
        }
    }

    @Test func aRuleMustBeTwoExpressions() {
        #expect(throws: GoDiagnostic.self) {
            try GoSourceRewriter.rewrite(GoSourceFile(path: "main.go", text: source), rule: "x += a -> x")
        }
        #expect(throws: GoDiagnostic.self) {
            try GoSourceRewriter.rewrite(GoSourceFile(path: "main.go", text: source), rule: "-> x")
        }
    }

    /// Rules and the lines of `source` each changes, by line number.
    static let cases: [(rule: String, changes: [Int: String])] = [
        ("a(b, c) -> a(c, b)", [11: "var total = sum(0, sum(2, 1))", 21: "\tfmt.Println(sum(p.B, p.A), id(3), local(4), total)", 24: "\t\tfmt.Println(sum(2, 1) == 3 == true)"]),
        ("sum(a, b) -> sum(b, a)", [11: "var total = sum(0, sum(2, 1))", 21: "\tfmt.Println(sum(p.B, p.A), id(3), local(4), total)", 24: "\t\tfmt.Println(sum(2, 1) == 3 == true)"]),
        ("f(1) -> 1", [22: "\tfmt.Println(1, (p.A+0)+0, list[1:len(list)], f((p.B)))"]),
        ("f(a) -> a", [21: "\tfmt.Println(sum(p.A, p.B), 3, 4, total)", 22: "\tfmt.Println(1, (p.A+0)+0, list[1:list], (p.B))", 24: "\t\tsum(1, 2) == 3 == true"]),
        ("a + 0 -> a", [22: "\tfmt.Println(f(f(1)), (p.A), list[1:len(list)], f((p.B)))"]),
        ("a[b:len(a)] -> a[b:]", [22: "\tfmt.Println(f(f(1)), (p.A+0)+0, list[1:], f((p.B)))"]),
        ("a == true -> a", [24: "\t\tfmt.Println(sum(1, 2) == 3)"]),
        ("pair{A: a, B: b} -> pair{A: b, B: a}", [19: "\tp := pair{A: 2, B: 1}"]),
        ("fmt.Println(a, b, c, d) -> fmt.Print(a, b, c, d)", [21: "\tfmt.Print(sum(p.A, p.B), id(3), local(4), total)", 22: "\tfmt.Print(f(f(1)), (p.A+0)+0, list[1:len(list)], f((p.B)))"]),
        ("len(list) -> n", [22: "\tfmt.Println(f(f(1)), (p.A+0)+0, list[1:n], f((p.B)))"]),
        ("p.A -> p.B", [21: "\tfmt.Println(sum(p.B, p.B), id(3), local(4), total)", 22: "\tfmt.Println(f(f(1)), (p.B+0)+0, list[1:len(list)], f((p.B)))"]),
        ("1 -> one", [11: "var total = sum(sum(one, 2), 0)", 19: "\tp := pair{A: one, B: 2}", 20: "\tlist := []int{one, 2, 3}", 22: "\tfmt.Println(f(f(one)), (p.A+0)+0, list[one:len(list)], f((p.B)))", 24: "\t\tfmt.Println(sum(one, 2) == 3 == true)"]),
        ("id -> ident", [9: "type ident int", 18: "\ttype local ident", 21: "\tfmt.Println(sum(p.A, p.B), ident(3), local(4), total)"]),
        ("sum -> add", [11: "var total = add(add(1, 2), 0)", 13: "func add(a int, b int) int { return a + b }", 21: "\tfmt.Println(add(p.A, p.B), id(3), local(4), total)", 24: "\t\tfmt.Println(add(1, 2) == 3 == true)"]),
        ("A -> First", [6: "\tFirst, B int", 19: "\tp := pair{First: 1, B: 2}", 21: "\tfmt.Println(sum(p.First, p.B), id(3), local(4), total)", 22: "\tfmt.Println(f(f(1)), (p.First+0)+0, list[1:len(list)], f((p.B)))"]),
        ("int -> int64", [6: "\tA, B int64", 9: "type id int64", 13: "func sum(a int64, b int64) int64 { return a + b }", 15: "func f(n int64) int64 { return n }", 20: "\tlist := []int64{1, 2, 3}"]),
        ("local -> inner", [18: "\ttype inner id", 21: "\tfmt.Println(sum(p.A, p.B), id(3), inner(4), total)"]),
        ("total -> grand", [11: "var grand = sum(sum(1, 2), 0)", 21: "\tfmt.Println(sum(p.A, p.B), id(3), local(4), grand)"]),
        ("fmt.Println -> fmt.Print", [21: "\tfmt.Print(sum(p.A, p.B), id(3), local(4), total)", 22: "\tfmt.Print(f(f(1)), (p.A+0)+0, list[1:len(list)], f((p.B)))", 24: "\t\tfmt.Print(sum(1, 2) == 3 == true)"]),
        ("list[a:b] -> list[a+1 : b]", [22: "\tfmt.Println(f(f(1)), (p.A+0)+0, list[1+1:len(list)], f((p.B)))"]),
        ("sum(a, 0) -> a", [11: "var total = sum(1, 2)"]),
        ("ab -> cd", [:]),
        ("(a) -> a", [22: "\tfmt.Println(f(f(1)), p.A+0+0, list[1:len(list)], f(p.B))"]),
        ("(a + 0) -> a", [22: "\tfmt.Println(f(f(1)), p.A+0, list[1:len(list)], f((p.B)))"]),
        ("f((a)) -> f(a)", [22: "\tfmt.Println(f(f(1)), (p.A+0)+0, list[1:len(list)], f(p.B))"]),
        ("sum(a, b) -> (a + b)", [11: "var total = ((1 + 2) + 0)", 21: "\tfmt.Println((p.A + p.B), id(3), local(4), total)", 24: "\t\tfmt.Println((1 + 2) == 3 == true)"]),
        ("(a) -> f(a)", [22: "\tfmt.Println(f(f(1)), f(p.A+0)+0, list[1:len(list)], f(f(p.B)))"]),
    ]
}

private let source = #"""
package main

import "fmt"

type pair struct {
	A, B int
}

type id int

var total = sum(sum(1, 2), 0)

func sum(a int, b int) int { return a + b }

func f(n int) int { return n }

func main() {
	type local id
	p := pair{A: 1, B: 2}
	list := []int{1, 2, 3}
	fmt.Println(sum(p.A, p.B), id(3), local(4), total)
	fmt.Println(f(f(1)), (p.A+0)+0, list[1:len(list)], f((p.B)))
	defer func() {
		fmt.Println(sum(1, 2) == 3 == true)
	}()
}

"""#
