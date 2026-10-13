/// Interfaces that embed interfaces: `interface { Reader; Writer }` has the
/// methods of both, to any depth, and `error` is embedded like one a program
/// declares.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change; a message pinned alone is one this dialect words or
/// places in its own way. An interface embedded in a struct is in
/// `GoStructEmbeddingTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go interface embedding")
struct GoInterfaceEmbeddingTests: GoTestHarness {

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

    /// `GoTypeExpression` has no case for it: the entry is a method named
    /// `$embed` whose result is the type, which `GoEmbedding.resolve` replaces
    /// by the methods of that type before anything is checked.
    @Test func anEmbeddedInterfaceIsCarriedAsAMethodNoSourceCanWrite() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\ntype I interface{ M() }\ntype J interface {\n\tI\n\tN() int\n}\nfunc main() {}\n")
        let parsed = try GoParser.parse(source)
        guard case .interface(let entries, _) = parsed.typeDeclarations[1].type else {
            Issue.record("not an interface type")
            return
        }
        #expect(entries.map(\.name) == [GoEmbedding.interfaceMethodName, "N"])
        #expect(entries[0].embeddedInterface != nil)
        #expect(entries[1].embeddedInterface == nil)
        #expect(parsed.typeDeclarations[1].type.functionSignature == nil)

