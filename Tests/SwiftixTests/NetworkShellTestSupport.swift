@testable import Swiftix

/// A single host with a shell on a PTY, for end-to-end tests of the network
/// built-ins. With `loopback` it has `lo` (127.0.0.1/8) whose egress is fed
/// straight back into its own ingress, so clients and servers on the same host
/// talk over the real TCP/UDP/ICMP paths; with `ethernet` it also has an
/// unattached `eth0` (10.0.0.1/24).
///
/// Everything is driven by logical time: `run` types a line, drains the loop,
/// and optionally advances the clock for commands that sleep or time out.
final class NetworkShell {
    let loop = EventLoop()
    let kernel: Kernel
    let pty = PseudoTerminal()
    private var output: [UInt8] = []

    init(loopback: Bool = true, ethernet: Bool = false) {
        let loop = self.loop
        let kernel = Kernel(loop: loop)
        self.kernel = kernel
        if loopback {
            kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
                address: IPv4Address(127, 0, 0, 1),
                mac: MACAddress("00:00:00:00:00:00")!,
                prefixLength: 8)))
            let lo = kernel.netns.stack.interface(at: 0)!
            lo.onEgress = { [weak kernel, weak lo] frame in
                guard let kernel, let lo else { return }
                loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: lo) }
            }
        }
        if ethernet {
            kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
                address: IPv4Address(10, 0, 0, 1),
                mac: MACAddress("02:00:00:00:00:0a")!,
                prefixLength: 24)))
        }
        let pty = self.pty
        pty.onOutput = { [unowned self, unowned pty] in
            self.output.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        output = []
    }

    /// Type `line`, run it, and return everything the terminal printed for it
    /// (carriage returns removed; includes the echoed line and the next prompt).
    @discardableResult
    func run(_ line: String, advance seconds: Double = 0) -> String {
        output = []
        pty.writeFromApp(Array((line + "\n").utf8))
        loop.runUntilIdle()
        if seconds > 0 {
            loop.advance(by: seconds)
            loop.runUntilIdle()
        }
        return String(decoding: output.filter { $0 != 13 }, as: UTF8.self)
    }

    /// Advance logical time and return whatever was printed meanwhile.
    @discardableResult
    func advance(_ seconds: Double) -> String {
        output = []
        loop.advance(by: seconds)
        loop.runUntilIdle()
        return String(decoding: output.filter { $0 != 13 }, as: UTF8.self)
    }

    /// Wire a second host (10.0.0.2/24) to this host's `eth0` (requires
    /// `ethernet: true`) and return its kernel. Zero latency, static neighbors:
    /// an exchange with the peer completes within one `runUntilIdle`.
    func attachPeer() -> Kernel {
        let peer = Kernel(loop: loop)
        let peerMAC = MACAddress("02:00:00:00:00:0b")!
        let peerIP = IPv4Address(10, 0, 0, 2)
        peer.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(address: peerIP, mac: peerMAC)))
        let index = kernel.netns.stack.interfaceIndex(named: "eth0")!
        let local = kernel.netns.stack.interface(at: index)!
        let remote = peer.netns.stack.interface(at: 0)!
        TestWire.connect(kernel.netns.stack, local, peer.netns.stack, remote, on: loop, latency: 0)
        kernel.netns.stack.configure(.addNeighbor(NetworkNeighborConfiguration(ip: peerIP, mac: peerMAC)))
        peer.netns.stack.configure(.addNeighbor(NetworkNeighborConfiguration(ip: local.address, mac: local.mac)))
        return peer
    }

    /// Start a built-in command as a process on `host` (default: this host),
    /// without a shell — how a test starts a server on the peer.
    func launch(_ argv: [String], on host: Kernel? = nil) {
        let command = CommandRegistry.builtins.resolve(argv[0])!
        switch command.body {
        case let .sync(run): (host ?? kernel).spawn(argv[0], args: argv) { run($0, argv) }
        case let .async(run): (host ?? kernel).spawn(argv[0], args: argv) { await run($0, argv) }
        }
        loop.runUntilIdle()
    }

    /// Create (or replace) a file by running a seeding process in the kernel.
    func write(_ path: String, _ contents: String, on host: Kernel? = nil) {
        (host ?? kernel).spawn("seed") { ctx in
            if let fd = ctx.open(path, create: true, truncate: true) {
                ctx.write(fd, Array(contents.utf8))
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
    }

    /// Read a file's contents back, or `nil` if it does not exist.
    func read(_ path: String) -> String? {
        final class Box { var text: String? }
        let box = Box()
        kernel.spawn("read") { ctx in
            if let fd = ctx.open(path) {
                var bytes: [UInt8] = []
                while true {
                    let chunk = ctx.read(fd, max: 65536)
                    if chunk.isEmpty { break }
                    bytes.append(contentsOf: chunk)
                }
                box.text = String(decoding: bytes, as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
        return box.text
    }
}
