/// Struct fields that share a type, `X, Y int`: what the parser makes of
/// them and how they behave. How `gofmt` lays them out is compared with Go's
/// in `GoGofmtConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go struct field lists")
struct GoFieldListTests: GoTestHarness {

    @Test func aFieldListDeclaresAFieldForEachName() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\ntype point struct {\n X, Y int\n name string\n a, b, c []bool\n}\n"))

        guard case .structure(let fields, _) = file.typeDeclarations[0].type else {
            Issue.record("unexpected type: \(file.typeDeclarations)")
            return
        }
        #expect(fields.map(\.name) == ["X", "Y", "name", "a", "b", "c"])
        // Each field is where its own name is.
        #expect(fields.map(\.position.column) == [2, 5, 2, 2, 5, 8])
        #expect(fields[0].type == .named("int", position: fields[0].type.position))
        #expect(fields[1].type == fields[0].type)
        #expect(fields[5].type == fields[3].type)
    }

    @Test func fieldsOfAListAreFieldsLikeAnyOther() throws {
        #expect(
            try runGoMain(
                """
                p := point{X: 1, Y: 2, name: "p", a: true}
                p.b, p.c = p.a, false
                q := point{3, 4, "q", false, true, false}
                fmt.Printf("%v %+v\\n", p, q)
                var s struct{ lo, hi int }
                s.hi = p.X + q.Y
                fmt.Println(s, segment{from: p, to: q}.to.Y)
                """,
                declarations: """
                    type point struct {
                        X, Y    int
                        name    string
                        a, b, c bool
                    }

                    type segment struct{ from, to point }
                    """)
                == "{1 2 p true true false} {X:3 Y:4 name:q a:false b:true c:false}\n{0 5} 4\n")
    }

    @Test func aFieldListIsChecked() {
        #expect(
            goMainDiagnostic("", declarations: "type t struct {\n X, Y int\n Y, Z string\n}")
                == "Y redeclared\n\tmain.go:4:5: other declaration of Y")
        #expect(
            goMainDiagnostic("", declarations: "type t struct {\n X, Y\n}") == "expected type")
        #expect(
            goMainDiagnostic("", declarations: "type t struct {\n X, int\n}") == "expected type")
        #expect(
            goMainDiagnostic(
                "fmt.Println(t{1, 2})", declarations: "type t struct {\n X, Y, Z int\n}")
                == "too few values in struct literal of type t")
    }

    @Test func gofmtKeepsTheNamesOfAListInOneColumn() throws {
        let formatted = try GoFormatter.format(
            GoSourceFile(
                path: "main.go",
                text: "package main\n\ntype point struct {\n\tX,Y int\n\tname string // n\n\ta, b,   c bool\n}\n\ntype one struct{ lo,hi int }\n"))
        #expect(
            formatted
                == "package main\n\ntype point struct {\n\tX, Y    int\n\tname    string // n\n\ta, b, c bool\n}\n\ntype one struct{ lo, hi int }\n")
    }
}
