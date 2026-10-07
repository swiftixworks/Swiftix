import Testing
@testable import Swiftix

/// `ping` / `traceroute` option handling and hostname resolution.
@Suite("ping and traceroute command line")
struct PingResolutionTests {

    /// The reported failure: `ping -c1 localhost` was a usage error.
    @Test func pingResolvesLocalhostWithAttachedCount() {
        let sh = NetworkShell()
        let out = sh.run("ping -c1 localhost; echo rc=$?")
        #expect(out.contains("PING localhost (127.0.0.1) 56(84) bytes of data."))
        #expect(out.contains("64 bytes from 127.0.0.1: icmp_seq=1 ttl=64"))
        #expect(out.contains("--- localhost ping statistics ---"))
        #expect(out.contains("1 packets transmitted, 1 received, 0.0% packet loss"))
        #expect(out.contains("rc=0"))
        #expect(!out.contains("usage"))
    }

    @Test func pingResolvesThroughHostsFile() {
        let sh = NetworkShell()
        sh.write("/etc/hosts", "# hosts\n127.0.0.1 loop alias\n")
        #expect(sh.run("ping -c 1 alias").contains("PING alias (127.0.0.1)"))
    }

    @Test func pingResolvesThroughDNS() {
        let sh = NetworkShell(ethernet: true)
        let peer = sh.attachPeer()
        sh.write("/etc/hosts", "10.0.0.2 peerbox\n", on: peer)   // the server's zone
        sh.launch(["dnsd"], on: peer)
        sh.write("/etc/resolv.conf", "nameserver 10.0.0.2\n")
        let out = sh.run("ping -c 1 peerbox; echo rc=$?")
        #expect(out.contains("PING peerbox (10.0.0.2) 56(84) bytes of data."))
        #expect(out.contains("64 bytes from 10.0.0.2: icmp_seq=1"))
        #expect(out.contains("rc=0"))
    }

    @Test func pingUnknownHostReportsNameError() {
        let sh = NetworkShell()
        let out = sh.run("ping -c1 nosuch.invalid; echo rc=$?")
        #expect(out.contains("ping: nosuch.invalid: Name or service not known"))
        #expect(out.contains("rc=2"))
        #expect(!out.contains("usage"))
    }

    @Test func quietPrintsOnlyTheSummary() {
        let sh = NetworkShell()
        let out = sh.run("ping -q -c 2 -i 0.2 127.0.0.1; echo rc=$?", advance: 1)
        #expect(out.contains("PING 127.0.0.1"))
        #expect(!out.contains("bytes from"))
        #expect(out.contains("2 packets transmitted, 2 received"))
        #expect(out.contains("rc=0"))
    }

    @Test func deadlineBoundsARunWithoutCount() {
        let sh = NetworkShell()
        var out = sh.run("ping -w 1 -i 0.3 127.0.0.1; echo rc=$?")
        #expect(out.contains("icmp_seq=1"))
        #expect(!out.contains("ping statistics"))          // still running
        out += sh.advance(2)
        #expect(out.contains("icmp_seq=4"))
        #expect(!out.contains("icmp_seq=5"))
        #expect(out.contains("4 packets transmitted, 4 received"))
        #expect(out.contains("time 1000ms"))
        #expect(out.contains("rc=0"))
    }

    @Test func deadlineCutsAnUnansweredRequestShort() {
        let sh = NetworkShell(loopback: false, ethernet: true)   // eth0 has no link: nothing answers
        var out = sh.run("ping -c 5 -W 2 -w 1 10.0.0.9; echo rc=$?")
        out += sh.advance(5)
        #expect(out.contains("1 packets transmitted, 0 received, 100.0% packet loss, time 1000ms"))
        #expect(out.contains("rc=1"))                       // all lost: exit 1, like Linux
    }

    @Test func legacyPositionalCountStillWorks() {
        let sh = NetworkShell()
        let out = sh.run("ping 127.0.0.1 2", advance: 2)
        #expect(out.contains("icmp_seq=2"))
        #expect(out.contains("2 packets transmitted"))
    }

    @Test func badOptionValuesAreUsageErrors() {
        let sh = NetworkShell()
        for line in ["ping -c abc 127.0.0.1", "ping -W 0 127.0.0.1", "ping -c", "ping"] {
            let out = sh.run("\(line); echo rc=$?")
            #expect(out.contains("ping: usage:"), "\(line): \(out)")
            #expect(out.contains("rc=2"), "\(line): \(out)")
        }
    }

    @Test func tracerouteResolvesNamesAndReportsUnknownOnes() {
        let sh = NetworkShell()
        let ok = sh.run("traceroute -n localhost", advance: 1)
        #expect(ok.contains("traceroute to localhost (127.0.0.1), 30 hops max"))
        #expect(ok.contains(" 1  127.0.0.1"))
        let bad = sh.run("traceroute nosuch.invalid; echo rc=$?")
        #expect(bad.contains("traceroute: nosuch.invalid: Name or service not known"))
        #expect(bad.contains("rc=2"))
    }
}
