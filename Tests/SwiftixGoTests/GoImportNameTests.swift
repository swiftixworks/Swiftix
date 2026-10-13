/// The names a file gives the packages it imports: `import f "fmt"`,
/// `import _ "fmt"`, and `import . "fmt"`, for packages of the run-time
/// library and for packages of the module. What such programs print is
/// compared with Go in `GoConformanceTests`, and how `gofmt` lays the imports
/// out in `GoGofmtConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go import names")
struct GoImportNameTests: GoTestHarness {

    private func parse(_ text: String, path: String = "main.go") throws -> GoFile {
        try GoParser.parse(GoSourceFile(path: path, text: text))
    }

    private func compile(_ files: [(path: String, text: String)]) throws -> GoExecutable {
        try GoCompiler.compile(sources: files.map { GoSourceFile(path: $0.path, text: $0.text) })
    }

    private func output(_ text: String) throws -> String {
        try output([("main.go", text)])
    }

    private func output(_ files: [(path: String, text: String)]) throws -> String {
        var output = ""
        try GoVirtualMachine().run(try compile(files)) { output += $0 }
        return output
    }

    private func diagnostic(_ text: String) -> String? {
        do {
            _ = try compile([("main.go", text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    /// A module `example/m` whose packages are the directories of `files`.
    private func packages(_ files: [(path: String, text: String)]) -> [GoPackageSource] {
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

    private func moduleOutput(_ files: [(path: String, text: String)]) throws -> String {
        let executable = try GoCompiler.compile(packages: packages(files), root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    private func moduleDiagnostic(_ files: [(path: String, text: String)]) -> String? {
        do {
            _ = try GoCompiler.compile(packages: packages(files), root: "example/m")
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    // MARK: Syntax

    @Test func anImportMayNameItsPackage() throws {
        let file = try parse(
            """
            package main

            import f "fmt"
            import _ "sort"
            import . "strings"
            import (
                "os"
                conv "strconv"; _ "io"
                . "errors"
            )

            func main() {}
            """)

        #expect(file.imports.map(\.path) == ["fmt", "sort", "strings", "os", "strconv", "io", "errors"])
        #expect(file.imports.map(\.name) == ["f", "_", ".", nil, "conv", "_", "."])
        // An import is where its name is, or its path when it has none: the
        // place Go reports it by.
        #expect(file.imports.map(\.position.line) == [3, 4, 5, 7, 8, 8, 9])
        #expect(file.imports.map(\.position.column) == [8, 8, 8, 5, 5, 21, 5])
        #expect(try parse("package main\nimport \"fmt\"\n").imports[0].position.column == 8)
        // The initializer that takes no name is the import of old.
        let position = file.imports[0].position
        #expect(GoImportDeclaration(path: "fmt", position: position).name == nil)

        #expect(diagnostic("package main\nimport f\nfunc main() {}\n") == "main.go:2:9: expected import path")
        #expect(
            diagnostic("package main\nimport (\n f g \"fmt\"\n)\nfunc main() {}\n")
                == "main.go:3:4: expected import path")
    }

    // MARK: Run-time library

    @Test func aNameStandsForThePackageWhereNothingHidesIt() throws {
        #expect(
            try output(
                """
                package main

                import (
                    f "fmt"
                    str "strings"
                    conv "strconv"
                )

                func double(str int) int { return str * 2 }

                func main() {
                    f.Println(str.ToUpper("ab"), conv.Itoa(double(4)))
                    n, err := conv.Atoi("12")
                    f.Println(n, err)
                    for conv := range []int{7, 8} {
                        f.Print(conv)
                    }
                    if n > 0 {
                        str := "hidden"
                        f.Println("", str, len(str))
                    }
                    f.Println(str.Repeat("x", 3), f.Sprintf("%03d", n))
                }
                """)
                == "AB 8\n12 <nil>\n01 hidden 6\nxxx 012\n")
    }

    @Test func thePackagesOwnNameIsFreeForTheProgram() throws {
        // A file that calls `time` something else may use `time`, and with it
        // `fmt` and `strings`, for what it likes: a variable, a function, a
        // type, a parameter.
        #expect(
            try output(
                """
                package main

                import (
                    f "fmt"
                    str "strings"
                    stdtime "time"
                )

                type fmt struct {
                    Width int
                }

                var time = 3

                func strings(fmt []string) string { return str.Join(fmt, "+") }

                func main() {
                    started := stdtime.Now()
                    time += 1
                    layout := fmt{Width: time}
                    f.Println(strings([]string{"a", "b"}), layout, time)
                    f.Printf("%T %v\\n", layout, stdtime.Since(started) >= 0)
                }
                """)
                == "a+b {4} 4\nmain.fmt true\n")
    }

    @Test func theNameReachesTypesConstantsAndValues() throws {
        #expect(
            try output(
                """
                package main

                import (
                    f "fmt"
                    in "io"
                    sys "os"
                    stdtime "time"
                )

                func out() *sys.File { return sys.Stdout }

                func since(start stdtime.Time) bool {
                    return stdtime.Since(start) < stdtime.Second
                }

                func main() {
                    var start stdtime.Time = stdtime.Now()
                    f.Println(since(start), in.EOF, in.SeekEnd, len(sys.Args) >= 0)
                    f.Printf("%T %T\\n", start, out())
                }
                """)
                == "true EOF 2 true\ntime.Time *os.File\n")
    }

    @Test func aPackageMayHaveSeveralNamesInOneFile() throws {
        #expect(
            try output(
                """
                package main

                import (
                    "fmt"
                    f "fmt"
                    fmt2 "fmt"
                    strings "strings"
                )

                func main() {
                    fmt.Print(strings.ToLower("A"))
                    f.Print("b")
                    fmt2.Println("c")
                }
                """)
                == "abc\n")
    }

    @Test func filesOfAPackageNameTheirImportsApart() throws {
        // `fmt` is the package in one file and a variable of the package in
        // the others, which is Go as long as no file imports it unnamed.
        #expect(
            try output([
                (
                    "main.go",
                    """
                    package main

                    import f "fmt"

                    var fmt = "own"

                    func main() {
                        f.Println(fmt, shout(), count())
                    }
                    """
                ),
                (
                    "shout.go",
                    """
                    package main

                    import "strings"

                    func shout() string { return strings.ToUpper(fmt) }
                    """
                ),
                (
                    "count.go",
                    """
                    package main

                    import s "strings"

                    func count() int {
                        strings := []string{fmt, fmt}
                        return len(s.Join(strings, ""))
                    }
                    """
                ),
            ]) == "own OWN 6\n")
    }

    @Test func aBlankImportNamesNothing() throws {
        #expect(
            diagnostic("package main\nimport _ \"fmt\"\nfunc main() {\n fmt.Println(1)\n}\n")
                == "main.go:4:2: undefined: fmt")
        #expect(
            try output(
                """
                package main

                import (
                    _ "fmt"
                    "fmt"
                    _ "sort"
                )

                func main() {
                    sort := "free"
                    fmt.Println(sort)
                }
                """) == "free\n")
        #expect(
            diagnostic("package main\nimport _ \"nowhere\"\nfunc main() {}\n")
                == "main.go:2:8: package nowhere is not available")
    }

    @Test func aDotImportBringsExportedNamesIntoTheFile() throws {
        #expect(
            try output(
                """
                package main

                import (
                    . "fmt"
                    "strings"
                )

                type Shape struct {
                    Sides int
                }

                func Describe(s Shape) string { return Sprint("sides=", s.Sides) }

                func main() {
                    Println(Describe(Shape{Sides: 3}), strings.ToUpper("x"))
                    if len(Sprint(1)) == 1 {
                        Println := "hidden"
                        Printf("%s %d\\n", Println, len(Println))
                    }
                }
                """) == "sides=3 X\nhidden 6\n")

        // Nothing lists what a library package declares, so one file takes
        // the unqualified names of one.
        #expect(
            diagnostic(
                "package main\nimport (\n . \"fmt\"\n . \"strings\"\n)\nfunc main() {\n Println(ToUpper(\"x\"))\n}\n")
                == "main.go:4:2: a file can dot-import only one package of the run-time library")
    }

    @Test func importNamesMustDiffer() {
        func program(_ imports: String, _ body: String = "") -> String {
            "package main\nimport (\n" + imports + "\n)\nfunc main() {\n" + body + "\n}\n"
        }

        #expect(
            diagnostic(program(" f \"fmt\"\n f \"os\"", " f.Println(1)"))
                == "main.go:4:2: f redeclared in this block")
        #expect(
            diagnostic(program(" \"fmt\"\n fmt \"strings\"", " fmt.Println(1)"))
                == "main.go:4:2: fmt redeclared in this block")
        #expect(
            diagnostic(program(" \"os\"\n \"os\"", " os.Exit(0)"))
                == "main.go:4:2: os redeclared in this block")
        // Under another name the package's own is not declared.
        #expect(
            diagnostic(program(" f \"fmt\"", " fmt.Println(1)\n f.Println(2)"))
                == "main.go:6:2: undefined: fmt")
        // A name a declaration hides is that declaration.
        #expect(
            diagnostic(program(" f \"fmt\"", " f.Print()\n f := 3\n f.Println(f)"))
                == "main.go:8:3: int has no field or method Println")
    }

    @Test func anImportMustBeUsed() {
        #expect(
            diagnostic("package main\nimport \"os\"\nfunc main() {}\n")
                == "main.go:2:8: \"os\" imported and not used")
        #expect(
            diagnostic(
                "package main\nimport (\n \"fmt\"\n \"os\"\n \"strings\"\n)\nfunc main() {\n fmt.Println(1)\n}\n")
                == "main.go:4:2: \"os\" imported and not used")
        #expect(
            diagnostic("package main\nimport f \"fmt\"\nfunc main() {}\n")
                == "main.go:2:8: \"fmt\" imported as f and not used")
        #expect(
            diagnostic("package main\nimport . \"fmt\"\nfunc main() {}\n")
                == "main.go:2:8: \"fmt\" imported and not used")
        // Each name of a package is an import of its own.
        #expect(
            diagnostic(
                "package main\nimport (\n \"fmt\"\n f \"fmt\"\n)\nfunc main() {\n fmt.Println(1)\n}\n")
                == "main.go:4:2: \"fmt\" imported as f and not used")
        // A variable of the name is no use of the package.
        #expect(
            diagnostic("package main\nimport \"os\"\nfunc main() {\n os := 1\n _ = os\n}\n")
                == "main.go:2:8: \"os\" imported and not used")
        // It comes before what is wrong further down.
        #expect(
            diagnostic("package main\nimport \"os\"\nfunc main() {\n x := 1\n}\n")
                == "main.go:2:8: \"os\" imported and not used")

        // A type of the package is a use, and `_` asks for none.
        #expect(
            diagnostic("package main\nimport \"time\"\nfunc main() {\n var t time.Time\n _ = t\n}\n")
                == nil)
        #expect(diagnostic("package main\nimport _ \"fmt\"\nfunc main() {}\n") == nil)
    }

    @Test func aPackageIsNoValue() {
        #expect(
            diagnostic("package main\nimport (\n f \"fmt\"\n \"os\"\n)\nfunc main() {\n f.Println(f, os.Args)\n}\n")
                == "main.go:7:12: use of package f not in selector")
        #expect(
            diagnostic("package main\nimport (\n \"fmt\"\n \"os\"\n)\nfunc main() {\n x := os\n fmt.Println(x)\n}\n")
                == "main.go:7:7: use of package os not in selector")
    }

    // MARK: Resolution

    @Test func resolutionLeavesTheLibrarysOwnNames() throws {
        let files = [
            try parse(
                """
                package main

                import (
                    f "fmt"
                    . "strings"
                    _ "sort"
                    "os"
                    web "net/http"
                )

                func handle(w web.ResponseWriter, fmt int) string {
                    return f.Sprint(ToUpper("x"), fmt, len(os.Args))
                }
                """)
        ]
        let resolved = try GoNames.resolve(files)

        // Every package by its own name; the blank import keeps its `_`.
        #expect(resolved[0].imports.map(\.path) == ["fmt", "strings", "sort", "os", "net/http"])
        #expect(resolved[0].imports.map(\.name) == [nil, nil, "_", nil, nil])
        let function = resolved[0].functions[0]
        #expect(function.parameters[0].type == .named("http.ResponseWriter", position: function.parameters[0].type.position))
        // The parameter `fmt` is the program's, and is spelled apart.
        let parameter = "fmt" + String(GoLocalTypes.marker)
        #expect(function.parameters[1].name == parameter)
        guard case .returnValues(let values, _) = function.body.statements[0],
            case .call(.selector(.identifier("fmt", _), "Sprint", _), let arguments, _) = values[0],
            case .call(.selector(.identifier("strings", _), "ToUpper", _), _, _) = arguments[0],
            case .identifier(parameter, _) = arguments[1],
            case .call(_, let lengthArguments, _) = arguments[2],
            case .selector(.identifier("os", _), "Args", _) = lengthArguments[0]
        else {
            Issue.record("unexpected tree: \(function.body.statements)")
            return
        }

        // Resolved files resolve to themselves, as files without a named
        // import do.
        #expect(try GoNames.resolve(resolved) == resolved)
        let plain = [try parse("package main\nimport \"fmt\"\nfunc main() {\n fmt.Println(1)\n}\n")]
        let checked = try GoNames.resolve(plain)
        #expect(checked[0].imports == plain[0].imports)
        #expect(checked[0].functions == plain[0].functions)
        #expect(try GoNames.resolve(checked) == checked)
    }

    @Test func aDiagnosticNamesWhatTheSourceNames() {
        // `time` is spelled apart from the package, and reported as written.
        #expect(
            diagnostic(
                "package main\nimport t \"time\"\nfunc main() {\n var time int\n var time string\n t.Sleep(0)\n}\n")
                == "main.go:4:6: declared and not used: time")
        #expect(GoLocalTypes.sourceNames(in: "a time\u{B7} and a T\u{B7}12, twice: T\u{B7}3.") == "a time and a T, twice: T.")
    }

    // MARK: Packages of the module

    private static let library = (
        path: "lib/lib.go",
        text: """
            package lib

            var Loaded []string

            const Limit = 3

            type Box struct {
                Value int
            }

            func (b Box) Twice() int { return b.Value * 2 }

            func Hello() string { return "hello" }
            """
    )

    @Test func aLocalPackageTakesANameToo() throws {
        #expect(
            try moduleOutput([
                Self.library,
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"
                        l "example/m/lib"
                    )

                    func twice(b l.Box) int { return b.Twice() }

                    func main() {
                        lib := l.Box{Value: l.Limit}
                        fmt.Println(l.Hello(), twice(lib), lib)
                        fmt.Printf("%T\\n", lib)
                        if lib.Value == 3 {
                            l := "hidden"
                            fmt.Println(l)
                        }
                    }
                    """
                ),
            ]) == "hello 6 {3}\nlib.Box\nhidden\n")
    }

    @Test func packagesOfOneNameAreToldApartByTheirImportNames() throws {
        #expect(
            try moduleOutput([
                (
                    "errors/errors.go",
                    """
                    package errors

                    import stderrors "errors"

                    var ErrMissing = stderrors.New("missing")

                    func Wrap(text string) error { return stderrors.New("wrapped " + text) }
                    """
                ),
                ("a/util/util.go", "package util\n\nfunc Name() string { return \"a\" }\n"),
                ("b/util/util.go", "package util\n\nfunc Name() string { return \"b\" }\n"),
                (
                    "main.go",
                    """
                    package main

                    import (
                        stderrors "errors"
                        "fmt"

                        first "example/m/a/util"
                        second "example/m/b/util"
                        "example/m/errors"
                    )

                    func main() {
                        err := errors.Wrap("x")
                        fmt.Println(first.Name(), second.Name(), err)
                        fmt.Println(stderrors.Is(err, errors.ErrMissing), stderrors.New("plain"))
                    }
                    """
                ),
            ]) == "a b wrapped x\nfalse plain\n")
    }

    @Test func aBlankImportOfALocalPackageRunsItsInitialization() throws {
        #expect(
            try moduleOutput([
                Self.library,
                (
                    "plugin/plugin.go",
                    """
                    package plugin

                    import registry "example/m/lib"

                    func init() {
                        registry.Loaded = append(registry.Loaded, "plugin")
                    }
                    """
                ),
                (
                    "main.go",
                    """
                    package main

                    import (
                        "fmt"

                        "example/m/lib"
                        _ "example/m/plugin"
                    )

                    func main() {
                        fmt.Println(lib.Loaded)
                    }
                    """
                ),
            ]) == "[plugin]\n")
    }

    @Test func aDotImportOfALocalPackage() throws {
        #expect(
            try moduleOutput([
                Self.library,
                (
                    "main.go",
                    """
                    package main

                    import (
                        . "fmt"

                        . "example/m/lib"
                    )

                    type Mine struct {
                        B Box
                    }

                    func main() {
                        b := Box{Value: Limit}
                        Println(Hello(), b.Twice(), Mine{B: b})
                        if Limit == 3 {
                            Hello := "hidden"
                            Println(Hello)
                        }
                    }
                    """
                ),
            ]) == "hello 6 {{3}}\nhidden\n")
    }

    @Test func aSeparatelyCompiledPackageTakesANameToo() throws {
        let library = try GoCompiler.compilePackage(sources: [
            GoSourceFile(
                path: "math/math.go",
                text: "package math\nimport str \"strings\"\nfunc Add(a, b int) int {\n\treturn a + len(str.Repeat(\"x\", b))\n}\n")
        ])
        let executable = try GoCompiler.compile(
            sources: [
                GoSourceFile(
                    path: "main.go",
                    text:
                        "package main\nimport m \"example/math\"\nimport f \"fmt\"\nfunc main() {\n\tmath := m.Add(3, 4)\n\tf.Println(math)\n}\n")
            ],
            importedPackages: ["math": library])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "7\n")
    }

    @Test func theGoToolBuildsRunsAndTestsNamedImports() {
        let output = runShell(
            ["cd /m", "go run .", "go test ./...", "gofmt -l .", "go build -o /m/app .", "/m/app"],
            seed: { context in
                for directory in ["/m", "/m/lib"] { _ = context.mkdir(directory) }
                Self.write(context, path: "/m/go.mod", contents: "module example/m\n\ngo 1.24\n")
                Self.write(
                    context, path: "/m/lib/lib.go",
                    contents: "package lib\n\nimport str \"strings\"\n\nfunc Shout(text string) string { return str.ToUpper(text) }\n")
                Self.write(
                    context, path: "/m/lib/lib_test.go",
                    contents:
                        "package lib\n\nimport tt \"testing\"\n\nfunc TestShout(t *tt.T) {\n\tif Shout(\"a\") != \"A\" {\n\t\tt.Fatal(\"shout\")\n\t}\n}\n")
                Self.write(
                    context, path: "/m/main.go",
                    contents:
                        "package main\n\nimport (\n\tf \"fmt\"\n\n\tl \"example/m/lib\"\n)\n\nfunc main() {\n\ttype greeting struct {\n\t\tText string\n\t}\n\tg := greeting{Text: l.Shout(\"hi\")}\n\tf.Printf(\"%v %T\\n\", g, g)\n}\n")
            })

        #expect(
            shellResultLines(output).joined(separator: "\n")
                == """
                {HI} main.greeting
                ?   \texample/m\t[no test files]
                --- PASS: TestShout
                ok  \texample/m/lib
                {HI} main.greeting
                """)
    }

    @Test func localImportNamesAreChecked() {
        func main(_ imports: String, _ body: String) -> [(path: String, text: String)] {
            [
                Self.library,
                ("main.go", "package main\nimport (\n" + imports + "\n)\nfunc main() {\n" + body + "\n}\n"),
            ]
        }

        #expect(
            moduleDiagnostic(main(" l \"example/m/lib\"", ""))
                == "/m/main.go:3:2: \"example/m/lib\" imported as l and not used")
        #expect(
            moduleDiagnostic(main(" . \"example/m/lib\"", ""))
                == "/m/main.go:3:2: \"example/m/lib\" imported and not used")
        // Imported for its initialization, a package need not be used.
        #expect(moduleDiagnostic(main(" _ \"example/m/lib\"", "")) == nil)
        #expect(
            moduleDiagnostic(main(" f \"fmt\"\n f \"example/m/lib\"", " f.Println(1)"))
                == "/m/main.go:4:2: f redeclared in this block")
        #expect(
            moduleDiagnostic(main(" \"fmt\"\n fmt \"example/m/lib\"", " fmt.Println(1)"))
                == "/m/main.go:4:2: fmt redeclared in this block")
        // Under another name the package's own is not declared.
        #expect(
            moduleDiagnostic(main(" \"fmt\"\n l \"example/m/lib\"", " fmt.Println(l.Hello(), lib.Hello())"))
                == "/m/main.go:7:25: undefined: lib")
        #expect(
            moduleDiagnostic(main(" \"fmt\"\n l \"example/m/lib\"", " fmt.Println(l.Missing())"))
                == "/m/main.go:7:14: undefined: l.Missing")
        #expect(
            moduleDiagnostic(main(" \"fmt\"\n l \"example/m/lib\"", " fmt.Println(l)"))
                == "/m/main.go:7:14: use of package l not in selector")
    }
}
