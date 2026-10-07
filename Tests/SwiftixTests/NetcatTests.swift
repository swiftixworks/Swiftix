import Testing
@testable import Swiftix

/// `nc` (TCP/UDP client and listener, port scan, timeouts) and `telnet`.
@Suite("nc and telnet")
struct NetcatTests {

    @Test func portRanges() {
        #expect(BuiltinCommands.parsePortRange("80") == 80...80)
        #expect(BuiltinCommands.parsePortRange("20-25") == 20...25)
        #expect(BuiltinCommands.parsePortRange("25-20") == nil)
        #expect(BuiltinCommands.parsePortRange("0") == nil)
        #expect(BuiltinCommands.parsePortRange("http") == nil)
        #expect(BuiltinCommands.parsePortRange("1-2-3") == nil)
    }

    // MARK: - TCP

    @Test(arguments: ["nc -l 9000 > /got.txt &", "nc -l -p 9000 > /got.txt &", "nc -lp 9000 -d > /got.txt &"])
    func listenerReceivesOneConnectionThenExits(line: String) {
        let sh = NetworkShell()
        sh.run(line)
        #expect(sh.run("ss -tlnp").contains("users:((\"nc\","), "\(line)")
        let out = sh.run("echo hello | nc -q 0 127.0.0.1 9000; echo rc=$?", advance: 0.5)
        #expect(out.contains("rc=0"), "\(line): \(out)")
        #expect(sh.read("/got.txt") == "hello\n", "\(line)")
        // Single accept: the listener is gone once its connection closed.
        #expect(!sh.run("ss -tln").contains(":9000"), "\(line)")
    }

    @Test func keepListeningAcceptsAgain() {
        let sh = NetworkShell()
        sh.run("nc -k -d -l 9000 > /got.txt &")
        sh.run("echo one | nc -q 0 127.0.0.1 9000", advance: 0.5)
        sh.run("echo two | nc -q 0 127.0.0.1 9000", advance: 0.5)
        #expect(sh.read("/got.txt") == "one\ntwo\n")
        #expect(sh.run("ss -tln").contains(":9000"))
    }

    @Test func listenerSendsItsInputToTheClient() {
        let sh = NetworkShell()
        sh.write("/banner", "welcome\n")
        sh.run("nc -l 9000 < /banner &")
        let out = sh.run("nc -d -w 1 127.0.0.1 9000; echo rc=$?", advance: 2)
        #expect(out.contains("welcome\n"))
        #expect(out.contains("rc=0"))
    }

    @Test func clientRelaysRepliesAndHonorsQuitDelay() {
        let sh = NetworkShell()
        sh.run("tcpecho 7 &")
        // The echo server never closes first: -q ends the relay after stdin EOF…
        var out = sh.run("echo ping | nc -q 1 127.0.0.1 7; echo rc=$?")
        #expect(out.contains("ping\n"))
        #expect(!out.contains("\nrc="))
        out += sh.advance(1.5)
        #expect(out.contains("rc=0"))
        // …and -w ends it after a second of silence.
        out = sh.run("echo pong | nc -w 1 127.0.0.1 7; echo rc=$?", advance: 1.5)
        #expect(out.contains("pong\nrc=0"))
    }

    /// Interactive use: lines typed at the terminal go to the peer, its replies
    /// are printed, and Ctrl-C ends the relay and returns to the prompt with no
    /// helper process left reading the terminal.
    @Test func interactiveClientRelaysTypedLinesUntilInterrupted() {
        let sh = NetworkShell()
        sh.run("tcpecho 7 &")
        #expect(!sh.run("nc 127.0.0.1 7").contains("root@"))          // connected, no prompt
        let echoed = sh.run("typed line")
        #expect(echoed == "typed line\ntyped line\n")                 // tty echo, then the server's echo
        sh.kernel.interruptForeground(signal: Signal.sigint.rawValue)  // what Ctrl-C is wired to
        sh.loop.runUntilIdle()
        // The shell has the terminal back: the line runs instead of being relayed.
        #expect(sh.run("echo back").contains("\nback\nroot@"))
        #expect(!sh.kernel.snapshotProcesses().contains { $0.name.hasPrefix("nc") && $0.lifecycle == .live })
    }

