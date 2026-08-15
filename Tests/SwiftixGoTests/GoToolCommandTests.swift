/// go run / build / install commands tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("go run / build / install commands")
struct GoToolCommandTests: GoTestHarness {

    @Test func goCommandRunsPackageAndExposesSwiftixTarget() {
        let output = runShell(
            ["cd /work", "go version", "go env GOOS GOARCH", "go run ."],
            seed: { context in
                _ = context.mkdir("/work")
                Self.write(context, path: "/work/go.mod", contents: "module example/hello\n\ngo 1.24\n")
                Self.write(
                    context, path: "/work/main.go",
                    contents: """
                        package main
                        import "fmt"
                        func message(name string) string { return "hello from " + name }
                        func main() {
                            for index := 0; index < 3; index++ {
                                switch index {
                                case 1:
                                    continue
                                default:
                                    fmt.Println(message("go"))
                                }
                            }
                        }
                        """)
            })

        #expect(output.contains("go version go1.24-swiftix.0.3 swiftix/svm64"))
        #expect(output.contains("swiftix\nsvm64"))
        #expect(output.contains("hello from go"))
    }

    @Test func goRunAndBuiltImagePropagateArgumentsAndExitStatus() {
        let output = runShell(
            [
                "cd /process-abi",
                "go run . 7 from-run",
                "echo run=$?",
                "go build -o app .",
                "./app 9 from-image",
                "echo image=$?",
            ],
            seed: { context in
                _ = context.mkdir("/process-abi")
                Self.write(
                    context,
                    path: "/process-abi/go.mod",
                    contents: "module example/process-abi\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/process-abi/main.go",
                    contents: """
                        package main
                        import "fmt"
                        import "os"
                        import "strconv"
                        func main() {
                            code, err := strconv.Atoi(os.Args[1])
                            if err != nil { os.Exit(2) }
                            fmt.Println(os.Args[2])
                            os.Exit(code)
                        }
                        """)
            })

        #expect(output.contains("from-run\n"))
        #expect(output.contains("run=7"))
        #expect(output.contains("from-image\n"))
        #expect(output.contains("image=9"))
    }

    @Test func goRunBuildsTransitiveLocalImportsAndRejectsImportCycles() {
        let output = runShell(
            [
                "cd /graph",
                "go run .",
                "echo run=$?",
                "cd /cycle",
                "go build .",
                "echo cycle=$?",
            ],
            seed: { context in
                _ = context.mkdir("/graph/lib/a")
                _ = context.mkdir("/graph/lib/b")
                Self.write(
                    context, path: "/graph/go.mod",
                    contents: "module example/graph\n\ngo 1.24\n")
                Self.write(
                    context, path: "/graph/main.go",
                    contents: "package main\nimport \"fmt\"\nimport \"example/graph/lib/a\"\ntype Answerer interface { Answer() int }\ntype answer struct { value int }\nfunc (v answer) Answer() int { return v.value }\nfunc printAnswer(v Answerer) { fmt.Println(v.Answer()) }\nfunc init() { fmt.Println(\"main init\") }\nfunc main() {\n\tdefer fmt.Println(\"done\")\n\tvalues := map[string]int{\"answer\": a.Answer()}\n\tprintAnswer(answer{value: values[\"answer\"]})\n}\n")
                Self.write(
                    context, path: "/graph/lib/a/a.go",
                    contents: "package a\nimport \"fmt\"\nimport \"example/graph/lib/b\"\nfunc init() { fmt.Println(\"a init\") }\nfunc Answer() int { return b.Double(21) }\n")
                Self.write(
                    context, path: "/graph/lib/b/b.go",
                    contents: "package b\nimport \"fmt\"\nfunc init() { fmt.Println(\"b init\") }\nfunc Double(value int) int { return value * 2 }\n")

                _ = context.mkdir("/cycle/a")
                _ = context.mkdir("/cycle/b")
                Self.write(
                    context, path: "/cycle/go.mod",
                    contents: "module example/cycle\n\ngo 1.24\n")
                Self.write(
                    context, path: "/cycle/main.go",
                    contents: "package main\nimport \"example/cycle/a\"\nfunc main() { a.Value() }\n")
                Self.write(
                    context, path: "/cycle/a/a.go",
                    contents: "package a\nimport \"example/cycle/b\"\nfunc Value() int { return b.Value() }\n")
                Self.write(
                    context, path: "/cycle/b/b.go",
                    contents: "package b\nimport \"example/cycle/a\"\nfunc Value() int { return a.Value() }\n")
            })

        #expect(output.contains("b init\na init\nmain init\n42\ndone\n"))
        #expect(output.contains("run=0"))
        #expect(output.contains("import cycle not allowed"))
        #expect(output.contains("cycle=1"))
    }

