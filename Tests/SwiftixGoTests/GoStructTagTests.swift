/// Struct tags: a string literal after a field. A tag changes nothing a
/// struct value does; it is part of the struct type, so two struct types
/// that differ in a tag are two types.
///
/// What each program prints is what Go 1.24.5 prints for it; a message
/// pinned alone is one this dialect words in its own way, at Go's place.
/// How `gofmt` aligns tags is in `GoEmbeddingGofmtTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go struct tags")
struct GoStructTagTests: GoTestHarness {

    /// Raw or interpreted, after a field, each field of a list, or an
    /// embedded field. The declaration keeps the value of the literal.
    @Test func aTagIsKeptWithTheFieldItFollows() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\ntype rec struct {\n\tName string `json:\"name\"`\n\tA, B int \"x:\\\"1\\\"\"\n\tbase `b`\n\tn int\n}\n"))
        guard case .structure(let fields, _) = file.typeDeclarations[0].type else {
            Issue.record("not a struct type")
            return
        }

        #expect(fields.map(\.name) == ["Name", "A", "B", "base", "n"])
        #expect(fields.map(\.tag) == ["json:\"name\"", "x:\"1\"", "x:\"1\"", "b", nil])
        #expect(fields[3].isEmbedded)
        #expect(
            GoStructFieldType(fields[0], type: .string)
                != GoStructFieldType(name: "Name", type: .string))
    }

    /// Fields are read, assigned, compared, and printed as before; `%T` of
    /// a struct type written in place shows its tags, as Go's does.
    @Test func aTaggedStructIsTheStructItWouldBeWithoutTags() throws {
        #expect(
            try runGoMain(
                #"""
                r := rec{"x", 3, 1, 2}
                r.Age++
                fmt.Printf("%v %+v %#v %T\n", r, r, r, r)
                var t struct {
                    A int `json:"a"`
                    B string
                }
                t.A = 1
                u := t
                fmt.Printf("%T|%v|%+v\n", t, t, u == t)
                var boxed any = t
                _, same := boxed.(struct {
                    A int `json:"a"`
                    B string
                })
                _, other := boxed.(struct {
                    A int
                    B string
                })
                fmt.Println(same, other)
                """#,
                declarations: #"""
                    type rec struct {
                        Name string `json:"name"`
                        Age  int    "json:\"age\""
                        a, b int    `x:"1"`
                    }
                    """#)
                == #"""
                {x 4 1 2} {Name:x Age:4 a:1 b:2} main.rec{Name:"x", Age:4, a:1, b:2} main.rec
                struct { A int "json:\"a\""; B string }|{1 }|true
                true false

                """#)
        #expect(
            goMainDiagnostic(
                """
                var t T
                var w struct {
                    A int `b`
                }
                w = t
                _ = w
                """,
                declarations: """
                    type T struct {
                        A int `a`
                    }
                    """)
                == #"cannot use t (variable of struct type T) as struct{A int "b"} value in assignment"#)
        #expect(
            goMainDiagnostic(
                """
                var t T
                _ = t
                """,
                declarations: """
                    type T struct {
                        Name string 5
                    }
                    """)
                == "expected semicolon or newline in struct type")
    }
}
