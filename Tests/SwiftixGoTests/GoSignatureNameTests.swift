/// Names in the signatures of interface methods, `Get(key string) (value
/// string, ok bool)`, and results that share a type, `(x, y int)`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go signature names")
struct GoSignatureNameTests: GoTestHarness {

    private func methods(_ body: String) throws -> [GoInterfaceMethodDeclaration] {
        let file = try GoParser.parse(
            GoSourceFile(path: "main.go", text: "package main\ntype t interface {\n" + body + "\n}\n"))
        guard case .interface(let methods, _) = file.typeDeclarations[0].type else { return [] }
        return methods
    }

    private func names(_ types: [GoTypeExpression]) -> [String] {
        types.map { type in
            switch type {
            case .named(let name, _): return name
            case .pointer(.named(let name, _), _): return "*" + name
            case .slice(.named(let name, _), _): return "[]" + name
            case .array(GoSpread.variadicLength, .named(let name, _), _): return "..." + name
            case .map: return "map"
            default: return "?"
            }
        }
    }

    @Test func anInterfaceMethodMayNameWhatItTakesAndGives() throws {
        let methods = try methods(
            """
             Get(key string) (value string, ok bool)
             Put(key, value string)
             Sum(first int, rest ...int) int
             Each(prefix string, out *os.File, limit, skip int) (n int, err error)
             Plain(string, int) bool
             Pair(a, b []string, m map[string]int) (x, y int)
             Len() int
            """)

        // A method of an interface keeps the types; a name before a type
        // gives every bare name before it that type.
        #expect(methods.map(\.name) == ["Get", "Put", "Sum", "Each", "Plain", "Pair", "Len"])
        #expect(names(methods[0].parameters) == ["string"])
        #expect(names(methods[0].results) == ["string", "bool"])
        #expect(names(methods[1].parameters) == ["string", "string"])
        #expect(names(methods[2].parameters) == ["int", "...int"])
        #expect(names(methods[3].parameters) == ["string", "*os.File", "int", "int"])
        #expect(names(methods[3].results) == ["int", "error"])
        #expect(names(methods[4].parameters) == ["string", "int"])
        #expect(names(methods[5].parameters) == ["[]string", "[]string", "map"])
        #expect(names(methods[5].results) == ["int", "int"])
        #expect(methods[6].parameters.isEmpty)

        #expect(
            goMainDiagnostic("", declarations: "type t interface {\n Sum(rest ...int, last int)\n}")
                == "can only use ... with final parameter in list")
        #expect(
            goMainDiagnostic("", declarations: "type t interface {\n Get(key string\n}")
                == "expected ',' or ')'")
    }

    @Test func aMethodWithNamesIsCalledLikeAnyOther() throws {
        #expect(
            try runGoMain(
                """
                var s store = &table{items: map[string]string{}}
                s.Put("k", "v")
                v, ok := s.Get("k")
                _, missing := s.Get("none")
                x, y := s.Pair([]string{"a"}, nil, map[string]int{"m": 1})
                fmt.Println(v, ok, missing, s.Sum(1), s.Sum(1, 2, 3), s.Plain("ab", 2), x, y)
                fmt.Printf("%T\\n", s)
                """,
                declarations: """
                    type store interface {
                        Get(key string) (value string, ok bool)
                        Put(key, value string)
                        Sum(first int, rest ...int) int
                        Plain(string, int) bool
                        Pair(a, b []string, m map[string]int) (x, y int)
                    }

                    type table struct {
                        items map[string]string
                    }

                    func (t *table) Get(key string) (value string, ok bool) {
                        value, ok = t.items[key]
                        return value, ok
                    }

                    func (t *table) Put(key, value string) { t.items[key] = value }

                    func (t *table) Sum(first int, rest ...int) int {
                        for _, r := range rest {
                            first += r
                        }
                        return first
                    }

                    func (t *table) Plain(s string, n int) bool { return len(s) == n }

                    func (t *table) Pair(a, b []string, m map[string]int) (x, y int) {
                        return len(a) + len(b), len(m)
                    }
                    """)
                == "v true false 1 6 true 1 1\n*main.table\n")
    }

    @Test func resultsOfOneTypeShareIt() throws {
        // `(x, y int)` used to fail where `(x int, y int)` did not.
        #expect(
            try runGoMain(
                """
                q, r := divide(17, 5)
                lo, hi, ok := bounds([]int{4, 9, 2})
                fmt.Println(q, r, lo, hi, ok)
                """,
                declarations: """
                    func divide(a, b int) (quotient, remainder int) {
                        quotient = a / b
                        remainder = a - quotient*b
                        return
                    }

                    func bounds(values []int) (low, high int, found bool) {
                        for i, v := range values {
                            if i == 0 || v < low {
                                low = v
                            }
                            if i == 0 || v > high {
                                high = v
                            }
                            found = true
                        }
                        return low, high, found
                    }
                    """) == "3 2 2 9 true\n")
    }

    @Test func gofmtSpacesTheNamesOfAMethod() throws {
        #expect(
            try GoFormatter.format(
                GoSourceFile(
                    path: "main.go",
                    text: "package main\n\ntype store interface {\n\tGet(key string)(value string,ok bool)\n\tPut(key,value string)\n\tSum(first int,rest ...int) int\n}\n"))
                == "package main\n\ntype store interface {\n\tGet(key string) (value string, ok bool)\n\tPut(key, value string)\n\tSum(first int, rest ...int) int\n}\n")
    }
}
