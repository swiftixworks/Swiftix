import Testing
@testable import Swiftix

/// `tcpdump` / `trace` / `drops` options and the filter over packet-path events.
@Suite("tcpdump filters")
struct PacketPathFilterTests {

    private let icmp = "12 outbound lo route len=84 proto=icmp route=127.0.0.1 via=127.0.0.1 dev=lo network=127.0.0.0/8"
    private let tcp = "13 inbound eth0 layer4 len=60 ether=ipv4 proto=tcp"
    private let arp = "14 inbound eth0 layer2 len=42 ether=arp"
    private let routed = "15 outbound eth0 route len=60 proto=udp route=8.8.8.8 via=10.0.0.254 dev=eth0 network=0.0.0.0/0 gateway=10.0.0.254"

    private func filter(_ words: [String], interface: String? = nil) throws -> BuiltinCommands.PacketPathFilter {
        var filter = BuiltinCommands.PacketPathFilter()
        filter.interface = interface
        try BuiltinCommands.parsePacketPathExpression(words, into: &filter)
        return filter
    }

    @Test func protocolWordsSelectEvents() throws {
        #expect(try filter(["icmp"]).matches(icmp))
        #expect(try !filter(["icmp"]).matches(tcp))
        #expect(try filter(["tcp"]).matches(tcp))
        #expect(try filter(["arp"]).matches(arp))
        #expect(try !filter(["arp"]).matches(tcp))
        #expect(try filter(["ip"]).matches(tcp))
        #expect(try filter(["udp"]).matches(routed))
        #expect(try filter([]).matches(arp))
    }

    @Test func interfaceAndHostNarrowTheMatch() throws {
        #expect(try filter([], interface: "lo").matches(icmp))
        #expect(try !filter([], interface: "lo").matches(tcp))
        #expect(try filter([], interface: "any").matches(tcp))
        #expect(try filter(["host", "8.8.8.8"]).matches(routed))
        #expect(try filter(["dst", "host", "10.0.0.254"]).matches(routed))
        #expect(try filter(["udp", "and", "host", "8.8.8.8"]).matches(routed))
        #expect(try !filter(["tcp", "and", "host", "8.8.8.8"]).matches(routed))
        #expect(try !filter(["host", "9.9.9.9"]).matches(routed))
        #expect(try !filter(["host", "8.8.8.8"]).matches(tcp))      // no addresses on that event
    }

    @Test func unsupportedAndMalformedExpressions() {
        #expect(throws: BuiltinCommands.PacketPathFilterError.self) { _ = try filter(["port", "80"]) }
        #expect(throws: BuiltinCommands.PacketPathFilterError.self) { _ = try filter(["not", "tcp"]) }
        #expect(throws: BuiltinCommands.PacketPathFilterError.self) { _ = try filter(["host"]) }
        #expect(throws: BuiltinCommands.PacketPathFilterError.self) { _ = try filter(["host", "name"]) }
        #expect(throws: BuiltinCommands.PacketPathFilterError.self) { _ = try filter(["bogus"]) }
    }

    @Test func tcpdumpSelectsFromRecentEvents() {
        let sh = NetworkShell()
        sh.run("ping -c 1 127.0.0.1")
        let all = sh.run("tcpdump -n")
        #expect(all.contains("seq direction interface stage details\n"))
        #expect(all.contains("proto=icmp"))

        let icmpOnly = sh.run("tcpdump -n -i lo icmp")
        #expect(icmpOnly.contains("proto=icmp"))
        #expect(!sh.run("tcpdump tcp").contains("proto=icmp"))
        #expect(!sh.run("tcpdump arp").contains("proto="))
        #expect(sh.run("tcpdump host 127.0.0.1").contains("route=127.0.0.1"))
        #expect(!sh.run("tcpdump host 10.9.9.9").contains("route="))

        let limited = sh.run("tcpdump -c 2 icmp").split(separator: "\n").filter { $0.contains("proto=icmp") }
        #expect(limited.count == 2)
        let one = sh.run("tcpdump -c1 -i any").split(separator: "\n").filter { $0.contains("len=") }
        #expect(one.count == 1)
    }

    @Test func tcpdumpErrors() {
        let sh = NetworkShell()
        let port = sh.run("tcpdump port 80; echo rc=$?")
        #expect(port.contains("tcpdump: 'port' filters are not supported: packet path events carry no port numbers"))
        #expect(port.contains("rc=1"))
        let device = sh.run("tcpdump -i eth9; echo rc=$?")
        #expect(device.contains("tcpdump: eth9: No such device exists"))
        #expect(device.contains("rc=1"))
        let syntax = sh.run("tcpdump bogus; echo rc=$?")
        #expect(syntax.contains("tcpdump: syntax error in filter expression near 'bogus'"))
        #expect(syntax.contains("rc=2"))
        #expect(sh.run("tcpdump -c 0; echo rc=$?").contains("rc=2"))
    }

    @Test func traceAndDropsKeepWorkingAndTakeTheSameOptions() {
        let sh = NetworkShell(ethernet: true)
        sh.run("ping -c 1 127.0.0.1")
        #expect(sh.run("trace").contains("proto=icmp"))
        #expect(sh.run("trace -i lo -c 1 icmp").contains("proto=icmp"))
        // eth0 has no link, so ARP for this neighbor never resolves: the queued
        // echo request is dropped once the retries run out, and recorded.
        sh.run("ping -c 1 -W 0.1 10.0.0.9", advance: 5)
        let drops = sh.run("drops")
        #expect(drops.contains("seq direction interface stage details\n"))
        #expect(drops.contains("drop=arpResolutionFailed"))
        #expect(sh.run("drops -i eth0").contains("drop=arpResolutionFailed"))
        #expect(!sh.run("drops -i lo").contains("drop=arpResolutionFailed"))
    }
}
