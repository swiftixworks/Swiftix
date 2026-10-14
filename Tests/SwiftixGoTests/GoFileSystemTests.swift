/// Go `os` file surface beyond the standard streams: `os.Open`, `os.Create`,
/// `os.OpenFile`, `(*os.File).Close`/`Seek`/`ReadAt`/`WriteAt`/`Sync`,
/// `os.Remove`/`os.Rename`/`os.Mkdir`, `io.EOF`, and the `io.Seek*` constants.
///
/// Concurrency: every fixture builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

extension GoProcessSession {
    /// Permission bits of guest file `path`, or nil when it does not exist.
    func fileMode(_ path: String) -> UInt16? {
        var result: UInt16?
        kernel.spawn("stat-fixture") { context in
            result = context.stat(path).map { $0.mode.rawValue & 0o777 }
            context.exit(0)
        }
        settle()
        return result
    }
}

@Suite("Go os file system")
struct GoFileSystemTests: GoTestHarness {

    /// A program with the usual imports, a `check` helper that prints an
    /// error's text or `ok`, and `f`, `err`, `n`, and `position` declared, so
    /// every call in `body` can assign its results with `=`.
    private static func program(_ body: String) -> String {
        """
        package main
        \(goImportLines(["fmt", "io"], usedIn: body).joined(separator: "\n"))
        import "os"
        func check(err error) string {
            if err != nil {
                return err.Error()
            }
            return "ok"
        }
        func main() {
            var f *os.File
            var err error
            var n int
            var position int
            if f != nil || err != nil || n != 0 || position != 0 {
                return
            }
        \(body)
        }
        """
    }

    private func diagnostic(_ body: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(path: "main.go", text: Self.program(body))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    // MARK: - Sequential I/O

    @Test func createWriteReopenAndReadSequentially() throws {
        let session = try GoProcessSession([
            "/seq": Self.program(
                """
                    f, err = os.Create("/log")
                    fmt.Println(check(err), f != nil)
                    n, err = f.WriteString("hello ")
                    fmt.Println(n, check(err))
                    n, err = f.Write([]byte("world\\n"))
                    fmt.Println(n, check(err))
                    fmt.Println(check(f.Sync()), check(f.Close()))

                    f, err = os.Open("/log")
                    fmt.Println(check(err))
                    buffer := make([]byte, 8)
                    total := ""
                    for {
                        n, err = f.Read(buffer)
                        total += string(buffer[:n])
                        if err == io.EOF {
                            break
                        }
                        if err != nil {
                            fmt.Println("read failed:", err)
                            break
                        }
                    }
                    fmt.Print(total)
                    n, err = f.WriteString("x")
                    fmt.Println(n, err != nil)
                    fmt.Println(check(f.Close()))
                """)
        ])

        #expect(
            session.run("/seq") == """
                ok true
                6 ok
                6 ok
                ok ok
                ok
                hello world
                0 true
                ok
                """)
        #expect(session.fileText("/log") == "hello world\n")
    }