        let resolved = try GoNames.resolve(program: GoNames.resolve([parsed]))
        guard case .interface(let methods, _) = resolved[0].typeDeclarations[1].type else {
            Issue.record("not an interface type")
            return
        }
        #expect(methods.map(\.name) == ["M", "N"])
        // Resolving again changes nothing, as the checker does after the compiler.
        #expect(try GoNames.resolve(program: resolved) == resolved)
    }

    /// A type implements it when it has them all, a value of it is a value
    /// of each interface it embeds, and `error` is embedded like any other.
    @Test func anInterfaceHasTheMethodsOfThoseItEmbeds() throws {
        #expect(
            try runGoMain(
                #"""
                a := &buf{data: []byte("hello world"), name: "a"}
                b := &buf{name: "b"}
                var rw ReadWriter = a
                var rwc ReadWriteCloser = b
                fmt.Println(copyAll(rwc, rw), string(b.data), rwc.Name(), rwc.Close())
                var r Reader = rwc
                var w Writer = rw
                rw = rwc
                readers := []Reader{rw, rwc, r}
                fmt.Printf("%T %T %T %d\n", rw, rwc, w, len(readers))

                var e error = fail()
                fmt.Println(e, fail().Code(), fail().Error())
                var c Coded
                if errors.As(e, &c) {
                    fmt.Println("as", c.Code())
                }
                """#,
                imports: ["errors", "fmt"],
                declarations: """
                    type Reader interface {
                        Read(p []byte) (n int, err error)
                    }

                    type Writer interface {
                        Write(p []byte) (int, error)
                    }

                    type Closer interface{ Close() error }

                    type ReadWriter interface {
                        Reader
                        Writer
                    }

                    type ReadWriteCloser interface {
                        ReadWriter
                        Closer
                        Name() string
                    }

                    type Coded interface {
                        error
                        Code() int
                    }

                    type buf struct {
                        data []byte
                        name string
                    }

                    func (b *buf) Read(p []byte) (int, error) {
                        n := copy(p, b.data)
                        b.data = b.data[n:]
                        if n == 0 {
                            return 0, errors.New("empty")
                        }
                        return n, nil
                    }
                    func (b *buf) Write(p []byte) (int, error) { b.data = append(b.data, p...); return len(p), nil }
                    func (b *buf) Close() error                { return nil }
                    func (b *buf) Name() string                { return b.name }

                    type codeErr struct{ c int }

                    func (e codeErr) Error() string { return fmt.Sprintf("code %d", e.c) }
                    func (e codeErr) Code() int     { return e.c }

                    func copyAll(dst Writer, src Reader) int {
                        total := 0
                        p := make([]byte, 4)
                        for {
                            n, err := src.Read(p)
                            if err != nil {
                                return total
                            }
                            dst.Write(p[:n])
                            total += n
                        }
                    }

                    func fail() Coded { return codeErr{7} }
                    """)
                == """
                11 hello world b <nil>
                *main.buf *main.buf *main.buf 3
                code 7 7 code 7
                as 7

                """)
    }

    /// An assertion to an interface that embeds others asks for every
    /// method; a conversion to an interface type, `Reader(rw)` or `error(e)`, is
    /// what an assignment to it is.
    @Test func assertionsAndConversionsBetweenInterfaces() throws {
        #expect(
            try runGoMain(
                #"""
                var rw ReadWriter = &buf{name: "a"}
                var r Reader = rw
                if c, ok := r.(ReadWriteCloser); ok {
                    fmt.Println("rwc", c.Name())
                }
                _, coded := r.(Coded)
                var e error = fail()
                cc, ok := e.(Coded)
                fmt.Println(coded, ok, cc.Code(), cc.Error())
                w := Writer(rw)
                plain := error(codeErr{3})
                boxed := any(plain)
                _, isCoded := boxed.(interface {
                    error
                    Code() int
                })
                fmt.Printf("%T %v %T %v\n", w, plain, boxed, isCoded)
                var x interface {
                    Coded
                    Closer
                }
                fmt.Println(x == nil)
                defer func() { fmt.Println(recover()) }()
                _ = boxed.(ReadWriteCloser)
                """#,
                imports: ["errors", "fmt"],
                declarations: """
                    type Reader interface {
                        Read(p []byte) (n int, err error)
                    }

                    type Writer interface {
                        Write(p []byte) (int, error)
                    }

                    type Closer interface{ Close() error }

                    type ReadWriter interface {
                        Reader
                        Writer
                    }

                    type ReadWriteCloser interface {
                        ReadWriter
                        Closer
                        Name() string
                    }

                    type Coded interface {
                        error
                        Code() int
                    }

                    type buf struct {
                        data []byte
                        name string
                    }

                    func (b *buf) Read(p []byte) (int, error) {
                        n := copy(p, b.data)
                        b.data = b.data[n:]
                        if n == 0 {
                            return 0, errors.New("empty")
                        }
                        return n, nil
                    }
                    func (b *buf) Write(p []byte) (int, error) { b.data = append(b.data, p...); return len(p), nil }
                    func (b *buf) Close() error                { return nil }
                    func (b *buf) Name() string                { return b.name }

                    type codeErr struct{ c int }

                    func (e codeErr) Error() string { return fmt.Sprintf("code %d", e.c) }
                    func (e codeErr) Code() int     { return e.c }

                    func copyAll(dst Writer, src Reader) int {
                        total := 0
                        p := make([]byte, 4)
                        for {
                            n, err := src.Read(p)
                            if err != nil {
                                return total
                            }
                            dst.Write(p[:n])
                            total += n
                        }
                    }

                    func fail() Coded { return codeErr{7} }
                    """)
                == """
                rwc a
                false true 7 code 7
                *main.buf code 3 main.codeErr true
                true
                interface conversion: main.codeErr is not main.ReadWriteCloser: missing method Close

                """)
        #expect(
            goMainDiagnostic(
                """
                var i I
                var j J = i
                _ = j
                """,
                declarations: """
                    type I interface{ M() }
                    type J interface {
                        I
                        N()
                    }
                    """)
                == "cannot use I as J value")
        #expect(
            goMainDiagnostic(
                """
                var j J = t{}
                _ = j
                """,
                declarations: """
                    type I interface{ M() }
                    type J interface {
                        I
                        N()
                    }
                    type t struct{}

                    func (v t) M() {}
                    """)
                == "cannot use t as J value")
    }

    /// Two embedded interfaces, or one and the interface itself, may have a
    /// method in common; with two signatures it is a duplicate, reported where
    /// the interface is embedded.
    @Test func aMethodTwiceIsOneWhenBothSayTheSame() throws {
        #expect(
            try runGoMain(
                """
                var j J = t{}
                var b both = t{}
                j.M()
                b.M()
                fmt.Println(j.N(), b.N())
                """,
                declarations: """
                    type I interface{ M() }
                    type K interface {
                        M()
                        N() int
                    }
                    type J interface {
                        I
                        K
                        M()
                    }
                    type both interface {
                        K
                        I
                    }
                    type t struct{}

                    func (v t) M()     { fmt.Print("M ") }
                    func (v t) N() int { return 1 }
                    """)
                == "M M 1 1\n")
        #expect(
            firstError(
                """
                var j J
                _ = j
                """,
                declarations: """
                    type I interface{ M() }
                    type J interface {
                        I
                        M() int
                    }
                    """)
                == "5:5: duplicate method M")
        #expect(
            firstError(
                """
                var j J
                _ = j
                """,
                declarations: """
                    type I interface{ M() }
                    type K interface{ M() int }
                    type J interface {
                        I
                        K
                    }
                    """)
                == "7:5: duplicate method M")
        #expect(
            firstError(
                """
                var j J
                _ = j
                """,
                declarations: """
                    type J interface {
                        M()
                        N()
                        M() int
                    }
                    """)
                == "6:5: duplicate method M")
    }

    /// Itself, directly or through another; a type that is not declared;
    /// and a type that is no interface, which Go has only in a type constraint
    /// and reports where the interface is used, this dialect where it embeds.
    @Test func whatAnInterfaceMayNotEmbed() {
        #expect(
            firstError(
                """
                var j J
                _ = j
                """,
                declarations: """
                    type J interface {
                        J
                    }
                    """)
                == "3:6: invalid recursive type: J refers to itself")
        #expect(
            firstError(
                """
                var a A
                _ = a
                """,
                declarations: """
                    type A interface {
                        B
                    }
                    type B interface {
                        A
                    }
                    """)
                == "3:6: invalid recursive type A")
        #expect(
            firstError(
                """
                var j J
                _ = j
                """,
                declarations: """
                    type J interface {
                        Undefined
                        M()
                    }
                    """)
                == "4:5: undefined: Undefined")
        #expect(
            goMainDiagnostic(
                """
                var j J
                _ = j
                """,
                declarations: """
                    type T struct{}
                    type J interface {
                        T
                        M()
                    }
                    """)
                == "cannot use type J outside a type constraint: interface contains type constraints")
    }
}
