import Testing
@testable import Swiftix

/// EADDRINUSE semantics for the socket syscall frontend: a second passive TCP
/// open — or a second UDP bind — on a port already in use is rejected instead of
/// silently displacing the incumbent (the bug that let two `httpd` instances both
/// "succeed" on port 80). The port becomes reusable once the last descriptor
/// handle to the owning socket closes (explicit close or process exit), and
/// `SO_REUSEADDR` waives the UDP conflict check.
@Suite("Address in use (EADDRINUSE)")
struct AddressInUseTests {

    // MARK: - TCP passive open

    /// Two passive opens on the same port: the first wins, the second is refused.
    @Test func secondTCPListenOnSamePortFails() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var first = false; var second = true }
        let result = Result()

        kernel.spawn("listeners") { ctx in
            let a = ctx.tcpSocket()!
            result.first = ctx.tcpListen(a, port: 80)
            let b = ctx.tcpSocket()!
            result.second = ctx.tcpListen(b, port: 80)
        }
        loop.advance(by: 0.1)

        #expect(result.first)             // first listener claims the port
        #expect(result.second == false)   // second is refused (EADDRINUSE)
    }

    /// Closing the listening socket frees the port for a fresh passive open.
    @Test func tcpPortReusableAfterListenerClosed() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var first = false; var reused = false }
        let result = Result()

        kernel.spawn("relisten") { ctx in
            let a = ctx.tcpSocket()!
            result.first = ctx.tcpListen(a, port: 80)
            ctx.tcpClose(a)                          // releases the port
            let b = ctx.tcpSocket()!
            result.reused = ctx.tcpListen(b, port: 80)
        }
        loop.advance(by: 0.1)

        #expect(result.first)
        #expect(result.reused)
    }

    /// A server process that listens and then exits releases its port, so a later
    /// server can bind it (the port is not leaked for the kernel's lifetime).
    @Test func tcpPortReleasedWhenServerProcessExits() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var first = false; var afterExit = false }
        let result = Result()

        kernel.spawn("srv1") { ctx in
            let fd = ctx.tcpSocket()!
            result.first = ctx.tcpListen(fd, port: 80)
            ctx.exit(0)                              // closeAll frees the port
        }
        loop.advance(by: 0.1)
        #expect(!kernel.netns.stack.tcpListenerExists(port: 80))

        kernel.spawn("srv2") { ctx in
            let fd = ctx.tcpSocket()!
            result.afterExit = ctx.tcpListen(fd, port: 80)
        }
        loop.advance(by: 0.1)

        #expect(result.first)
        #expect(result.afterExit)
    }

    /// A child that inherits the listener fd and exits must NOT evict the parent's
    /// still-open listener (handle-counted release).
    @Test func inheritedListenerHandleClosingKeepsParentListener() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var listened = false }
        let result = Result()

        kernel.spawn("parent") { ctx in
            let fd = ctx.tcpSocket()!
            result.listened = ctx.tcpListen(fd, port: 80)
            // Child inherits the listener fd, then exits immediately.
            ctx.spawn("child") { child in
                child.exit(0)
            }
            // Parent parks in accept so it stays alive holding the listener.
            ctx.tcpAccept(fd) { _ in }
        }
        loop.advance(by: 0.2)

        #expect(result.listened)
        // Parent still holds the port despite the child's inherited handle closing.
        #expect(kernel.netns.stack.tcpListenerExists(port: 80))
    }

    /// `serveTCP` refuses to start a second server on a busy port: the second
    /// process never reaches its accept loop (its `onListening` never fires).
    @Test func serveTCPRejectsSecondListenerOnSamePort() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Flags { var firstListening = false; var secondListening = false }
        let flags = Flags()

        kernel.spawn("srv1") { (ctx: ProcessContext) async in
            await Programs.serveTCP(ctx, port: 80, onListening: { flags.firstListening = true }) { _, _ in }
        }
        loop.advance(by: 0.1)

        kernel.spawn("srv2") { (ctx: ProcessContext) async in
            await Programs.serveTCP(ctx, port: 80, onListening: { flags.secondListening = true }) { _, _ in }
        }
        loop.advance(by: 0.1)

        #expect(flags.firstListening)
        #expect(flags.secondListening == false)
    }

    // MARK: - UDP bind

    /// Two UDP binds on the same port: the first wins, the second is refused.
    @Test func secondUDPBindOnSamePortFails() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var first = false; var second = true }
        let result = Result()

        kernel.spawn("binders") { ctx in
            let a = ctx.socket()!
            result.first = ctx.bind(a, address: nil, port: 7000)
            let b = ctx.socket()!
            result.second = ctx.bind(b, address: nil, port: 7000)
        }
        loop.advance(by: 0.1)

        #expect(result.first)
        #expect(result.second == false)
    }

    /// `SO_REUSEADDR` waives the UDP conflict check (explicit reuse takes over).
    @Test func udpBindWithReuseAddressWaivesConflict() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var first = false; var reuse = false }
        let result = Result()

        kernel.spawn("binders") { ctx in
            let a = ctx.socket()!
            result.first = ctx.bind(a, address: nil, port: 7000)
            let b = ctx.socket()!
            try? ctx.setSocketOption(b, .reuseAddress, enabled: true)
            result.reuse = ctx.bind(b, address: nil, port: 7000)
        }
        loop.advance(by: 0.1)

        #expect(result.first)
        #expect(result.reuse)
    }

    /// Closing a bound UDP socket frees the port for a fresh bind.
    @Test func udpPortReusableAfterSocketClosed() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var first = false; var reused = false }
        let result = Result()

        kernel.spawn("rebind") { ctx in
            let a = ctx.socket()!
            result.first = ctx.bind(a, address: nil, port: 7000)
            ctx.close(a)
            let b = ctx.socket()!
            result.reused = ctx.bind(b, address: nil, port: 7000)
        }
        loop.advance(by: 0.1)

        #expect(result.first)
        #expect(result.reused)
    }
}
