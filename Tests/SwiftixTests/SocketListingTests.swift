import Testing
@testable import Swiftix

/// `netstat` and `ss`: listening sockets are visible, flags select rows, and
/// `-p` attributes sockets to the processes that hold them.
@Suite("netstat and ss")
struct SocketListingTests {

    private let listener = NetworkSocketSnapshot(kind: .tcpListener, localAddress: nil, localPort: 80,
                                                 remoteAddress: nil, remotePort: 0, state: "LISTEN",
                                                 receiveQueue: 0, sendQueue: 0)
    private let connection = NetworkSocketSnapshot(kind: .tcpConnection, localAddress: IPv4Address(10, 0, 0, 1),
                                                   localPort: 49152, remoteAddress: IPv4Address(10, 0, 0, 2),
                                                   remotePort: 80, state: "ESTABLISHED",
                                                   receiveQueue: 3, sendQueue: 7)
    private let datagram = NetworkSocketSnapshot(kind: .udp, localAddress: nil, localPort: 53,
                                                 remoteAddress: nil, remotePort: 0, state: "UNCONN",
                                                 receiveQueue: 0, sendQueue: 0)

    // MARK: - Renderers

    @Test func ssFollowsLinuxRowSelection() {
        let all = [listener, connection, datagram]
        var selection = BuiltinCommands.SocketSelection()
        let connected = BuiltinCommands.renderSS(all, selection: selection)
        #expect(connected.contains("ESTAB"))
        #expect(!connected.contains("LISTEN"))
        #expect(!connected.contains("UNCONN"))

        selection.listening = true
        let listening = BuiltinCommands.renderSS(all, selection: selection)
        #expect(listening.contains("LISTEN"))
        #expect(listening.contains("UNCONN"))
        #expect(!listening.contains("ESTAB"))

        selection.tcp = true
        #expect(!BuiltinCommands.renderSS(all, selection: selection).contains("udp"))

        selection = BuiltinCommands.SocketSelection()
        selection.all = true
        selection.udp = true
        let udpOnly = BuiltinCommands.renderSS(all, selection: selection)
        #expect(udpOnly.contains("udp"))
        #expect(!udpOnly.contains("tcp"))
    }

