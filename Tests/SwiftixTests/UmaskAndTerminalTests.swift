import Testing
@testable import Swiftix

/// The per-process file-mode creation mask, and the `tty`/`stty` commands over
/// the terminal state the PTY models.
@Suite("umask, tty and stty")
struct UmaskAndTerminalTests {

    private func mode(_ ctx: ProcessContext, _ path: String) -> UInt16? {
        ctx.stat(path)?.mode.rawValue
    }

    // MARK: - umask

    @Test func defaultMaskKeepsHistoricalModes() {
        let result = runInFreshKernel { ctx -> [UInt16?] in
            let fd = ctx.open("/f", create: true)!
            ctx.close(fd)
            ctx.mkdir("/d")
            ctx.mkfifo("/p")
            ctx.symlink("/f", at: "/l")
            return [ctx.fileCreationMask.rawValue, self.mode(ctx, "/f"), self.mode(ctx, "/d"),
                    self.mode(ctx, "/p"), ctx.lstat("/l")?.mode.rawValue]
        }
        #expect(result == [0o022, 0o644, 0o755, 0o644, 0o777])
    }

    @Test func maskIsAppliedToFilesDirectoriesAndFifos() {
        let result = runInFreshKernel { ctx -> [UInt16?] in
            let previous = ctx.umask(FileMode(rawValue: 0o077))
            let fd = ctx.open("/f", create: true)!
            ctx.close(fd)
            ctx.mkdir("/d")
            ctx.mkfifo("/p")
            try? ctx.mkdir("scoped", in: FileSystemScope(rootPath: "/d"))
            let scopedFile = try? ctx.openFile("file", in: FileSystemScope(rootPath: "/d"),
                                               flags: [.create], access: .readWrite)
            let zero = ctx.umask(FileMode(rawValue: 0))
            let open = ctx.open("/open", create: true)!
            ctx.close(open)
            ctx.mkdir("/opendir")
            // Re-opening an existing file never changes its mode.
            ctx.umask(FileMode(rawValue: 0o777))
            let again = ctx.open("/f", create: true)!
            ctx.close(again)
            return [previous.rawValue, self.mode(ctx, "/f"), self.mode(ctx, "/d"), self.mode(ctx, "/p"),
                    self.mode(ctx, "/d/scoped"), scopedFile == nil ? nil : self.mode(ctx, "/d/file"),
                    zero.rawValue, self.mode(ctx, "/open"), self.mode(ctx, "/opendir")]
        }
        #expect(result == [0o022, 0o600, 0o700, 0o600, 0o700, 0o600, 0o077, 0o666, 0o777])
    }

    @Test func maskKeepsOnlyPermissionBitsAndIsInheritedBySpawn() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var parent: UInt16 = 0; var child: UInt16 = 0; var grandchildFile: UInt16? }
        let box = Box()
        kernel.spawn("parent") { ctx in
            ctx.umask(FileMode(rawValue: 0o7027))
            box.parent = ctx.fileCreationMask.rawValue
            ctx.spawn("child") { child in
                box.child = child.fileCreationMask.rawValue
                child.umask(FileMode(rawValue: 0o002))       // does not affect the parent
                child.spawn("grandchild") { grandchild in
                    let fd = grandchild.open("/g", create: true)!
                    grandchild.close(fd)
                    box.grandchildFile = grandchild.stat("/g")?.mode.rawValue
                }
                child.wait { _ in child.exit(0) }
            }
            ctx.wait { _ in
                box.parent = ctx.fileCreationMask.rawValue
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()
        #expect(box.parent == 0o027)
        #expect(box.child == 0o027)
        #expect(box.grandchildFile == 0o664)
    }

    // MARK: - tty / stty

    @Test func ttyNamesTheTerminalOnStandardInput() {
        let session = SystemSession()
        #expect(session.lines("tty; echo rc=$?") == ["/dev/pts/0", "rc=0"])
        #expect(session.lines("tty -s; echo rc=$?") == ["rc=0"])
        session.write("/input", "")
        #expect(session.lines("tty < /input; echo rc=$?") == ["not a tty", "rc=1"])
    }

    @Test func sttyReportsAndSetsWindowSizeAndMode() {
        let session = SystemSession()
        session.pty.windowSize = WindowSize(rows: 40, columns: 132)
        #expect(session.lines("stty size") == ["40 132"])
        #expect(session.lines("stty -a") == ["rows 40; columns 132;", "icanon isig"])
        #expect(session.lines("stty") == ["rows 40; columns 132;", "icanon isig"])
        session.run("stty rows 30 cols 100")
        #expect(session.pty.windowSize == WindowSize(rows: 30, columns: 100))
        // The shell restores canonical mode at each prompt, so observe raw mode
        // within one command line.
        #expect(session.lines("stty raw; stty -a") == ["rows 30; columns 100;", "-icanon -isig"])
        #expect(session.lines("stty raw; stty sane; stty -a").last == "icanon isig")
        #expect(!session.pty.rawMode)
        #expect(session.run("stty bogus").contains("stty: unsupported argument 'bogus'"))
        #expect(session.run("stty rows x").contains("invalid integer argument"))
        session.write("/input", "")
        #expect(session.lines("stty size < /input; echo rc=$?")
                == ["stty: standard input: Inappropriate ioctl for device", "rc=1"])
    }
}
