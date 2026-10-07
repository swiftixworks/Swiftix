import Testing
@testable import Swiftix

/// Kernel-provided `/dev`: the data devices, the per-process descriptor views,
/// the terminal nodes, and their presence after a filesystem restore.
@Suite("Device nodes")
struct DeviceNodeTests {

    // MARK: - Data devices

    @Test func zeroReadsZerosAndDiscardsWrites() {
        let result = runInFreshKernel { ctx -> ([UInt8], Int, [UInt8]) in
            let fd = ctx.open("/dev/zero")!
            let bytes = ctx.read(fd, max: 16)
            let written = ctx.write(fd, [1, 2, 3])
            let again = ctx.read(fd, max: 4)
            ctx.close(fd)
            return (bytes, written, again)
        }
        #expect(result?.0 == [UInt8](repeating: 0, count: 16))
        #expect(result?.1 == 3)
        #expect(result?.2 == [0, 0, 0, 0])
    }

    @Test func fullRejectsWritesWithNoSpace() {
        let result = runInFreshKernel { ctx -> (Int, SyscallError?, [UInt8], Int) in
            let fd = ctx.open("/dev/full")!
            let plain = ctx.write(fd, [1, 2, 3])
            var thrown: SyscallError?
            do { _ = try ctx.writeFile(fd, [1]) } catch { thrown = error as? SyscallError }
            let empty = (try? ctx.writeFile(fd, [])) ?? -1
            return (plain, thrown, ctx.read(fd, max: 3), empty)
        }
        #expect(result?.0 == 0)
        #expect(result?.1 == .noSpace)
        #expect(result?.2 == [0, 0, 0])
        #expect(result?.3 == 0)
    }

    @Test func randomIsDeterministicForASeed() {
        func sample(seed: UInt64?) -> [UInt8]? {
            runInFreshKernel(configure: { if let seed { $0.seedRandom(seed) } }) { ctx in
                let fd = ctx.open("/dev/urandom")!
                defer { ctx.close(fd) }
                return ctx.read(fd, max: 24)
            }
        }
        let first = sample(seed: 7)
        #expect(first?.count == 24)
        #expect(first == sample(seed: 7))
        #expect(first != sample(seed: 8))
        #expect(sample(seed: nil) == sample(seed: Kernel.defaultRandomSeed))
        #expect(Set(first ?? []).count > 8)       // not a constant stream

        var generator = DeterministicRandom(seed: 7)
        #expect(first == generator.bytes(24))
    }

    /// `/dev/random` and `/dev/urandom` are two names for one kernel stream.
    @Test func randomAndUrandomShareOneStream() {
        let result = runInFreshKernel(configure: { $0.seedRandom(99) }) { ctx -> [UInt8] in
            let random = ctx.open("/dev/random")!
            let urandom = ctx.open("/dev/urandom")!
            return ctx.read(random, max: 8) + ctx.read(urandom, max: 8) + ctx.randomBytes(8)
        }
        var generator = DeterministicRandom(seed: 99)
        #expect(result == generator.bytes(8) + generator.bytes(8) + generator.bytes(8))
    }

    /// A synchronous read-to-EOF loop over an endless device must terminate:
    /// one scheduler step can draw at most `StepReadBudget.bytesPerStep`.
    @Test func endlessDevicesAreBoundedWithinOneSchedulerStep() {
        let total = runInFreshKernel { ctx -> Int in
            let fd = ctx.open("/dev/zero")!
            var total = 0
            while true {
                let chunk = ctx.read(fd, max: 65_536)
                if chunk.isEmpty { break }
                total += chunk.count
            }
            return total
        }
        #expect(total == StepReadBudget.bytesPerStep)
    }

    /// A reader that yields between reads (the blocking frontend) gets a fresh
    /// allowance each step, i.e. an endless stream.
    @Test func endlessDevicesKeepStreamingAcrossSteps() {
        final class Box { var total = 0; var rounds = 0 }
        let box = Box()
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("reader") { ctx in
            let fd = ctx.open("/dev/urandom")!
            func pump() {
                ctx.read(fd, max: StepReadBudget.bytesPerStep) { bytes in
                    box.total += bytes.count
                    box.rounds += 1
                    if box.rounds < 3 { pump() } else { ctx.exit(0) }
                }
            }
            pump()
        }
        loop.runUntilIdle()
        #expect(box.rounds == 3)
        #expect(box.total == 3 * StepReadBudget.bytesPerStep)
    }