    @Test func ssColumnsAndStates() {
        var selection = BuiltinCommands.SocketSelection()
        selection.all = true
        let lines = BuiltinCommands.renderSS([listener, connection], selection: selection)
            .split(separator: "\n").map(String.init)
        #expect(lines[0].split(separator: " ").map(String.init)
                == ["Netid", "State", "Recv-Q", "Send-Q", "Local", "Address:Port", "Peer", "Address:Port"])
        #expect(lines[1].split(separator: " ").map(String.init) == ["tcp", "LISTEN", "0", "0", "0.0.0.0:80", "0.0.0.0:*"])
        #expect(lines[2].split(separator: " ").map(String.init)
                == ["tcp", "ESTAB", "3", "7", "10.0.0.1:49152", "10.0.0.2:80"])
        #expect(BuiltinCommands.renderSS([], selection: selection, header: false) == "")
    }

    @Test func stateSpellingsDifferPerTool() {
        let closing = NetworkSocketSnapshot(kind: .tcpConnection, localAddress: nil, localPort: 1,
                                            remoteAddress: IPv4Address(1, 1, 1, 1), remotePort: 2,
                                            state: "FIN_WAIT_1", receiveQueue: 0, sendQueue: 0)
        #expect(BuiltinCommands.ssState(closing) == "FIN-WAIT-1")
        #expect(BuiltinCommands.netstatState(closing) == "FIN_WAIT1")
        #expect(BuiltinCommands.ssState(datagram) == "UNCONN")
        #expect(BuiltinCommands.netstatState(datagram) == "")
    }

    @Test func netstatListeningOnlyAndProcessColumn() {
        var selection = BuiltinCommands.SocketSelection()
        selection.listening = true
        selection.processes = true
        let owners = [BuiltinCommands.socketOwnerKey(listener): [
            BuiltinCommands.SocketOwner(pid: 9, name: "httpd", descriptor: 3),
            BuiltinCommands.SocketOwner(pid: 4, name: "httpd", descriptor: 3),
        ]]
        let text = BuiltinCommands.renderNetstat([listener, connection, datagram], selection: selection, owners: owners)
        #expect(text.contains("Active Internet connections (only servers)"))
        #expect(text.contains("tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      4/httpd"))
        #expect(text.contains("udp        0      0 0.0.0.0:53              0.0.0.0:*                           -"))
        #expect(!text.contains("ESTABLISHED"))
    }

    @Test func descriptorTableParsing() {
        let text = """
            FD TYPE ACCESS FLAGS OFFSET SIZE DETAIL
            0 tty rw - - - pty-slave
            3 tcp rw - - - listen=:80
            4 tcp rw - - - local=:49152,remote=10.0.0.2:80,state=ESTABLISHED
            5 udp rw - - - local=:53
            6 udp rw - - - unbound
            """
        let keys = BuiltinCommands.socketKeys(inDescriptorTable: text)
        #expect(keys.map(\.key) == ["tcp listen=:80", "tcp local=:49152,remote=10.0.0.2:80", "udp local=:53", "udp unbound"])
        #expect(keys.map(\.descriptor) == [3, 4, 5, 6])
        #expect(keys[0].key == BuiltinCommands.socketOwnerKey(listener))
        #expect(keys[1].key == BuiltinCommands.socketOwnerKey(connection))
        #expect(keys[2].key == BuiltinCommands.socketOwnerKey(datagram))
    }

    // MARK: - Through the shell

    /// The reported gap: after `httpd &`, the listener must be visible.
    @Test func listeningServerIsVisible() {
        let sh = NetworkShell()
        sh.run("httpd &")
        for line in ["netstat", "netstat -tlnp", "netstat -an", "netstat -tln"] {
            let out = sh.run(line)
            #expect(out.contains("0.0.0.0:80"), "\(line): \(out)")
            #expect(out.contains("LISTEN"), "\(line): \(out)")
        }
        #expect(sh.run("netstat -u").contains("0.0.0.0:80") == false)
        let ss = sh.run("ss -tln")
        #expect(ss.contains("Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port"))
        #expect(ss.contains("tcp   LISTEN 0      0              0.0.0.0:80         0.0.0.0:*"))
        #expect(!sh.run("ss -t").contains("LISTEN"))   // like Linux: connected sockets only
    }

    @Test func boundUDPPortIsVisible() {
        let sh = NetworkShell()
        sh.run("dnsd &")
        #expect(sh.run("netstat -uln").contains("udp        0      0 0.0.0.0:53              0.0.0.0:*"))
        #expect(sh.run("ss -uln").contains("UNCONN"))
        #expect(sh.run("ss -uln").contains("0.0.0.0:53"))
        #expect(!sh.run("ss -tln").contains("0.0.0.0:53"))
    }

    @Test func processAttributionComesFromDescriptorTables() throws {
        let sh = NetworkShell()
        sh.run("httpd 8080 &")
        sh.run("dnsd &")
        let pid = try #require(sh.kernel.snapshotProcesses().first { $0.name == "httpd" }?.pid)
        #expect(sh.run("netstat -tlnp").contains("LISTEN      \(pid)/httpd"))
        #expect(sh.run("ss -tlnp").contains("users:((\"httpd\",pid=\(pid),fd=3))"))
        #expect(sh.run("ss -ulnp").contains("users:((\"dnsd\","))
        #expect(!sh.run("ss -tln").contains("users:"))
    }

    @Test func establishedConnectionShowsBothEndpoints() {
        let sh = NetworkShell()
        sh.run("tcpecho 7 &")
        sh.run("nc -d 127.0.0.1 7 &")
        let ss = sh.run("ss -tn")
        #expect(ss.contains("ESTAB"))
        #expect(ss.contains("127.0.0.1:7"))
        let netstat = sh.run("netstat -tan")
        #expect(netstat.contains("ESTABLISHED"))
        #expect(netstat.contains("127.0.0.1:7"))
        #expect(netstat.contains("LISTEN"))
    }

    @Test func netstatRoutesAndInterfaces() {
        let sh = NetworkShell(ethernet: true)
        sh.run("ip route add default via 10.0.0.254")
        let routes = sh.run("netstat -rn")
        #expect(routes.contains("Kernel IP routing table"))
        #expect(routes.contains("Destination     Gateway         Genmask         Flags Iface"))
        #expect(routes.contains("0.0.0.0         10.0.0.254      0.0.0.0         UG    eth0"))
        #expect(routes.contains("10.0.0.0        0.0.0.0         255.255.255.0   U     eth0"))
        let interfaces = sh.run("netstat -i")
        #expect(interfaces.contains("Kernel Interface table"))
        #expect(interfaces.contains("lo              65536"))
        #expect(interfaces.contains("eth0             1500"))
    }
}