    @Test func goRunAndBuiltImageExecuteM4StandardPackages() {
        let output = runShell(
            ["cd /m4-tool", "go run .", "go build -o app .", "./app"],
            seed: { context in
                _ = context.mkdir("/m4-tool")
                Self.write(
                    context,
                    path: "/m4-tool/go.mod",
                    contents: "module example/m4-tool\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/m4-tool/main.go",
                    contents: "package main\nimport \"fmt\"\nimport \"runtime\"\nimport \"sync\"\nimport \"time\"\nvar group sync.WaitGroup\nfunc finish() {\n\tdefer group.Done()\n\tselect {\n\tcase <-time.After(time.Millisecond):\n\t}\n\truntime.GC()\n}\nfunc main() {\n\tgroup.Add(1)\n\tgo finish()\n\tgroup.Wait()\n\tfmt.Println(\"m4 ready\")\n}\n")
            })

        #expect(output.split(separator: "\n").filter { $0 == "m4 ready" }.count == 2)
    }

    @Test func goBuildProducesPersistentExecutableForShellAndPipelines() {
        let output = runShell(
            [
                "cd /build",
                "go build -o hello .",
                "echo broken > main.go",
                "./hello",
                "./hello | cat",
            ],
            seed: { context in
                _ = context.mkdir("/build")
                Self.write(
                    context,
                    path: "/build/go.mod",
                    contents: "module example/build\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/build/main.go",
                    contents: """
                        package main
                        import "fmt"
                        func message(name string) string { return "built " + name }
                        func main() { fmt.Println(message("once")) }
                        """)
            })

        #expect(output.split(separator: "\n").filter { $0 == "built once" }.count == 2)
        #expect(!output.contains("command not found"))
    }

    @Test func goBuildUsesGoStyleDefaultOutputName() {
        let output = runShell(
            ["cd /default-name", "go build .", "./default-name"],
            seed: { context in
                _ = context.mkdir("/default-name")
                Self.write(
                    context,
                    path: "/default-name/go.mod",
                    contents: "module example/default-name\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/default-name/main.go",
                    contents: """
                        package main
                        import "fmt"
                        func main() { fmt.Println("default output") }
                        """)
            })

        #expect(output.contains("default output"))
    }

    @Test func goInstallWritesPersistentExecutableToDefaultGoBin() {
        let output = runShell(
            [
                "cd /install-demo",
                "go install .",
                "echo install=$?",
                "echo broken > main.go",
                "/root/go/bin/install-demo",
            ],
            seed: { context in
                _ = context.mkdir("/install-demo")
                Self.write(
                    context,
                    path: "/install-demo/go.mod",
                    contents: "module example/install-demo\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/install-demo/main.go",
                    contents: """
                        package main
                        import "fmt"
                        func main() { fmt.Println("installed once") }
                        """)
            })

        #expect(output.contains("install=0"))
        #expect(output.contains("installed once"))
        #expect(!output.contains("command not found"))
    }

    @Test func goInstallHonorsAbsoluteGoBinAndRejectsRelativeGoBin() {
        let output = runShell(
            [
                "cd /custom-install",
                "GOBIN=/opt/swiftix/bin go install .",
                "/opt/swiftix/bin/custom-install",
                "GOBIN=relative go install .",
                "echo relative=$?",
            ],
            seed: { context in
                _ = context.mkdir("/custom-install")
                Self.write(
                    context,
                    path: "/custom-install/go.mod",
                    contents: "module example/custom-install\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/custom-install/main.go",
                    contents: """
                        package main
                        import "fmt"
                        func main() { fmt.Println("custom GOBIN") }
                        """)
            })

        #expect(output.contains("custom GOBIN"))
        #expect(output.contains("GOBIN must be an absolute path"))
        #expect(output.contains("relative=1"))
    }

    @Test func goBuildReportsInvalidFlagsWithoutCreatingOutput() {
        let output = runShell(
            ["cd /bad-build", "go build -o", "go build -unsupported .", "ls"],
            seed: { context in
                _ = context.mkdir("/bad-build")
                Self.write(
                    context,
                    path: "/bad-build/go.mod",
                    contents: "module example/bad\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/bad-build/main.go",
                    contents: "package main\nfunc main() {}\n")
            })

        #expect(output.contains("flag needs an argument: -o"))
        #expect(output.contains("unsupported build flag -unsupported"))
        #expect(!output.split(separator: "\n").contains { $0 == "bad-build" })
    }
}
