/// How the part of the run-time library that is Go text is linked
/// (`GoSourceLibrary`), and how a function of the library becomes a value:
/// what a program that uses them is made of, and that a program that uses
/// none is made of what it was.
///
/// What the functions do is in `GoSortTests`, `GoSyncOnceTests`, and
/// `GoLibraryFunctionValueTests`. The module below prints what Go 1.24.5
/// prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go source library")
struct GoSourceLibraryTests: GoTestHarness {

    /// The names of the functions of the image `body` compiles to, as the
    /// body of `func main`.
    private func functionNames(
        _ body: String, imports: [String], declarations: String = ""
    ) throws -> Set<String> {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(body, imports: imports, declarations: declarations))
        ])
        return Set(executable.functions.map(\.name))
    }

    /// A program that imports `sort` and `sync` for what the VM has of them
    /// gets nothing of their Go text.
    @Test func aProgramThatUsesNoneGetsNone() throws {
        let names = try functionNames(
            """
            xs := []int{3, 1, 2}
            sort.Ints(xs)
            var mu sync.Mutex
            mu.Lock()
            defer mu.Unlock()
            fmt.Println(xs, strings.ToUpper("x"))
            """, imports: ["fmt", "sort", "strings", "sync"])

        #expect(names == ["main"])
    }

    /// Only the declarations a program names are linked, and those they
    /// reach: a search brings no sort, and a sort of a slice does not bring
    /// the family that sorts an `Interface`.
    @Test func onlyWhatAProgramUsesIsLinked() throws {
        let search = try functionNames(
            "fmt.Println(sort.Search(9, func(i int) bool { return i > 3 }))", imports: ["fmt", "sort"])
        #expect(search.filter { $0.hasPrefix("sort.") } == ["sort.Search"])

        let slice = try functionNames(
            """
            xs := []int{3, 1, 2}
            sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
            fmt.Println(xs)
            """, imports: ["fmt", "sort"])
        #expect(slice.contains("sort.Slice"))
        #expect(slice.contains("sort.quickSortFunc"))
        #expect(slice.contains("sort.heapSortFunc"))
        #expect(!slice.contains("sort.quickSort"))
        #expect(!slice.contains("sort.stableSortFunc"))
        #expect(!slice.contains("sort.Search"))
        #expect(!slice.contains { $0.contains("IntSlice") || $0.contains("sync.") })

        let sorted = try functionNames(
            """
            xs := sort.IntSlice{3, 1, 2}
            sort.Sort(xs)
            fmt.Println(xs)
            """, imports: ["fmt", "sort"])
        #expect(sorted.contains("sort.quickSort"))
        #expect(sorted.contains("sort.IntSlice.Less"))
        #expect(!sorted.contains("sort.quickSortFunc"))
        #expect(!sorted.contains("sort.StringSlice.Less"))
        #expect(!sorted.contains("sort.stableSort"))

        let once = try functionNames(
            """
            var once sync.Once
            once.Do(func() { fmt.Println("once") })
            """, imports: ["fmt", "sync"])
        #expect(once.contains("*sync.Once.Do"))
        #expect(!once.contains { $0.hasPrefix("sort.") })
    }

    /// A library function that is a value is one synthesized function,
    /// however often the program names it; a call by name needs none.
    @Test func aLibraryValueIsOneFunction() throws {
        let called = try functionNames(
            "fmt.Println(strings.ToUpper(\"x\"))", imports: ["fmt", "strings"])
        #expect(called == ["main"])

        let named = try functionNames(
            """
            f, g := strings.ToUpper, strings.ToUpper
            var wg sync.WaitGroup
            wg.Add(1)
            done := wg.Done
            done()
            fmt.Println(f("x"), g("y"), apply(strings.ToUpper))
            """, imports: ["fmt", "strings", "sync"],
            declarations: "func apply(f func(string) string) string { return f(\"z\") }")
        #expect(
            named == [
                "main", "apply", "$native.main.$value.strings.ToUpper",
                "$native.main.$value.sync.WaitGroup.Done",
            ])
    }

    /// The text of a package is its own unit of the program, after the
    /// program's: the files of a program that uses none are not touched.
    @Test func theUnitsOfAProgramThatUsesNoneAreItsOwn() throws {
        let file = try GoNames.resolve([
            try GoParser.parse(
                GoSourceFile(
                    path: "main.go",
                    text: "package main\nimport \"sort\"\nfunc main() { sort.Ints(nil) }\n"))
        ])
        let units = [GoLinkedUnit(importPath: "main", initializerName: "$package.init", files: file)]
        let linked = try GoSourceLibrary.link(units)
        #expect(linked.count == 1)
        #expect(linked[0].files == file)

        let using = try GoNames.resolve([
            try GoParser.parse(
                GoSourceFile(
                    path: "main.go",
                    text: "package main\nimport \"sort\"\nfunc main() { sort.Stable(nil) }\n"))
        ])
        let withText = try GoSourceLibrary.link([
            GoLinkedUnit(importPath: "main", initializerName: "$package.init", files: using)
        ])
        #expect(withText.map(\.importPath) == ["main", "sort"])
        #expect(
            withText[1].files.map(\.path)
                == ["$GOROOT/src/sort/sort.go", "$GOROOT/src/sort/sorting.go"])
        #expect(withText[1].files[1].functions.contains { $0.name == "sort.stableSort" })
        #expect(!withText[1].files[1].functions.contains { $0.name == "sort.quickSort" })
    }

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(_ body: String, imports: [String], declarations: String = "") -> String? {
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

    /// A package that is all Go is linked like one that is Go in part: a
    /// constant brings no function, a variable brings what initializes it,
    /// and a type brings its methods and what they reach, not the package.
    @Test func aPackageIsLinkedByWhatIsReachedOfIt() throws {
        let constants = try functionNames(
            "fmt.Println(http.StatusOK, http.MethodGet)", imports: ["fmt", "net/http"])
        #expect(constants == ["main", "$net/http.init"])

        let discard = try functionNames(
            """
            n, err := io.Discard.Write([]byte("gone"))
            fmt.Println(n, err, io.EOF)
            """, imports: ["fmt", "io"])
        // Go's Discard has a ReadFrom that borrows its buffer from a pool.
        #expect(
            Set(discard) == [
                "main", "$io.init", "io.discard.Write", "io.discard.WriteString",
                "io.discard.ReadFrom", "*sync.Pool.Get", "*sync.Pool.Put",
                "$literal.$GOROOT/src/io/io.go.20244",
            ])

        let header = try functionNames(
            """
            h := http.Header{}
            h.Set("a", "b")
            fmt.Println(h.Get("A"))
            """, imports: ["fmt", "net/http"])
        #expect(header.contains("net/http.Header.Set"))
        #expect(!header.contains("net/http.ListenAndServe"))
        #expect(!header.contains { $0.contains("Server") || $0.contains("Client") })
        #expect(!header.contains { $0.hasPrefix("net/url.") || $0.hasPrefix("io.") })

        let server = try functionNames(
            "http.ListenAndServe(\":80\", nil)", imports: ["net/http"])
        #expect(server.contains("*net/http.Server.Serve"))
        #expect(server.contains("net/url.ParseRequestURI"))
        #expect(!server.contains("net/http.Get"))
        #expect(!server.contains("*net/http.Client.Do"))
    }

    /// The packages of the text are units after the program's, a package
    /// after those it names, and they initialize before the program.
    @Test func thePackagesOfTheTextInitializeFirstInGosOrder() throws {
        let program = try GoNames.resolve([
            try GoParser.parse(
                GoSourceFile(
                    path: "main.go",
                    text: """
                        package main
                        import "net/http"
                        import "sort"
                        var mux = http.DefaultServeMux
                        func main() { sort.Stable(nil) }

                        """))
        ])
        let units = try GoSourceLibrary.link([
            GoLinkedUnit(importPath: "main", initializerName: "$package.init", files: program)
        ])

        let paths = units.map(\.importPath)
        #expect(paths.first == "main")
        #expect(Set(paths.dropFirst()) == ["context", "io", "net/http", "net/url", "sort"])
        #expect(try #require(paths.firstIndex(of: "net/url")) < (try #require(paths.firstIndex(of: "net/http"))))
        #expect(try #require(paths.firstIndex(of: "io")) < (try #require(paths.firstIndex(of: "net/http"))))
        #expect(units.map(\.isLibrary) == [false] + Array(repeating: true, count: units.count - 1))
        #expect(
            GoSourceLibrary.initializationOrder(of: units)
                == Array(1..<units.count) + [0])
    }

    /// A variable of a package of the text has its value when a variable
    /// or an `init` of the program reads it. Expected output is Go's.
    @Test func aVariableOfTheTextIsInitializedBeforeTheProgram() throws {
        #expect(
            try runGoMain(
                """
                n, err := sink.Write([]byte("gone"))
                fmt.Println(n, err, errors.Is(wrapped, http.ErrServerClosed), status, notFound)
                fmt.Println(io.ErrUnexpectedEOF, io.ErrShortWrite, http.ErrBodyNotAllowed)
                fmt.Println(fmt.Sprintf("%T %T %T", sink, mux, http.NoBody))
                fmt.Println(http.DefaultClient == http.DefaultClient, http.MethodGet, http.TimeFormat)
                """,
                imports: ["errors", "fmt", "io", "net/http"],
                declarations: """
                    var (
                        mux      = http.DefaultServeMux
                        sink     = io.Discard
                        closed   = http.ErrServerClosed
                        wrapped  = fmt.Errorf("serve: %w", http.ErrServerClosed)
                        status   = http.StatusTeapot
                        notFound = http.StatusText(http.StatusNotFound)
                    )

                    func init() {
                        fmt.Println("init", mux != nil, mux == http.DefaultServeMux, closed)
                    }
                    """)
                == """
                init true true http: Server closed
                4 <nil> true 418 Not Found
                unexpected EOF short write http: request method or response status code does not allow body
                io.discard *http.ServeMux http.noBody
                true GET Mon, 02 Jan 2006 15:04:05 GMT

                """)
    }

    /// A member written in Go is named as Go names it, whatever the path
    /// of its package and whatever the file calls the package, and what
    /// the text does not export is not there. Each is Go's first error.
    @Test func mistakesNameTheLibraryAsGoDoes() {
        #expect(
            firstError("fmt.Println(http.cleanPath(\"/\"))", imports: ["fmt", "net/http"])
                == "6:18: undefined: http.cleanPath")
        #expect(
            firstError("var d io.discard\nfmt.Println(d)", imports: ["fmt", "io"])
                == "6:10: undefined: io.discard")
        #expect(
            firstError(
                "mux := http.NewServeMux()\nfmt.Println(mux.mu)", imports: ["fmt", "net/http"])
                == "7:17: mux.mu undefined (cannot refer to unexported field mu)")
        #expect(
            firstError("http.HandleFunc(\"/\", 5)", imports: ["net/http"])
                == "5:22: cannot use 5 (untyped int constant) as func(http.ResponseWriter, *http.Request) value in argument to http.HandleFunc")
        #expect(
            firstError(
                "h.HandleFunc(\"/\", 5)", imports: [], declarations: "import h \"net/http\"")
                == "4:19: cannot use 5 (untyped int constant) as func(http.ResponseWriter, *http.Request) value in argument to h.HandleFunc")
        #expect(
            firstError(
                "var u *url.URL = &http.Request{}\nfmt.Println(u)",
                imports: ["fmt", "net/http", "net/url"])
                == "7:18: cannot use &http.Request{} (value of type *http.Request) as *url.URL value in variable declaration")
    }

    /// Two packages of one module that both sort, share a `sync.Once`
    /// across a call, and keep library functions in variables link the
    /// library once.
    @Test func aModuleLinksTheLibraryOnce() throws {
        let packages = [
            GoPackageSource(
                importPath: "example/m",
                sources: [
                    GoSourceFile(
                        path: "/m/main.go",
                        text: """
                            package main

                            import (
                                "fmt"
                                "sort"
                                "strconv"
                                "strings"
                                "sync"

                                "example/m/lib"
                                names "example/m/v2"
                            )

                            var once sync.Once

                            func main() {
                                fmt.Println(lib.Formatters["upper"]("x"), lib.Formatters["trim"](" y ")+"|")
                                lib.Log("logged", 1)
                                r := &lib.Registry{}
                                fmt.Println(r.Entries(), r.Entries(), r.Loads)
                                ranked := lib.Ranked(r.Entries(), func(a, b lib.Entry) bool { return a.Name > b.Name })
                                fmt.Println(ranked)
                                sorter := lib.Sorter()
                                scores := sort.IntSlice{5, 1, 4}
                                sorter(scores)
                                fmt.Println(scores, sort.IsSorted(lib.ByScore(ranked)))
                                fmt.Println(lib.Apply(strings.ToUpper, "a", "b"), lib.Apply(strings.TrimSpace, " q "+strconv.Itoa(7)+" "))
                                ns := names.Names{"b", "c", "a"}
                                fmt.Println(ns.Sorted(), names.Index([]string{"a", "c"}, "b"))
                                once.Do(func() { fmt.Println("main once") })
                                once.Do(func() { fmt.Println("main twice") })
                                fmt.Println(fmt.Sprintf("%T %T %T", sorter, lib.Log, r))
                            }
                            """)
                ]),
            GoPackageSource(
                importPath: "example/m/lib",
                sources: [
                    GoSourceFile(
                        path: "/m/lib/lib.go",
                        text: """
                            package lib

                            import (
                                "fmt"
                                "sort"
                                "strings"
                                "sync"
                            )

                            // Formatters are library functions kept as values of another package.
                            var Formatters = map[string]func(string) string{
                                "upper": strings.ToUpper,
                                "trim":  strings.TrimSpace,
                            }

                            var Log = fmt.Println

                            type Entry struct {
                                Name  string
                                Score int
                            }

                            type ByScore []Entry

                            func (b ByScore) Len() int           { return len(b) }
                            func (b ByScore) Less(i, j int) bool { return b[i].Score < b[j].Score }
                            func (b ByScore) Swap(i, j int)      { b[i], b[j] = b[j], b[i] }

                            type Registry struct {
                                once    sync.Once
                                entries []Entry
                                Loads   int
                            }

                            func (r *Registry) Entries() []Entry {
                                r.once.Do(func() {
                                    r.Loads++
                                    r.entries = []Entry{Entry{"c", 3}, Entry{"a", 1}, Entry{"b", 2}, Entry{"d", 1}}
                                    sort.Stable(ByScore(r.entries))
                                })
                                return r.entries
                            }

                            func Ranked(entries []Entry, less func(a, b Entry) bool) []Entry {
                                out := make([]Entry, len(entries))
                                copy(out, entries)
                                sort.Slice(out, func(i, j int) bool { return less(out[i], out[j]) })
                                return out
                            }

                            func Sorter() func(sort.Interface) { return sort.Sort }

                            func Apply(f func(string) string, values ...string) []string {
                                out := make([]string, 0, len(values))
                                for _, v := range values {
                                    out = append(out, f(v))
                                }
                                return out
                            }
                            """)
                ]),
            GoPackageSource(
                importPath: "example/m/v2",
                sources: [
                    GoSourceFile(
                        path: "/m/v2/names.go",
                        text: """
                            package names

                            import "sort"

                            type Names []string

                            func (n Names) Sorted() Names {
                                out := append(Names{}, n...)
                                sort.Sort(sort.Reverse(sort.StringSlice(out)))
                                return out
                            }

                            func Index(sorted []string, name string) int { return sort.SearchStrings(sorted, name) }
                            """)
                ]),
        ]
        let executable = try GoCompiler.compile(packages: packages, root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output == """
                X y|
                logged 1
                [{a 1} {d 1} {b 2} {c 3}] [{a 1} {d 1} {b 2} {c 3}] 1
                [{d 1} {c 3} {b 2} {a 1}]
                [1 4 5] false
                [A B] [q 7]
                [c b a] 1
                main once
                func(sort.Interface) func(...interface {}) (int, error) *lib.Registry

                """)
        #expect(executable.functions.filter { $0.name == "sort.Slice" }.count == 1)
        #expect(executable.functions.filter { $0.name == "*sync.Once.Do" }.count == 1)
    }
}
