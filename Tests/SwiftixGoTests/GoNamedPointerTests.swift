/// Pointer types with a name, `type ptr *t`.
///
/// Such a type is a pointer in all but its name: it selects the fields of
/// what it points to, is followed with `*`, compares with `nil` and with
/// `*t`, and converts to and from `*t`. It has no methods, its own or those
/// of `t`.
///
/// What each program prints is what Go 1.24.5 prints for it. An error pinned
/// with its place is at the place of the first one Go's compiler reports;
/// where the message is Go's too it was copied without change, and otherwise
/// it is this dialect's, which names a value by its type.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go named pointer types")
struct GoNamedPointerTests: GoTestHarness {

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

    /// Reading, assigning, `++`, `op=`, `*p`, and the address of a field.
    @Test func itSelectsAndAssignsTheFieldsOfWhatItPointsTo() throws {
        #expect(
            try runGoMain(
                #"""
                var p ptr = &t{n: 1, s: "a"}
                fmt.Println(p.n, p.s)
                p.n = 5
                p.n++
                p.s += "b"
                fmt.Println(p.n, p.s, *p, (*p).n)
                *p = t{9, "z"}
                field := &p.n
                *field = 10
                x := *p
                x.n = 0
                fmt.Println(*p, x.n)
                fmt.Printf("%v %+v %T\n", *p, *p, p)
                """#,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t
                    """)
                == "1 a\n6 ab {6 ab} 6\n{10 z} 0\n{10 z} {n:10 s:z} main.ptr\n")
        #expect(
            try runGoMain(
                """
                var p deep = &outer{}
                p.inner.v = 3
                p.list[1] = 4
                fmt.Println(p.inner.v, p.list, len(p.list))
                n := 1
                var q number = &n
                *q += 4
                *q++
                fmt.Println(n, *q == n)
                """,
                declarations: """
                    type outer struct {
                        inner struct{ v int }
                        list  [2]int
                    }
                    type deep *outer
                    type number *int
                    """)
                == "3 [0 4] 2\n6 true\n")
    }

    /// A `*t` goes where a `ptr` is asked for and the reverse, as any type
    /// without a name does beside one of its structure; two such values compare.
    @Test func itComparesWithNilAndConvertsToAndFromThePointer() throws {
        #expect(
            try runGoMain(
                """
                var p ptr = &t{n: 1}
                var q ptr
                fmt.Println(p == nil, p != nil, q == nil)
                q = p
                var raw *t = p
                p = raw
                p = ptr(raw)
                raw = (*t)(p)
                fmt.Println(q == p, p == raw, raw == p, raw.n)
                a, b := p, raw
                a.n, b.n = 7, 8
                fmt.Println(p.n, show(p), show(&t{n: 4}), make1().n)
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    func show(p ptr) int { return p.n }

                    func make1() ptr { return &t{n: 3} }
                    """)
                == "false true true\ntrue true true 1\n8 8 4 3\n")
    }

    /// `%T` and a type assertion see the name; a nil one in an interface is
    /// no nil interface. A linked list is the usual use.
    @Test func itIsATypeOfItsOwnInAnInterfaceAndInACollection() throws {
        #expect(
            try runGoMain(
                #"""
                var p ptr = &t{n: 1}
                var a any = p
                _, isPtr := a.(ptr)
                _, isPointer := a.(*t)
                var none ptr
                var b any = none
                fmt.Println(isPtr, isPointer, a != nil, b == nil)
                fmt.Printf("%T %v %T\n", a, none, none)
                var head link
                for i := 0; i < 3; i++ {
                    head = &node{value: i, next: head}
                }
                for n := head; n != nil; n = n.next {
                    fmt.Print(n.value, " ")
                }
                fmt.Println()
                h := holder{byName: map[string]ptr{}}
                for i := 0; i < 3; i++ {
                    h.list = append(h.list, &t{n: i})
                }
                h.byName["two"] = h.list[2]
                h.list[1].n += 10
                h.byName["two"].n = 20
                for _, each := range h.list {
                    fmt.Print(each.n, " ")
                }
                fmt.Println(h.byName["none"] == nil)
                """#,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    type node struct {
                        value int
                        next  link
                    }
                    type link *node
                    type holder struct {
                        list   []ptr
                        byName map[string]ptr
                    }
                    """)
                == "true false true false\nmain.ptr <nil> main.ptr\n2 1 0 \n0 11 20 true\n")
        #expect(
            try runGoMain(
                """
                var p ptr
                defer func() { fmt.Println("recovered:", recover()) }()
                p.n = 1
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t
                    """)
                == """
                recovered: runtime error: invalid memory address or nil pointer dereference

                """)
    }

    /// Go refuses a method declared on such a type, and on a type that is an
    /// interface underneath; the methods of `t` are not those of `ptr`, and a
    /// pointer to a `ptr` selects nothing.
    @Test func itHasNoMethods() throws {
        #expect(
            firstError("", declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    func (p ptr) m() {}
                    """)
                == "9:9: invalid receiver type ptr (pointer or interface type)")
        #expect(
            firstError("", declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    func (p *ptr) m() {}
                    """)
                == "9:10: invalid receiver type ptr (pointer or interface type)")
        #expect(
            firstError("", declarations: """
                    type i interface{ m() }

                    func (x i) n() {}
                    """)
                == "5:9: invalid receiver type i (pointer or interface type)")
        #expect(
            firstError(
                """
                var p ptr = &t{}
                fmt.Println(p.get())
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    func (x *t) get() int { return x.n }
                    """)
                == "12:15: ptr has no field or method get")
        #expect(
            firstError(
                """
                var p ptr = &t{}
                var q pp = &p
                fmt.Println((*q).n, q.n)
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    type pp *ptr
                    """)
                == "13:23: pp has no field or method n")
        #expect(
            try runGoMain(
                """
                var p ptr = &t{n: 1}
                fmt.Println((*t)(p).get(), (*p).get())
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    func (x *t) get() int { return x.n }
                    """)
                == "1 1\n")
    }

    /// Two names for one pointer type are two types.
    @Test func anotherTypeIsStillAnother() throws {
        #expect(
            firstError(
                """
                var p ptr = &t{}
                var i int = p
                _ = i
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t
                    """)
                == "10:13: cannot use ptr as int value")
        #expect(
            firstError(
                """
                var p ptr = &u{}
                _ = p
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    type u struct{ n int }
                    """)
                == "11:13: cannot use *u as ptr value")
        #expect(
            firstError(
                """
                var p ptr = &t{}
                var q other = p
                _ = q
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    type other *t
                    """)
                == "12:15: cannot use ptr as other value")
        #expect(
            try runGoMain(
                """
                var p ptr = &t{}
                var q other = other(p)
                fmt.Println(q.n, p == ptr(q))
                """,
                declarations: """
                    type t struct {
                        n int
                        s string
                    }
                    type ptr *t

                    type other *t
                    """)
                == "0 true\n")
    }
}
