import Testing
@testable import Swiftix

@Suite("Unified network configuration")
struct NetworkConfigurationTests {

    @Test func fullConfigurationAppliesToTablesSnapshotsAndProcfs() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack

        let interface = NetworkInterfaceConfiguration(address: IPv4Address(10, 0, 0, 1),
                                                      mac: MACAddress("02:00:00:00:00:01")!,
                                                      prefixLength: 24)
        let connected = NetworkRouteConfiguration(destination: IPv4Address(10, 0, 0, 0),
                                                  prefixLength: 24,
                                                  gateway: nil,
                                                  interfaceIndex: 0)
        let defaultRoute = NetworkRouteConfiguration(destination: IPv4Address(0, 0, 0, 0),
                                                     prefixLength: 0,
                                                     gateway: IPv4Address(10, 0, 0, 254),
                                                     interfaceIndex: 0)
        let neighbor = NetworkNeighborConfiguration(ip: IPv4Address(10, 0, 0, 254),
                                                    mac: MACAddress("02:00:00:00:00:fe")!)
        let resolver = NetworkResolverConfiguration(nameServers: [IPv4Address(10, 0, 0, 53)],
                                                    searchDomains: ["lab"])
        let configuration = NetworkConfiguration(hostname: "router-a",
                                                 interfaces: [interface],
                                                 routes: [connected, defaultRoute],
                                                 neighbors: [neighbor],
                                                 resolver: resolver,
                                                 ipForwardingEnabled: true)

        stack.configure(configuration)

        let snapshot = stack.snapshotConfiguration()
        #expect(snapshot.hostname == "router-a")
        #expect(snapshot.interfaces == [interface])
        #expect(snapshot.routes == [connected, defaultRoute])
        #expect(snapshot.neighbors == [neighbor])
        #expect(snapshot.resolver == resolver)
        #expect(snapshot.ipForwardingEnabled)
        #expect(stack.interface(at: 0)?.address == interface.address)

        let devText = readProcFile("/proc/net/dev", kernel, loop: loop)
        let routeText = readProcFile("/proc/net/route", kernel, loop: loop)
        let arpText = readProcFile("/proc/net/arp", kernel, loop: loop)

        #expect(devText.contains("eth0 10.0.0.1 02:00:00:00:00:01"))
        #expect(routeText.contains("10.0.0.0/24 * eth0"))
        #expect(routeText.contains("0.0.0.0/0 10.0.0.254 eth0"))
        #expect(arpText.contains("10.0.0.254 02:00:00:00:00:fe"))
    }

    @Test func incrementalChangesUpdateTheSameConfigurationSnapshot() {
        let stack = NetworkStack(loop: EventLoop())
        stack.configure(.setHostname("host-a"))
        stack.configure(.setResolver(NetworkResolverConfiguration(nameServers: [IPv4Address(1, 1, 1, 1)])))
        stack.configure(.setIPForwarding(true))

        stack.configure(.addInterface(NetworkInterfaceConfiguration(address: IPv4Address(192, 168, 1, 10),
                                                                    mac: MACAddress("02:00:00:00:00:10")!,
                                                                    prefixLength: 24)))
        stack.configure(.addRoute(NetworkRouteConfiguration(destination: IPv4Address(0, 0, 0, 0),
                                                            prefixLength: 0,
                                                            gateway: IPv4Address(192, 168, 1, 1),
                                                            interfaceIndex: 0)))
        stack.configure(.addNeighbor(NetworkNeighborConfiguration(ip: IPv4Address(192, 168, 1, 1),
                                                                  mac: MACAddress("02:00:00:00:00:01")!)))
        let interface = stack.interface(at: 0)!

        let snapshot = stack.snapshotConfiguration()
        #expect(snapshot.hostname == "host-a")
        #expect(snapshot.resolver.nameServers == [IPv4Address(1, 1, 1, 1)])
        #expect(snapshot.ipForwardingEnabled)
        #expect(snapshot.interfaces == [
            NetworkInterfaceConfiguration(address: IPv4Address(192, 168, 1, 10),
                                          mac: interface.mac,
                                          prefixLength: 24)
        ])
        #expect(snapshot.routes.contains {
            $0.destination == IPv4Address(192, 168, 1, 0)
                && $0.prefixLength == 24
                && $0.gateway == nil
                && $0.interfaceIndex == 0
        })
        #expect(snapshot.routes.contains {
            $0.destination == IPv4Address(0, 0, 0, 0)
                && $0.prefixLength == 0
                && $0.gateway == IPv4Address(192, 168, 1, 1)
                && $0.interfaceIndex == 0
        })
        #expect(snapshot.neighbors == [
            NetworkNeighborConfiguration(ip: IPv4Address(192, 168, 1, 1),
                                         mac: MACAddress("02:00:00:00:00:01")!)
        ])
    }

    @Test func validatedConfigurationRejectsInvalidInputWithoutMutation() {
        let stack = NetworkStack(loop: EventLoop())
        let original = NetworkInterfaceConfiguration(address: IPv4Address(10, 0, 0, 1),
                                                     mac: MACAddress("02:00:00:00:00:01")!)
        stack.configure(.addInterface(original))

        #expect(throws: NetworkConfigurationError.invalidPrefixLength(33)) {
            try stack.configureValidated(.addInterface(NetworkInterfaceConfiguration(
                address: IPv4Address(10, 0, 1, 1),
                mac: MACAddress("02:00:00:00:00:02")!,
                prefixLength: 33)))
        }
        #expect(throws: NetworkConfigurationError.invalidInterfaceIndex(7)) {
            try stack.configureValidated(.addRoute(NetworkRouteConfiguration(
                destination: IPv4Address(0, 0, 0, 0),
                prefixLength: 0,
                gateway: IPv4Address(10, 0, 0, 254),
                interfaceIndex: 7)))
        }
        #expect(throws: NetworkConfigurationError.duplicateAddress(original.address)) {
            try stack.configureValidated(.addInterface(NetworkInterfaceConfiguration(
                address: original.address,
                mac: MACAddress("02:00:00:00:00:03")!)))
        }

        #expect(stack.snapshotConfiguration().interfaces == [original])
    }

    private func readProcFile(_ path: String, _ kernel: Kernel, loop: EventLoop) -> String {
        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open(path) else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()
        return captured.text
    }
}
