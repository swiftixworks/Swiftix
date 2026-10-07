import Testing
@testable import Swiftix

/// `ip` show/add/del forms and the classic `ifconfig` / `route` / `arp`.
@Suite("ip, ifconfig, route, arp")
struct IPCommandTests {

    private func link(_ index: Int, _ name: String, _ address: IPv4Address, _ prefix: Int,
                      mac: String, carrier: Bool = true) -> NetworkLinkSnapshot {
        NetworkLinkSnapshot(index: index, name: name, address: address, prefixLength: prefix,
                            mac: MACAddress(mac)!, isLoopback: name == "lo", hasCarrier: carrier,
                            counters: NetworkInterfaceCounters())
    }

    // MARK: - Renderers

    @Test func addressRenderingIsLinuxShaped() {
        let links = [link(0, "lo", IPv4Address(127, 0, 0, 1), 8, mac: "00:00:00:00:00:00"),
                     link(1, "eth0", IPv4Address(10, 0, 0, 1), 24, mac: "02:00:00:00:00:0a")]
        let text = BuiltinCommands.renderAddresses(links)
        #expect(text.contains("1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN\n"))
        #expect(text.contains("    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00\n"))
        #expect(text.contains("    inet 127.0.0.1/8 scope host lo\n"))
        #expect(text.contains("2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\n"))
        #expect(text.contains("    link/ether 02:00:00:00:00:0a brd ff:ff:ff:ff:ff:ff\n"))
        #expect(text.contains("    inet 10.0.0.1/24 brd 10.0.0.255 scope global eth0\n"))
    }

    @Test func carrierFollowsTheEgressSeam() {
        let down = link(0, "eth0", IPv4Address(10, 0, 0, 1), 24, mac: "02:00:00:00:00:0a", carrier: false)
        #expect(BuiltinCommands.linkFlags(down) == "NO-CARRIER,BROADCAST,MULTICAST,UP")
        #expect(BuiltinCommands.linkOperationalState(down) == "DOWN")
    }

    @Test func briefAndIPv6Views() {
        let links = [link(0, "lo", IPv4Address(127, 0, 0, 1), 8, mac: "00:00:00:00:00:00")]
        var options = BuiltinCommands.IPDisplayOptions()
        options.brief = true
        #expect(BuiltinCommands.renderAddresses(links, options: options) == "lo               UNKNOWN        127.0.0.1/8 \n")
        options = BuiltinCommands.IPDisplayOptions()
        options.family = 6
        #expect(BuiltinCommands.renderAddresses(links, options: options) == "")   // IPv6 is not implemented
    }

