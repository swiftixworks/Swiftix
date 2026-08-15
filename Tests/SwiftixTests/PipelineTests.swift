import Testing
@testable import Swiftix

/// Descriptor inheritance + `dup`/`dup2` primitives and the shell composition
/// they unlock: pipelines (`a | b`) and I/O redirection (`>`, `<`). These are the
/// foundation for "programs compose", the essence of a general Unix-like userland.
@Suite("Pipes, redirection, and fd inheritance")
struct PipelineTests {

    // MARK: - Primitives

    /// A child inherits the parent's open descriptors (POSIX `fork` semantics):
    /// here it reads the read end of a pipe the parent created and wrote to.
    @Test func childInheritsOpenDescriptors() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var got: [UInt8] = [] }
        let box = Box()
        kernel.spawn("parent") { ctx in
            let (read, write) = ctx.pipe()
            ctx.write(write, Array("inherited".utf8))
            ctx.spawn("child") { child in
                box.got = child.read(read, max: 32)   // read end came from the parent
                child.exit(0)
            }
            ctx.close(read)
            ctx.close(write)
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()

        #expect(box.got == Array("inherited".utf8))
    }

    /// `dup2` redirects stdout: after pointing fd 1 at a file, `print` (which
    /// writes fd 1) lands in the file.
    @Test func dup2RedirectsStdoutToFile() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var got: [UInt8] = [] }
        let box = Box()
        kernel.spawn("p") { ctx in
            let fd = ctx.open("/out", create: true)!
            ctx.dup2(fd, onto: 1)          // stdout now writes to /out
            ctx.print("through stdout")
            ctx.close(1)
            let reader = ctx.open("/out")!
            box.got = ctx.read(reader, max: 64)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.got == Array("through stdout".utf8))
    }

    /// A blocked pipe reader observes EOF only once the last writer closes — the
    /// reference-counted-across-processes behavior that makes pipelines correct.
    @Test func pipeReaderSeesEOFAfterWriterExits() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var chunks: [[UInt8]] = []; var sawEOF = false }
        let box = Box()
        kernel.spawn("parent") { ctx in
            let (read, write) = ctx.pipe()
            // Producer child writes then exits (closing its inherited write end).
            ctx.spawn("producer") { child in
                child.write(write, Array("streamed".utf8))
                child.exit(0)
            }
            // Parent drops its own write end so only the producer holds one.
            ctx.close(write)
            func pump() {
                ctx.read(read) { bytes in
                    if bytes.isEmpty { box.sawEOF = true; ctx.exit(0); return }
                    box.chunks.append(bytes)
                    pump()
                }
            }
            pump()
        }
        loop.runUntilIdle()

        #expect(box.chunks.flatMap { $0 } == Array("streamed".utf8))
        #expect(box.sawEOF)
    }

    /// Multiple processes may block on one stream concurrently. One write wakes
    /// enough readers to drain all available bytes instead of overwriting an
    /// earlier reader's callback and leaving it parked forever.
    @Test func onePipeWriteWakesMultipleBlockedReaders() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var chunks: [[UInt8]] = [] }
        let box = Box()
        kernel.spawn("parent") { ctx in
            let pipe = ctx.pipe()
            for name in ["reader-1", "reader-2"] {
                ctx.spawn(name) { child in
                    child.close(pipe.write)
                    child.read(pipe.read, max: 1) { bytes in
                        box.chunks.append(bytes)
                        child.exit(0)
                    }
                }
            }
            ctx.spawn("writer") { child in
                child.close(pipe.read)
                child.write(pipe.write, Array("AB".utf8))
                child.exit(0)
            }
            ctx.close(pipe.read)
            ctx.close(pipe.write)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.chunks == [[65], [66]])
    }

    /// With a handler installed, a write to a readerless pipe reports EPIPE and
    /// delivers SIGPIPE without terminating the caller.
    @Test func readerlessPipeWriteThrowsBrokenPipeAndDeliversSignal() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var caught = false; var error: SyscallError? }
        let box = Box()
        kernel.spawn("writer") { ctx in
            ctx.signal(Signal.sigpipe.rawValue) { box.caught = true }
            let pipe = ctx.pipe()
            ctx.close(pipe.read)
            do {
                _ = try ctx.writeFile(pipe.write, [1])
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.caught)
        #expect(box.error == .brokenPipe)
    }

    /// SIGPIPE's default disposition terminates a process that writes after the
    /// final read end closes.
    @Test func readerlessPipeWriteTerminatesByDefault() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        kernel.spawn("writer") { ctx in
            let pipe = ctx.pipe()
            ctx.close(pipe.read)
            ctx.write(pipe.write, [1])
        }
        loop.runUntilIdle()

        #expect(kernel.processCount == 0)
    }

    // MARK: - Shell pipelines + redirection

    @Test func shellPipesEchoIntoCat() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("echo hello pipe | cat\n".utf8))
        loop.runUntilIdle()

        #expect(contains(cap.out, Array("hello pipe".utf8)))
    }

    @Test func shellThreeStagePipeline() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("echo threaded | cat | cat\n".utf8))
        loop.runUntilIdle()

        #expect(contains(cap.out, Array("threaded".utf8)))
    }

    @Test func shellRedirectsStdoutThenReadsBack() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("echo saved to file > /tmp/note\n".utf8))
        loop.runUntilIdle()
        pty.writeFromApp(Array("cat /tmp/note\n".utf8))
        loop.runUntilIdle()

        #expect(contains(cap.out, Array("saved to file".utf8)))
    }

    @Test func shellRedirectsStdinFromFile() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in
            let fd = ctx.open("/etc/motd", create: true)!
            ctx.write(fd, Array("from stdin file\n".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let pty = PseudoTerminal()
        let cap = capture(pty)
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("cat < /etc/motd\n".utf8))
        loop.runUntilIdle()

        #expect(contains(cap.out, Array("from stdin file".utf8)))
    }

    // MARK: - Helpers

    final class Cap: @unchecked Sendable { var out: [UInt8] = [] }

    private func makeShell() -> (EventLoop, Kernel, PseudoTerminal, Cap) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let cap = capture(pty)
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        return (loop, kernel, pty, cap)
    }

    private func capture(_ pty: PseudoTerminal) -> Cap {
        let cap = Cap()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            cap.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        return cap
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
