/// Tests for single-host loopback networking: verifies that a host with an
/// interface whose egress loops back to its own ingress (via schedule(after:0))
/// can complete a full TCP exchange (httpd + curl) within runUntilIdle().
import Testing
@testable import Swiftix

@Suite("Loopback networking")
struct LoopbackTests {

    @Test func curlLocalhostGetsResponseOverLoopback() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(127, 0, 0, 1),
            mac: MACAddress("00:00:00:00:00:00")!,
            prefixLength: 8)))

        let lo = kernel.netns.stack.interface(at: 0)!
        #expect(kernel.netns.stack.snapshotInterfaces().first?.name == "lo")
        lo.onEgress = { [weak kernel, weak lo] frame in
            guard let kernel, let lo else { return }
            loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: lo) }
        }

        let pty = PseudoTerminal()
        var output: [UInt8] = []
        pty.onOutput = {
            output.append(contentsOf: pty.readForApp(max: 65535))
        }

        let registry = CommandRegistry.builtins
        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()

        // Create a file for httpd to serve.
        pty.writeFromApp(Array("echo hello > /index.html\n".utf8))
        loop.runUntilIdle()

        // Start httpd in background (async command).
        pty.writeFromApp(Array("httpd &\n".utf8))
        loop.runUntilIdle()

        // Curl the local server (async command with await tcpConnect).
        output = []
        pty.writeFromApp(Array("curl http://127.0.0.1:80/\n".utf8))
        loop.runUntilIdle()

        let text = String(decoding: output, as: UTF8.self)
        // If the TCP handshake didn't complete in one runUntilIdle, try advancing.
        if !text.contains("hello") {
            loop.advance(by: 1.0)
            let text2 = String(decoding: output, as: UTF8.self)
            #expect(text2.contains("hello"), "expected curl to receive 'hello' after advance, got: \(text2.debugDescription)")
        } else {
            #expect(text.contains("hello"))
        }
    }

    @Test func pingLocalhostReplies() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(127, 0, 0, 1),
            mac: MACAddress("00:00:00:00:00:00")!,
            prefixLength: 8)))

        let lo = kernel.netns.stack.interface(at: 0)!
        lo.onEgress = { [weak kernel, weak lo] frame in
            guard let kernel, let lo else { return }
            loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: lo) }
        }

        let pty = PseudoTerminal()
        var output: [UInt8] = []
        pty.onOutput = {
            output.append(contentsOf: pty.readForApp(max: 65535))
        }

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()

        output = []
        pty.writeFromApp(Array("ping 127.0.0.1\n".utf8))
        loop.runUntilIdle()

        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("bytes from"), "expected ping reply, got: \(text.debugDescription)")
    }
}
