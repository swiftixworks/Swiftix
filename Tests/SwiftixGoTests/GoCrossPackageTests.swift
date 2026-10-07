/// Cross-package linking within one module: functions, constants, variables,
/// types, and methods of local packages, their initialization order, export
/// and import rules, and the `go` tool paths over a multi-package module.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

/// A module laid out in the guest VFS under `/m` with module path `example/m`.
private struct GuestModule {
    var files: [(path: String, text: String)]

    init(_ files: [(String, String)]) {
        self.files = files.map { (path: $0.0, text: $0.1) }
    }

    func seed(_ context: ProcessContext) {
        _ = context.mkdir("/m")
        write(context, "/m/go.mod", "module example/m\n\ngo 1.24\n")
        for file in files {
            var directory = "/m"
            for component in file.path.split(separator: "/").dropLast() {
                directory += "/" + component
                if context.stat(directory) == nil { _ = context.mkdir(directory) }
            }
            write(context, "/m/" + file.path, file.text)
        }
    }

    private func write(_ context: ProcessContext, _ path: String, _ text: String) {
        let descriptor = context.open(path, create: true, truncate: true)!
        context.write(descriptor, Array(text.utf8))
        context.close(descriptor)
    }

    /// The module as packages for `GoCompiler.compile(packages:root:)`.
    var packages: [GoPackageSource] {
        var byPath: [String: [GoSourceFile]] = [:]
        for file in files {
            let directory = file.path.split(separator: "/").dropLast().joined(separator: "/")
            let importPath = directory.isEmpty ? "example/m" : "example/m/" + directory
            byPath[importPath, default: []].append(
                GoSourceFile(path: "/m/" + file.path, text: file.text))
        }
        return byPath.keys.sorted().map {
            GoPackageSource(importPath: $0, sources: byPath[$0] ?? [])
        }
    }
}

@Suite("Go cross-package linking")
struct GoCrossPackageTests: GoTestHarness {

    /// Runs `commands` in `/m` after seeding `module` and returns the command
    /// output lines joined by newlines.
    private func shell(_ module: GuestModule, _ commands: [String] = ["go run ."]) -> String {
        let output = runShell(["cd /m"] + commands, seed: module.seed)
        return shellResultLines(output).joined(separator: "\n")
    }

    /// Compiles and runs `module` in memory and returns what it printed.
    private func run(
        _ module: GuestModule,
        machine: GoVirtualMachine = GoVirtualMachine()
    ) throws -> String {
        let executable = try GoCompiler.compile(packages: module.packages, root: "example/m")
        var output = ""
        try machine.run(executable) { output += $0 }
        return output
    }

    private func diagnostic(_ module: GuestModule, root: String = "example/m") -> String? {
        do {
            _ = try GoCompiler.compile(packages: module.packages, root: root)
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return "unexpected error: \(error)"
        }
    }

    private static let main = "package main\nimport \"fmt\"\n"

    // MARK: Functions

    @Test func functionsWithZeroOneAndMultipleResults() {
        let module = GuestModule([
            (
                "lib/lib.go",
                """
                package lib
                import "fmt"
                func Hello() { fmt.Println("hello") }
                func One(x int) int { return x + 1 }
                func Pair(x int) (int, string) { return x * 2, "p" }
                func Triple() (first int, second int, third int) {
                    first = 1
                    second = 2
                    third = 3
                    return
                }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/lib"
                    func forward() (int, string) { return lib.Pair(4) }
                    func sum(a int, b int, c int) int { return a + b + c }
                    func main() {
                        lib.Hello()
                        fmt.Println(lib.One(1))
                        a, s := lib.Pair(3)
                        fmt.Println(a, s)
                        b, t := forward()
                        fmt.Println(b, t)
                        var x int
                        var y int
                        var z int
                        x, z, y = lib.Triple()
                        fmt.Println(x, y, sum(x, z, lib.One(y)))
                    }
                    """
            ),
        ])
        #expect(shell(module) == "hello\n2\n6 p\n8 p\n1 3 7")
    }

    /// Closures, `defer`, and goroutines inside an imported package bind that
    /// package's own names.
    @Test func closuresDeferAndGoroutinesInsideAnImportedPackage() throws {
        let module = GuestModule([
            (
                "lib/lib.go",
                """
                package lib
                import "fmt"
                var total = 0
                func add(x int) { total = total + x }
                func Run() int {
                    add(2)
                    defer func() { fmt.Println("deferred", total) }()
                    done := make(chan int)
                    go func(out chan int) {
                        add(40)
                        out <- total
                    }(done)
                    return <-done
                }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/lib"
                    var total = 1000
                    func add(x int) { total = total - x }
                    func main() {
                        add(1)
                        fmt.Println(lib.Run(), total)
                    }
                    """
            ),
        ])
        #expect(try run(module) == "deferred 42\n42 999\n")
    }