    @Test func routeRenderingPutsDefaultFirst() {
        let links = [link(0, "eth0", IPv4Address(10, 0, 0, 1), 24, mac: "02:00:00:00:00:0a")]
        let routes = [
            NetworkRouteConfiguration(destination: IPv4Address(10, 0, 0, 0), prefixLength: 24, gateway: nil),
            NetworkRouteConfiguration(destination: IPv4Address(192, 168, 0, 0), prefixLength: 16, gateway: nil),
            NetworkRouteConfiguration(destination: IPv4Address(0, 0, 0, 0), prefixLength: 0,
                                      gateway: IPv4Address(10, 0, 0, 254)),
        ]
        #expect(BuiltinCommands.renderRoutes(routes, links: links) == """
            default via 10.0.0.254 dev eth0
            10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.1
            192.168.0.0/16 dev eth0 scope link

            """)
    }

    @Test func routeLookupIsLongestPrefix() {
        let routes = [
            NetworkRouteConfiguration(destination: IPv4Address(0, 0, 0, 0), prefixLength: 0,
                                      gateway: IPv4Address(10, 0, 0, 254), interfaceIndex: 1),
            NetworkRouteConfiguration(destination: IPv4Address(10, 0, 0, 0), prefixLength: 24, gateway: nil,
                                      interfaceIndex: 1),
        ]
        #expect(BuiltinCommands.lookupRoute(IPv4Address(10, 0, 0, 7), in: routes)?.prefixLength == 24)
        #expect(BuiltinCommands.lookupRoute(IPv4Address(8, 8, 8, 8), in: routes)?.prefixLength == 0)
        #expect(BuiltinCommands.lookupRoute(IPv4Address(8, 8, 8, 8), in: Array(routes.dropFirst())) == nil)
    }

    @Test func routeWithoutDevUsesTheGatewaysSubnet() {
        let links = [link(0, "lo", IPv4Address(127, 0, 0, 1), 8, mac: "00:00:00:00:00:00"),
                     link(1, "eth0", IPv4Address(10, 0, 0, 1), 24, mac: "02:00:00:00:00:0a"),
                     link(2, "eth1", IPv4Address(10, 0, 1, 1), 24, mac: "02:00:00:00:00:0b")]
        #expect(BuiltinCommands.inferRouteInterface(gateway: IPv4Address(10, 0, 1, 254), links: links) == 2)
        #expect(BuiltinCommands.inferRouteInterface(gateway: IPv4Address(172, 16, 0, 1), links: links) == 1)
        #expect(BuiltinCommands.inferRouteInterface(gateway: nil, links: links) == 1)
    }

    // MARK: - ip through the shell

    @Test(arguments: ["ip addr", "ip a", "ip addr show", "ip address list", "ip -4 addr", "ip a s"])
    func addressShowForms(line: String) {
        let sh = NetworkShell(ethernet: true)
        let out = sh.run(line)
        #expect(out.contains("1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536"), "\(out)")
        #expect(out.contains("inet 127.0.0.1/8 scope host lo"), "\(out)")
        #expect(out.contains("2: eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500"), "\(out)")
        #expect(out.contains("inet 10.0.0.1/24 brd 10.0.0.255 scope global eth0"), "\(out)")
        #expect(!out.contains("usage"), "\(out)")
    }

    @Test func addressShowSelectsOneDevice() {
        let sh = NetworkShell(ethernet: true)
        for line in ["ip addr show dev eth0", "ip addr show eth0"] {
            let out = sh.run(line)
            #expect(out.contains("eth0:"))
            #expect(!out.contains("lo:"))
        }
        let missing = sh.run("ip addr show dev eth9; echo rc=$?")
        #expect(missing.contains("Device \"eth9\" does not exist."))
        #expect(missing.contains("rc=1"))
    }

    @Test func briefAddressAndLink() {
        let sh = NetworkShell(ethernet: true)
        let addresses = sh.run("ip -br addr")
        #expect(addresses.contains("lo               UNKNOWN        127.0.0.1/8"))
        #expect(addresses.contains("eth0             DOWN           10.0.0.1/24"))
        let links = sh.run("ip -br link")
        #expect(links.contains("eth0             DOWN           02:00:00:00:00:0a <NO-CARRIER,BROADCAST,MULTICAST,UP>"))
    }

    @Test(arguments: ["ip link", "ip l", "ip link show"])
    func linkShowForms(line: String) {
        let sh = NetworkShell(ethernet: true)
        let out = sh.run(line)
        #expect(out.contains("1: lo: <LOOPBACK,UP,LOWER_UP>"), "\(out)")
        #expect(out.contains("    link/ether 02:00:00:00:00:0a brd ff:ff:ff:ff:ff:ff"), "\(out)")
        #expect(!out.contains("inet "), "\(out)")
    }

    @Test func linkStatisticsShowCounters() {
        let sh = NetworkShell()
        sh.run("ping -c 1 127.0.0.1")
        let out = sh.run("ip -s link show lo")
        #expect(out.contains("RX:  bytes packets dropped"))
        #expect(out.contains("TX:  bytes packets"))
        #expect(!out.contains("         0       0\n"), "counters should be non-zero after a ping: \(out)")
    }

    @Test(arguments: ["ip route", "ip r", "ip route show", "ip r l"])
    func routeShowForms(line: String) {
        let sh = NetworkShell(ethernet: true)
        sh.run("ip route add default via 10.0.0.254 dev eth0")
        let out = sh.run(line)
        #expect(out.contains("default via 10.0.0.254 dev eth0\n"), "\(out)")
        #expect(out.contains("10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.1\n"), "\(out)")
        #expect(!out.contains("usage"), "\(out)")
    }

    @Test func routeAddInfersDeviceAndDelRemoves() {
        let sh = NetworkShell(ethernet: true)
        #expect(sh.run("ip route add default via 10.0.0.254; echo rc=$?").contains("rc=0"))
        #expect(sh.run("ip route add 192.168.5.0/24 via 10.0.0.9; echo rc=$?").contains("rc=0"))
        var out = sh.run("ip route")
        #expect(out.contains("default via 10.0.0.254 dev eth0"))
        #expect(out.contains("192.168.5.0/24 via 10.0.0.9 dev eth0"))
        #expect(sh.run("ip route get 192.168.5.7").contains("192.168.5.7 via 10.0.0.9 dev eth0 src 10.0.0.1"))
        #expect(sh.run("ip route get 10.0.0.77").contains("10.0.0.77 dev eth0 src 10.0.0.1"))

        let duplicate = sh.run("ip route add default via 10.0.0.254; echo rc=$?")
        #expect(duplicate.contains("RTNETLINK answers: File exists"))
        #expect(duplicate.contains("rc=2"))

        #expect(sh.run("ip route del 192.168.5.0/24; echo rc=$?").contains("rc=0"))
        #expect(sh.run("ip r d default; echo rc=$?").contains("rc=0"))
        out = sh.run("ip route")
        #expect(!out.contains("default"))
        #expect(!out.contains("192.168.5.0"))
        let missing = sh.run("ip route del 192.168.5.0/24; echo rc=$?")
        #expect(missing.contains("RTNETLINK answers: No such process"))
        #expect(missing.contains("rc=2"))
        // The connected route is what delivers on-link traffic and is still there.
        #expect(sh.kernel.netns.stack.snapshotRoutes().contains { $0.prefixLength == 24 })
    }

    @Test func routeGetWithoutARouteIsUnreachable() {
        let sh = NetworkShell(loopback: false, ethernet: true)
        let out = sh.run("ip route get 8.8.8.8; echo rc=$?")
        #expect(out.contains("Network is unreachable"))
        #expect(out.contains("rc=2"))
    }

    @Test(arguments: ["ip neigh", "ip n", "ip neighbor show", "ip neighbour", "ip neigh show dev eth0"])
    func neighborShowForms(line: String) {
        let sh = NetworkShell(ethernet: true)
        sh.run("ip neigh add 10.0.0.2 lladdr 02:00:00:00:00:0b")
        let out = sh.run(line)
        #expect(out.contains("10.0.0.2 dev eth0 lladdr 02:00:00:00:00:0b REACHABLE\n"), "\(out)")
    }

    @Test func neighborAddReplaceAndDelete() {
        let sh = NetworkShell(ethernet: true)
        #expect(sh.run("ip neigh add 10.0.0.2 lladdr 02:00:00:00:00:0b dev eth0; echo rc=$?").contains("rc=0"))
        let again = sh.run("ip neigh add 10.0.0.2 lladdr 02:00:00:00:00:0c; echo rc=$?")
        #expect(again.contains("File exists"))
        #expect(again.contains("rc=2"))
        #expect(sh.run("ip neigh replace 10.0.0.2 lladdr 02:00:00:00:00:0c; echo rc=$?").contains("rc=0"))
        #expect(sh.run("ip n").contains("10.0.0.2 dev eth0 lladdr 02:00:00:00:00:0c REACHABLE"))
        #expect(sh.run("ip neigh show dev lo").contains("10.0.0.2") == false)
        #expect(sh.run("ip neigh del 10.0.0.2; echo rc=$?").contains("rc=0"))
        #expect(!sh.run("ip neigh").contains("10.0.0.2 dev"))
        #expect(sh.run("ip neigh del 10.0.0.2; echo rc=$?").contains("rc=2"))
        #expect(sh.kernel.netns.stack.snapshotARP().isEmpty)
    }

    @Test func addressAddCreatesAnInterfaceAndRejectsDuplicates() {
        let sh = NetworkShell()
        #expect(sh.run("ip addr add 192.168.9.2/24 lladdr 02:00:00:00:09:02; echo rc=$?").contains("rc=0"))
        #expect(sh.run("ip addr").contains("inet 192.168.9.2/24 brd 192.168.9.255 scope global eth0"))
        let duplicate = sh.run("ip addr add 192.168.9.2/24 lladdr 02:00:00:00:09:03; echo rc=$?")
        #expect(duplicate.contains("ip: address 192.168.9.2 is already assigned"))
        #expect(duplicate.contains("rc=2"))
        let noMAC = sh.run("ip addr add 192.168.9.3/24 dev eth0; echo rc=$?")
        #expect(noMAC.contains("lladdr <mac>"))
        #expect(noMAC.contains("rc=2"))
    }

    /// What the stack does not model is refused with a reason, not faked.
    @Test func unmodeledOperationsAreClearErrors() {
        let sh = NetworkShell(ethernet: true)
        for line in ["ip link set eth0 down", "ip link set dev eth0 up"] {
            let out = sh.run("\(line); echo rc=$?")
            #expect(out.contains("ip: link set: not supported: this stack does not model link state"), "\(out)")
            #expect(out.contains("rc=1"), "\(out)")
        }
        #expect(sh.run("ip link set eth9 up").contains("Cannot find device \"eth9\""))
        let delete = sh.run("ip addr del 10.0.0.1/24 dev eth0; echo rc=$?")
        #expect(delete.contains("ip: addr del: not supported"))
        #expect(delete.contains("rc=1"))
        #expect(sh.run("ip addr").contains("inet 10.0.0.1/24"))
    }

    @Test func unknownObjectAndForwardingExtension() {
        let sh = NetworkShell()
        let unknown = sh.run("ip bogus; echo rc=$?")
        #expect(unknown.contains("ip: Object \"bogus\" is unknown"))
        #expect(unknown.contains("rc=1"))
        #expect(sh.run("ip forwarding").contains("forwarding: off"))
        #expect(sh.run("ip forwarding on").contains("forwarding: on"))
        #expect(sh.kernel.netns.stack.ipForwardingEnabled)
        #expect(sh.run("ip; echo rc=$?").contains("rc=2"))
    }

    // MARK: - ifconfig / route / arp

    @Test func ifconfigAcceptsAllFlagAndInterfaceName() {
        let sh = NetworkShell(ethernet: true)
        #expect(sh.run("ifconfig -a").contains("eth0 10.0.0.1 02:00:00:00:00:0a"))
        let one = sh.run("ifconfig lo")
        #expect(one.contains("lo 127.0.0.1"))
        #expect(!one.contains("eth0 10.0.0.1"))
        let missing = sh.run("ifconfig eth9; echo rc=$?")
        #expect(missing.contains("ifconfig: eth9: error fetching interface information: Device not found"))
        #expect(missing.contains("rc=1"))
    }

    @Test func routeAcceptsNumericFlagAndDeletes() {
        let sh = NetworkShell(ethernet: true)
        sh.run("route add default gw 10.0.0.254")
        let table = sh.run("route -n")
        #expect(table.contains("destination gateway interface"))
        #expect(table.contains("0.0.0.0/0 10.0.0.254 eth0"))
        #expect(sh.run("route del default; echo rc=$?").contains("rc=0"))
        #expect(!sh.run("route").contains("0.0.0.0/0"))
    }

    @Test func arpAcceptsDisplayFlagsAndDeletes() {
        let sh = NetworkShell(ethernet: true)
        sh.run("arp -s 10.0.0.2 02:00:00:00:00:0b")
        #expect(sh.run("arp -a").contains("? (10.0.0.2) at 02:00:00:00:00:0b [ether] on eth0"))
        for line in ["arp -n", "arp", "arp -an"] {
            let out = sh.run(line)
            #expect(out.contains("10.0.0.2"), "\(line): \(out)")
            #expect(!out.contains("usage"), "\(line): \(out)")
        }
        #expect(sh.run("arp -n").contains("address hwaddress\n10.0.0.2 02:00:00:00:00:0b\n"))
        #expect(sh.run("arp -d 10.0.0.2; echo rc=$?").contains("rc=0"))
        #expect(!sh.run("arp -a").contains("10.0.0.2) at"))
        let missing = sh.run("arp -d 10.0.0.2; echo rc=$?")
        #expect(missing.contains("arp: no ARP entry for 10.0.0.2"))
        #expect(missing.contains("rc=1"))
    }
}