    @Test func clientEndsWhenThePeerCloses() {
        let sh = NetworkShell()
        sh.write("/index.html", "<p>served</p>\n")
        sh.run("httpd &")
        sh.write("/request", "GET /index.html HTTP/1.0\r\n\r\n")
        let out = sh.run("nc 127.0.0.1 80 < /request; echo rc=$?", advance: 1)
        #expect(out.contains("HTTP/1.1 200 OK"))
        #expect(out.contains("<p>served</p>\nrc=0"))
    }

    @Test func clientResolvesHostnames() {
        let sh = NetworkShell()
        sh.write("/etc/hosts", "127.0.0.1 echohost\n")
        sh.run("tcpecho 7 &")
        #expect(sh.run("echo named | nc -q 1 echohost 7", advance: 1.5).contains("named\n"))
        let bad = sh.run("nc nosuch.invalid 7; echo rc=$?")
        #expect(bad.contains("nc: getaddrinfo for host \"nosuch.invalid\" port 7: Name or service not known"))
        #expect(bad.contains("rc=1"))
    }

    @Test func connectFailuresAreReported() {
        let sh = NetworkShell(ethernet: true)
        let refused = sh.run("nc 127.0.0.1 81; echo rc=$?")
        #expect(refused.contains("nc: connect to 127.0.0.1 port 81 (tcp) failed: Connection refused"))
        #expect(refused.contains("rc=1"))

        var timedOut = sh.run("nc -w 2 10.0.0.9 80; echo rc=$?")     // no link on eth0
        #expect(!timedOut.contains("\nrc="))
        timedOut += sh.advance(3)
        #expect(timedOut.contains("nc: connect to 10.0.0.9 port 80 (tcp) failed: Operation timed out"))
        #expect(timedOut.contains("rc=1"))
    }

    @Test func portInUseAndUsage() {
        let sh = NetworkShell()
        sh.run("tcpecho 7 &")
        let busy = sh.run("nc -l 7; echo rc=$?")
        #expect(busy.contains("nc: Address already in use"))
        #expect(busy.contains("rc=1"))
        for line in ["nc", "nc host", "nc -l", "nc host notaport", "nc host 1-5"] {
            let out = sh.run("\(line); echo rc=$?")
            #expect(out.contains("nc: usage:"), "\(line): \(out)")
            #expect(out.contains("rc=2"), "\(line): \(out)")
        }
    }

    // MARK: - Scan

    @Test func zeroIOScanReportsOpenAndClosedPorts() {
        let sh = NetworkShell()
        sh.run("tcpecho 7 &")
        let open = sh.run("nc -zv 127.0.0.1 7; echo rc=$?")
        #expect(open.contains("Connection to 127.0.0.1 7 port [tcp/*] succeeded!"))
        #expect(open.contains("rc=0"))

        let closed = sh.run("nc -z -v 127.0.0.1 8; echo rc=$?")
        #expect(closed.contains("nc: connect to 127.0.0.1 port 8 (tcp) failed: Connection refused"))
        #expect(closed.contains("rc=1"))

        let quiet = sh.run("nc -z 127.0.0.1 8; echo rc=$?")
        #expect(!quiet.contains("failed"))
        #expect(quiet.contains("rc=1"))

        let range = sh.run("nc -zv localhost 6-8; echo rc=$?")
        #expect(range.contains("port 6 (tcp) failed"))
        #expect(range.contains("Connection to localhost 7 port [tcp/*] succeeded!"))
        #expect(range.contains("port 8 (tcp) failed"))
        #expect(range.contains("rc=0"))
        // A scan transfers nothing: the echo server saw only opens and closes.
        #expect(!sh.run("ss -tn").contains("ESTAB"))
    }

