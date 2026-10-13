/// Variables a function declares and never reads, which Go refuses:
/// `declared and not used: x`.
///
/// `cases` holds bodies of `func main` and, for each, the first error the
/// compiler of Go 1.24.5 reports, copied without change; the test requires
/// Swiftix Go to report the same error at the same place. They cover what
/// counts as a read (everything but being the bare target of an assignment:
/// `x = 1` alone leaves `x` unused, while `x++`, `x += 1`, `x.f = 1`,
/// `x[i] = 1`, and `&x` read it), which declarations must be read (those of a
/// statement, not parameters, results, or constants), where each name is, and
/// which of several errors comes first.
///
/// To add a case, compile the body with Go and paste its first error.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go unused variables")
struct GoUnusedVariableTests: GoTestHarness {

    private static let prelude =
        "package main\n\ntype T struct{ f int }\n\nfunc f() (int, error) { return 1, nil }\n\n"
        + "func use(v int) {}\n\nfunc main() {\n"

    private func diagnostic(_ text: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    @Test(arguments: cases.indices)
    func theFirstErrorIsTheOneGoReports(index: Int) {
        let (body, expected) = Self.cases[index]
        #expect(diagnostic(Self.prelude + body + "\n}\n") == expected, "\(body)")
    }

    @Test func theParserKeepsWhereEachNameIs() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\nfunc main() {\n a,  b := 1, 2\n var c, d int\n for i, v := range x {\n }\n var e int\n}\n"))
        let statements = file.functions[0].body.statements

        // A statement has one position; the names of each are beside it.
        func columns(_ statement: GoStatement) -> [Int]? {
            switch statement {
            case .multiDeclaration(_, _, let position), .declaration(_, _, _, _, let position),
                .forRangeStatement(_, _, _, _, let position):
                return file.namePositions[position.offset]?.map(\.column)
            default:
                return nil
            }
        }
        // After the names of a `:=` comes the `:=` itself.
        #expect(statements.map(columns) == [[2, 6, 8], [6, 9], [6, 9], [6]])
    }