    @Test func appendModeAlwaysWritesAtTheEnd() throws {
        let session = try GoProcessSession(
            [
                "/append": Self.program(
                    """
                        for round := 0; round < 2; round++ {
                            f, err = os.OpenFile("/aof", os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
                            if err != nil {
                                fmt.Println(err)
                                return
                            }
                            position, err = f.Seek(0, io.SeekStart)
                            fmt.Println(position, check(err))
                            f.WriteString("SET k v\\n")
                            n, err = f.WriteAt([]byte("x"), 0)
                            fmt.Println(n, check(err))
                            f.Close()
                        }
                    """)
            ],
            files: ["/aof": Array("DEL k\n".utf8)])

        #expect(
            session.run("/append") == """
                0 ok
                0 os: invalid use of WriteAt on file opened with O_APPEND
                0 ok
                0 os: invalid use of WriteAt on file opened with O_APPEND
                """)
        #expect(session.fileText("/aof") == "DEL k\nSET k v\nSET k v\n")
    }

    @Test func truncateAndExclusiveFlagsFollowGo() throws {
        let session = try GoProcessSession(
            [
                "/flags": Self.program(
                    """
                        f, err = os.OpenFile("/old", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
                        fmt.Println(f == nil, check(err))
                        f, err = os.OpenFile("/old", os.O_RDWR|os.O_TRUNC, 0)
                        fmt.Println(check(err))
                        position, err = f.Seek(0, io.SeekEnd)
                        fmt.Println(position)
                        f.Close()
                        f, err = os.OpenFile("/fresh", os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o640)
                        fmt.Println(check(err))
                        f.Close()
                        f, err = os.OpenFile("/old", 3, 0)
                        fmt.Println(check(err))
                        f, err = os.OpenFile("/old", os.O_RDONLY|4096, 0)
                        fmt.Println(check(err))
                        f, err = os.Create("/default")
                        f.Close()
                    """)
            ],
            files: ["/old": Array("previous contents".utf8)])

        #expect(
            session.run("/flags") == """
                true open /old: file exists
                ok
                0
                ok
                open /old: invalid argument
                open /old: invalid argument
                """)
        #expect(session.fileBytes("/old") == [])
        // The requested mode is masked by the default umask 022.
        #expect(session.fileMode("/fresh") == 0o640)
        #expect(session.fileMode("/default") == 0o644)
    }

    // MARK: - Positional I/O

    @Test func seekReadAtAndWriteAtAddressFixedSizePages() throws {
        let session = try GoProcessSession([
            "/pages": Self.program(
                """
                    f, err = os.OpenFile("/db", os.O_RDWR|os.O_CREATE, 0o644)
                    fmt.Println(check(err))
                    page := make([]byte, 16)
                    for number := 0; number < 4; number++ {
                        for i := 0; i < len(page); i++ {
                            page[i] = byte(number*16 + i)
                        }
                        n, err = f.WriteAt(page, number*16)
                        if n != 16 || err != nil {
                            fmt.Println("write failed", n, err)
                        }
                    }
                    // Positional I/O leaves the file offset alone.
                    position, err = f.Seek(0, io.SeekCurrent)
                    fmt.Println(position, check(err))
                    position, err = f.Seek(0, io.SeekEnd)
                    fmt.Println(position, check(err))

                    n, err = f.ReadAt(page, 32)
                    fmt.Println(n, check(err), page[0], page[15])
                    n, err = f.ReadAt(page, 56)
                    fmt.Println(n, err == io.EOF, page[0], page[7], page[8])
                    n, err = f.ReadAt(page, 64)
                    fmt.Println(n, err == io.EOF)
                    n, err = f.ReadAt(page[:0], 0)
                    fmt.Println(n, check(err))
                    var none []byte
                    n, err = f.ReadAt(none, 0)
                    fmt.Println(n, check(err))

                    position, err = f.Seek(-8, io.SeekEnd)
                    fmt.Println(position, check(err))
                    tail := make([]byte, 16)
                    n, err = f.Read(tail)
                    fmt.Println(n, check(err), tail[0], tail[7])
                    position, err = f.Seek(-4, io.SeekCurrent)
                    fmt.Println(position)

                    // A write past the end leaves a zero-filled gap.
                    n, err = f.WriteAt([]byte{9}, 70)
                    fmt.Println(n, check(err))
                    n, err = f.ReadAt(page[:8], 64)
                    fmt.Println(n, err == io.EOF, page[0], page[5], page[6])

                    position, err = f.Seek(-1, io.SeekStart)
                    fmt.Println(position, check(err))
                    position, err = f.Seek(0, 3)
                    fmt.Println(position, check(err))
                    n, err = f.ReadAt(page, -1)
                    fmt.Println(n, check(err))
                    n, err = f.WriteAt(page, -1)
                    fmt.Println(n, check(err))
                    fmt.Println(check(f.Close()))
                """)
        ])

        #expect(
            session.run("/pages") == """
                ok
                0 ok
                64 ok
                16 ok 32 47
                8 true 56 63 40
                0 true
                0 ok
                0 ok
                56 ok
                8 ok 56 63
                60
                1 ok
                7 true 0 0 9
                0 seek /db: invalid argument
                0 seek /db: invalid argument
                0 readat /db: negative offset
                0 writeat /db: negative offset
                ok
                """)
        #expect(session.fileBytes("/db")?.count == 71)
    }

    @Test func readAtFillsASubsliceInPlace() throws {
        let session = try GoProcessSession(
            [
                "/window": Self.program(
                    """
                        f, err = os.Open("/data")
                        buffer := make([]byte, 12)
                        for i := 0; i < len(buffer); i++ {
                            buffer[i] = 46
                        }
                        window := buffer[4:8]
                        n, err = f.ReadAt(window, 2)
                        fmt.Println(n, check(err), string(buffer), string(window), cap(window))
                        f.Close()
                    """)
            ],
            files: ["/data": Array("abcdefghij".utf8)])

        #expect(session.run("/window") == "4 ok ....cdef.... cdef 8")
    }

    // MARK: - Errors and lifetime

    @Test func failuresUseGoPathErrorWording() throws {
        let session = try GoProcessSession(
            [
                "/errors": Self.program(
                    """
                        f, err = os.Open("/nope")
                        fmt.Println(f == nil, check(err))
                        f, err = os.Open("/nope/deeper")
                        fmt.Println(check(err))
                        f, err = os.Create("/missing/dir/file")
                        fmt.Println(check(err))
                        f, err = os.Create("/plain/file")
                        fmt.Println(check(err))
                        f, err = os.OpenFile("/plain", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
                        fmt.Println(check(err))
                        f, err = os.OpenFile("/", os.O_WRONLY, 0)
                        fmt.Println(check(err))
                        f, err = os.Open("/")
                        fmt.Println(f == nil, check(err))

                        var missing *os.File
                        fmt.Println(check(missing.Close()), check(missing.Sync()))
                        position, err = missing.Seek(0, io.SeekStart)
                        fmt.Println(position, check(err))
                        n, err = missing.ReadAt(make([]byte, 1), 0)
                        fmt.Println(n, check(err))
                        n, err = missing.WriteAt(make([]byte, 1), 0)
                        fmt.Println(n, check(err))

                        n, err = os.Stdout.ReadAt(make([]byte, 1), 0)
                        fmt.Println(n, check(err))
                    """)
            ],
            files: ["/plain": []])

        #expect(
            session.run("/errors") == """
                true open /nope: no such file or directory
                open /nope/deeper: no such file or directory
                open /missing/dir/file: no such file or directory
                open /plain/file: not a directory
                open /plain: file exists
                open /: is a directory
                true open /: is a directory
                invalid argument invalid argument
                0 invalid argument
                0 invalid argument
                0 invalid argument
                0 read /dev/stdout: bad file descriptor
                """)
    }

    @Test func aClosedFileStaysClosedWhenItsDescriptorIsReused() throws {
        let session = try GoProcessSession([
            "/reuse": Self.program(
                """
                    first, firstErr := os.Create("/first")
                    first.WriteString("first")
                    alias := first
                    fmt.Println(check(firstErr), check(first.Close()))

                    second, secondErr := os.Create("/second")
                    fmt.Println(check(secondErr), first == second, alias == first)
                    n, err = alias.WriteString("stale")
                    fmt.Println(n, check(err))
                    n, err = first.Write([]byte("stale"))
                    fmt.Println(n, check(err))
                    n, err = first.Read(make([]byte, 4))
                    fmt.Println(n, check(err))
                    fmt.Fprintln(first, "stale")
                    position, err = first.Seek(0, io.SeekStart)
                    fmt.Println(position, check(err))
                    n, err = first.ReadAt(make([]byte, 4), 0)
                    fmt.Println(n, check(err))
                    n, err = first.WriteAt([]byte("stale"), 0)
                    fmt.Println(n, check(err))
                    fmt.Println(check(first.Sync()), check(first.Close()))

                    second.WriteString("second")
                    fmt.Println(check(second.Close()))
                """)
        ])

        #expect(
            session.run("/reuse") == """
                ok ok
                ok false true
                0 write: file already closed
                0 write: file already closed
                0 read: file already closed
                0 seek: file already closed
                0 readat: file already closed
                0 writeat: file already closed
                sync: file already closed close: file already closed
                ok
                """)
        #expect(session.fileText("/first") == "first")
        #expect(session.fileText("/second") == "second")
    }

    @Test func filesLeftOpenAreClosedWhenASynchronousRunEnds() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: Self.program(
                    """
                        first, firstErr := os.Create("/one")
                        second, secondErr := os.Create("/two")
                        second.WriteString("kept")
                        fmt.Fprint(second, "!")
                        fmt.Println(first != second, check(firstErr), check(secondErr))
                    """))
        ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var output = ""
        var descriptorBefore: Int?
        var descriptorAfter: Int?
        var contents: [UInt8] = []

        kernel.spawn("go-host") { context in
            // The lowest free descriptor shows whether the run left any open.
            descriptorBefore = context.open("/probe", create: true)
            if let descriptorBefore { context.close(descriptorBefore) }
            _ = try? GoVirtualMachine().run(executable, eventLoop: loop, processContext: context) {
                output += $0
            }
            descriptorAfter = context.open("/probe")
            if let descriptor = context.open("/two") {
                contents = context.read(descriptor, max: 16)
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        // The process has no standard streams, so the files get descriptors
        // 0 and 1; a file on descriptor 1 is still not the run's stdout.
        #expect(output == "true ok ok\n")
        #expect(descriptorBefore != nil)
        #expect(descriptorAfter == descriptorBefore)
        #expect(contents == Array("kept!".utf8))
    }

    @Test func fileWritesDoNotSpendTheOutputBudget() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: Self.program(
                    """
                        f, err = os.Create("/big")
                        chunk := make([]byte, 256)
                        for round := 0; round < 8; round++ {
                            n, err = f.Write(chunk)
                        }
                        fmt.Fprint(f, "tail")
                        fmt.Println(n, check(err), check(f.Close()))
                        if len(os.Args) > 1 {
                            fmt.Println(string(make([]byte, 256)))
                        }
                    """))
        ])
        let machine = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(maximumOutputBytes: 64))
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var output = ""
        var size: Int?
        var overBudget: GoRuntimeError?

        kernel.spawn("go-host") { context in
            _ = try? machine.run(executable, eventLoop: loop, processContext: context) {
                output += $0
            }
            size = context.stat("/big")?.size
            // Standard output is still limited.
            do {
                try machine.run(
                    executable, eventLoop: loop, processContext: context,
                    arguments: ["main", "print"]
                ) { _ in }
            } catch let error as GoRuntimeError {
                overBudget = error
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        #expect(output == "256 ok ok\n")
        #expect(size == 8 * 256 + 4)
        #expect(overBudget == .resourceLimitExceeded("output bytes"))
    }

    @Test func goRunReachesTheGuestFileSystem() {
        let output = runShell(
            ["cd /work", "go run .", "cat /work/out.txt"],
            seed: { context in
                _ = context.mkdir("/work")
                Self.write(context, path: "/work/go.mod", contents: "module example/files\n")
                Self.write(
                    context,
                    path: "/work/main.go",
                    contents: Self.program(
                        """
                            f, err = os.Create("out.txt")
                            if err != nil {
                                fmt.Println(err)
                                return
                            }
                            f.WriteString("relative path\\n")
                            fmt.Println(check(f.Close()), check(os.Rename("out.txt", "/work/moved.txt")))
                            fmt.Println(check(os.Rename("/work/moved.txt", "out.txt")))
                        """))
            })

        #expect(shellResultLines(output).suffix(3) == ["ok ok", "ok", "relative path"])
    }

    // MARK: - Directory entries

    @Test func removeRenameAndMkdirReportGoErrors() throws {
        let session = try GoProcessSession(
            [
                "/entries": Self.program(
                    """
                        fmt.Println(check(os.Mkdir("/data", 0o750)))
                        fmt.Println(check(os.Mkdir("/data", 0o755)))
                        fmt.Println(check(os.Mkdir("/absent/child", 0o755)))
                        fmt.Println(check(os.Mkdir("/file/child", 0o755)))

                        f, err = os.Create("/data/dump.tmp")
                        f.WriteString("snapshot")
                        fmt.Println(check(os.Rename("/data/dump.tmp", "/data/dump.rdb")))
                        // The open file follows its node across the rename.
                        f.WriteString("!")
                        f.Close()
                        fmt.Println(check(os.Rename("/data/dump.tmp", "/data/other")))
                        fmt.Println(check(os.Rename("/data/dump.rdb", "/absent/dump.rdb")))
                        fmt.Println(check(os.Rename("/file", "/data/dump.rdb")))

                        fmt.Println(check(os.Remove("/data")))
                        fmt.Println(check(os.Remove("/data/dump.rdb")))
                        fmt.Println(check(os.Remove("/data/dump.rdb")))
                        fmt.Println(check(os.Remove("/data")))
                        fmt.Println(check(os.Remove("/")))
                        f, err = os.Open("/data")
                        fmt.Println(check(err))
                    """)
            ],
            files: ["/file": Array("replacement".utf8)])
        let lines = session.run("/entries").split(separator: "\n").map(String.init)

        #expect(
            lines == [
                "ok",
                "mkdir /data: file exists",
                "mkdir /absent/child: no such file or directory",
                "mkdir /file/child: not a directory",
                "ok",
                "rename /data/dump.tmp /data/other: no such file or directory",
                "rename /data/dump.rdb /absent/dump.rdb: no such file or directory",
                "ok",
                "remove /data: directory not empty",
                "ok",
                "remove /data/dump.rdb: no such file or directory",
                "ok",
                "remove /: invalid argument",
                "open /data: no such file or directory",
            ])
        #expect(session.fileText("/file") == nil)
    }

    @Test func mkdirAppliesTheRequestedModeUnderTheUmask() throws {
        let session = try GoProcessSession([
            "/mk": Self.program(
                """
                    fmt.Println(check(os.Mkdir("/private", 0o700)), check(os.Mkdir("/shared", 0o777)))
                """)
        ])

        #expect(session.run("/mk") == "ok ok")
        #expect(session.fileMode("/private") == 0o700)
        #expect(session.fileMode("/shared") == 0o755)
    }

    // MARK: - Without a process

    @Test func aRunWithoutAProcessHasNoFileSystem() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: Self.program(
                    """
                        f, err = os.Open("/etc/hostname")
                        fmt.Println(f == nil, check(err))
                        fmt.Println(check(os.Remove("/x")), check(os.Mkdir("/x", 0o755)))
                        fmt.Println(check(os.Rename("/x", "/y")), check(os.Stdout.Sync()))
                        fmt.Println(io.SeekStart, io.SeekCurrent, io.SeekEnd, io.EOF)
                        fmt.Println(os.O_RDONLY, os.O_WRONLY, os.O_RDWR)
                        fmt.Println(os.O_CREATE, os.O_EXCL, os.O_TRUNC, os.O_APPEND)
                    """))
        ])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output == """
                true open /etc/hostname: no file system
                remove /x: no file system mkdir /x: no file system
                rename /x /y: no file system sync /dev/stdout: no file system
                0 1 2 EOF
                0 1 2
                64 128 512 1024

                """)
    }

    // MARK: - Front end

    @Test func fileCallsAreTypeChecked() {
        #expect(
            diagnostic("g := os.Open(\"/x\")\nfmt.Println(g)")
                == "assignment mismatch: 1 variable but os.Open returns 2 values")
        #expect(
            diagnostic("f, err = os.OpenFile(\"/x\", os.O_RDONLY)\nfmt.Println(f, err)")
                == "not enough arguments in call to os.OpenFile\n\thave (string, int)\n\twant (string, int, int)")
        #expect(
            diagnostic("fmt.Println(os.Stdout.Seek(0))")
                == "not enough arguments in call to os.Stdout.Seek\n\thave (number)\n\twant (int, int)")
        #expect(diagnostic("var count int = os.Stdout.Close()\nfmt.Println(count)") != nil)
        #expect(diagnostic("var count int = io.EOF\nfmt.Println(count)") != nil)
        #expect(diagnostic("var flag string = os.O_APPEND\nfmt.Println(flag)") != nil)
        #expect(diagnostic("fmt.Println(os.Stdout.Truncate(0))") != nil)
        #expect(diagnostic("fmt.Println(io.ErrClosedPipe)") != nil)
        #expect(
            diagnostic(
                """
                    var failure error = io.EOF
                    var whence int = io.SeekEnd
                    flag := os.O_RDWR | os.O_CREATE
                    fmt.Println(failure == io.EOF, whence, flag, check(os.Stdout.Sync()))
                """) == nil)
    }

    @Test func aLocalNamedLikeAPackageShadowsItsMembers() {
        #expect(
            diagnostic(
                """
                    io := 1
                    fmt.Println(io.EOF)
                """) != nil)
    }

    @Test func openModeDecodesGoFlags() {
        #expect(GoFiles.openMode(0)?.access == .readOnly)
        #expect(GoFiles.openMode(1)?.access == .writeOnly)
        #expect(GoFiles.openMode(2)?.access == .readWrite)
        #expect(GoFiles.openMode(0)?.flags == [])
        #expect(
            GoFiles.openMode(0o100 | 0o200 | 0o1000 | 0o2000 | 2)?.flags
                == [.create, .exclusive, .truncate, .append])
        #expect(GoFiles.openMode(3) == nil)
        #expect(GoFiles.openMode(-1) == nil)
        #expect(GoFiles.openMode(0o4000) == nil)
    }

    @Test func splitResolvesAgainstTheWorkingDirectory() {
        #expect(GoFiles.split("/a/b/c", workingDirectory: "/x")! == ("/a/b", "c"))
        #expect(GoFiles.split("c", workingDirectory: "/x/y")! == ("/x/y", "c"))
        #expect(GoFiles.split("c", workingDirectory: "/")! == ("/", "c"))
        #expect(GoFiles.split("./a/../b", workingDirectory: "/x")! == ("/x", "b"))
        #expect(GoFiles.split("../../../top", workingDirectory: "/x")! == ("/", "top"))
        #expect(GoFiles.split("/", workingDirectory: "/x") == nil)
        #expect(GoFiles.split("..", workingDirectory: "/x") == nil)
    }
}
