/// Embedded fields: a struct type that names a type where a field would be
/// has a field of that name, and is lent the fields and the methods of the
/// type.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change; a message pinned alone is one this dialect words in its
/// own way, at Go's place. Interfaces that embed interfaces are in
/// `GoInterfaceEmbeddingTests`, and how `gofmt` lays embedded fields out in
/// `GoEmbeddingGofmtTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go struct embedding")
struct GoStructEmbeddingTests: GoTestHarness {

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

    /// The syntax tree has no case for it: the field declaration says it is
    /// embedded, and an interface embedded in an interface is a method no
    /// program can write until `GoEmbedding.resolve` has put its methods there.
    @Test func anEmbeddedFieldIsAFieldNamedByItsTypeWithAMark() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\ntype s struct {\n\tbase\n\t*other\n\tsync.Mutex\n\tn int\n}\n"))
        guard case .structure(let fields, _) = file.typeDeclarations[0].type else {
            Issue.record("not a struct type")
            return
        }

        #expect(fields.map(\.name) == ["base", "other", "Mutex", "n"])
        #expect(fields.map(\.isEmbedded) == [true, true, true, false])
        #expect(file.usesEmbedding)
        guard case .pointer(.named("other", _), _) = fields[1].type,
            case .named("sync.Mutex", _) = fields[2].type
        else {
            Issue.record("the type of an embedded field is the type written")
            return
        }
        // A field declared the old way says nothing new, and is what it was.
        #expect(
            fields[3]
                == GoStructFieldDeclaration(
                    name: "n", type: fields[3].type, position: fields[3].position))
    }

    /// `d.id` is `d.base.id`, through a pointer and through several levels,
    /// as an operand, a target, and the operand of `&`.
    @Test func promotedFieldsAreReadAssignedAndAddressed() throws {
        #expect(
            try runGoMain(
                """
                d := derived{base{1, nil}, "x"}
                fmt.Println(d.id, d.name, d.base.id)
                d.id = 5
                d.base.id++
                d.id += 2
                ip := &d.id
                *ip *= 2
                p := &d
                p.id++
                fmt.Println(d.id, p.id, *ip)

                x := deep{derived{base{3, []string{"a"}}, "z"}, 7}
                x.id = 4
                x.tags = append(x.tags, "b")
                for i, t := range x.tags {
                    fmt.Print(i, t, " ")
                }
                fmt.Println(x.id, x.name, x.level, len(x.tags), x.derived.base.id)

                q := viaPointer{&base{id: 30}, "n"}
                q.id++
                alias := q
                alias.id += 10
                fmt.Println(q.id, alias.id, q.note)

                a, b := derived{base: base{id: 1}}, derived{base: base{id: 2}}
                a.id, b.id = b.id, a.id
                fmt.Println(a.id, b.id)
                """,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == "1 x 1\n17 17 17\n0a 1b 4 z 7 2 4\n41 41 n\n2 1\n")
    }

    /// A method with a pointer receiver changes the embedded field of the
    /// variable it is called on; one declared on the outer type hides the
    /// promoted one, which stays reachable through the field.
    @Test func promotedMethodsAreCalledWithTheEmbeddedFieldAsReceiver() throws {
        #expect(
            try runGoMain(
                """
                d := derived{base{1, nil}, "x"}
                d.SetID(9)
                p := &d
                p.SetID(p.ID() + 1)
                fmt.Println(d.id, d.Describe(), p.Describe(), p.Name())

                x := deep{derived{base{3, nil}, "z"}, 7}
                x.SetID(x.ID() + 10)
                fmt.Println(x.Describe(), x.Name(), x.ID())

                q := viaPointer{&base{id: 30}, "n"}
                q.SetID(q.id * 2)
                fmt.Println(q.Describe(), q.id)

                l := loud{base{id: 8}}
                fmt.Println(l.Describe(), l.base.Describe(), l.ID())

                n, ok := d.pair()
                fmt.Println(n, ok, d.sum(), d.sum(1, 2), d.sum([]int{4, 5}...))
                """,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }

                    func (d derived) Name() string { return d.name }

                    type loud struct{ base }

                    func (l loud) Describe() string { return "LOUD " + l.base.Describe() }

                    func (b base) pair() (int, bool) { return b.id, b.id > 0 }
                    func (b base) sum(xs ...int) int {
                        t := b.id
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == """
                10 base(10) base(10) x
                base(13) z 13
                base(60) 60
                LOUD base(8) base(8) 8
                10 true 10 13 19

                """)
    }

    /// The method set is Go's: a value has the promoted methods with value
    /// receivers, and those with pointer receivers too when the field is a
    /// pointer; a pointer to the struct has them all. The method the interface
    /// calls is the one of the embedded field.
    @Test func aStructImplementsAnInterfaceThroughAnEmbeddedType() throws {
        #expect(
            try runGoMain(
                #"""
                d := derived{base{1, nil}, "x"}
                x := deep{d, 7}
                q := viaPointer{&base{id: 30}, "n"}
                var ds describer = d
                fmt.Print(ds.Describe(), " ")
                ds = &d
                fmt.Print(ds.Describe(), " ")
                ds = x
                fmt.Print(ds.Describe(), " ")
                ds = q
                fmt.Println(ds.Describe())

                var st setter = &d
                st.SetID(100)
                st = q
                st.SetID(200)
                st = &x
                st.SetID(300)
                fmt.Println(d.id, q.id, x.id)

                var a1, a2, a3 any = d, &d, q
                _, ok1 := a1.(describer)
                _, ok2 := a1.(setter)
                _, ok3 := a2.(setter)
                _, ok4 := a3.(setter)
                fmt.Println(ok1, ok2, ok3, ok4)
                fmt.Printf("%T %T %T\n", ds, st, a1)
                """#,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == """
                base(1) base(1) base(1) base(30)
                100 200 300
                true false true true
                main.viaPointer *main.deep main.derived

                """)
        #expect(
            firstError(
                """
                var s setter = derived{}
                fmt.Println(s)
                """,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == "30:16: cannot use derived{} (value of struct type derived) as setter value in variable declaration: derived does not implement setter (method SetID has pointer receiver)")
        #expect(
            goMainDiagnostic("derived{}.SetID(1)", declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == "cannot call pointer method SetID on base")
        #expect(
            firstError("fmt.Println(derived.SetID)", declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == "30:21: invalid method expression derived.SetID (needs pointer receiver (*derived).SetID)")
    }

    /// A name of the struct itself hides every embedded one, and a nearer
    /// embedded field hides a farther one. A struct may embed two types that
    /// have a name in common; selecting that name is the error.
    @Test func theShallowestNameWinsAndTwoAtOneDepthAreAmbiguousWhenUsed() throws {
        #expect(
            try runGoMain(
                """
                ab := AB{A{1, 10}, B{2, 20}}
                fmt.Println(ab.onlyA, ab.onlyB, ab.A.x, ab.B.x, ab.A.Who(), ab.B.Who())
                c := C{A{1, 10}, 99}
                c.x = 5
                c.A.x = 6
                fmt.Println(c.x, c.A.x, c.Who(), c.A.Who(), c.onlyA)
                d := D{c, B{2, 20}}
                px := &d.onlyA
                *px = 77
                fmt.Println(d.onlyA, d.onlyB, d.C.x, d.B.x, d.C.Who())
                """,
                declarations: """
                    type A struct{ x, onlyA int }

                    func (a A) Who() string { return "A" }

                    type B struct{ x, onlyB int }

                    func (b B) Who() string { return "B" }

                    type AB struct {
                        A
                        B
                    }

                    type C struct {
                        A
                        x int
                    }

                    func (c C) Who() string { return "C" }

                    type D struct {
                        C
                        B
                    }
                    """)
                == "10 20 1 2 A B\n5 6 C A 10\n77 20 5 2 C\n")
        #expect(
            firstError(
                """
                var v c
                fmt.Println(v.x)
                """,
                declarations: """
                    type a struct{ x int }
                    type b struct{ x int }
                    type c struct {
                        a
                        b
                    }
                    """)
                == "11:15: ambiguous selector v.x")
        #expect(
            firstError(
                """
                var v c
                v.m()
                """,
                declarations: """
                    type a struct{ x int }

                    func (v a) m() {}

                    type b struct{ y int }

                    func (v b) m() {}

                    type c struct {
                        a
                        b
                    }
                    """)
                == "17:3: ambiguous selector v.m")
        #expect(
            firstError(
                """
                var v c
                v.x = 1
                """,
                declarations: """
                    type inner struct{ x int }
                    type a struct{ inner }
                    type b struct{ inner }
                    type c struct {
                        a
                        b
                    }
                    """)
                == "12:3: ambiguous selector v.x")
        #expect(
            firstError(
                """
                var v c
                var g getter = v
                fmt.Println(g)
                """,
                declarations: """
                    type inner struct{ x int }

                    func (i inner) get() int { return i.x }

                    type a struct{ inner }
                    type b struct{ inner }
                    type c struct {
                        a
                        b
                    }
                    type getter interface{ get() int }
                    """)
                == "16:16: cannot use v (variable of struct type c) as getter value in variable declaration: c does not implement getter (ambiguous selector c.get)")
    }

    /// Without keys an embedded field is given in its place; with keys its
    /// name is the name of its type.
    @Test func aLiteralNamesTheEmbeddedFieldByItsTypeAndNoPromotedField() throws {
        #expect(
            try runGoMain(
                #"""
                d := derived{base{1, nil}, "x"}
                e := derived{base: base{id: 2}, name: "y"}
                z := derived{}
                q := &viaPointer{base: &e.base}
                fmt.Printf("%+v %+v %+v %v\n", d, e, z, q.id)
                """#,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == """
                {base:{id:1 tags:[]} name:x} {base:{id:2 tags:[]} name:y} {base:{id:0 tags:[]} name:} 2

                """)
        #expect(
            firstError(
                """
                v := derived{id: 1, name: "x"}
                fmt.Println(v)
                """,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == "30:14: unknown field id in struct literal of type derived")
        #expect(
            firstError(
                """
                v := derived{1, "x"}
                fmt.Println(v)
                """,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == "30:14: cannot use 1 (untyped int constant) as base value in struct literal")
    }

    /// `%+v` and `%#v` name the field by its type; `==` compares it; a copy
    /// of the struct has a copy of it, and a zero struct a zero one.
    @Test func anEmbeddedValuePrintsComparesAndCopiesAsTheFieldItIs() throws {
        #expect(
            try runGoMain(
                #"""
                d := derived{base{9, nil}, "x"}
                fmt.Printf("%v %+v %#v %T\n", d, d, d, d)
                var zero derived
                c := d
                c.id = -1
                fmt.Printf("%+v %d %d\n", zero, d.id, c.id)

                var zp pair
                zq := pair{point{1, 2}, &point{3, 4}}
                zr := zq
                fmt.Println(zp == pair{}, zq == zr, zq == zp, zq.point == zr.point, zp, zq.x, zq.y)

                o := Outer{Stringy{"s"}, 1}
                fmt.Println(o, &o, o.String())
                fmt.Printf("%v %+v %s %d\n", o, o, o, o)
                var o3 Outer2
                fmt.Printf("%d|%v\n", o3.N, o3)
                """#,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }

                    type point struct{ x, y int }
                    type pair struct {
                        point
                        other *point
                    }

                    type Stringy struct{ s string }

                    func (s Stringy) String() string { return "<" + s.s + ">" }

                    type Outer struct {
                        Stringy
                        N int
                    }

                    type Outer2 struct {
                        *Stringy
                        N int
                    }
                    """)
                == """
                {{9 []} x} {base:{id:9 tags:[]} name:x} main.derived{base:main.base{id:9, tags:[]string(nil)}, name:"x"} main.derived
                {base:{id:0 tags:[]} name:} 9 -1
                true true false true {{0 0} <nil>} 1 2
                <s> <s> <s>
                <s> <s> <s> {{%!d(string=s)} 1}
                0|%!v(PANIC=String method: runtime error: invalid memory address or nil pointer dereference)

                """)
    }

    /// The methods are those of the value the field holds; `error` is such
    /// an interface, and `errors` finds the methods a struct has through it.
    @Test func anEmbeddedInterfaceLendsItsMethods() throws {
        #expect(
            try runGoMain(
                #"""
                n := named{rect{2, 3}, "box"}
                var s Shape = n
                fmt.Println(n.Area(), n.Name(), s.Area(), s.Name())
                n.Shape = rect{4, 5}
                fmt.Printf("%d %d %v %+v\n", n.Area(), s.Area(), n, n)

                w := wrapped{errors.New("boom"), "read"}
                var err error = w
                fmt.Println(err, w.Error(), errors.Unwrap(err) == w.error)
                cause := errors.New("cause")
                w2 := wrapped{cause, "x"}
                var target wrapped
                fmt.Println(errors.Is(w2, cause), errors.Is(w, cause), errors.As(fmt.Errorf("ctx: %w", w2), &target), target.op)
                """#,
                imports: ["errors", "fmt"],
                declarations: """
                    type Shape interface {
                        Area() int
                        Name() string
                    }

                    type rect struct{ w, h int }

                    func (r rect) Area() int    { return r.w * r.h }
                    func (r rect) Name() string { return "rect" }

                    type named struct {
                        Shape
                        label string
                    }

                    func (n named) Name() string { return n.label + ":" + n.Shape.Name() }

                    type wrapped struct {
                        error
                        op string
                    }

                    func (w wrapped) Unwrap() error { return w.error }
                    """)
                == """
                6 box:rect 6 box:rect
                20 6 {{4 5} box} {Shape:{w:4 h:5} label:box}
                boom boom true
                true false true x

                """)
        #expect(
            firstError(
                """
                var x T
                fmt.Println(x)
                """,
                declarations: """
                    type I interface{ M() }
                    type T struct {
                        *I
                    }
                    """)
                == "5:5: embedded field type cannot be a pointer to an interface")
    }

    /// Reading or calling through it is a nil pointer dereference, also for a
    /// method value, which reads its receiver when it is selected.
    @Test func aNilEmbeddedPointerPanicsWhereGoDoes() throws {
        #expect(
            try runGoMain(
                """
                var nh holder
                try("field read", func() { fmt.Println(nh.n) })
                try("field write", func() { nh.n = 1 })
                try("value method", func() { fmt.Println(nh.Get()) })
                try("pointer method", func() { fmt.Println(nh.Inc()) })
                try("method value", func() { f := nh.Get; fmt.Println("bound"); fmt.Println(f()) })
                var nn named
                try("interface method", func() { fmt.Println(nn.Area()) })
                var np *valueHolder
                try("outer pointer", func() { fmt.Println(np.Get()) })
                h := holder{&counter{}, "h"}
                h.Inc()
                inc := h.Inc
                get := h.Get
                inc()
                fmt.Println(h.n, h.Get(), get())
                """,
                declarations: """
                    type counter struct{ n int }

                    func (c *counter) Inc() int { c.n++; return c.n }
                    func (c counter) Get() int  { return c.n }

                    type holder struct {
                        *counter
                        name string
                    }

                    type valueHolder struct{ counter }

                    type Shape interface{ Area() int }
                    type named struct{ Shape }

                    func try(name string, f func()) {
                        defer func() {
                            if r := recover(); r != nil {
                                fmt.Println(name, "panic:", r)
                            }
                        }()
                        f()
                        fmt.Println(name, "ok")
                    }
                    """)
                == """
                field read panic: runtime error: invalid memory address or nil pointer dereference
                field write panic: runtime error: invalid memory address or nil pointer dereference
                value method panic: runtime error: invalid memory address or nil pointer dereference
                pointer method panic: runtime error: invalid memory address or nil pointer dereference
                method value panic: runtime error: invalid memory address or nil pointer dereference
                interface method panic: runtime error: invalid memory address or nil pointer dereference
                outer pointer panic: runtime error: invalid memory address or nil pointer dereference
                2 2 1

                """)
    }

    /// `d.Describe` has its receiver, `derived.Describe` takes it first, and
    /// both are the method of the embedded type.
    @Test func methodValuesAndMethodExpressionsOfPromotedMethods() throws {
        #expect(
            try runGoMain(
                #"""
                d := derived{base{1, nil}, "x"}
                f := d.Describe
                g := derived.Describe
                h := (*derived).SetID
                set := d.SetID
                h(&d, 41)
                fmt.Println(f(), g(d))
                set(42)
                fmt.Println(d.id, (*derived).Describe(&d), deep.ID(deep{d, 1}))
                fmt.Printf("%T %T %T\n", f, g, h)
                """#,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }
                    """)
                == """
                base(1) base(41)
                42 base(42) 42
                func() string func(main.derived) string func(*main.derived, int)

                """)
    }

    /// `sync.Mutex` and `sync.WaitGroup` lend `Lock`, `Unlock`, `Add`,
    /// `Done`, and `Wait`, to a declared struct type and to one written in
    /// place, and a struct that embeds a mutex is a locker.
    @Test func mutexesAndWaitGroupsAreEmbedded() throws {
        #expect(
            try runGoMain(
                """
                c := &cache{m: map[string]int{}}
                c.put("a", 1)
                c.put("b", 2)
                fmt.Println(c.get("a") + c.get("b"))

                var p pool
                for i := 1; i <= 4; i++ {
                    p.Add(1)
                    go func(n int) {
                        defer p.Done()
                        p.Lock()
                        p.total += n
                        p.Unlock()
                    }(i)
                }
                p.Wait()
                fmt.Println(p.total)

                withLock(c, func() { c.m["c"] = 3 })
                var l locker = c
                l.Lock()
                unlock := c.Unlock
                unlock()
                state.Lock()
                state.hits++
                state.Unlock()
                func() {
                    state.Lock()
                    defer state.Unlock()
                    state.hits += 10
                }()
                fmt.Println(len(c.m), state.hits)
                """,
                imports: ["fmt", "sync"],
                declarations: """
                    type cache struct {
                        sync.Mutex
                        m map[string]int
                    }

                    func (c *cache) put(k string, v int) {
                        c.Lock()
                        defer c.Unlock()
                        c.m[k] = v
                    }

                    func (c *cache) get(k string) int {
                        c.Lock()
                        v := c.m[k]
                        c.Unlock()
                        return v
                    }

                    type pool struct {
                        sync.WaitGroup
                        sync.Mutex
                        total int
                    }

                    type locker interface {
                        Lock()
                        Unlock()
                    }

                    var state struct {
                        sync.Mutex
                        hits int
                    }

                    func withLock(l locker, f func()) {
                        l.Lock()
                        f()
                        l.Unlock()
                    }
                    """)
                == "3\n10\n3 11\n")
    }

    /// A `time.Time` and a `*os.File` lend the methods the dialect has for
    /// them, with the results a call of the field has.
    @Test func timesAndFilesAreEmbedded() throws {
        #expect(
            try runGoMain(
                #"""
                s := stamped{time.Unix(100, 5), "t"}
                u := stamped{time.Unix(200, 0), "u"}
                fmt.Println(s.Unix(), s.UnixNano(), s.Before(u.Time), u.Sub(s.Time) > 0, s.label)
                lf := &logfile{File: os.Stdout}
                lf.Log("first")
                n, err := lf.WriteString("second\n")
                fmt.Println(lf.lines, n, err)
                """#,
                imports: ["fmt", "os", "time"],
                declarations: #"""
                    type stamped struct {
                        time.Time
                        label string
                    }

                    type logfile struct {
                        *os.File
                        lines int
                    }

                    func (l *logfile) Log(s string) {
                        l.WriteString(s + "\n")
                        l.lines++
                    }
                    """#)
                == "100 100000000005 true true t\nfirst\nsecond\n1 7 <nil>\n")
    }

    /// The field of an embedded alias has the alias's name and the type it
    /// stands for; a type declared in a function is embedded under the name the
    /// source gives it, also inside a function literal that captures the
    /// variable; and any named type may be embedded, `int` included.
    @Test func aliasesLocalTypesAndOtherNamedTypesAreEmbedded() throws {
        #expect(
            try runGoMain(
                #"""
                a := aliased{P{1, 2}, 3}
                a.move(1)
                fmt.Printf("%d %v %#v %T\n", a.x, a.P, a, a)
                ap := aliasedPtr{&a.P}
                ap.move(5)
                r := renamed{point{7, 8}, 9}
                r.move(1)
                fmt.Println(ap.x, a.x, r.x, r.n, r.String())

                m := mixed{Fn: func(v int) int { return v + 1 }, Celsius: 100, int: 5, string: "s"}
                m.int++
                m.string += "t"
                fmt.Println(m.twice(1), m.Fn(1), m.F(), m.int, m.string)

                g := outer()
                fmt.Println(g())
                fmt.Println(g())

                for i := 1; i <= 3; i++ {
                    var u struct {
                        point
                        n int
                    }
                    u.x = i
                    u.register()
                }
                for _, p := range all {
                    fmt.Print(p.x, " ")
                }
                fmt.Println(len(all))
                """#,
                declarations: """
                    type point struct{ x, y int }

                    var all []*point

                    func (p point) String() string { return fmt.Sprintf("(%d,%d)", p.x, p.y) }
                    func (p *point) move(dx int)   { p.x += dx }
                    func (p *point) register()     { all = append(all, p) }

                    type P = point
                    type PP = *point

                    type aliased struct {
                        P
                        n int
                    }

                    type aliasedPtr struct{ PP }

                    type renamed aliased

                    type Fn func(int) int

                    func (fn Fn) twice(v int) int { return fn(fn(v)) }

                    type Celsius int

                    func (c Celsius) F() int { return int(c)*9/5 + 32 }

                    type mixed struct {
                        Fn
                        Celsius
                        int
                        string
                    }

                    func outer() func() string {
                        type inner struct {
                            point
                            tag string
                        }
                        type wrapper struct {
                            *inner
                            k int
                        }
                        v := inner{point{1, 2}, "t"}
                        w := wrapper{&v, 3}
                        return func() string {
                            w.move(10)
                            w.tag += "!"
                            v.y++
                            return fmt.Sprint(w.x, w.y, w.tag, w.k, v, w.String())
                        }
                    }
                    """)
                == """
                2 (2,2) main.aliased{P:main.point{x:2, y:2}, n:3} main.aliased
                7 7 8 9 (8,8)
                3 2 212 6 st
                11 3t!3 (11,3)(11,3)
                21 4t!!3 (21,4)(21,4)
                1 2 3 3

                """)
    }

    /// A promoted method is started by `go` and `defer` with its receiver
    /// read at the statement, and a promoted field that holds a function is
    /// called like a method.
    @Test func goDeferAndFunctionFieldsThroughAnEmbeddedField() throws {
        #expect(
            try runGoMain(
                """
                a := &derived{base: base{id: 2}}
                s := service{hooks: hooks{func() string { return "before" }, func(v int) (int, error) { return v * 2, nil }}, derived: a}
                v, err := s.after(21)
                fmt.Println(s.before(), v, err, s.ID(), s.id)
                r := resource{&file{"r"}, 1}
                func() {
                    defer r.Close()
                    defer fmt.Println("deferred", a.ID())
                    defer a.SetID(7)
                    fmt.Println("body")
                }()
                done := make(chan bool)
                sig := signaler{&notifier{done}}
                go sig.notify(true)
                fmt.Println(<-done, a.id)
                """,
                declarations: """
                    type base struct {
                        id   int
                        tags []string
                    }

                    func (b base) Describe() string { return fmt.Sprintf("base(%d)", b.id) }
                    func (b base) ID() int          { return b.id }
                    func (b *base) SetID(id int)    { b.id = id }

                    type derived struct {
                        base
                        name string
                    }

                    type deep struct {
                        derived
                        level int
                    }

                    type viaPointer struct {
                        *base
                        note string
                    }

                    type describer interface{ Describe() string }
                    type setter interface{ SetID(int) }

                    type hooks struct {
                        before func() string
                        after  func(int) (int, error)
                    }

                    type service struct {
                        hooks
                        *derived
                    }

                    type closer interface{ Close() error }
                    type file struct{ name string }

                    func (f *file) Close() error {
                        fmt.Println("closing", f.name)
                        return nil
                    }

                    type resource struct {
                        closer
                        n int
                    }

                    type notifier struct{ ch chan bool }

                    func (n *notifier) notify(v bool) { n.ch <- v }

                    type signaler struct{ *notifier }
                    """)
                == "before 42 <nil> 2 2\nbody\ndeferred 2\nclosing r\ntrue 7\n")
    }

    /// A field name twice, a pointer to an interface, a pointer type under a
    /// name, and a type that is not declared.
    @Test func whatAStructMayNotEmbed() {
        #expect(
            firstError(
                """
                var v derived
                fmt.Println(v)
                """,
                declarations: """
                    type base struct{ id int }
                    type derived struct {
                        base
                        base int
                    }
                    """)
                == "6:5: base redeclared\n\tmain.go:5:5: other declaration of base")
        #expect(
            firstError(
                """
                var v derived
                fmt.Println(v)
                """,
                declarations: """
                    type base struct{ id int }
                    type P *base
                    type derived struct {
                        P
                    }
                    """)
                == "6:5: embedded field type cannot be a pointer")
        #expect(
            firstError(
                """
                var v c
                fmt.Println(v)
                """,
                declarations: """
                    type c struct {
                        undefinedType
                    }
                    """)
                == "4:5: undefined: undefinedType")
        #expect(
            firstError(
                """
                var v c
                fmt.Println(v.y)
                """,
                declarations: """
                    type a struct{ x int }
                    type c struct {
                        a
                    }
                    """)
                == "9:15: v.y undefined (type c has no field or method y)")
    }

    /// Whether a field is embedded is part of what makes two struct types
    /// one, and `%T` writes an embedded field as Go does, by its type alone.
    @Test func anUnnamedStructTypeIsATypeOfItsEmbeddedFieldsAndTags() throws {
        #expect(
            try runGoMain(
                #"""
                var x struct {
                    base
                    n int
                }
                x.id = 3
                x.SetID(x.id + 1)
                h := x.Describe
                fmt.Println(x.id, x.Describe(), h(), x)
                fmt.Printf("%T\n%#v\n", x, x)
                var any1 any = x
                _, emb := any1.(struct {
                    base
                    n int
                })
                _, notEmb := any1.(struct {
                    base base
                    n    int
                })
                fmt.Println(emb, notEmb)
                """#,
                declarations: """
                    type base struct{ id int }

                    func (b base) Describe() string { return fmt.Sprint("base ", b.id) }
                    func (b *base) SetID(v int)     { b.id = v }
                    """)
                == """
                4 base 4 base 4 {{4} 0}
                struct { main.base; n int }
                struct { main.base; n int }{base:main.base{id:4}, n:0}
                true false

                """)
    }
}