    @Test func aProgramWithoutUnusedVariablesCompilesToWhatItDid() throws {
        // The check adds nothing to a program that passes it.
        #expect(
            try runGoMain(
                """
                total := 0
                for i, v := range []int{1, 2, 3} {
                    total += i * v
                }
                n, err := fmt.Println(total)
                var last struct{ n int }
                last.n = n
                if ok := err == nil; ok {
                    fmt.Println(last.n, ok)
                }
                """) == "8\n2 true\n")
    }

    /// Bodies of `func main` and the first error Go reports for each.
    static let cases: [(body: String, expected: String?)] = [
        ("\ta := 1", "main.go:10:2: declared and not used: a"),
        ("\tb := 1\n\tb = 2", "main.go:10:2: declared and not used: b"),
        ("\tc := 0\n\tc++", nil),
        ("\td := 0\n\td += 1", nil),
        ("\tvar e T\n\te.f = 1", nil),
        ("\tvar g [3]int\n\tg[0] = 1", nil),
        ("\th := map[string]int{}\n\th[\"k\"] = 1", nil),
        ("\ti := &T{}\n\ti.f = 1", nil),
        ("\tfor j, k := range []int{1} {\n\t}", "main.go:10:6: declared and not used: j"),
        ("\tfor j, k := range []int{1} {\n\t\tuse(j)\n\t}", "main.go:10:9: declared and not used: k"),
        ("\tfor _, k := range []int{1} {\n\t}", "main.go:10:9: declared and not used: k"),
        ("\tfor j := range []int{1} {\n\t}", "main.go:10:6: declared and not used: j"),
        ("\tl, m := 1, 2\n\tuse(l)", "main.go:10:5: declared and not used: m"),
        ("\tl,   m := 1, 2\n\tuse(m)", "main.go:10:2: declared and not used: l"),
        ("\tvar n int", "main.go:10:6: declared and not used: n"),
        ("\tvar n, nn int\n\tuse(n)", "main.go:10:9: declared and not used: nn"),
        ("\tvar (\n\t\tn1 = 1\n\t\tn2, n3 = 2, 3\n\t)\n\tuse(n1 + n2)", "main.go:12:7: declared and not used: n3"),
        ("\tconst o = 1", nil),
        ("\tif p := 1; true {\n\t}", "main.go:10:5: declared and not used: p"),
        ("\tswitch q := 1; {\n\t}", "main.go:10:9: declared and not used: q"),
        ("\tswitch q := 1; q {\n\t}", nil),
        ("\tr := 1\n\tr, s := 2, 3\n\tuse(s)", "main.go:10:2: declared and not used: r"),
        ("\tt := 1\n\tu := &t", "main.go:11:2: declared and not used: u"),
        ("\tch := make(chan int, 1)\n\tselect {\n\tcase v := <-ch:\n\tdefault:\n\t}", "main.go:12:7: declared and not used: v"),
        ("\tch := make(chan int, 1)\n\tselect {\n\tcase v, ok := <-ch:\n\t\tuse(v)\n\tdefault:\n\t}", "main.go:12:10: declared and not used: ok"),
        ("\tw, err := f()", "main.go:10:2: declared and not used: w"),
        ("\tw, err := f()\n\tuse(w)", "main.go:10:5: declared and not used: err"),
        ("\t_, err := f()", "main.go:10:5: declared and not used: err"),
        ("\tx := []int{1}\n\tx = append(x, 2)", nil),
        ("\ty := 1\n\ty = y + 1", nil),
        ("\tvar z *T\n\t*z = T{}", nil),
        ("\tfor aa := 0; aa < 1; aa++ {\n\t}", nil),
        ("\tfor bb := 0; ; {\n\t\tbreak\n\t}", "main.go:10:6: declared and not used: bb"),
        ("\tcc := 1\n\t{\n\t\tcc = 2\n\t}", "main.go:10:2: declared and not used: cc"),
        ("\tdd := []int{1}\n\tdd[0]++", nil),
        ("\tee := T{}\n\tee.f++", nil),
        ("\tm := map[string]int{}\n\tv, ok := m[\"k\"]\n\tuse(v)", "main.go:11:5: declared and not used: ok"),
        ("\tvar i interface{} = 1\n\tn, ok := i.(int)\n\tuse(n)", "main.go:11:5: declared and not used: ok"),
        ("\tvar i interface{} = 1\n\tn, ok := i.(int)\n\tif ok {\n\t}", "main.go:11:2: declared and not used: n"),
        ("\tch := make(chan int, 1)\n\tv, ok := <-ch", "main.go:11:2: declared and not used: v"),
        ("\tfirst := 1\n\t{\n\t\tsecond := 2\n\t}\n\tuse(first)", "main.go:12:3: declared and not used: second"),
        ("\t{\n\t\tinner := 2\n\t}\n\touter := undefined", "main.go:11:3: declared and not used: inner"),
        ("\touter := 1\n\t{\n\t\tinner := undefined\n\t\tuse(inner)\n\t}", "main.go:10:2: declared and not used: outer"),
        ("\tearly := 1\n\tlater := undefined\n\tuse(early)", "main.go:11:2: declared and not used: later"),
        ("\tif x := 1; x > 0 {\n\t\ty := 2\n\t} else {\n\t\tuse(x)\n\t}", "main.go:11:3: declared and not used: y"),
        ("\tx := 1\n\tdefer func() {\n\t\ty := 2\n\t}()\n\tuse(x)", "main.go:12:3: declared and not used: y"),
        ("\tx := 1\n\tfunc() {\n\t\tuse(1)\n\t}()", "main.go:10:2: declared and not used: x"),
        ("\tvar a, b = f()\n\tuse(a)", "main.go:10:9: declared and not used: b"),
        ("\tx := 1\n\tx, y := 2, 3\n\tuse(x)", "main.go:11:5: declared and not used: y"),
        ("\ttype local int\n\tvar v local", "main.go:11:6: declared and not used: v"),
        ("\tp := T{}\n\tq := &p\n\tq.f = 1", nil),
        ("\ts := \"a\"\n\ts += \"b\"", nil),
        ("\tn := 0\n\tfor n < 3 {\n\t\tn++\n\t}", nil),
        ("\ttotal := 0\n\tfor i := 0; i < 3; i++ {\n\t\ttotal = i\n\t}", "main.go:10:2: declared and not used: total"),
        ("\ta := 1\n\tif undefined {\n\t\tuse(a)\n\t}", "main.go:11:5: undefined: undefined"),
        ("\ta := 1\n\tb := 2\n\tc := a + undefined + b", "main.go:12:2: declared and not used: c"),
        ("\ta := 1\n\tfor i := 0; i < undefined; i++ {\n\t\tuse(a)\n\t}\n\tb := 2", "main.go:11:18: undefined: undefined"),
        ("\ta := 1\n\tdefer func() {\n\t\tb := undefined\n\t}()", "main.go:10:2: declared and not used: a"),
        ("\ta, b := 1, undefined\n\tuse(a)", "main.go:10:5: declared and not used: b"),
        ("\tx := undefined\n\ty := x\n\tz := 1", "main.go:10:7: undefined: undefined"),
        ("\tconst k = undefined\n\tv := k", "main.go:10:12: undefined: undefined"),
        ("\tuse(undefined)\n\tlate := 1", "main.go:10:6: undefined: undefined"),
    ]
}
