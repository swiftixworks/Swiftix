import Testing
@testable import Swiftix

/// File-permission enforcement: the kernel checks a non-root process's uid/gid
/// against a file's mode on open (EACCES), while root (uid 0) bypasses the check.
/// Verified both at the syscall boundary (`openFile` throwing `permissionDenied`)
/// and through the shell with `chmod` / `su` / `whoami`.
@Suite("File permissions")
struct PermissionTests {

    // MARK: - Syscall-level enforcement

    @Test func nonRootCannotReadAModeSixHundredFile() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/secret", contents: "classified",
                 mode: [.ownerRead, .ownerWrite])                       // 0600

        final class Result { var error: SyscallError?; var opened = false }
        let result = Result()
        kernel.spawn("user") { ctx in
            ctx.setuid(1000); ctx.setgid(1000)
            do {
                let fd = try ctx.openFile("/secret")
                result.opened = true
                ctx.close(fd)
            } catch let error as SyscallError {
                result.error = error
            } catch {}
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(!result.opened)
        #expect(result.error == .permissionDenied)
    }

    @Test func nonRootCanReadAWorldReadableFile() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/pub", contents: "hi",
                 mode: [.ownerRead, .ownerWrite, .groupRead, .otherRead])  // 0644

        final class Result { var opened = false }
        let result = Result()
        kernel.spawn("user") { ctx in
            ctx.setuid(1000); ctx.setgid(1000)
            if let fd = try? ctx.openFile("/pub") { result.opened = true; ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.opened)
    }

    @Test func nonRootCannotWriteAReadOnlyFile() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/ro", contents: "locked",
                 mode: [.ownerRead, .groupRead, .otherRead])            // 0444

        final class Result { var error: SyscallError? }
        let result = Result()
        kernel.spawn("user") { ctx in
            ctx.setuid(1000); ctx.setgid(1000)
            do {
                _ = try ctx.openFile("/ro", truncate: true)             // open to modify
            } catch let error as SyscallError {
                result.error = error
            } catch {}
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.error == .permissionDenied)
    }

    @Test func readableDescriptorCannotBypassMissingWritePermission() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/ro", contents: "locked",
                 mode: [.ownerRead, .groupRead, .otherRead])

        final class Result {
            var nonThrowingWrite = -1
            var throwingError: SyscallError?
            var contents = ""
        }
        let result = Result()
        kernel.spawn("user") { ctx in
            ctx.setuid(1000); ctx.setgid(1000)
            do {
                let fd = try ctx.openFile("/ro")
                result.nonThrowingWrite = ctx.write(fd, Array("changed".utf8))
                do {
                    _ = try ctx.writeFile(fd, Array("changed".utf8))
                } catch let error as SyscallError {
                    result.throwingError = error
                } catch {}
                ctx.close(fd)
            } catch {}
            if let fd = ctx.open("/ro") {
                result.contents = String(decoding: ctx.read(fd, max: 64), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.nonThrowingWrite == 0)
        #expect(result.throwingError == .badFileDescriptor)
        #expect(result.contents == "locked")
    }

    @Test func explicitWriteOpenChecksWritePermission() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/ro", contents: "locked",
                 mode: [.ownerRead, .groupRead, .otherRead])

        final class Result { var error: SyscallError? }
        let result = Result()
        kernel.spawn("user") { ctx in
            ctx.setuid(1000); ctx.setgid(1000)
            do {
                _ = try ctx.openFile("/ro", flags: [], access: .writeOnly)
            } catch let error as SyscallError {
                result.error = error
            } catch {}
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.error == .permissionDenied)
    }

    @Test func rootBypassesPermissionChecks() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/locked", contents: "x", mode: [])   // 0000

        final class Result { var opened = false }
        let result = Result()
        kernel.spawn("root") { ctx in                                   // uid 0 by default
            if let fd = try? ctx.openFile("/locked") { result.opened = true; ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.opened)
    }

    @Test func ownerPermissionsApplyWhenUidMatches() {
        let (loop, kernel) = boot()
        seedFile(kernel, loop, path: "/mine", contents: "data",
                 mode: [.ownerRead, .ownerWrite], owner: 1000)          // 0600, owned by 1000

        final class Result { var opened = false }
        let result = Result()
        kernel.spawn("user") { ctx in
            ctx.setuid(1000); ctx.setgid(1000)
            if let fd = try? ctx.openFile("/mine") { result.opened = true; ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.opened)                                          // owner may read
    }

    // MARK: - Through the shell (chmod / su / whoami)

    @Test func shellChmodAndSuEnforceReadAccess() {
        let harness = ShellHarness()
        harness.run("printf 'top secret\\n' > /secret")
        harness.run("chmod 600 /secret")
        harness.run("cat /secret > /rootview")            // root reads it
        harness.run("su 1000 cat /secret > /userview")    // uid 1000 cannot
        #expect(harness.contents(of: "/rootview") == "top secret\n")
        #expect(!harness.contents(of: "/userview").contains("top secret"))  // nothing leaked
    }

    @Test func whoamiReflectsEffectiveUid() {
        let harness = ShellHarness()
        harness.run("whoami > /w1")
        harness.run("su 1000 whoami > /w2")
        #expect(harness.contents(of: "/w1") == "root\n")
        #expect(harness.contents(of: "/w2") == "user1000\n")
    }

    @Test func chownSelectsThePermissionTriad() {
        let harness = ShellHarness()
        harness.run("printf 'owned\\n' > /f")
        harness.run("chmod 600 /f")
        harness.run("chown 1000 /f")                      // hand the file to uid 1000
        harness.run("su 1000 cat /f > /out")              // now the owner triad applies
        #expect(harness.contents(of: "/out") == "owned\n")
    }

    // MARK: - Helpers

    private func boot() -> (EventLoop, Kernel) {
        let loop = EventLoop()
        return (loop, Kernel(loop: loop))
    }

    /// Create a file as root with given contents, mode, and owner uid.
    private func seedFile(_ kernel: Kernel, _ loop: EventLoop,
                          path: String, contents: String, mode: FileMode, owner: UInt32 = 0) {
        kernel.spawn("seed") { ctx in
            if let fd = ctx.open(path, create: true, truncate: true) {
                ctx.write(fd, Array(contents.utf8))
                ctx.close(fd)
            }
            _ = ctx.chmod(path, mode: mode)
            if owner != 0 { _ = ctx.chown(path, uid: owner, gid: owner) }
            ctx.exit(0)
        }
        loop.runUntilIdle()
    }

    private final class ShellHarness {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()

        init() {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak pty] in _ = pty?.readForApp(max: 65_535) }
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

        func run(_ line: String) {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }

        func contents(of path: String) -> String {
            final class Box { var text: String? }
            let box = Box()
            kernel.spawn("read") { ctx in
                if let fd = ctx.open(path) {
                    box.text = String(decoding: ctx.read(fd, max: 1 << 20), as: UTF8.self)
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
            return box.text ?? "<missing>"
        }
    }
}
