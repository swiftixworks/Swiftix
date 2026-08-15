import Testing
import Foundation
@testable import Swiftix

@Suite("procfs (synthetic /proc files)")
struct ProcFSTests {

    @Test func procNetDevListsInterface() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 5),
                                        mac: MACAddress("02:00:00:00:00:09")!)

        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open("/proc/net/dev") else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()

        #expect(captured.text.contains("eth0"))
        #expect(captured.text.contains("10.0.0.5"))
    }

    @Test func procProcessesListsRunningProcess() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("myproc") { ctx in
            guard let fd = ctx.open("/proc/processes") else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()

        #expect(captured.text.contains("myproc"))
    }

    @Test func procNetUDPListsBoundPort() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let socket = kernel.netns.stack.openUDPSocket()
        socket.bind(address: nil, port: 7000)

        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open("/proc/net/udp") else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()

        #expect(captured.text.contains("7000"))
    }

    /// End to end: type `cat /proc/net/dev` into the shell and see interface info.
    @Test func shellCatReadsProcFile() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 5),
                                        mac: MACAddress("02:00:00:00:00:09")!)

        let pty = PseudoTerminal()
        final class Capture { var out: [UInt8] = [] }
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("cat /proc/net/dev\n".utf8))
        loop.runUntilIdle()

        #expect(String(decoding: captured.out, as: UTF8.self).contains("10.0.0.5"))
    }
}
