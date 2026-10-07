/// Front end of the `*os.File` surface: `os.Stdin/Stdout/Stderr`,
/// `fmt.Fprint/Fprintln`, file methods, and `os.ReadFile/WriteFile`.
///
/// These tests stop at the compiled image. They pin the reserved native call
/// names and stack contracts the compiler emits; the host-I/O natives
/// themselves belong to the VM and are covered with it, so nothing here runs
/// a `$fmt.*` or `$os.*` call.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go os.File front end")
struct GoFileInterfaceTests: GoTestHarness {

    private func compile(
        _ body: String,
        declarations: String = ""
    ) throws -> GoExecutable {
        try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(body, imports: ["fmt", "os"], declarations: declarations))
        ])
    }

    /// `name/argumentCount` of every call, spawn, and defer in `function`.
    private func calls(in executable: GoExecutable, function: String = "main") -> [String] {
        (executable.functions.first { $0.name == function }?.instructions ?? []).compactMap {
            switch $0 {
            case .call(let name, let count): return "call \(name)/\(count)"
            case .spawn(let name, let count): return "go \(name)/\(count)"
            case .deferCall(let name, let count): return "defer \(name)/\(count)"
            default: return nil
            }
        }
    }

    @Test func standardFilesAreComparableFileDescriptorValues() throws {
        let output = try runGoMain(
            """
            out := os.Stdout
            var in *os.File = os.Stdin
            fmt.Println(out == os.Stdout, out != os.Stderr, in == os.Stdin, same(out, os.Stderr))
            fmt.Println(pick(true) == os.Stderr, pick(false) == out, out == nil)
            files := []*os.File{os.Stdin, os.Stdout, os.Stderr}
            fmt.Println(len(files), files[2] == os.Stderr)
            """,
            imports: ["fmt", "os"],
            declarations: """
                func same(a *os.File, b *os.File) bool { return a == b }
                func pick(failed bool) *os.File {
                    if failed {
                        return os.Stderr
                    }
                    return os.Stdout
                }
                """)

        #expect(output == "true true true false\ntrue true false\n3 true\n")
    }

    @Test func standardFilesLowerToTheirDescriptorNumbers() throws {
        let executable = try compile("a := os.Stdin\nb := os.Stdout\nc := os.Stderr\nfmt.Println(a, b, c)")
        let pushes = executable.functions[0].instructions.compactMap { instruction -> Int64? in
            if case .push(.int(let value)) = instruction { return value }
            return nil
        }

        #expect(pushes == [0, 1, 2])
    }

    @Test func printingToAFileEmitsTheDescriptorThenTheValues() throws {
        let executable = try compile(
            """
            fmt.Fprint(os.Stderr, "a", 2, true)
            fmt.Fprintln(os.Stdout)
            log(os.Stderr, "x")
            """,
            declarations: "func log(f *os.File, message string) { fmt.Fprintln(f, message, 1) }")

        #expect(calls(in: executable) == ["call $fmt.Fprint/4", "call $fmt.Fprintln/1", "call log/2"])
        #expect(calls(in: executable, function: "log") == ["call $fmt.Fprintln/3"])
        // Stack contract: the descriptor first, then the values in order, and
        // no result to store.
        let log = try #require(executable.functions.first { $0.name == "log" })
        #expect(log.instructions == [
            .push(.int(1)), .store(2), .load(0), .load(1), .load(2),
            .call("$fmt.Fprintln", argumentCount: 3), .return,
        ])
    }

    @Test func fileMethodsEmitReceiverFirstAndStoreBothResults() throws {
        let executable = try compile(
            """
            out := os.Stdout
            n, err := out.Write([]byte("hi"))
            n, err = os.Stderr.WriteString("s")
            buffer := make([]byte, 16)
            n, err = os.Stdin.Read(buffer)
            out.WriteString("discarded")
            fmt.Println(n, err == nil)
            """)

        #expect(calls(in: executable) == [
            "call $conv.stringToBytes/1", "call $os.File.Write/2", "call $os.File.WriteString/2",
            "call $os.File.Read/2", "call $os.File.WriteString/2",
        ])
        // Every call is followed by two stores (err on top, then n), even
        // when the statement discards the results.
        let instructions = executable.functions[0].instructions
        for (index, instruction) in instructions.enumerated() {
            guard case .call(let name, _) = instruction, name.hasPrefix("$os.File.") else { continue }
            guard case .store = instructions[index + 1], case .store = instructions[index + 2] else {
                Issue.record("\(name) does not store two results")
                continue
            }
        }
    }

    @Test func wholeFileCallsEmitTheirReservedNames() throws {
        let executable = try compile(
            """
            data, err := os.ReadFile("/etc/motd")
            failure := os.WriteFile("/tmp/out", data, 420)
            if err != nil {
                fmt.Println(err.Error(), failure == nil, len(data))
            }
            os.WriteFile("/tmp/again", []byte("x"), 384)
            """)

        #expect(calls(in: executable) == [
            "call $os.ReadFile/1", "call $os.WriteFile/3", "call $conv.stringToBytes/1",
            "call $os.WriteFile/3",
        ])
        let image = try GoExecutableImage.encode(executable)
        #expect(try GoExecutableImage.decode(image) == executable)
    }

    @Test func errorResultsHaveTheErrorTypeAndAWorkingErrorMethod() throws {
        // Native errors are `error` values: they can be returned as `error`
        // and expose `Error()`. The method is a synthesized function named
        // after the run-time type name `error` that returns the message.
        let executable = try compile(
            "fmt.Println(load(\"/missing\"))",
            declarations: """
                func load(path string) error {
                    _, err := os.ReadFile(path)
                    if err != nil {
                        fmt.Println(err.Error())
                    }
                    return err
                }
                """)
        let method = try #require(executable.functions.first { $0.name == "error.Error" })
        #expect(method.parameterCount == 1)
        #expect(method.returnCount == 1)
        #expect(method.instructions == [.load(0), .returnValues(count: 1)])

        // Dispatch on a native error value, produced here by `strconv.Atoi`.
        var output = ""
        try GoVirtualMachine().run(
            GoExecutable(
                entryPoint: "main",
                functions: [
                    GoBytecodeFunction(
                        name: "main",
                        localCount: 0,
                        instructions: [
                            .push(.string("x")), .parseInt,
                            .callInterface("Error", argumentCount: 0),
                            .print(argumentCount: 2, newline: true), .return,
                        ]),
                    method,
                ])
        ) { output += $0 }
        #expect(output == "0 strconv.Atoi: parsing \"x\": invalid syntax\n")

        // Programs that never call Error() do not carry the method.
        let plain = try compile("_, err := os.ReadFile(\"/x\")\nfmt.Println(err == nil)")
        #expect(!plain.functions.contains { $0.name == "error.Error" })
    }

    @Test func goAndDeferUseWrappersThatDropTheResults() throws {
        let executable = try compile(
            """
            defer fmt.Fprintln(os.Stderr, "bye", 1)
            defer os.Stdout.WriteString("done")
            go fmt.Fprint(os.Stdout, "x")
            """)

        #expect(calls(in: executable) == [
            "defer $native.main.$fmt.Fprintln.3/3",
            "defer $native.main.$os.File.WriteString.2/2",
            "go $native.main.$fmt.Fprint.2/2",
        ])
        let wrapper = try #require(
            executable.functions.first { $0.name == "$native.main.$os.File.WriteString.2" })
        #expect(wrapper.parameterCount == 2)
        #expect(wrapper.localCount == 4)
        #expect(wrapper.instructions == [
            .load(0), .load(1), .call("$os.File.WriteString", argumentCount: 2),
            .store(3), .store(2), .return,
        ])
    }

    @Test func typeCheckerEnforcesTheFileSurface() {
        func diagnostic(_ body: String, declarations: String = "") -> String? {
            goMainDiagnostic(body, imports: ["fmt", "os"], declarations: declarations)
        }
        #expect(diagnostic("fmt.Fprintln(1, \"x\")") == "cannot use int as *os.File value")
        #expect(diagnostic("fmt.Fprint()") == "wrong number of arguments in call to fmt.Fprint")
        #expect(
            diagnostic("n, err := fmt.Fprintln(os.Stdout, \"x\")\nfmt.Println(n, err)")
                == "fmt.Fprintln results are not supported; call it as a statement")
        #expect(
            diagnostic("n := fmt.Fprint(os.Stdout, \"x\")\nfmt.Println(n)")
                == "fmt.Fprint results are not supported; call it as a statement")
        #expect(
            diagnostic("n := os.Stdout.Write([]byte(\"x\"))\nfmt.Println(n)")
                == "multiple-value Write() in single-value context")
        #expect(
            diagnostic("fmt.Println(os.Stdout.WriteString(\"x\"))")
                == "multiple-value os.File.WriteString() in single-value context")
        #expect(diagnostic("os.Stdout.Write(\"x\")") == "cannot use string as []byte value")
        #expect(diagnostic("os.Stdout.Write([]int{1})") == "cannot use []int as []byte value")
        #expect(diagnostic("os.Stdout.WriteString([]byte(\"x\"))") == "cannot use []byte as string value")
        #expect(
            diagnostic("os.Stdin.Read()") == "wrong number of arguments in call to os.File.Read")
        #expect(diagnostic("os.Stdout.Close()") == "*os.File has no field or method Close")
        #expect(diagnostic("os.Stdout = os.Stderr") == "undefined: os")
        #expect(diagnostic("var n int = os.Stdout\nfmt.Println(n)") == "cannot use *os.File as int value")
        #expect(diagnostic("fmt.Println(os.Stdout + 1)") == "mismatched types *os.File and int")
        #expect(
            diagnostic("f := *os.Stdout\nfmt.Println(f)")
                == "os.File is opaque; a *os.File cannot be dereferenced")
        #expect(
            diagnostic("data := os.ReadFile(\"/x\")\nfmt.Println(data)")
                == "multiple-value ReadFile() in single-value context")
        #expect(
            diagnostic("os.WriteFile(\"/x\", \"text\", 420)") == "cannot use string as []byte value")
        #expect(
            diagnostic("os.WriteFile(\"/x\", []byte(\"t\"))")
                == "wrong number of arguments in call to os.WriteFile")
        #expect(
            diagnostic("var n int = os.WriteFile(\"/x\", []byte(\"t\"), 420)\nfmt.Println(n)")
                == "cannot use interface{...} as int value")
        #expect(diagnostic("os.Open(\"/x\")") == "undefined: os.Open")
        #expect(
            goMainDiagnostic("fmt.Fprintln(os.Stdout, 1)") == "undefined: os")
    }
}