    @Test func scanTimeoutBoundsAnUnreachableHost() {
        let sh = NetworkShell(ethernet: true)
        var out = sh.run("nc -zv -w 1 10.0.0.9 80; echo rc=$?")
        out += sh.advance(2)
        #expect(out.contains("failed: Operation timed out"))
        #expect(out.contains("rc=1"))
    }

    // MARK: - UDP

    @Test func udpListenerReceivesDatagrams() {
        let sh = NetworkShell()
        sh.run("nc -u -d -l 5000 > /udp.txt &")
        #expect(sh.run("ss -uln").contains("0.0.0.0:5000"))
        #expect(sh.run("echo datagram | nc -u 127.0.0.1 5000; echo rc=$?", advance: 0.5).contains("rc=0"))
        sh.run("echo again | nc -u localhost 5000", advance: 0.5)
        #expect(sh.read("/udp.txt") == "datagram\nagain\n")
    }

    @Test func udpListenerRepliesToTheFirstSender() {
        let sh = NetworkShell()
        sh.write("/etc/hosts", "127.0.0.1 localhost\n")
        // dnsd answers on 53: a UDP client that sends a query and lingers (-w)
        // prints the reply it gets back.
        sh.run("dnsd &")
        final class Box { var reply: [UInt8] = [] }
        sh.kernel.spawn("mkquery") { ctx in
            let fd = ctx.open("/query", create: true, truncate: true)!
            ctx.write(fd, DNS.encodeQuery(id: 0x4142, name: "localhost"))
            ctx.close(fd)
            ctx.exit(0)
        }
        sh.loop.runUntilIdle()
        sh.run("nc -u -w 1 127.0.0.1 53 < /query > /answer", advance: 2)
        let box = Box()
        sh.kernel.spawn("read") { ctx in
            if let fd = ctx.open("/answer") { box.reply = ctx.read(fd, max: 4096); ctx.close(fd) }
            ctx.exit(0)
        }
        sh.loop.runUntilIdle()
        let message = DNS.parseMessage(box.reply)
        #expect(message?.id == 0x4142)
        #expect(message?.answers.first?.address == IPv4Address(127, 0, 0, 1))
    }

    @Test func udpPortInUse() {
        let sh = NetworkShell()
        sh.run("dnsd &")
        let out = sh.run("nc -u -l 53; echo rc=$?")
        #expect(out.contains("nc: Address already in use"))
        #expect(out.contains("rc=1"))
    }

    // MARK: - telnet

    @Test func telnetPrintsTheConnectionBanner() {
        let sh = NetworkShell()
        sh.write("/etc/hosts", "127.0.0.1 echohost\n")
        sh.run("tcpecho 7 &")
        var out = sh.run("echo hi | telnet echohost 7; echo rc=$?")
        out += sh.advance(2)
        #expect(out.contains("Trying 127.0.0.1...\nConnected to echohost.\nEscape character is '^]'.\nhi\n"))
        #expect(out.contains("rc=0"))
    }

    @Test func telnetReportsPeerCloseAndFailures() {
        let sh = NetworkShell()
        sh.write("/index.html", "page\n")
        sh.run("httpd &")
        sh.write("/request", "GET / HTTP/1.0\r\n\r\n")
        let closed = sh.run("telnet 127.0.0.1 80 < /request; echo rc=$?", advance: 1)
        #expect(closed.contains("Connected to 127.0.0.1."))
        #expect(closed.contains("page\n"))
        #expect(closed.contains("Connection closed by foreign host.\nrc=1"))

        let refused = sh.run("telnet 127.0.0.1; echo rc=$?")          // default port 23
        #expect(refused.contains("Trying 127.0.0.1...\ntelnet: Unable to connect to remote host: Connection refused"))
        #expect(refused.contains("rc=1"))

        let unknown = sh.run("telnet nosuch.invalid 80; echo rc=$?")
        #expect(unknown.contains("telnet: could not resolve nosuch.invalid/80: Name or service not known"))
        #expect(sh.run("telnet; echo rc=$?").contains("rc=2"))
    }
}
