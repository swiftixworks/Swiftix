/// Go standard streams and byte-level I/O: `os.Stdin`/`os.Stdout`/`os.Stderr`,
/// `fmt.Fprint*`, `(*os.File).Read`/`Write`/`WriteString`, and
/// `os.ReadFile`/`os.WriteFile`, for file-backed processes and synchronous runs.
///
/// Concurrency: every fixture builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

extension GoProcessSession {
    /// The bytes of guest file `path`, or nil when it cannot be opened.
    func fileBytes(_ path: String) -> [UInt8]? {
        var result: [UInt8]?
        kernel.spawn("read-fixture") { context in
            if let descriptor = context.open(path) {
                var bytes: [UInt8] = []
                while true {
                    let chunk = context.read(descriptor, max: 65_536)
                    if chunk.isEmpty { break }
                    bytes.append(contentsOf: chunk)
                }
                context.close(descriptor)
                result = bytes
            }
            context.exit(0)
        }
        settle()
        return result
    }

    func fileText(_ path: String) -> String? {
        fileBytes(path).map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite("Go standard streams")
struct GoStandardStreamsTests: GoTestHarness {
    /// Every byte value, including sequences that are not valid UTF-8.
    static let binary: [UInt8] = (0..<4).flatMap { _ in (0...255).map { UInt8($0) } }

    // MARK: - Standard error

    @Test func diagnosticsGoToStandardErrorNotStandardOutput() throws {
        let session = try GoProcessSession([
            "/tool": """
                package main
                import "fmt"
                import "os"
                func main() {
                    fmt.Println("result")
                    fmt.Fprintln(os.Stderr, "tool: bad option", 7)
                    fmt.Fprint(os.Stderr, "try", " --help\\n")
                    fmt.Fprintln(os.Stdout, "more")
                    os.Exit(2)
                }
                """,
        ])
        #expect(session.run("/tool >/out 2>/err; echo status=$?") == "status=2")
        #expect(session.fileText("/out") == "result\nmore\n")
        #expect(session.fileText("/err") == "tool: bad option 7\ntry --help\n")
        // Unredirected, both reach the terminal.
        #expect(session.run("/tool 2>/dev/null") == "result\nmore")
        #expect(session.run("/tool >/dev/null") == "tool: bad option 7\ntry --help")
    }

    @Test func fileValuesCanBePassedAndCompared() throws {
        let session = try GoProcessSession([
            "/tool": """
                package main
                import "fmt"
                import "os"
                func report(stream *os.File, text string) {
                    if stream == os.Stderr {
                        fmt.Fprintln(stream, "E:"+text)
                    } else {
                        fmt.Fprintln(stream, "O:"+text)
                    }
                }
                func main() {
                    report(os.Stdout, "one")
                    target := os.Stderr
                    report(target, "two")
                    count, err := os.Stdout.WriteString("three\\n")
                    fmt.Println(count, err == nil)
                }
                """,
        ])
        #expect(session.run("/tool 2>/err") == "O:one\nthree\n6 true")
        #expect(session.fileText("/err") == "E:two\n")
    }

    @Test func synchronousRunWithoutAProcessSendsStandardErrorToItsSink() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "fmt"
                import "os"
                func main() {
                    fmt.Fprintln(os.Stderr, "warn")
                    fmt.Println("out")
                }
                """)
        ])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "warn\nout\n")
    }

    @Test func goRunKeepsStandardErrorSeparate() {
        let output = runShell(
            ["cd /app", "go run . 2>/err", "echo ---", "cat /err"],
            seed: { context in
                _ = context.mkdir("/app")
                Self.write(context, path: "/app/go.mod", contents: "module example/app\n\ngo 1.24\n")
                Self.write(
                    context, path: "/app/main.go",
                    contents: """
                        package main
                        import "fmt"
                        import "os"
                        func main() {
                            fmt.Println("stdout line")
                            fmt.Fprintln(os.Stderr, "stderr line")
                        }
                        """)
            })
        let lines = shellResultLines(output).map(String.init)
        let separator = try! #require(lines.firstIndex(of: "---"))
        #expect(lines[..<separator].contains("stdout line"))
        #expect(!lines[..<separator].contains("stderr line"))
        #expect(lines[separator...].contains("stderr line"))
    }

    // MARK: - Bytes

    @Test func stdoutWriteEmitsArbitraryBytes() throws {
        let session = try GoProcessSession([
            "/emit": """
                package main
                import "fmt"
                import "os"
                func main() {
                    data := []byte{255, 254, 0, 65, 128, 10}
                    count, err := os.Stdout.Write(data)
                    fmt.Fprintln(os.Stderr, count, err == nil)
                }
                """,
        ])
        #expect(session.run("/emit >/out") == "6 true")
        #expect(session.fileBytes("/out") == [255, 254, 0, 65, 128, 10])
    }

    @Test func stdinReadCopiesBinaryInputExactly() throws {
        let session = try GoProcessSession(
            [
                "/copy": """
                    package main
                    import "os"
                    func main() {
                        buffer := make([]byte, 300)
                        for {
                            count, err := os.Stdin.Read(buffer)
                            if count > 0 {
                                os.Stdout.Write(buffer[:count])
                            }
                            if err != nil {
                                break
                            }
                        }
                    }
                    """,
            ],
            files: ["/data": Self.binary])
        #expect(session.run("/copy </data >/out; echo status=$?") == "status=0")
        #expect(session.fileBytes("/out") == Self.binary)
        // Through pipes, between two Go processes.
        #expect(session.run("/copy </data | /copy | /copy >/piped; echo status=$?") == "status=0")
        #expect(session.fileBytes("/piped") == Self.binary)
    }

    @Test func exactByteCountsCanSplitMultiByteCharacters() throws {
        let session = try GoProcessSession(
            [
                "/headc": """
                    package main
                    import "os"
                    func main() {
                        buffer := make([]byte, 4)
                        count, _ := os.Stdin.Read(buffer)
                        os.Stdout.Write(buffer[:count])
                    }
                    """,
            ],
            files: ["/text": Array("ab\u{00e9}\u{00e9}z".utf8)])
        _ = session.run("/headc </text >/out")
        // "ab" plus the two bytes of the first é: an exact byte count.
        #expect(session.fileBytes("/out") == [0x61, 0x62, 0xC3, 0xA9])
        _ = session.run("/headc </dev/null >/empty")
        #expect(session.fileBytes("/empty") == [])
    }

    @Test func readFileAndWriteFileRoundTripBytes() throws {
        let session = try GoProcessSession(
            [
                "/dup": """
                    package main
                    import "fmt"
                    import "os"
                    func main() {
                        data, err := os.ReadFile("/data")
                        if err != nil {
                            fmt.Fprintln(os.Stderr, "dup:", err)
                            os.Exit(1)
                        }
                        fmt.Println(len(data), data[255], data[256])
                        if os.WriteFile("/copy", data, 420) != nil {
                            os.Exit(1)
                        }
                        _, missing := os.ReadFile("/nope")
                        fmt.Println(missing != nil)
                        fmt.Println(os.WriteFile("/no/such/dir/file", data, 420) != nil)
                    }
                    """,
            ],
            files: ["/data": Self.binary])
        #expect(session.run("/dup") == "1024 255 0\ntrue\ntrue")
        #expect(session.fileBytes("/copy") == Self.binary)
    }

    @Test func largeByteWriteWaitsForThePipeReader() throws {
        let session = try GoProcessSession([
            "/blob": """
                package main
                import "fmt"
                import "os"
                func main() {
                    data := make([]byte, 200000)
                    for index := 0; index < len(data); index++ {
                        data[index] = byte(index)
                    }
                    count, err := os.Stdout.Write(data)
                    fmt.Fprintln(os.Stderr, count, err == nil)
                }
                """,
        ])
        #expect(session.run("/blob 2>/err | wc -c").filter { !$0.isWhitespace } == "200000")
        #expect(session.fileText("/err") == "200000 true\n")
    }

    @Test func checksumLoopUsesBytesAndBitwiseOperators() throws {
        // CRC-32 (IEEE) of "123456789" is 0xCBF43926.
        let session = try GoProcessSession(
            [
                "/crc": """
                    package main
                    import "fmt"
                    import "os"
                    func main() {
                        data, _ := os.ReadFile("/digits")
                        crc := 4294967295
                        for index := 0; index < len(data); index++ {
                            crc = crc ^ int(data[index])
                            for bit := 0; bit < 8; bit++ {
                                if crc&1 == 1 {
                                    crc = (crc >> 1) ^ 3988292384
                                } else {
                                    crc = crc >> 1
                                }
                            }
                        }
                        fmt.Println(crc ^ 4294967295)
                    }
                    """,
            ],
            files: ["/digits": Array("123456789".utf8)])
        #expect(session.run("/crc") == "3421780262")
    }
}
