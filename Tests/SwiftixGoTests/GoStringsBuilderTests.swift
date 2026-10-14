/// `strings.Builder`, which is Go text of the library
/// (`Sources/SwiftixGoLibrary/strings/builder.go`) over a `[]byte`: each
/// write is one `append`, so it costs the same VM instructions whatever
/// its length.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports. The text
/// itself is held to Go's `strings` with random inputs by
/// `Scripts/go-library-harness/run.sh strings`. `Cap` is not compared: the
/// capacities of this VM's slices grow by doubling, not by Go's size
/// classes.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go strings.Builder")
struct GoStringsBuilderTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// A Builder needs no constructor. The writes return what Go's return: a
    /// length and a nil error, and for a rune the length of its encoding, with
    /// U+FFFD for a value that is no code point.
    @Test func theZeroValueIsReadyAndEveryWriteAdds() throws {
        #expect(
            try runGoMain(
                #"""
                var b strings.Builder
                fmt.Println(b.Len(), b.String() == "", b.Cap())
                n, err := b.WriteString("héllo")
                fmt.Println(n, err, b.Len())
                fmt.Println(b.WriteByte('!'))
                n, err = b.WriteRune('世')
                fmt.Println(n, err)
                n, err = b.WriteRune(-1)
                fmt.Println(n, err)
                n, err = b.WriteRune(0x10ffff + 1)
                fmt.Println(n, err)
                n, err = b.WriteRune('a')
                fmt.Println(n, err)
                n, err = b.Write([]byte(" bytes"))
                fmt.Println(n, err)
                fmt.Println(b.String(), b.Len(), b.Cap() >= b.Len())
                fmt.Printf("%q %T\n", b.String(), &b)
                """#,
                imports: ["fmt", "strings"])
                == """
                0 true 0
                6 <nil> 6
                <nil>
                3 <nil>
                3 <nil>
                3 <nil>
                1 <nil>
                6 <nil>
                héllo!世��a bytes 23 true
                "héllo!世��a bytes" *strings.Builder

                """)
        #expect(
            try runGoMain(
                """
                var b strings.Builder
                for _, c := range []byte("世界") {
                    b.WriteByte(c)
                }
                fmt.Println(b.String(), b.Len(), len(b.String()))
                s := b.String()
                b.WriteString("!")
                fmt.Println(s, b.String())
                """,
                imports: ["fmt", "strings"])
                == "世界 6 6\n世界 世界!\n")
        #expect(
            try runGoMain(
                """
                var big strings.Builder
                for i := 0; i < 2000; i++ {
                    big.WriteString("0123456789")
                }
                fmt.Println(big.Len(), len(big.String()), big.String()[19990:])
                """,
                imports: ["fmt", "strings"])
                == "20000 20000 0123456789\n")
    }

    /// `Reset` empties a Builder and gives up its bytes; `Grow` makes room and
    /// refuses a negative count with Go's panic.
    @Test func resetAndGrow() throws {
        #expect(
            try runGoMain(
                """
                var b strings.Builder
                b.WriteString("text")
                b.Reset()
                fmt.Println(b.Len(), b.Cap(), b.String() == "")
                b.Grow(100)
                fmt.Println(b.Len(), b.Cap() >= 100)
                before := b.Cap()
                b.WriteString(strings.Repeat("x", 100))
                fmt.Println(b.Cap() == before, b.Len())
                b.Grow(0)
                b.Grow(5)
                fmt.Println(b.Cap()-b.Len() >= 5, b.Len())
                try("negative", func() { b.Grow(-1) })
                """,
                imports: ["fmt", "strings"],
                declarations: """
                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }
                    """)
                == """
                0 0 true
                0 true
                true 100
                true 100
                negative -> strings.Builder.Grow: negative count

                """)
    }

    /// `*strings.Builder` has `Write`, so `fmt.Fprintf` and its kin write to
    /// it, and it is an `io.Writer` and an `io.StringWriter` wherever one is
    /// asked for.
    @Test func aBuilderIsAWriter() throws {
        #expect(
            try runGoMain(
                #"""
                var b strings.Builder
                fill(&b, 5)
                fmt.Fprint(&b, "x", 1, 2, "y")
                fmt.Fprintln(&b, "end", 3)
                n, err := fmt.Fprintf(&b, "%05.1f|%-4s|%q\n", 3.14159, "ab", "q")
                fmt.Print(b.String())
                fmt.Println(n, err)
                pb := new(strings.Builder)
                pb.WriteString("pointer")
                io.WriteString(pb, " via io")
                var sw io.StringWriter = pb
                sw.WriteString(" sw")
                var w io.Writer = pb
                w.Write([]byte(" w"))
                fmt.Println(pb)
                fmt.Println(pb.String())
                """#,
                imports: ["fmt", "io", "strings"],
                declarations: """
                    func fill(w io.Writer, n int) {
                        for i := 0; i < n; i++ {
                            fmt.Fprintf(w, "%d,", i)
                        }
                    }
                    """)
                == """
                0,1,2,3,4,x1 2yend 3
                003.1|ab  |"q"
                15 <nil>
                pointer via io sw w
                pointer via io sw w

                """)
    }

    /// A Builder is a struct like any other: a field, an embedded field, an
    /// element, behind an alias, in a type declared in a function, and
    /// captured by a function literal.
    @Test func aBuilderInAFieldALocalTypeAnAliasAndAClosure() throws {
        #expect(
            try runGoMain(
                """
                p := &page{title: "t"}
                p.body.WriteString("in a field")
                fmt.Fprintf(&p.body, " %s", p.title)
                fmt.Println(p.body.String(), p.body.Len())

                var alias B
                alias.WriteString("alias")
                fmt.Println(alias.String())

                type local struct{ strings.Builder }
                var l local
                _, _ = l.WriteString("embedded")
                fmt.Println(l.String(), l.Len())

                parts := []string{"a", "b", "c"}
                join := func(sep string) string {
                    var sb strings.Builder
                    for i, s := range parts {
                        if i > 0 {
                            sb.WriteString(sep)
                        }
                        sb.WriteString(s)
                    }
                    return sb.String()
                }
                fmt.Println(join("-"))

                var shared strings.Builder
                add := func(s string) { shared.WriteString(s) }
                add("one,")
                add("two")
                fmt.Println(shared.String())

                builders := make([]strings.Builder, 3)
                for i := range builders {
                    fmt.Fprint(&builders[i], i, i)
                }
                fmt.Println(builders[0].String(), builders[2].String())
                byName := map[string]*strings.Builder{"a": {}}
                byName["a"].WriteString("in a map")
                fmt.Println(byName["a"].String())
                write := shared.WriteString
                write("!")
                fmt.Println(shared.String(), render(&shared))
                """,
                imports: ["fmt", "strings"],
                declarations: """
                    type page struct {
                        title string
                        body  strings.Builder
                    }

                    type B = strings.Builder

                    func render(b *strings.Builder) string {
                        b.WriteByte('.')
                        return b.String()
                    }
                    """)
                == """
                in a field t 12
                alias
                embedded 8
                a-b-c
                one,two
                0 0 2 2
                in a map
                one,two! one,two!.

                """)
    }

    /// Go forbids copying a Builder that has been written to: the copy would
    /// share its bytes. A write through the copy panics with Go's text; a copy
    /// of an empty Builder, or one that is reset first, is its own.
    @Test func aCopyOfAWrittenBuilderPanicsWhenWritten() throws {
        #expect(
            try runGoMain(
                """
                try("copy of the zero value", func() {
                    var x strings.Builder
                    y := x
                    y.WriteString("ok")
                    x.WriteString("fine")
                    fmt.Println(x.String(), y.String())
                })
                try("copy of a written one", func() {
                    var x strings.Builder
                    x.WriteString("one")
                    y := x
                    fmt.Println(y.String(), y.Len())
                    y.WriteString("two")
                })
                try("WriteByte", func() {
                    var x strings.Builder
                    x.WriteByte('1')
                    y := x
                    y.WriteByte('2')
                })
                try("WriteRune", func() {
                    var x strings.Builder
                    x.WriteRune('1')
                    y := x
                    y.WriteRune('2')
                })
                try("Write", func() {
                    var x strings.Builder
                    x.Write(nil)
                    y := x
                    y.Write(nil)
                })
                try("Grow", func() {
                    var x strings.Builder
                    x.Grow(1)
                    y := x
                    y.Grow(2)
                })
                try("reset first", func() {
                    var x strings.Builder
                    x.WriteString("one")
                    y := x
                    y.Reset()
                    y.WriteString("two")
                    fmt.Println(x.String(), y.String())
                })
                try("passed by value", func() {
                    var x strings.Builder
                    x.WriteString("one")
                    byValue(x)
                })
                var none *strings.Builder
                try("nil", func() { fmt.Println(none.Len()) })
                """,
                imports: ["fmt", "strings"],
                declarations: """
                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    func byValue(b strings.Builder) { b.WriteString("two") }
                    """)
                == """
                fine ok
                copy of the zero value -> <nil>
                one 3
                copy of a written one -> strings: illegal use of non-zero Builder copied by value
                WriteByte -> strings: illegal use of non-zero Builder copied by value
                WriteRune -> strings: illegal use of non-zero Builder copied by value
                Write -> strings: illegal use of non-zero Builder copied by value
                Grow -> strings: illegal use of non-zero Builder copied by value
                one two
                reset first -> <nil>
                passed by value -> strings: illegal use of non-zero Builder copied by value
                nil -> runtime error: invalid memory address or nil pointer dereference

                """)
    }

    /// The methods have pointer receivers, and the fields are the package's
    /// own: Go's errors, at Go's places.
    @Test func whatABuilderIsNot() {
        #expect(
            firstError(
                """
                var b strings.Builder
                var w io.Writer = b
                _ = w
                """,
                imports: ["io", "strings"])
                == "7:19: cannot use b (variable of struct type strings.Builder) as io.Writer value in variable declaration: strings.Builder does not implement io.Writer (method Write has pointer receiver)")
        #expect(
            firstError(
                """
                var b strings.Builder
                b.WriteString(1)
                """,
                imports: ["strings"])
                == "6:15: cannot use 1 (untyped int constant) as string value in argument to b.WriteString")
        #expect(
            firstError(
                """
                var b strings.Builder
                var n int = b.String()
                _ = n
                """,
                imports: ["strings"])
                == "6:13: cannot use b.String() (value of type string) as int value in variable declaration")
        #expect(
            firstError(
                """
                var b strings.Builder
                b.buf = nil
                """,
                imports: ["strings"])
                == "6:3: b.buf undefined (cannot refer to unexported field buf)")
        #expect(
            firstError(
                """
                var b strings.Builder
                b.Truncate(1)
                """,
                imports: ["strings"])
                == "6:3: b.Truncate undefined (type strings.Builder has no field or method Truncate)")
        #expect(
            firstError(
                """
                b := strings.Builder{buf: nil}
                _ = b
                """,
                imports: ["strings"])
                == "5:22: cannot refer to unexported field buf in struct literal of type strings.Builder")
    }
}
