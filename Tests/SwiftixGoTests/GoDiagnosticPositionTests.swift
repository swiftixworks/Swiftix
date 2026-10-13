/// Where a diagnostic about a function or a selection is reported: at the
/// function's name, at the end of its body for a missing return, at the
/// name of a result, and at the selected name. Each expectation is the
/// first error of Go 1.24.5 for the same source, place and text, except
/// where a comment says the text is Swiftix Go's.

@testable import SwiftixGo
import Testing

@Suite("Go diagnostic positions")
struct GoDiagnosticPositionTests {

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

    @Test func aMissingReturnIsWhereTheBodyEnds() {
        #expect(
            diagnostic(
                "package main\nfunc f(n int) int {\n if n > 0 {\n  return 1\n }\n}\nfunc main() { _ = f(1) }\n")
                == "main.go:6:1: missing return")
        #expect(
            diagnostic("package main\nfunc f(n int) int { _ = n }\nfunc main() { _ = f(1) }\n")
                == "main.go:2:27: missing return")
        #expect(
            diagnostic(
                "package main\ntype T int\nfunc (t T) M() int {\n}\nfunc main() { _ = T(1).M() }\n")
                == "main.go:4:1: missing return")
    }

    @Test func aFunctionIsReportedAtItsName() {
        #expect(
            diagnostic("package main\nfunc f() {}\nfunc f() {}\nfunc main() { f() }\n")
                == "main.go:3:6: f redeclared in this block")
        #expect(
            diagnostic("package main\nvar f = 1\nfunc f() {}\nfunc main() {}\n")
                == "main.go:3:6: f redeclared in this block")
        #expect(
            diagnostic("package main\nfunc init(n int) {}\nfunc main() {}\n")
                == "main.go:2:6: func init must have no arguments and no return values")
        #expect(
            diagnostic("package main\nfunc main() int { return 1 }\n")
                == "main.go:2:6: func main must have no arguments and no return values")
    }

    @Test func aMethodDeclaredTwiceNamesTheFirst() {
        #expect(
            diagnostic(
                "package main\ntype T int\nfunc (t T) M() {}\nfunc (t T) M() {}\nfunc main() {}\n")
                == "main.go:4:12: method T.M already declared at main.go:3:12")
        // A type has one method of a name, whichever receiver each has.
        #expect(
            diagnostic(
                "package main\ntype T int\nfunc (t T) M() {}\nfunc (t *T) M() {}\nfunc main() {}\n")
                == "main.go:4:13: method T.M already declared at main.go:3:12")
    }

    @Test func aResultIsReportedAtItsName() {
        #expect(
            diagnostic("package main\nfunc f(a int) (a int) { return a }\nfunc main() { _ = f(1) }\n")
                == "main.go:2:16: a redeclared in this block")
        #expect(
            diagnostic(
                "package main\nfunc f(a int) (n int, a string) { return 1, \"\" }\nfunc main() { _, _ = f(1) }\n")
                == "main.go:2:23: a redeclared in this block")
        #expect(
            diagnostic(
                "package main\nfunc f(b int) (a, b int) { return 1, 2 }\nfunc main() { _, _ = f(1) }\n")
                == "main.go:2:19: b redeclared in this block")
    }

    @Test func aSelectionIsReportedAtTheSelectedName() {
        // The texts are Swiftix Go's; Go says `b.inner.missing undefined
        // (type *box has no field or method missing)` at the same places.
        let declarations = "package main\ntype box struct {\n inner *box\n name string\n}\n"
        #expect(
            diagnostic(declarations + "func main() {\n b := &box{}\n _ = b.inner.missing\n}\n")
                == "main.go:8:14: *box has no field or method missing")
        // Also where the name is on a line of its own.
        #expect(
            diagnostic(declarations + "func main() {\n b := &box{}\n _ = b.\n  inner.\n  missing\n}\n")
                == "main.go:10:3: *box has no field or method missing")
        #expect(
            diagnostic(declarations + "func main() {\n b := &box{}\n b.inner.grow()\n}\n")
                == "main.go:8:10: *box has no field or method grow")
    }
}