    @Test func shellCommandsCanUseTheDataDevices() {
        let session = SystemSession()
        #expect(session.lines("echo discarded > /dev/null; echo rc=$?") == ["rc=0"])
        #expect(session.lines("cat /dev/null; echo rc=$?") == ["rc=0"])
        #expect(session.lines("echo kept > /dev/zero; echo rc=$?") == ["rc=0"])
        // /dev/full reads like /dev/zero (endless), so it is bounded with head.
        #expect(session.lines("head -c 3 /dev/full | od -An -c") == ["  \\0  \\0  \\0"])
        #expect(session.lines("head -c 16 /dev/zero | od -c") == [
            "0000000  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0  \\0",
            "0000020",
        ])
        #expect(session.lines("cat /dev/zero | head -c 5 | wc -c") == ["5"])
        #expect(session.lines("mkdir /tmp; dd if=/dev/urandom of=/tmp/r bs=1k count=4 2> /dev/null; wc -c < /tmp/r") == ["4096"])
    }

    /// A failed write is reported, not swallowed: /dev/full is ENOSPC.
    @Test func writingToAFullDeviceFails() {
        let session = SystemSession()
        #expect(session.lines("echo x > /dev/full; echo rc=$?")
                == ["echo: write error: No space left on device", "rc=1"])
        #expect(session.lines("printf abc > /dev/full; echo rc=$?")
                == ["printf: write error: No space left on device", "rc=1"])
    }

    /// `cat` of an endless device streams until it is interrupted, as on
    /// Linux; Ctrl-C ends it and the shell reports 130.
    @Test func catOfAnEndlessDeviceRunsUntilInterrupted() {
        let session = SystemSession()
        session.pty.onControlC = { [weak session] in
            guard let session else { return }
            session.kernel.interruptProcessGroup(session.pty.foregroundProcessGroupID,
                                                 sessionID: session.shellPID,
                                                 signal: Signal.sigint.rawValue)
        }
        session.pty.writeFromApp(Array("cat /dev/zero > /dev/null\n".utf8))
        #expect(session.loop.runUntilIdle(stepBudget: 2_000) == .budgetExceeded)
        #expect(session.kernel.snapshotProcesses().contains { $0.name == "cat" })
        session.pty.writeFromApp([0x03])
        session.loop.runUntilIdle()
        #expect(!session.kernel.snapshotProcesses().contains { $0.name == "cat" })
        #expect(session.lines("echo rc=$?") == ["rc=130"])
    }

    // MARK: - Per-process descriptor views

    @Test func stdStreamsAreLinksIntoProcSelf() {
        let result = runInFreshKernel { ctx -> [String?] in
            [ctx.readlink("/dev/stdin"), ctx.readlink("/dev/stdout"),
             ctx.readlink("/dev/stderr"), ctx.readlink("/dev/fd")]
        }
        #expect(result == ["/proc/self/fd/0", "/proc/self/fd/1", "/proc/self/fd/2", "/proc/self/fd"])
    }

    @Test func devFdOpensTheSameOpenFileDescription() {
        let result = runInFreshKernel { ctx -> [String] in
            let fd = ctx.open("/data", create: true)!
            ctx.write(fd, Array("abcdef".utf8))
            _ = ctx.seek(fd, to: 0, whence: 0)
            guard let view = ctx.open("/dev/fd/\(fd)") else { return ["open failed"] }
            let first = String(decoding: ctx.read(view, max: 2), as: UTF8.self)
            // Shared offset: the original descriptor continues where the view stopped.
            let second = String(decoding: ctx.read(fd, max: 2), as: UTF8.self)
            ctx.close(fd)
            let third = String(decoding: ctx.read(view, max: 10), as: UTF8.self)
            let listing = ctx.listDirectory("/dev/fd") ?? []
            return [first, second, third, listing.joined(separator: ","), "\(view)"]
        }
        #expect(result?[0] == "ab")
        #expect(result?[1] == "cd")
        #expect(result?[2] == "ef")
        #expect(result?[3] == result?[4])   // only the view remains open
    }

    @Test func devStdoutWritesToTheCallersOwnDescriptor() {
        let session = SystemSession()
        #expect(session.lines("echo through > /dev/stdout") == ["through"])
        session.write("/input", "redirected\n")
        #expect(session.lines("cat /dev/stdin < /input") == ["redirected"])
        #expect(session.lines("cat /dev/fd/0 < /input") == ["redirected"])
        #expect(session.lines("cat /proc/self/fd/0 < /input") == ["redirected"])
        #expect(session.lines("echo err > /dev/stderr") == ["err"])
        #expect(session.run("cat /dev/fd/99").contains("No such file"))
    }

    /// Each process resolves `/dev/stdin` to *its own* descriptor table.
    @Test func descriptorViewsArePerProcess() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var parent = ""; var child = "" }
        let box = Box()
        kernel.spawn("parent") { ctx in
            let pipe = ctx.pipe()
            ctx.write(pipe.write, Array("P".utf8))
            ctx.dup2(pipe.read, onto: 0)
            ctx.spawn("child") { child in
                let own = child.pipe()
                child.write(own.write, Array("C".utf8))
                child.dup2(own.read, onto: 0)
                if let fd = child.open("/dev/stdin") {
                    box.child = String(decoding: child.read(fd, max: 8), as: UTF8.self)
                }
                child.exit(0)
            }
            ctx.wait { _ in
                if let fd = ctx.open("/dev/stdin") {
                    box.parent = String(decoding: ctx.read(fd, max: 8), as: UTF8.self)
                }
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()
        #expect(box.child == "C")
        #expect(box.parent == "P")
    }

    @Test func anotherUsersDescriptorsAreNotOpenable() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var error: SyscallError?; var rootOpened = false }
        let box = Box()
        let owner = kernel.spawn("owner") { ctx in
            _ = ctx.open("/secret", create: true)
            ctx.sleep(100) { ctx.exit(0) }
        }
        loop.advance(by: 0)
        kernel.spawn("intruder") { ctx in
            ctx.setgid(1000); ctx.setuid(1000)
            do { _ = try ctx.openFile("/proc/\(owner)/fd/0", flags: [], access: .readOnly) }
            catch { box.error = error as? SyscallError }
        }
        kernel.spawn("root") { ctx in
            box.rootOpened = (try? ctx.openFile("/proc/\(owner)/fd/0", flags: [], access: .readOnly)) != nil
        }
        loop.advance(by: 0)
        #expect(box.error == .permissionDenied)
        #expect(box.rootOpened)
        kernel.shutdown()
    }

    // MARK: - Terminals

    @Test func devTtyIsTheControllingTerminalEvenWhenStdoutIsRedirected() {
        let session = SystemSession(register: { registry in
            registry.register(Command(name: "viatty", summary: "write to /dev/tty") { ctx, _ in
                guard let fd = try? ctx.openFile("/dev/tty", flags: [], access: .readWrite) else {
                    ctx.fail("no tty", code: 1); return
                }
                ctx.write(fd, Array("on-terminal\n".utf8))
                ctx.print("on-stdout\n")
                ctx.exit(ctx.isATTY(fd) ? 0 : 3)
            })
        })
        #expect(session.lines("viatty > /captured; echo rc=$?") == ["on-terminal", "rc=0"])
        #expect(session.lines("cat /captured") == ["on-stdout"])
        #expect(session.lines("echo hello > /dev/tty") == ["hello"])
        #expect(session.lines("echo hello > /dev/pts/0") == ["hello"])
        #expect(session.lines("ls /dev/pts") == ["0"])
    }

    @Test func devTtyWithoutATerminalIsNoSuchDevice() {
        let error = runInFreshKernel { ctx -> SyscallError? in
            do { _ = try ctx.openFile("/dev/tty", flags: [], access: .readWrite); return nil }
            catch { return error as? SyscallError }
        }
        #expect(error == .noSuchDevice)
    }

    @Test func terminalsGetStablePtsNumbers() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let first = PseudoTerminal()
        let second = PseudoTerminal()
        final class Box { var names: [String?] = [] }
        let box = Box()
        for pty in [first, second] {
            kernel.spawn("sh") { ctx in
                ctx.installStandardIO(pty.slave)
                box.names.append(ctx.controllingTerminalName)
                box.names.append(ctx.terminalName(1))
                ctx.sleep(10) { ctx.exit(0) }
            }
        }
        loop.advance(by: 0)
        #expect(box.names == ["pts/0", "pts/0", "pts/1", "pts/1"])
        #expect(kernel.terminalIndices == [0, 1])
        #expect(kernel.terminalSessions().map(\.terminalIndex) == [0, 1])
        kernel.shutdown()
    }

    // MARK: - Listing and persistence

    @Test func devListsEveryKernelNode() {
        let listing = runInFreshKernel { $0.listDirectory("/dev") }
        #expect(listing == ["fd", "full", "null", "pts/", "random", "stderr", "stdin",
                            "stdout", "tty", "urandom", "zero"])
    }

    /// Devices are kernel-provided: they are never persisted, and they exist
    /// after restoring a snapshot that was captured without them.
    @Test func devicesAreNotPersistedAndReappearAfterRestore() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("w") { ctx in
            let fd = ctx.open("/keep", create: true)!
            ctx.write(fd, [7])
            ctx.close(fd)
        }
        loop.runUntilIdle()
        let snapshot = kernel.snapshotFileSystem()
        guard case let .directory(root) = snapshot.root,
              case let .directory(dev)? = root["dev"] else {
            Issue.record("expected a /dev directory in the snapshot")
            return
        }
        #expect(dev.isEmpty)                       // no devices, links, or pts
        if case let .directory(proc)? = root["proc"] { #expect(proc["sys"] == nil) }

        // A legacy image: only user content, not even a /dev directory.
        let legacy = FilesystemSnapshot(root: .directory(children: ["keep": .file(bytes: [7])]))
        for image in [snapshot, legacy] {
            let restoredLoop = EventLoop()
            let restored = Kernel(loop: restoredLoop)
            #expect(restored.restoreFileSystem(image))
            final class Box { var listing: [String]?; var zero: [UInt8] = []; var link: String?; var host = "" }
            let box = Box()
            restored.spawn("check") { ctx in
                box.listing = ctx.listDirectory("/dev")
                if let fd = ctx.open("/dev/zero") { box.zero = ctx.read(fd, max: 2) }
                box.link = ctx.readlink("/dev/stdin")
                if let fd = ctx.open("/proc/sys/kernel/ostype") {
                    box.host = String(decoding: ctx.read(fd, max: 64), as: UTF8.self)
                }
            }
            restoredLoop.runUntilIdle()
            #expect(box.listing == ["fd", "full", "null", "pts/", "random", "stderr", "stdin",
                                    "stdout", "tty", "urandom", "zero"])
            #expect(box.zero == [0, 0])
            #expect(box.link == "/proc/self/fd/0")
            #expect(box.host == "Swiftix\n")
            // Restore then snapshot is stable: kernel nodes add nothing.
            #expect(restored.snapshotFileSystem() == restored.snapshotFileSystem())
        }

        let roundTripLoop = EventLoop()
        let roundTrip = Kernel(loop: roundTripLoop)
        #expect(roundTrip.restoreFileSystem(snapshot))
        #expect(roundTrip.snapshotFileSystem() == snapshot)
    }

    /// A restored tree that carries a stale regular file where a kernel link
    /// belongs still ends up with the kernel's link.
    @Test func restoreReplacesStaleEntriesAtKernelLinkPaths() {
        let image = FilesystemSnapshot(root: .directory(children: [
            "dev": .directory(children: ["stdin": .file(bytes: [1, 2, 3])]),
        ]))
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        #expect(kernel.restoreFileSystem(image))
        let box = ResultBox<String?>()
        kernel.spawn("check") { ctx in box.value = ctx.readlink("/dev/stdin") }
        loop.runUntilIdle()
        #expect(box.value == "/proc/self/fd/0")
    }
}
