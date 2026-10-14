/// Packages whose name is not the last element of their import path, such
/// as `package api` in `example/m/v2`: Go prints a type by its package's
/// name, which the linker therefore keeps in the package's symbols.

@testable import SwiftixGo
@testable import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go package names")
struct GoPackageNameTests: GoTestHarness {

    private static let shapes = GoPackageSource(
        importPath: "example/m/internal/shapes",
        sources: [
            GoSourceFile(
                path: "/m/internal/shapes/g.go",
                text: """
                    package geometry

                    import "fmt"

                    type Rect struct {
                        W, H int
                    }

                    type Sized interface {
                        Area() int
                    }

                    type Kind int

                    func (r Rect) Area() int { return r.W * r.H }

                    func Local() interface{} {
                        type hidden struct {
                            N int
                        }
                        return hidden{N: 1}
                    }

                    func Describe(v interface{}) string {
                        return fmt.Sprintf("%T", v)
                    }

                    func Must(v interface{}) Rect {
                        return v.(Rect)
                    }
                    """)
        ])

    private static let api = GoPackageSource(
        importPath: "example/m/v2",
        sources: [
            GoSourceFile(
                path: "/m/v2/api.go",
                text: "package api\n\ntype Request struct {\n Path string\n}\n")
        ])

    private func packages(main: String) -> [GoPackageSource] {
        [
            GoPackageSource(
                importPath: "example/m", sources: [GoSourceFile(path: "/m/main.go", text: main)]),
            Self.shapes, Self.api,
        ]
    }

    private func output(main: String) throws -> String {
        let executable = try GoCompiler.compile(packages: packages(main: main), root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    private func diagnostic(main: String) -> String? {
        do {
            _ = try GoCompiler.compile(packages: packages(main: main), root: "example/m")
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.description
        } catch {
            return String(describing: error)
        }
    }

    @Test func aTypePrintsByTheNameOfItsPackage() throws {
        #expect(
            try output(
                main: """
                    package main

                    import (
                        "fmt"

                        geometry "example/m/internal/shapes"
                        "example/m/v2"
                    )

                    func try(v interface{}) {
                        defer func() {
                            fmt.Println(recover())
                        }()
                        fmt.Println(geometry.Must(v))
                    }

                    func main() {
                        r := geometry.Rect{W: 2, H: 3}
                        var s geometry.Sized = r
                        fmt.Printf("%T %T %T %T %v\\n", r, &r, s, geometry.Kind(1), s.Area())
                        fmt.Printf("%T %T %s\\n", []geometry.Rect{r}, map[string]*geometry.Rect{}, geometry.Describe(r))
                        fmt.Printf("%T %v\\n", geometry.Local(), geometry.Local())
                        fmt.Printf("%T %#v\\n", api.Request{}, r)
                        try(api.Request{})
                        try(r)
                    }
                    """)
                == """
                geometry.Rect *geometry.Rect geometry.Rect geometry.Kind 6
                []geometry.Rect map[string]*geometry.Rect geometry.Rect
                geometry.hidden {1}
                api.Request geometry.Rect{W:2, H:3}
                interface conversion: interface {} is api.Request, not geometry.Rect
                {2 3}
                <nil>

                """)
    }

    @Test func aDiagnosticNamesThePackageToo() {
        let imports = "package main\nimport (\n \"fmt\"\n geometry \"example/m/internal/shapes\"\n \"example/m/v2\"\n)\n"
        #expect(
            diagnostic(
                main: imports + "func main() {\n var r geometry.Rect = api.Request{}\n fmt.Println(r)\n}\n")
                == "/m/main.go:8:24: cannot use api.Request{} (value of struct type api.Request) as geometry.Rect value in variable declaration")
        #expect(
            diagnostic(
                main: imports + "func main() {\n fmt.Println(geometry.Missing, api.Request{})\n}\n")
                == "/m/main.go:8:23: undefined: geometry.Missing")
        // Without a name of the file's, the package goes by its own.
        #expect(
            diagnostic(
                main: "package main\nimport (\n \"fmt\"\n \"example/m/v2\"\n)\nfunc main() {\n var n int = api.Request{}\n fmt.Println(n)\n}\n")
                == "/m/main.go:7:14: cannot use api.Request{} (value of struct type api.Request) as int value in variable declaration")
    }

    @Test func theSymbolsOfAPackageCarryItsName() {
        // Only where the path does not say it.
        #expect(GoModuleLinker.symbolPath(importPath: "example/m/lib", packageName: "lib") == "example/m/lib")
        #expect(GoModuleLinker.symbolPath(importPath: "example/m/v2", packageName: "api") == "example/m/v2@api")
        #expect(GoModuleLinker.symbol("example/m/v2@api", "Request") == "example/m/v2@api.Request")

        // The VM and the compiler spell a symbol the same way.
        #expect(GoTypeDescriptor.goName("example/m/lib.Point") == "lib.Point")
        #expect(GoTypeDescriptor.goName("example/m/v2@api.Request") == "api.Request")
        #expect(GoTypeDescriptor.goName("*example/m/v2@api.Request") == "*api.Request")
        #expect(GoTypeDescriptor.goName("example/m/v2@api.hidden\u{B7}3") == "api.hidden")
        #expect(GoTypeDescriptor.goName("point") == "main.point")
        #expect(GoTypeDescriptor.packagePath(ofTypeName: "example/m/v2@api.Request") == "example/m/v2@api")
    }
}