    /// Function values are as limited across packages as inside one: the
    /// same diagnostics, with the qualified spelling.
    @Test func functionValuesKeepTheInPackageDiagnostics() {
        let library = ("lib/lib.go", "package lib\nfunc One(x int) int { return x + 1 }\nvar Hook = func(x int) {}\n")
        let value = GuestModule([
            library,
            ("main.go", Self.main + "import \"example/m/lib\"\nfunc main() {\n\tf := lib.One\n\tfmt.Println(f(1))\n}\n"),
        ])
        #expect(diagnostic(value) == "/m/main.go:5:7: undefined: lib.One")
        #expect(goMainDiagnostic("f := one\nfmt.Println(f(1))", declarations: "func one(x int) int { return x + 1 }") == "undefined: one")

        let variable = GuestModule([
            library,
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.Hook(1)\n}\n"),
        ])
        #expect(diagnostic(variable) == "/m/main.go:4:2: undefined: lib.Hook")
        #expect(goMainDiagnostic("hook(1)", declarations: "var hook = func(x int) {}") == "undefined: hook")
    }

    // MARK: Constants and variables

    @Test func exportedConstantsKeepTheirKind() {
        let module = GuestModule([
            (
                "lib/lib.go",
                """
                package lib
                const Limit = 10
                const Name = "lib"
                const Mask byte = 7
                const Typed int = 3
                const Wide = Limit * 20
                const Flags = 1 << 4 | 1
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/lib"
                    const local = lib.Limit + 1
                    func main() {
                        var b byte = lib.Mask + 1
                        var adopted byte = lib.Limit
                        x := lib.Limit * 2
                        fmt.Println(b, adopted, x, lib.Typed+1, lib.Name+"!", len(lib.Name))
                        fmt.Println(local, lib.Wide, lib.Flags)
                        table := [3]int{lib.Typed, lib.Limit, local}
                        fmt.Println(table[1], lib.Name[0])
                    }
                    """
            ),
        ])
        #expect(shell(module) == "8 10 20 4 lib! 3\n11 200 17\n10 108")
    }

    @Test func untypedConstantOverflowIsDiagnosedAcrossPackages() {
        let module = GuestModule([
            ("lib/lib.go", "package lib\nconst Big = 300\n"),
            (
                "main.go",
                Self.main + "import \"example/m/lib\"\nfunc main() {\n\tvar b byte = lib.Big\n\tfmt.Println(b)\n}\n"
            ),
        ])
        let message = diagnostic(module)
        #expect(message?.contains("300") == true)
        #expect(message?.contains("byte") == true)
    }

    @Test func constantsCannotBeAssignedAcrossPackages() {
        let module = GuestModule([
            ("lib/lib.go", "package lib\nconst Limit = 10\n"),
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.Limit = 2\n}\n"),
        ])
        #expect(diagnostic(module)?.contains("lib.Limit") == true)
    }

    @Test func exportedVariablesAreSharedStorage() {
        let module = GuestModule([
            (
                "lib/lib.go",
                """
                package lib
                var Counter = 5
                var Names = []string{"a"}
                var Label string
                func Get() int { return Counter }
                func Bump() { Counter++ }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/lib"
                    var derived = lib.Counter * 2
                    func main() {
                        fmt.Println(lib.Counter, derived)
                        lib.Counter = lib.Counter + 10
                        lib.Counter++
                        lib.Bump()
                        fmt.Println(lib.Counter, lib.Get(), lib.Counter*2 > 30)
                        lib.Names = append(lib.Names, "b")
                        lib.Label = "set"
                        pointer := &lib.Counter
                        *pointer = 1
                        fmt.Println(len(lib.Names), lib.Names[1], lib.Label, lib.Get())
                    }
                    """
            ),
        ])
        #expect(shell(module) == "5 10\n17 17 true\n2 b set 1")
    }

    // MARK: Initialization order

    @Test func packagesInitializeDependenciesFirstExactlyOnce() throws {
        let module = GuestModule([
            (
                "b/b.go",
                """
                package b
                import "fmt"
                var Value = trace("b.var")
                func trace(text string) int {
                    fmt.Println(text)
                    return 1
                }
                func init() {
                    fmt.Println("b.init")
                    Value = Value + 10
                }
                """
            ),
            (
                "a/a.go",
                """
                package a
                import "fmt"
                import "example/m/b"
                var Value = b.Value + trace()
                func trace() int {
                    fmt.Println("a.var")
                    return 100
                }
                func init() { fmt.Println("a.init", Value) }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/a"
                    import "example/m/b"
                    var value = a.Value + b.Value
                    func init() { fmt.Println("main.init", value) }
                    func main() { fmt.Println("main", a.Value, b.Value) }
                    """
            ),
        ])
        let expected = "b.var\nb.init\na.var\na.init 111\nmain.init 122\nmain 111 11\n"
        #expect(try run(module) == expected)

        let executable = try GoCompiler.compile(packages: module.packages, root: "example/m")
        #expect(
            executable.initializers == [
                "$example/m/b.init", "$init.0", "$example/m/a.init", "$init.1",
                "$package.init", "$init.2",
            ])
        #expect(executable.globalCount == 3)
        let decoded = try GoExecutableImage.decode(GoExecutableImage.encode(executable))
        #expect(decoded == executable)
    }

    @Test func initializationCycleInsideAnImportedPackageIsRejected() {
        let module = GuestModule([
            ("lib/lib.go", "package lib\nvar First = second + 1\nvar second = First + 1\n"),
            ("main.go", Self.main + "import \"example/m/lib\"\nfunc main() {\n\tfmt.Println(lib.First)\n}\n"),
        ])
        #expect(diagnostic(module)?.contains("initialization cycle") == true)
    }

    // MARK: Types and methods

    @Test func namedTypesStructsAndMethodsCrossPackages() {
        let module = GuestModule([
            (
                "geo/geo.go",
                """
                package geo
                type ID int
                type Point struct {
                    X int
                    Y int
                }
                type Shape interface {
                    Area() int
                }
                func NewPoint(x int, y int) Point { return Point{X: x, Y: y} }
                func (p Point) Sum() int { return p.X + p.Y }
                func (p *Point) Move(delta int) {
                    p.X = p.X + delta
                    p.Y = p.Y + delta
                }
                func (id ID) Next() ID { return id + 1 }
                func Describe(shape Shape) int { return shape.Area() * 2 }
                func Origin() *Point {
                    origin := Point{X: 0, Y: 0}
                    return &origin
                }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/geo"
                    type square struct {
                        side int
                    }
                    func (s square) Area() int { return s.side * s.side }
                    func total(points []geo.Point) int {
                        sum := 0
                        for _, point := range points {
                            sum = sum + point.Sum()
                        }
                        return sum
                    }
                    func main() {
                        p := geo.Point{X: 1, Y: 2}
                        p.X = 5
                        fmt.Println(p.X, p.Y, p.Sum())
                        p.Move(1)
                        q := geo.NewPoint(3, 4)
                        fmt.Println(p.Sum(), total([]geo.Point{p, q, geo.Point{Y: 9}}))
                        var id geo.ID = 3
                        fmt.Println(id.Next(), geo.ID(40)+2, int(id)+1)
                        origin := geo.Origin()
                        origin.Move(2)
                        index := map[string]geo.Point{"o": *origin}
                        fmt.Println(index["o"].X, geo.Describe(square{side: 3}))
                        var shape geo.Shape = square{side: 2}
                        fmt.Println(shape.Area())
                    }
                    """
            ),
        ])
        #expect(shell(module) == "5 2 7\n9 25\n4 42 4\n2 18\n4")
    }

    @Test func errorsInterfacesAndCollectionsOfImportedTypes() throws {
        let module = GuestModule([
            (
                "store/store.go",
                """
                package store
                type Item struct {
                    Name string
                    Count int
                }
                type NotFound struct {
                    Key string
                }
                type Visitor interface {
                    Visit(Item) int
                }
                var items = map[string]Item{"a": Item{Name: "a", Count: 2}}
                func (e NotFound) Error() string { return "no item " + e.Key }
                func Find(key string) (Item, error) {
                    item, ok := items[key]
                    if !ok {
                        return Item{Name: "", Count: 0}, NotFound{Key: key}
                    }
                    return item, nil
                }
                func Each(list []Item, visitor Visitor) int {
                    total := 0
                    for _, item := range list {
                        total += visitor.Visit(item)
                    }
                    return total
                }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/store"
                    type counter struct {
                        seen []string
                    }
                    func (c *counter) Visit(item store.Item) int {
                        c.seen = append(c.seen, item.Name)
                        return item.Count
                    }
                    func lookup(key string) (store.Item, error) { return store.Find(key) }
                    func main() {
                        item, err := lookup("a")
                        fmt.Println(item.Name, item.Count, err == nil)
                        _, missing := store.Find("z")
                        fmt.Println(missing.Error())
                        failure, isNotFound := missing.(store.NotFound)
                        fmt.Println(isNotFound, failure.Key)
                        state := counter{seen: []string{}}
                        visitor := &state
                        list := []store.Item{item, store.Item{Name: "b", Count: 5}}
                        fmt.Println(store.Each(list, visitor), len(visitor.seen), list[1].Name)
                    }
                    """
            ),
        ])
        #expect(try run(module) == "a 2 true\nno item z\ntrue z\n7 2 b\n")
    }

    @Test func sameNamesInDifferentPackagesDoNotCollide() throws {
        func library(_ name: String, value: Int) -> String {
            """
            package \(name)
            type T struct {
                N int
            }
            var Value = \(value)
            const Kind = "\(name)"
            func helper() int { return Value * 2 }
            func Name() string { return Kind }
            func Twice() int { return helper() }
            func (t T) String() string { return Kind }
            func (t T) Get() int { return t.N + Value }
            """
        }
        let module = GuestModule([
            ("a/a.go", library("a", value: 1)),
            ("b/b.go", library("b", value: 10)),
            ("deep/a/a.go", library("a", value: 100)),
            (
                "other.go",
                "package main\nimport \"example/m/deep/a\"\nfunc deep() int { return a.Twice() + a.T{N: 1}.Get() }\n"
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/a"
                    import "example/m/b"
                    type T struct {
                        N int
                    }
                    var Value = 1000
                    func helper() int { return Value }
                    func (t T) Get() int { return t.N }
                    func main() {
                        fmt.Println(a.Name(), b.Name(), a.Twice(), b.Twice(), helper())
                        fmt.Println(a.T{N: 1}.Get(), b.T{N: 1}.Get(), T{N: 1}.Get(), deep())
                        var first any = a.T{N: 0}
                        var second any = b.T{N: 0}
                        _, isA := first.(a.T)
                        _, isB := first.(b.T)
                        _, same := second.(b.T)
                        fmt.Println(isA, isB, same)
                    }
                    """
            ),
        ])
        #expect(try run(module) == "a b 2 20 1000\n2 11 1 301\ntrue false true\n")
    }

    @Test func localNamesShadowPackageLevelNamesInsideAnImportedPackage() throws {
        let module = GuestModule([
            (
                "lib/lib.go",
                """
                package lib
                var count = 7
                func size() int { return 3 }
                func Shadow(size int) int {
                    count := size + 1
                    return count
                }
                func Direct() int { return count + size() }
                """
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/lib"
                    type pair struct {
                        Shadow int
                    }
                    func main() {
                        fmt.Println(lib.Shadow(1), lib.Direct())
                        lib := pair{Shadow: 9}
                        fmt.Println(lib.Shadow)
                    }
                    """
            ),
        ])
        #expect(try run(module) == "2 10\n9\n")
    }

    @Test func transitiveImportsAndSharedDependencies() {
        let module = GuestModule([
            ("c/c.go", "package c\nconst Base = 2\nfunc Scale(x int) (int, bool) { return x * Base, x > 0 }\n"),
            (
                "b/b.go",
                "package b\nimport \"example/m/c\"\ntype Box struct {\n\tV int\n}\nfunc Make(x int) Box {\n\tv, _ := c.Scale(x)\n\treturn Box{V: v}\n}\n"
            ),
            (
                "a/a.go",
                "package a\nimport \"example/m/b\"\nimport \"example/m/c\"\nfunc Build(x int) (b.Box, int) {\n\treturn b.Make(x), c.Base\n}\n"
            ),
            (
                "main.go",
                Self.main + """
                    import "example/m/a"
                    import "example/m/c"
                    func main() {
                        box, base := a.Build(5)
                        scaled, ok := c.Scale(box.V)
                        fmt.Println(box.V, base, scaled, ok)
                    }
                    """
            ),
        ])
        #expect(shell(module) == "10 2 20 true")
    }

    // MARK: Diagnostics

    @Test func unexportedAndUndefinedNamesAreRejected() {
        let library = (
            "lib/lib.go",
            "package lib\nconst limit = 1\nvar hidden = 2\ntype secret struct {\n\tN int\n}\nfunc helper() int { return 1 }\nfunc Public() int { return helper() + hidden + limit }\n"
        )
        func message(_ body: String) -> String? {
            diagnostic(GuestModule([
                library,
                ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\t\(body)\n}\n"),
            ]))
        }
        #expect(message("lib.helper()") == "/m/main.go:4:2: cannot refer to unexported name lib.helper")
        #expect(message("x := lib.hidden")?.hasSuffix("cannot refer to unexported name lib.hidden") == true)
        #expect(message("x := lib.limit")?.hasSuffix("cannot refer to unexported name lib.limit") == true)
        #expect(message("var s lib.secret")?.hasSuffix("cannot refer to unexported name lib.secret") == true)
        #expect(message("s := lib.secret{N: 1}")?.hasSuffix("cannot refer to unexported name lib.secret") == true)
        #expect(message("lib.Missing()")?.hasSuffix("undefined: lib.Missing") == true)
        #expect(message("var m lib.Missing")?.hasSuffix("undefined: lib.Missing") == true)
        #expect(message("lib.Public()") == nil)
    }

    @Test func diagnosticsUseGoSpellingForLinkedNames() {
        let module = GuestModule([
            ("lib/lib.go", "package lib\ntype Point struct {\n\tX int\n}\nfunc Take(p Point) int { return p.X }\nfunc broken() int { return missing }\n"),
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.Take(1)\n}\n"),
        ])
        let message = diagnostic(module) ?? ""
        #expect(!message.contains("example/m/lib"))
        #expect(message == "/m/lib/lib.go:6:28: undefined: missing")

        let argument = GuestModule([
            ("lib/lib.go", "package lib\ntype Point struct {\n\tX int\n}\nfunc Take(p Point) int { return p.X }\n"),
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.Take(1)\n}\n"),
        ])
        let mismatch = diagnostic(argument) ?? ""
        #expect(mismatch.hasPrefix("/m/main.go:4:"))
        #expect(mismatch.contains("lib.Point") || mismatch.contains("lib.Take"))
        #expect(!mismatch.contains("example/m/lib"))
    }

    @Test func importRulesAreEnforced() {
        let cycle = GuestModule([
            ("a/a.go", "package a\nimport \"example/m/b\"\nfunc A() int { return b.B() }\n"),
            ("b/b.go", "package b\nimport \"example/m/a\"\nfunc B() int { return a.A() }\n"),
            ("main.go", "package main\nimport \"example/m/a\"\nfunc main() {\n\ta.A()\n}\n"),
        ])
        #expect(
            diagnostic(cycle)
                == "/m/b/b.go:2:1: import cycle not allowed: example/m/a imports example/m/b imports example/m/a")
        #expect(shell(cycle).contains("import cycle not allowed"))

        let unused = GuestModule([
            ("lib/lib.go", "package lib\nfunc F() {}\n"),
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {}\n"),
        ])
        #expect(diagnostic(unused) == "/m/main.go:2:1: \"example/m/lib\" imported and not used")

        let program = GuestModule([
            ("tool/main.go", "package main\nfunc main() {}\nfunc Helper() {}\n"),
            ("main.go", "package main\nimport \"example/m/tool\"\nfunc main() {\n\tmain.Helper()\n}\n"),
        ])
        #expect(
            diagnostic(program)
                == "/m/main.go:2:1: import \"example/m/tool\" is a program, not an importable package")

        let missing = GuestModule([
            ("main.go", "package main\nimport \"example/m/absent\"\nfunc main() {\n\tabsent.F()\n}\n")
        ])
        #expect(diagnostic(missing) == "/m/main.go:2:1: package example/m/absent is not available")

        let mixed = GuestModule([
            ("lib/a.go", "package lib\nfunc F() {}\n"),
            ("lib/b.go", "package other\nfunc G() {}\n"),
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.F()\n}\n"),
        ])
        #expect(diagnostic(mixed)?.hasSuffix("found packages lib and other") == true)

        let clash = GuestModule([
            ("x/lib/lib.go", "package lib\nfunc F() {}\n"),
            ("y/lib/lib.go", "package lib\nfunc G() {}\n"),
            (
                "main.go",
                "package main\nimport \"example/m/x/lib\"\nimport \"example/m/y/lib\"\nfunc main() {\n\tlib.F()\n}\n"
            ),
        ])
        #expect(diagnostic(clash) == "/m/main.go:3:1: lib redeclared in this block")
    }

    @Test func internalPackagesAreVisibleOnlyInsideTheirParentTree() throws {
        let hidden = ("tools/internal/secret/secret.go", "package secret\nfunc Value() int { return 42 }\n")
        let inside = GuestModule([
            hidden,
            (
                "tools/cmd/main.go",
                Self.main + "import \"example/m/tools/internal/secret\"\nfunc main() {\n\tfmt.Println(secret.Value())\n}\n"
            ),
        ])
        let executable = try GoCompiler.compile(
            packages: inside.packages, root: "example/m/tools/cmd")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "42\n")

        let outside = GuestModule([
            hidden,
            (
                "main.go",
                Self.main + "import \"example/m/tools/internal/secret\"\nfunc main() {\n\tfmt.Println(secret.Value())\n}\n"
            ),
        ])
        #expect(
            diagnostic(outside)
                == "/m/main.go:3:1: use of internal package example/m/tools/internal/secret not allowed")
        #expect(shell(outside).contains("use of internal package example/m/tools/internal/secret not allowed"))

        #expect(GoModuleLinker.allowsInternalImport(of: "m/internal/x", from: "m"))
        #expect(GoModuleLinker.allowsInternalImport(of: "m/internal/x", from: "m/cmd/y"))
        #expect(GoModuleLinker.allowsInternalImport(of: "m/internal", from: "m/internal/x"))
        #expect(!GoModuleLinker.allowsInternalImport(of: "m/internal/x", from: "mm/y"))
        #expect(!GoModuleLinker.allowsInternalImport(of: "m/a/internal/x", from: "m/b"))
        #expect(GoModuleLinker.allowsInternalImport(of: "m/internals/x", from: "other"))
    }

    // MARK: Cost and limits

    /// A cross-package call must cost what an in-package call costs: file-backed
    /// programs are scheduled per instruction quantum.
    @Test func crossPackageCallCostsTheSameAsAnInPackageCall() throws {
        func body(_ q: String) -> String {
            """
            func main() {
                total := 0
                for index := 0; index < 1000; index++ {
                    total = total + \(q)Add(index, 1)
                    a, b := \(q)Pair(index)
                    total = total + a + b + \(q)Limit + \(q)Counter
                }
                fmt.Println(total)
            }
            """
        }
        let library = """
            const Limit = 3
            var Counter = 4
            func Add(a int, b int) int { return a + b }
            func Pair(x int) (int, int) { return x, x + 1 }
            """
        let single = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: Self.main + library + "\n" + body(""))
        ])
        let module = GuestModule([
            ("lib/lib.go", "package lib\n" + library),
            ("main.go", Self.main + "import \"example/m/lib\"\n" + body("lib.")),
        ])
        let linked = try GoCompiler.compile(packages: module.packages, root: "example/m")

        func instructions(_ executable: GoExecutable) throws -> Int {
            var low = 1
            var high = 1_000_000
            while low < high {
                let middle = (low + high) / 2
                do {
                    try GoVirtualMachine(maximumInstructions: middle).run(executable) { _ in }
                    high = middle
                } catch {
                    low = middle + 1
                }
            }
            return low
        }
        let singleCount = try instructions(single)
        let linkedCount = try instructions(linked)
        #expect(singleCount == linkedCount)
        #expect(singleCount > 10_000)

        let singleMain = single.functions.first { $0.name == "main" }
        let linkedMain = linked.functions.first { $0.name == "main" }
        #expect(singleMain?.instructions.count == linkedMain?.instructions.count)
        #expect(
            single.functions.first { $0.name == "Add" }?.instructions
                == linked.functions.first { $0.name == "example/m/lib.Add" }?.instructions)
    }

    @Test func linkedProgramsObeyRuntimeLimits() throws {
        let library = (
            "lib/lib.go",
            "package lib\nfunc Spin() {\n\tfor {\n\t}\n}\nfunc Deep(n int) int { return Deep(n+1) + 1 }\n"
        )
        let spinning = GuestModule([
            library,
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.Spin()\n}\n"),
        ])
        #expect(throws: GoRuntimeError.instructionLimitExceeded) {
            try run(spinning, machine: GoVirtualMachine(maximumInstructions: 10_000))
        }
        let recursive = GuestModule([
            library,
            ("main.go", "package main\nimport \"example/m/lib\"\nfunc main() {\n\tlib.Deep(0)\n}\n"),
        ])
        #expect(throws: GoRuntimeError.self) {
            try run(recursive, machine: GoVirtualMachine(maximumCallDepth: 64))
        }
    }

    @Test func packageListIsValidated() {
        let source = GoSourceFile(path: "main.go", text: "package main\nfunc main() {}\n")
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(
                packages: [
                    GoPackageSource(importPath: "m", sources: [source]),
                    GoPackageSource(importPath: "m", sources: [source]),
                ], root: "m")
        }
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(
                packages: [GoPackageSource(importPath: "m", sources: [source])], root: "absent")
        }
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(
                packages: [GoPackageSource(importPath: "m", sources: [])], root: "m")
        }
        let library = GoSourceFile(path: "lib.go", text: "package lib\nfunc F() {}\n")
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(
                packages: [GoPackageSource(importPath: "m", sources: [library])], root: "m")
        }
    }

    @Test func buildsAreBoundedInPackageCountAndImportDepth() throws {
        // A chain as deep as the limit links; one more package is refused.
        func chain(_ count: Int) -> [GoPackageSource] {
            (0..<count).map { index in
                let name = index == 0 ? "main" : "p\(index)"
                let next = index + 1 < count ? "p\(index + 1)" : nil
                let call = next.map { "\($0).F()" } ?? "1"
                let imports = (index == 0 ? "import \"fmt\"\n" : "")
                    + (next.map { "import \"chain/\($0)\"\n" } ?? "")
                let body = index == 0
                    ? "func main() {\n\tfmt.Println(\(call))\n}\n"
                    : "func F() int { return \(call) }\n"
                return GoPackageSource(
                    importPath: index == 0 ? "chain" : "chain/\(name)",
                    sources: [
                        GoSourceFile(
                            path: "\(name).go", text: "package \(name)\n\(imports)\(body)")
                    ])
            }
        }
        let limit = GoModuleLinker.maximumPackages
        let executable = try GoCompiler.compile(packages: chain(limit), root: "chain")
        #expect(executable.functions.contains { $0.name == "chain/p\(limit - 1).F" })
        var output = ""
        try GoVirtualMachine(maximumCallDepth: limit + 8).run(executable) { output += $0 }
        #expect(output == "1\n")
        do {
            _ = try GoCompiler.compile(packages: chain(limit + 1), root: "chain")
            Issue.record("expected the package limit to be enforced")
        } catch let diagnostic as GoDiagnostic {
            #expect(diagnostic.message == "build has too many packages (limit 1024)")
        }
    }

    @Test func gofmtFormatsQualifiedNamesAndResultLists() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"example/m/geo\"\nfunc build(x int)(geo.Point,error){p:=geo.Point{X:x,Y:geo.Limit}\nreturn p,nil}\nfunc main(){ps:=[]geo.Point{geo.Point{X:1}}\ngeo.Counter+=len(ps)}\n")
        let formatted = try GoFormatter.format(source)
        #expect(
            formatted
                == "package main\n\nimport \"example/m/geo\"\n\nfunc build(x int) (geo.Point, error) {\n\tp := geo.Point{X: x, Y: geo.Limit}\n\treturn p, nil\n}\n\nfunc main() {\n\tps := []geo.Point{geo.Point{X: 1}}\n\tgeo.Counter += len(ps)\n}\n")
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: formatted)) == formatted)
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(path: "main.go", text: formatted), rule: "len(a) -> cap(a)")
        #expect(rewritten.text.contains("geo.Counter += cap(ps)"))
        #expect(rewritten.text.contains("p := geo.Point{X: x, Y: geo.Limit}"))
    }

    @Test func packagesCanBeResolvedOnDemand() throws {
        let module = GuestModule([
            ("b/b.go", "package b\nfunc Two() int { return 2 }\n"),
            ("a/a.go", "package a\nimport \"example/m/b\"\nfunc Four() int { return b.Two() * 2 }\n"),
            ("unused/unused.go", "package unused\nthis is not Go\n"),
            (
                "main.go",
                Self.main + "import \"swiftix/userland\"\nimport \"example/m/a\"\nfunc main() {\n\trows, _ := userland.WindowSize()\n\tfmt.Println(a.Four() + rows)\n}\n"
            ),
        ])
        let available = Dictionary(
            uniqueKeysWithValues: module.packages.map { ($0.importPath, $0.sources) })
        var requests: [String] = []
        let executable = try GoCompiler.compile(root: "example/m") { importPath in
            requests.append(importPath)
            return available[importPath]
        }
        // Runtime packages are never requested, and nothing is asked twice.
        #expect(requests == ["example/m", "example/m/a", "example/m/b"])
        #expect(executable == (try GoCompiler.compile(packages: module.packages, root: "example/m")))
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "4\n")

        do {
            _ = try GoCompiler.compile(root: "example/m") { importPath in
                importPath == "example/m/b" ? nil : available[importPath]
            }
            Issue.record("expected a missing package to be reported")
        } catch let diagnostic as GoDiagnostic {
            #expect(diagnostic.description == "/m/a/a.go:2:1: package example/m/b is not available")
        }
    }

    // MARK: Tools

    /// Sources already in `gofmt` form, so the format tools report nothing.
    private static let toolModule = GuestModule([
        (
            "internal/text/text.go",
            "package text\n\nconst Greeting = \"hello\"\n\nfunc Join(a string, b string) (string, int) {\n\treturn a + \" \" + b, len(a) + len(b)\n}\n"
        ),
        (
            "internal/text/text_test.go",
            "package text\n\nimport \"testing\"\n\nfunc TestJoin(t *testing.T) {\n\tjoined, size := Join(\"a\", \"b\")\n\tif joined != \"a b\" || size != 2 {\n\t\tt.Fatal(\"join\")\n\t}\n}\n"
        ),
        (
            "cmd/greet/main.go",
            "package main\n\nimport \"fmt\"\nimport \"example/m/internal/text\"\n\nfunc main() {\n\tjoined, size := text.Join(text.Greeting, \"world\")\n\tfmt.Println(joined, size)\n}\n"
        ),
        (
            "cmd/greet/main_test.go",
            "package main\n\nimport \"testing\"\nimport \"example/m/internal/text\"\n\nfunc TestGreeting(t *testing.T) {\n\tif text.Greeting != \"hello\" {\n\t\tt.Fatal(\"greeting\")\n\t}\n}\n"
        ),
    ])

    @Test func goToolsBuildRunTestAndInstallMultiPackageModules() {
        let output = runShell(
            [
                "cd /m/cmd/greet", "go run .", "go build -o /tmp/greet .", "/tmp/greet",
                "go install .", "/root/go/bin/greet",
                "cd /m", "go run ./cmd/greet", "go build -o /tmp/greet2 ./cmd/greet", "/tmp/greet2",
                "go test ./...", "gofmt -l .", "go fmt ./...",
            ],
            seed: { context in
                _ = context.mkdir("/tmp")
                Self.toolModule.seed(context)
            })
        let lines = shellResultLines(output).joined(separator: "\n")
        #expect(
            lines
                == """
                hello world 10
                hello world 10
                hello world 10
                hello world 10
                hello world 10
                --- PASS: TestGreeting
                ok  \texample/m/cmd/greet
                --- PASS: TestJoin
                ok  \texample/m/internal/text
                """)
    }

    @Test func buildCacheInvalidatesWhenAnImportedPackageChanges() {
        let output = runShell(
            [
                "cd /m/cmd/greet", "go build -o /tmp/greet .", "/tmp/greet",
                "go build -o /tmp/greet .", "/tmp/greet",
                "cp /m/next.go /m/internal/text/text.go",
                "go build -o /tmp/greet .", "/tmp/greet", "go run .",
            ],
            seed: { context in
                _ = context.mkdir("/tmp")
                Self.toolModule.seed(context)
                Self.write(
                    context, path: "/m/next.go",
                    contents: "package text\nconst Greeting = \"goodbye\"\nfunc Join(a string, b string) (string, int) {\n\treturn a + \", \" + b, 0\n}\n")
            })
        #expect(
            shellResultLines(output).joined(separator: "\n")
                == "hello world 10\nhello world 10\ngoodbye, world 0\ngoodbye, world 0")
    }

    @Test func buildCacheKeyCoversEveryPackageOfTheBuild() {
        let main = GoSourceFile(path: "/m/main.go", text: "package main\nfunc main() {}\n")
        let library = GoSourceFile(path: "/m/lib/lib.go", text: "package lib\nfunc F() {}\n")
        let changed = GoSourceFile(path: "/m/lib/lib.go", text: "package lib\nfunc F() { }\n")
        func key(_ sources: [GoSourceFile], root: String = "example/m") -> String {
            GoBuildCache.key(
                toolVersion: GoToolchain.toolVersion,
                languageVersion: GoToolchain.languageVersion,
                sources: sources,
                moduleFile: nil,
                rootPackage: root)
        }
        #expect(key([library, main]) == key([library, main]))
        #expect(key([library, main]) != key([changed, main]))
        #expect(key([library, main]) != key([main]))
        #expect(key([library, main]) != key([library, main], root: "example/m/lib"))
    }
}
