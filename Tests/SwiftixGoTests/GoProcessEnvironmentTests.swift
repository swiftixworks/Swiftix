/// `os.Getenv`, `LookupEnv`, `Setenv`, `Unsetenv`, `Environ`, `Getpid`,
/// `Hostname`, and `Getwd`.
///
/// A program sees the environment of its Swiftix process, not the host's, so
/// each program here sets what it reads. What each prints is what Go 1.24.5
/// prints for it, and each error pinned with its place is the first one its
/// compiler reports, copied without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go os environment and process functions")
struct GoProcessEnvironmentTests: GoTestHarness {

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

    /// A variable that is set and empty is not one that is not set, a
    /// variable that is set again keeps its place among the others and a new one
    /// goes last, and `Unsetenv` never fails.
    @Test func aProgramSetsReadsAndUnsetsItsVariables() throws {
        #expect(
            try runGoMain(
                """
                show("SWX_NONE")
                fmt.Println(os.Setenv("SWX_A", "1"), os.Setenv("SWX_B", ""), os.Setenv("SWX_C", "x=y z"))
                show("SWX_A")
                show("SWX_B")
                show("SWX_C")
                fmt.Println(mine())
                fmt.Println(os.Setenv("SWX_A", "2"), os.Unsetenv("SWX_B"), os.Unsetenv("SWX_NONE"))
                show("SWX_A")
                show("SWX_B")
                fmt.Println(mine())
                fmt.Println(os.Setenv("SWX_B", "again"))
                fmt.Println(mine())
                """,
                imports: ["fmt", "os", "strings"],
                declarations: #"""
                    func show(key string) {
                        v, ok := os.LookupEnv(key)
                        fmt.Printf("%s: %q %q %v\n", key, os.Getenv(key), v, ok)
                    }

                    func mine() []string {
                        var out []string
                        for _, kv := range os.Environ() {
                            if strings.HasPrefix(kv, "SWX_") {
                                out = append(out, kv)
                            }
                        }
                        return out
                    }
                    """#)
                == """
                SWX_NONE: "" "" false
                <nil> <nil> <nil>
                SWX_A: "1" "1" true
                SWX_B: "" "" true
                SWX_C: "x=y z" "x=y z" true
                [SWX_A=1 SWX_B= SWX_C=x=y z]
                <nil> <nil> <nil>
                SWX_A: "2" "2" true
                SWX_B: "" "" false
                [SWX_A=2 SWX_C=x=y z]
                <nil>
                [SWX_A=2 SWX_C=x=y z SWX_B=again]

                """)
        #expect(
            try runGoMain(
                #"""
                err := os.Setenv("", "v")
                fmt.Println(err, err != nil)
                fmt.Println(os.Setenv("A=B", "v"), os.Setenv("SWX_NUL", "a\x00b"), os.Setenv("SWX\x00", "v"))
                fmt.Println(os.Unsetenv(""), os.Unsetenv("A=B"), os.Getenv("") == "", os.Getenv("A=B") == "")
                _, ok := os.LookupEnv("")
                fmt.Println(ok)
                """#,
                imports: ["fmt", "os", "strings"])
                == """
                setenv: invalid argument true
                setenv: invalid argument setenv: invalid argument setenv: invalid argument
                <nil> <nil> true true
                false

                """)
    }

    /// The answers are the process's, so only their shape is compared.
    @Test func aProgramAsksWhoAndWhereItIs() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(os.Getpid() > 0)
                host, err := os.Hostname()
                fmt.Println(host != "", err)
                dir, err := os.Getwd()
                fmt.Println(strings.HasPrefix(dir, "/"), err)
                """,
                imports: ["fmt", "os", "strings"])
                == "true\ntrue <nil>\ntrue <nil>\n")
    }

    /// Each has its Go type, and `go` and `defer` start them.
    @Test func theFunctionsAreValues() throws {
        #expect(
            try runGoMain(
                #"""
                get, look, set, unset, env := os.Getenv, os.LookupEnv, os.Setenv, os.Unsetenv, os.Environ
                fmt.Printf("%T %T %T %T %T\n", get, look, set, unset, env)
                fmt.Printf("%T %T %T\n", os.Getpid, os.Hostname, os.Getwd)
                fmt.Println(set("SWX_F", "f"), get("SWX_F"))
                fmt.Println(look("SWX_F"))
                fmt.Println(unset("SWX_F"), len(env()) >= 0)
                lookup := map[string]func(string) string{"env": os.Getenv}
                func() {
                    defer os.Setenv("SWX_D", "deferred")
                }()
                fmt.Println(lookup["env"]("SWX_D"))
                """#,
                imports: ["fmt", "os", "strings"])
                == """
                func(string) string func(string) (string, bool) func(string, string) error func(string) error func() []string
                func() int func() (string, error) func() (string, error)
                <nil> f
                f true
                <nil> true
                deferred

                """)
    }

    /// The first error of Go's compiler for each.
    @Test func wrongCallsAreReportedAsGoReportsThem() {
        #expect(
            firstError(
                """
                x := os.Getenv()
                _ = x
                """,
                imports: ["fmt", "os", "strings"])
                == "7:6: not enough arguments in call to os.Getenv\n\thave ()\n\twant (string)")
        #expect(
            firstError(
                """
                x := os.Getenv(1)
                _ = x
                """,
                imports: ["fmt", "os", "strings"])
                == "7:16: cannot use 1 (untyped int constant) as string value in argument to os.Getenv")
        #expect(
            firstError(
                """
                v := os.LookupEnv("A")
                _ = v
                """,
                imports: ["fmt", "os", "strings"])
                == "7:6: assignment mismatch: 1 variable but os.LookupEnv returns 2 values")
        #expect(
            firstError("os.Setenv(\"A\")", imports: ["fmt", "os", "strings"])
                == "7:11: not enough arguments in call to os.Setenv\n\thave (string)\n\twant (string, string)")
        #expect(
            firstError(
                """
                var n int = os.Setenv("A", "B")
                _ = n
                """,
                imports: ["fmt", "os", "strings"])
                == "7:13: cannot use os.Setenv(\"A\", \"B\") (value of interface type error) as int value in variable declaration")
        #expect(
            firstError(
                """
                x := os.Environ(1)
                _ = x
                """,
                imports: ["fmt", "os", "strings"])
                == "7:17: too many arguments in call to os.Environ\n\thave (number)\n\twant ()")
        #expect(
            firstError(
                """
                var s string = os.Getpid()
                _ = s
                """,
                imports: ["fmt", "os", "strings"])
                == "7:16: cannot use os.Getpid() (value of type int) as string value in variable declaration")
        #expect(
            firstError(
                """
                h := os.Hostname()
                _ = h
                """,
                imports: ["fmt", "os", "strings"])
                == "7:6: assignment mismatch: 1 variable but os.Hostname returns 2 values")
    }

    /// The variables are those of the Swiftix process the program runs as,
    /// what it sets its process has, and what it unsets its process has no more.
    @Test func aRunWithAProcessHasItsEnvironment() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    #"""
                    fmt.Println(os.Getenv("GREETING"), os.Getenv("HOME") == "")
                    os.Setenv("ANSWER", "42")
                    os.Unsetenv("GREETING")
                    dir, _ := os.Getwd()
                    host, _ := os.Hostname()
                    fmt.Println(os.Environ(), dir, host, os.Getpid() > 0)
                    """#, imports: ["fmt", "os"]))
        ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var output = ""
        var after: [String: String] = [:]
        kernel.spawn("program") { context in
            context.setenv("GREETING", "hello")
            context.setenv("ZED", "z")
            context.setenv("ALPHA", "a")
            _ = try? GoVirtualMachine().run(executable, eventLoop: loop, processContext: context) {
                output += $0
            }
            after = context.environment
            context.exit(0)
        }
        loop.runUntilIdle()
        #expect(output.hasPrefix("hello true\n[ALPHA=a "))
        #expect(output.hasSuffix(" ZED=z ANSWER=42] / swiftix true\n"))
        #expect(after["ANSWER"] == "42")
        #expect(after["GREETING"] == nil)
    }
}
