import Testing
@testable import Swiftix

/// Guest power control: `ProcessContext.requestPower` forwards to the host's
/// `Kernel.onPowerRequest`, restricted to uid 0, and the `shutdown`/`reboot`/
/// `poweroff`/`halt` commands report an unsupported host clearly.
@Suite("Guest power requests")
struct PowerRequestTests {

    @Test func commandsForwardRequestsToTheHostHandler() {
        var received: [PowerRequest] = []
        let session = SystemSession()
        session.kernel.onPowerRequest = { received.append($0) }
        #expect(session.lines("shutdown -h now; echo rc=$?") == ["rc=0"])
        #expect(session.lines("shutdown -r now; echo rc=$?") == ["rc=0"])
        #expect(session.lines("reboot; echo rc=$?") == ["rc=0"])
        #expect(session.lines("poweroff; echo rc=$?") == ["rc=0"])
        #expect(session.lines("halt; echo rc=$?") == ["rc=0"])
        #expect(session.lines("shutdown; echo rc=$?") == ["rc=0"])
        #expect(received == [.shutdown, .reboot, .reboot, .shutdown, .shutdown, .shutdown])
        #expect(session.shellIsAlive)            // the core never acts on its own
    }

    @Test func withoutAHandlerCommandsReportUnsupportedHost() {
        let session = SystemSession()
        for command in ["shutdown -h now", "reboot", "poweroff", "halt"] {
            let name = command.split(separator: " ")[0]
            #expect(session.lines("\(command); echo rc=$?")
                    == ["\(name): power control is not supported by this host", "rc=1"])
        }
        #expect(session.run("shutdown +5").contains("shutdown: unsupported argument '+5'"))
    }

    @Test func nonRootCallersAreRefused() {
        var received: [PowerRequest] = []
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.onPowerRequest = { received.append($0) }
        final class Box { var error: SyscallError?; var rootResult: Bool? }
        let box = Box()
        kernel.spawn("user") { ctx in
            ctx.setgid(1000); ctx.setuid(1000)
            do { try ctx.requestPower(.shutdown) } catch { box.error = error as? SyscallError }
        }
        loop.runUntilIdle()
        #expect(box.error == .permissionDenied)
        #expect(received.isEmpty)

        kernel.spawn("root") { ctx in box.rootResult = try? ctx.requestPower(.reboot) }
        loop.runUntilIdle()
        #expect(box.rootResult == true)
        #expect(received == [.reboot])
    }

    @Test func nonRootCommandPrintsMustBeSuperuser() {
        let session = SystemSession()
        session.kernel.onPowerRequest = { _ in Issue.record("must not be delivered") }
        #expect(session.lines("su 1000 reboot; echo rc=$?") == ["reboot: must be superuser", "rc=1"])
    }

    /// The handler runs from a kernel-owned job after the requesting step, so a
    /// host may tear the kernel down from inside it.
    @Test func handlerRunsOutsideTheRequestingStepAndMayShutDown() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var order: [String] = []
        kernel.onPowerRequest = { [unowned kernel] request in
            order.append("handler:\(request)")
            kernel.shutdown()
        }
        kernel.spawn("init") { ctx in
            let delivered = (try? ctx.requestPower(.shutdown)) ?? false
            order.append("returned:\(delivered)")
            ctx.sleep(1000) { ctx.exit(0) }
        }
        loop.runUntilIdle()
        #expect(order == ["returned:true", "handler:shutdown"])
        #expect(kernel.isShutdown)
        #expect(kernel.processCount == 0)
    }

    @Test func requestsAreNotDeliveredAfterShutdown() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var received = 0
        kernel.onPowerRequest = { _ in received += 1 }
        kernel.shutdown()
        #expect(kernel.postPowerRequest(.reboot) == false)
        loop.runUntilIdle()
        #expect(received == 0)
    }
}
