/// A field or a method whose name is not exported belongs to the package
/// that declares its type, and no other package may name it.
///
/// After linking a program is one flat set of declarations, so the checker
/// is told what package the file it checks is of, and reads the package of
/// a type off its symbol. A field reached through a struct type that has no
/// name is not checked, and neither are the fields of embedded structs.
///
/// Each error is at the place of the first one Go 1.24.5 reports. Of a
/// selection the message is this dialect's, which does not repeat the
/// operand; of a struct literal and a method expression it is Go's, copied
/// without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go unexported fields and methods")
struct GoUnexportedMemberTests: GoTestHarness {

    /// The packages of a module `example/m` whose files are `files`, each
    /// by its path below the module's root.
    private func packages(_ files: [(String, String)]) -> [GoPackageSource] {
        var byPath: [String: [GoSourceFile]] = [:]
        for (path, text) in files {
            let directory = path.split(separator: "/").dropLast().joined(separator: "/")
            byPath[directory.isEmpty ? "example/m" : "example/m/" + directory, default: []]
                .append(GoSourceFile(path: path, text: text))
        }
        return byPath.keys.sorted().map {
            GoPackageSource(importPath: $0, sources: byPath[$0] ?? [])
        }
    }

    /// What the module prints.
    private func runModule(_ files: [(String, String)]) throws -> String {
        let executable = try GoCompiler.compile(packages: packages(files), root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// The first error of compiling the module, as Go prints it:
    /// `path:line:column: message`.
    private func moduleError(_ files: [(String, String)]) -> String? {
        do {
            _ = try GoCompiler.compile(packages: packages(files), root: "example/m")
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    /// To read it, assign it, increment it, or take its address, through a
    /// value or a pointer.
    @Test func anotherPackageMayNotSelectAnUnexportedField() {
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.New()
                        fmt.Println(v.Pub, v.secret)
                    }
                    """
                ),
            ])
                == "main.go:11:26: cannot refer to unexported field secret")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.NewP()
                        v.secret = 3
                        fmt.Println(v.Pub)
                    }
                    """
                ),
            ])
                == "main.go:11:7: cannot refer to unexported field secret")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.New()
                        v.secret++
                        fmt.Println(v.Pub)
                    }
                    """
                ),
            ])
                == "main.go:11:7: cannot refer to unexported field secret")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.New()
                        p := &v.secret
                        fmt.Println(*p)
                    }
                    """
                ),
            ])
                == "main.go:11:13: cannot refer to unexported field secret")
    }

    /// Called or taken as a value, of a struct, a pointer, or an interface.
    @Test func norAnUnexportedMethod() {
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.New()
                        fmt.Println(v.Shown(), v.hidden())
                    }
                    """
                ),
            ])
                == "main.go:11:30: cannot refer to unexported method hidden")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.NewP()
                        fmt.Println(v.bump())
                    }
                    """
                ),
            ])
                == "main.go:11:19: cannot refer to unexported method bump")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.Get()
                        fmt.Println(v.Open(), v.closed())
                    }
                    """
                ),
            ])
                == "main.go:11:29: cannot refer to unexported method closed")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.New()
                        f := v.hidden
                        fmt.Println(f())
                    }
                    """
                ),
            ])
                == "main.go:11:12: cannot refer to unexported method hidden")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        f := lib.T.hidden
                        fmt.Println(f(lib.New()))
                    }
                    """
                ),
            ])
                == "main.go:10:16: lib.T.hidden undefined (cannot refer to unexported method hidden)")
    }

    /// By name or by its place.
    @Test func aStructLiteralMayNotGiveAnUnexportedField() {
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.T{Pub: 1, secret: 1}
                        fmt.Println(v.Pub)
                    }
                    """
                ),
            ])
                == "main.go:10:24: cannot refer to unexported field secret in struct literal of type lib.T")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := &lib.T{secret: 1}
                        fmt.Println(v.Pub)
                    }
                    """
                ),
            ])
                == "main.go:10:17: cannot refer to unexported field secret in struct literal of type lib.T")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.T{1, 2}
                        fmt.Println(v.Pub)
                    }
                    """
                ),
            ])
                == "main.go:10:19: implicit assignment to unexported field secret in struct literal of type lib.T")
        #expect(
            moduleError([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    func main() {
                        v := lib.T{nothing: 1}
                        fmt.Println(v)
                    }
                    """
                ),
            ])
                == "main.go:10:16: unknown field nothing in struct literal of type lib.T")
    }

    /// Exported fields and methods, a literal that names only those, a value
    /// of an unexported type, and a package's own unexported names, also where
    /// another package has the same ones.
    @Test func whatIsExportedAndWhatIsItsOwnStayOpen() throws {
        #expect(
            try runModule([
                (
                    "lib/lib.go",
                    """
                    package lib

                    type T struct {
                        Pub    int
                        secret int
                    }

                    type AllPub struct{ A, B int }

                    type I interface {
                        Open() int
                        closed() int
                    }

                    type impl struct{}

                    func New() T             { return T{Pub: 1, secret: 2} }
                    func NewP() *T           { return &T{Pub: 1, secret: 2} }
                    func Get() I             { return impl{} }
                    func (t T) Shown() int   { return t.secret + t.hidden() }
                    func (t T) hidden() int  { return t.secret }
                    func (t *T) bump() int   { t.secret++; return t.secret }
                    func (t *T) Bump() int   { return t.bump() }
                    func (impl) Open() int   { return 1 }
                    func (impl) closed() int { return 2 }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                    )

                    type mine struct {
                        Pub    int
                        secret int
                    }

                    func (m mine) hidden() int { return m.secret }

                    func main() {
                        v := lib.New()
                        p := lib.NewP()
                        w := lib.T{Pub: 5}
                        z := lib.T{}
                        all := lib.AllPub{1, 2}
                        v.Pub++
                        fmt.Println(v.Pub, v.Shown(), p.Bump(), w, z.Pub, all.A+all.B, lib.Get().Open())
                        m := mine{1, 2}
                        m.secret += 5
                        q := &m
                        fmt.Println(m.hidden(), q.secret, mine{secret: 3})
                    }
                    """
                ),
            ])
                == "2 4 3 {5 0} 0 3 1\n7 7 {0 3}\n")
    }
}
