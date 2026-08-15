import Testing
@testable import Swiftix

/// Filesystem syscalls (`mkdir`, `remove`, `stat`, `open` with truncate) and the
/// commands + `>`/`>>` redirection built on them.
@Suite("Filesystem syscalls + commands")
struct FileSystemTests {

    // MARK: - Syscalls

    @Test func mkdirRemoveAndStat() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var madeDir = false
            var dirStat: FileStat?
            var removed = false
            var afterRemove: FileStat?
        }
        let box = Box()
        kernel.spawn("p") { ctx in
            box.madeDir = ctx.mkdir("/data/sub")     // mkdir -p
            box.dirStat = ctx.stat("/data/sub")
            box.removed = ctx.remove("/data/sub")
            box.afterRemove = ctx.stat("/data/sub")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.madeDir)
        #expect(box.dirStat?.isDirectory == true)
        #expect(box.removed)
        #expect(box.afterRemove == nil)
    }

    @Test func capabilityScopedRenamePreservesOpenFileAndDirectoryMetadata() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box {
            var oldExists = true
            var newContents: [UInt8] = []
            var openHandleContents: [UInt8] = []
            var entries: [FileSystemDirectoryEntry] = []
            var error: SyscallError?
        }
        let box = Box()

        kernel.spawn("rename") { ctx in
            _ = ctx.mkdir("/sandbox/from")
            _ = ctx.mkdir("/sandbox/to")
            do {
                let handle = try ctx.openFile("/sandbox/from/file",
                                              flags: [.create],
                                              access: .readWrite)
                _ = try ctx.writeFile(handle, Array("payload".utf8))
                let scope = FileSystemScope(rootPath: "/sandbox")
                try ctx.rename("from/file", in: scope, to: "to/renamed", in: scope)
                box.oldExists = ctx.stat("/sandbox/from/file") != nil
                let reader = try ctx.openFile("/sandbox/to/renamed", access: .readOnly)
                box.newContents = try ctx.readFile(reader, max: 64)
                try ctx.closeFile(reader)
                _ = ctx.seek(handle, to: 0, whence: 0)
                box.openHandleContents = try ctx.readFile(handle, max: 64)
                try ctx.closeFile(handle)
                box.entries = try ctx.listDirectory("to", in: scope)
            } catch let error as SyscallError {
                box.error = error
            } catch {
                box.error = .invalidArgument
            }
        }
        loop.runUntilIdle()

        #expect(box.error == nil)
        #expect(!box.oldExists)
        #expect(box.newContents == Array("payload".utf8))
        #expect(box.openHandleContents == Array("payload".utf8))
        #expect(box.entries == [FileSystemDirectoryEntry(name: "renamed", type: .regular)])
    }

    @Test func openTruncateDiscardsExistingContents() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var readBack: [UInt8] = []; var size = -1 }
        let box = Box()
        kernel.spawn("p") { ctx in
            let a = ctx.open("/f", create: true)!
            ctx.write(a, Array("first write".utf8))
            ctx.close(a)
            // Reopen with truncate: contents are discarded before writing.
            let b = ctx.open("/f", create: true, truncate: true)!
            ctx.write(b, Array("second".utf8))
            ctx.close(b)
            let r = ctx.open("/f")!
            box.readBack = ctx.read(r, max: 64)
            ctx.close(r)
            box.size = ctx.stat("/f")?.size ?? -1
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.readBack == Array("second".utf8))
        #expect(box.size == 6)
    }

    @Test func seekThenWriteOverwritesAndCanCreateSparseHole() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var overwritten: [UInt8] = []; var sparse: [UInt8] = [] }
        let box = Box()
        kernel.spawn("positional-write") { ctx in
            let fd = ctx.open("/f", create: true, access: .readWrite)!
            ctx.write(fd, Array("abcdef".utf8))
            _ = ctx.seek(fd, to: 2, whence: 0)
            ctx.write(fd, Array("XY".utf8))
            _ = ctx.seek(fd, to: 0, whence: 0)
            box.overwritten = ctx.read(fd, max: 64)

            _ = ctx.seek(fd, to: 8, whence: 0)
            ctx.write(fd, [0x7A])
            _ = ctx.seek(fd, to: 0, whence: 0)
            box.sparse = ctx.read(fd, max: 64)
            ctx.close(fd)
        }
        loop.runUntilIdle()

        #expect(box.overwritten == Array("abXYef".utf8))
        #expect(box.sparse == Array("abXYef".utf8) + [0, 0, 0x7A])
    }

    @Test func appendFlagWritesAtEndAfterSeek() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var contents: [UInt8] = [] }
        let box = Box()

        kernel.spawn("append") { ctx in
            let seed = ctx.open("/f", create: true)!
            ctx.write(seed, Array("one".utf8))
            ctx.close(seed)

            do {
                let fd = try ctx.openFile("/f", flags: [.append], access: .writeOnly)
                _ = ctx.seek(fd, to: 0, whence: 0)
                _ = try ctx.writeFile(fd, Array("two".utf8))
                try ctx.closeFile(fd)
            } catch {
                Issue.record("append open/write failed: \(error)")
            }

            let reader = ctx.open("/f")!
            box.contents = ctx.read(reader, max: 64)
            ctx.close(reader)
        }
        loop.runUntilIdle()

        #expect(box.contents == Array("onetwo".utf8))
    }

    @Test func descriptorReadinessRespectsOpenAccessMode() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var read: IOReadiness = []; var write: IOReadiness = [] }
        let box = Box()
        kernel.spawn("access-readiness") { ctx in
            let seed = ctx.open("/f", create: true)!
            ctx.close(seed)
            let readFD = try? ctx.openFile("/f", flags: [], access: .readOnly)
            let writeFD = try? ctx.openFile("/f", flags: [], access: .writeOnly)
            if let readFD { box.read = ctx.readiness(readFD) ?? [] }
            if let writeFD { box.write = ctx.readiness(writeFD) ?? [] }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.read.contains(.readable))
        #expect(!box.read.contains(.writable))
        #expect(!box.write.contains(.readable))
        #expect(box.write.contains(.writable))
    }

    @Test func statReportsTypeModeAndLstatKeepsFinalSymlink() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var file: FileStat?
            var directory: FileStat?
            var linkStat: FileStat?
            var linkLStat: FileStat?
        }
        let box = Box()

        kernel.spawn("metadata") { ctx in
            _ = ctx.mkdir("/data")
            let fd = ctx.open("/data/file.txt", create: true)!
            ctx.write(fd, Array("body".utf8))
            ctx.close(fd)
            _ = ctx.symlink("/data/file.txt", at: "/data/link.txt")

            box.file = ctx.stat("/data/file.txt")
            box.directory = ctx.stat("/data")
            box.linkStat = ctx.stat("/data/link.txt")
            box.linkLStat = ctx.lstat("/data/link.txt")
        }
        loop.runUntilIdle()

        #expect(box.file?.type == .regular)
        #expect(box.file?.mode == .regularDefault)
        #expect(box.file?.size == 4)
        #expect(box.directory?.type == .directory)
        #expect(box.directory?.mode == .directoryDefault)
        #expect(box.linkStat?.type == .regular)
        #expect(box.linkLStat?.type == .symlink)
        #expect(box.linkLStat?.mode == .symlinkDefault)
        #expect(box.linkLStat?.size == "/data/file.txt".utf8.count)
    }

    @Test func openFlagsCreateExclusiveTruncateAndNonBlocking() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var exclusiveError: SyscallError?
            var readBack: [UInt8] = []
            var flags: FileStatusFlags?
        }
        let box = Box()

        kernel.spawn("open-flags") { ctx in
            do {
                let created = try ctx.openFile("/flags", flags: [.create, .exclusive])
                _ = try ctx.writeFile(created, Array("old".utf8))
                try ctx.closeFile(created)

                do {
                    _ = try ctx.openFile("/flags", flags: [.create, .exclusive])
                } catch let error as SyscallError {
                    box.exclusiveError = error
                } catch {}

                let truncated = try ctx.openFile("/flags", flags: [.truncate, .nonBlocking])
                box.flags = ctx.fileStatusFlags(truncated)
                _ = try ctx.writeFile(truncated, Array("new".utf8))
                try ctx.closeFile(truncated)

                let reader = try ctx.openFile("/flags", flags: [])
                box.readBack = try ctx.readFile(reader, max: 64)
                try ctx.closeFile(reader)
            } catch {}
        }
        loop.runUntilIdle()

        #expect(box.exclusiveError == .fileExists)
        #expect(box.flags?.contains(.nonBlocking) == true)
        #expect(box.readBack == Array("new".utf8))
    }

    // MARK: - Commands via the shell

    @Test func shellMkdirTouchStatRm() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("mkdir /var\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("touch /var/log\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("stat /var/log\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("Size: 0".utf8)))

        pty.writeFromApp(Array("rm /var/log\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("stat /var/log\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("No such file".utf8)))
    }

    @Test func redirectionTruncatesButAppendAdds() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("echo AAAA > /f\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("echo BB > /f\n".utf8)); loop.runUntilIdle()   // truncates
        pty.writeFromApp(Array("cat /f\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("BB".utf8)))
        #expect(!contains(cap.out, Array("AAAA".utf8)))   // old content gone

        pty.writeFromApp(Array("echo CC >> /f\n".utf8)); loop.runUntilIdle()  // appends
        pty.writeFromApp(Array("cat /f\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("CC".utf8)))
    }

    // MARK: - Helpers

    final class Cap: @unchecked Sendable { var out: [UInt8] = [] }

    /// Returns the kernel too so the caller keeps it alive (the shell holds an
    /// `unowned` kernel reference). Echo is off so the capture holds only prompts
    /// and command output, not the typed input.
    private func makeShell() -> (loop: EventLoop, kernel: Kernel, pty: PseudoTerminal, cap: Cap) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        pty.echo = false
        let cap = Cap()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            cap.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        return (loop, kernel, pty, cap)
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
