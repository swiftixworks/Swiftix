//
//  UplinkNATTests.swift
//  SwiftixTests
//
//  Deterministic integration coverage for the SLIRP-style real-network uplink.
//  A real guest TCP stack talks through a one-interface NAT gateway on the same
//  logical EventLoop; a fake UplinkTransport stands in for the host's real
//  sockets, so handshakes, payload relay, failures, and teardown have no
//  wall-clock or external-network dependency.
//

import Testing
@testable import Swiftix

@Suite("User-mode NAT uplink")
struct UplinkNATTests {

    @Test func realOpenGatesGuestHandshakeAndRelaysBytesBothWays() {
        let topology = makeTopology()
        let request = Array("GET / HTTP/1.0\r\n\r\n".utf8)
        let response = Array("HTTP/1.0 200 OK\r\n\r\nhello".utf8)

        final class Capture {
            var connected = false
            var received: [UInt8] = []
        }
        let capture = Capture()

        topology.guest.spawn("nat-client") { context in
            guard let descriptor = context.tcpSocket() else { return }
            context.tcpConnect(descriptor,
                               to: topology.remote,
                               port: topology.remotePort) {
                capture.connected = true
                _ = context.tcpSend(descriptor, request)
                context.tcpRecv(descriptor) { bytes in
                    capture.received = bytes
                }
            }
        }

        // Deliver the guest SYN to the gateway. The NAT engine opens the real
        // channel but deliberately withholds SYN-ACK until that channel reports
        // success, so an unreachable upstream never looks connected to the guest.
        topology.loop.advance(by: 0.05)
        #expect(topology.transport.channels.count == 1)
        #expect(topology.transport.channels.first?.endpoint
                == UplinkEndpoint(host: topology.remote, port: topology.remotePort))
        #expect(!capture.connected)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 1)

        let channel = topology.transport.channels[0]
        channel.succeed()
        topology.loop.advance(by: 0.1)

        #expect(capture.connected)
        #expect(channel.sent == request)
        #expect(topology.loop.pendingWorkCount <= 2,
                "NAT timers must be cancelled; the guest TCP stack may retain two legal timers")

        channel.receive(response)
        topology.loop.advance(by: 0.1)

        #expect(capture.received == response)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 1)
    }

    @Test func gracefulHalfClosesInBothDirectionsAndReleasesFlow() {
        let topology = makeTopology()
        let reply = Array("done".utf8)

        final class Capture {
            var connected = false
            var eof = false
        }
        let capture = Capture()

        topology.guest.spawn("nat-close-client") { context in
            guard let descriptor = context.tcpSocket() else { return }
            context.tcpConnect(descriptor,
                               to: topology.remote,
                               port: topology.remotePort) {
                capture.connected = true
                context.tcpRecv(descriptor) { first in
                    #expect(first == reply)
                    context.tcpClose(descriptor)
                }
            }
        }

        topology.loop.advance(by: 0.05)
        let channel = topology.transport.channels[0]
        channel.succeed()
        topology.loop.advance(by: 0.1)
        #expect(capture.connected)

        channel.receive(reply)
        topology.loop.advance(by: 0.1)
        #expect(channel.didFinish,
                "guest FIN must half-close the real channel's send direction")

        channel.finishFromPeer()
        topology.loop.advance(by: 0.2)

        #expect(channel.wasCancelled,
                "once both FINs are acknowledged the NAT flow releases its channel")
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
        _ = capture.eof
    }

    @Test func upstreamRefusalResetsGuestAndReleasesFlow() {
        let topology = makeTopology()

        // The callback-style tcpConnect API uses one completion to unblock the
        // process for both establishment and reset (it has no Result parameter),
        // so "resumed" is not a success flag. The authoritative refusal evidence
        // is that the guest connection is removed after accepting the RST.
        final class Capture { var resumed = false }
        let capture = Capture()

        topology.guest.spawn("nat-refused-client") { context in
            guard let descriptor = context.tcpSocket() else { return }
            context.tcpConnect(descriptor,
                               to: topology.remote,
                               port: topology.remotePort) {
                capture.resumed = true
            }
        }

        topology.loop.advance(by: 0.05)
        #expect(topology.transport.channels.count == 1)
        topology.transport.channels[0].fail(.connectionRefused)
        topology.loop.advance(by: 0.1)

        #expect(capture.resumed,
                "RST must unblock a callback-style connect waiter")
        #expect(topology.guest.netns.stack.tcpConnectionCount == 0,
                "guest must accept the refused-connection RST and remove the socket flow")
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
    }

    @Test func invalidGuestTCPChecksumCannotCreateOrMutateAFlow() {
        let topology = makeTopology()
        let guestSequence: UInt32 = 1234
        let tcpWithZeroChecksum = TCPSegment.build(sourcePort: 49_152,
                                                   destinationPort: topology.remotePort,
                                                   sequence: guestSequence,
                                                   acknowledgment: 0,
                                                   flags: [.syn],
                                                   window: 4096,
                                                   payload: [])
        let datagram = IPv4Packet.build(source: topology.guestIP,
                                        destination: topology.remote,
                                        proto: IPProtocol.tcp.rawValue,
                                        payload: tcpWithZeroChecksum)
        let frame = EthernetFrame.build(destination: topology.gatewayInterface.mac,
                                        source: topology.guestInterface.mac,
                                        etherType: EtherType.ipv4.rawValue,
                                        payload: datagram)

        topology.gateway.netns.stack.receive(frame, on: topology.gatewayInterface)

        #expect(topology.transport.channels.isEmpty)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
        #expect(topology.gatewayInterface.counters.drops == 1)
        #expect(topology.gatewayInterface.counters.dropsByReason[
            PacketDropReason.invalidTCPChecksum.rawValue
        ] == 1)
    }

    @Test(arguments: [1, 64, 535, 536, 537, 1_460, 4_096])
    func peerPayloadIsRelayedExactlyAcrossSegmentBoundaries(byteCount: Int) {
        let topology = makeTopology()
        let payload = (0..<byteCount).map { UInt8(truncatingIfNeeded: $0) }

        final class Capture { var received: [UInt8] = [] }
        let capture = Capture()

        topology.guest.spawn("nat-segment-client") { context in
            guard let descriptor = context.tcpSocket() else { return }
            context.tcpConnect(descriptor,
                               to: topology.remote,
                               port: topology.remotePort) {
                func receiveUntilComplete() {
                    context.tcpRecv(descriptor) { bytes in
                        guard !bytes.isEmpty else { return }
                        capture.received.append(contentsOf: bytes)
                        if capture.received.count < payload.count {
                            receiveUntilComplete()
                        }
                    }
                }
                receiveUntilComplete()
            }
        }

        topology.loop.advance(by: 0.05)
        let channel = topology.transport.channels[0]
        channel.succeed()
        topology.loop.advance(by: 0.1)
        channel.receive(payload)
        topology.loop.advance(by: 1.0)

        #expect(capture.received == payload)
        #expect(capture.received.count == byteCount)
    }

    @Test func udpPreservesDatagramsBothWaysAndReclaimsIdleFlow() {
        let topology = makeTopology()
        let guestPort: UInt16 = 53_000
        let request = Array("dns-query".utf8)
        let response = Array("dns-response".utf8)

        final class Capture {
            var bytes: [UInt8] = []
            var address: IPv4Address?
            var port: UInt16?
        }
        let capture = Capture()

        topology.guest.spawn("nat-udp-client") { context in
            guard let descriptor = context.socket() else { return }
            #expect(context.bind(descriptor,
                                 address: topology.guestIP,
                                 port: guestPort))
            _ = context.sendto(descriptor,
                               request,
                               to: topology.remote,
                               port: topology.remotePort)
            context.recvfrom(descriptor) { bytes, address, port in
                capture.bytes = bytes
                capture.address = address
                capture.port = port
            }
        }

        topology.loop.advance(by: 0.1)
        #expect(topology.transport.udpChannels.count == 1)
        let channel = topology.transport.udpChannels[0]
        #expect(channel.endpoint
                == UplinkEndpoint(host: topology.remote, port: topology.remotePort))
        #expect(channel.sent == [request])
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 1)

        channel.receive(response)
        topology.loop.advance(by: 0.1)

        #expect(capture.bytes == response)
        #expect(capture.address == topology.remote)
        #expect(capture.port == topology.remotePort)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 1)

        topology.loop.advance(by: 30.1)
        #expect(channel.wasCancelled)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
    }

    @Test func waitingHostConnectionTimesOutAndReleasesFlow() {
        let topology = makeTopology()

        topology.guest.spawn("nat-timeout-client") { context in
            guard let descriptor = context.tcpSocket() else { return }
            context.tcpConnect(descriptor,
                               to: topology.remote,
                               port: topology.remotePort) {}
        }

        topology.loop.advance(by: 0.05)
        #expect(topology.transport.channels.count == 1)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 1)

        topology.loop.advance(by: 30.1)

        #expect(topology.transport.channels[0].wasCancelled)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
    }

    @Test func removingGuestFlowsCancelsTCPAndUDPBeforeKernelReuse() {
        let topology = makeTopology()

        topology.guest.spawn("nat-live-tcp") { context in
            guard let descriptor = context.tcpSocket() else { return }
            context.tcpConnect(descriptor,
                               to: topology.remote,
                               port: topology.remotePort) {}
        }
        topology.guest.spawn("nat-live-udp") { context in
            guard let descriptor = context.socket() else { return }
            _ = context.sendto(descriptor,
                               [0x01],
                               to: topology.remote,
                               port: 53)
        }

        topology.loop.advance(by: 0.1)
        #expect(topology.transport.channels.count == 1)
        #expect(topology.transport.udpChannels.count == 1)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 2)

        topology.gateway.netns.stack.removeUplinkFlows(for: topology.guestIP)

        #expect(topology.transport.channels[0].wasCancelled)
        #expect(topology.transport.udpChannels[0].wasCancelled)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
    }

    @Test func ttlExpiryCannotOpenARealTransportChannel() {
        let topology = makeTopology()
        var segment = TCPSegment.build(sourcePort: 49_152,
                                       destinationPort: topology.remotePort,
                                       sequence: 1234,
                                       acknowledgment: 0,
                                       flags: [.syn],
                                       window: 4096,
                                       payload: [])
        let checksum = TransportChecksum.transport(source: topology.guestIP,
                                                   destination: topology.remote,
                                                   proto: IPProtocol.tcp.rawValue,
                                                   segment: segment)
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)
        let datagram = IPv4Packet.build(source: topology.guestIP,
                                        destination: topology.remote,
                                        proto: IPProtocol.tcp.rawValue,
                                        ttl: 1,
                                        payload: segment)
        let frame = EthernetFrame.build(destination: topology.gatewayInterface.mac,
                                        source: topology.guestInterface.mac,
                                        etherType: EtherType.ipv4.rawValue,
                                        payload: datagram)

        topology.gateway.netns.stack.receive(frame, on: topology.gatewayInterface)

        #expect(topology.transport.channels.isEmpty)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 0)
        #expect(topology.gatewayInterface.counters.dropsByReason[
            PacketDropReason.ttlExpired.rawValue
        ] == 1)
    }

    @Test func repeatedUDPActivityKeepsOneIdleTimerPerAssociation() {
        let topology = makeTopology()

        topology.guest.spawn("nat-udp-burst") { context in
            guard let descriptor = context.socket() else { return }
            #expect(context.bind(descriptor,
                                 address: topology.guestIP,
                                 port: 53_001))
            for byte in UInt8(0)..<100 {
                _ = context.sendto(descriptor,
                                   [byte],
                                   to: topology.remote,
                                   port: topology.remotePort)
            }
        }

        topology.loop.advance(by: 0.5)

        #expect(topology.transport.udpChannels.count == 1)
        #expect(topology.transport.udpChannels[0].sent.count == 100)
        #expect(topology.gateway.netns.stack.uplinkFlowCount == 1)
        #expect(topology.loop.pendingWorkCount <= 2,
                "one UDP association must not enqueue one idle timer per datagram")
    }

    // MARK: - Harness

    private struct Topology {
        let loop: EventLoop
        let guest: Kernel
        let gateway: Kernel
        let guestIP: IPv4Address
        let remote: IPv4Address
        let remotePort: UInt16
        let guestInterface: NetworkStack.Interface
        let gatewayInterface: NetworkStack.Interface
        let transport: FakeUplinkTransport
    }

    private func makeTopology() -> Topology {
        let loop = EventLoop()
        let guest = Kernel(loop: loop)
        let gateway = Kernel(loop: loop)
        let guestIP = IPv4Address(10, 42, 0, 2)
        let gatewayIP = IPv4Address(10, 42, 0, 1)
        let remote = IPv4Address(203, 0, 113, 80)
        let remotePort: UInt16 = 443
        let guestMAC = MACAddress("02:00:00:00:42:02")!
        let gatewayMAC = MACAddress("02:00:00:00:42:01")!

        let guestInterface = guest.netns.stack.configuredInterface(address: guestIP,
                                                                   mac: guestMAC)
        let gatewayInterface = gateway.netns.stack.configuredInterface(address: gatewayIP,
                                                                       mac: gatewayMAC)
        guest.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                           prefixLength: 0,
                                           gateway: gatewayIP)
        guest.netns.stack.configuredNeighbor(ip: gatewayIP, mac: gatewayMAC)
        gateway.netns.stack.configuredNeighbor(ip: guestIP, mac: guestMAC)
        TestWire.connect(guest.netns.stack,
                         guestInterface,
                         gateway.netns.stack,
                         gatewayInterface,
                         on: loop,
                         latency: 0.001)

        let transport = FakeUplinkTransport()
        gateway.netns.stack.installUplink(transport, initialISN: 0x0102_0304)

        return Topology(loop: loop,
                        guest: guest,
                        gateway: gateway,
                        guestIP: guestIP,
                        remote: remote,
                        remotePort: remotePort,
                        guestInterface: guestInterface,
                        gatewayInterface: gatewayInterface,
                        transport: transport)
    }
}

/// Deterministic stand-in for SwiftixBridge's real socket transport. Tests drive
/// every lifecycle callback explicitly on the same executor as the stack.
private final class FakeUplinkTransport: UplinkTransport {
    final class Channel: UplinkTCPChannel {
        let endpoint: UplinkEndpoint
        private var observer: (any UplinkTCPObserver)?
        private(set) var sent: [UInt8] = []
        private(set) var didFinish = false
        private(set) var wasCancelled = false

        init(endpoint: UplinkEndpoint, observer: any UplinkTCPObserver) {
            self.endpoint = endpoint
            self.observer = observer
        }

        func send(_ bytes: [UInt8]) {
            guard !wasCancelled else { return }
            sent.append(contentsOf: bytes)
        }

        func finish() {
            guard !wasCancelled else { return }
            didFinish = true
        }

        func cancel() {
            wasCancelled = true
            observer = nil
        }

        func succeed() {
            guard !wasCancelled else { return }
            observer?.uplinkDidOpen()
        }

        func receive(_ bytes: [UInt8]) {
            guard !wasCancelled else { return }
            observer?.uplinkDidReceive(bytes)
        }

        func finishFromPeer() {
            guard !wasCancelled else { return }
            observer?.uplinkDidFinish()
        }

        func fail(_ failure: UplinkFailure) {
            guard !wasCancelled else { return }
            let current = observer
            observer = nil
            current?.uplinkDidFail(failure)
        }
    }

    final class UDPChannel: UplinkUDPChannel {
        let endpoint: UplinkEndpoint
        private var observer: (any UplinkUDPObserver)?
        private(set) var sent: [[UInt8]] = []
        private(set) var wasCancelled = false

        init(endpoint: UplinkEndpoint, observer: any UplinkUDPObserver) {
            self.endpoint = endpoint
            self.observer = observer
        }

        func send(_ bytes: [UInt8]) {
            guard !wasCancelled else { return }
            sent.append(bytes)
        }

        func cancel() {
            wasCancelled = true
            observer = nil
        }

        func receive(_ bytes: [UInt8]) {
            guard !wasCancelled else { return }
            observer?.uplinkUDPDidReceive(bytes)
        }

        func fail(_ failure: UplinkFailure) {
            guard !wasCancelled else { return }
            let current = observer
            observer = nil
            current?.uplinkUDPDidFail(failure)
        }
    }

    private(set) var channels: [Channel] = []
    private(set) var udpChannels: [UDPChannel] = []

    func openTCP(to endpoint: UplinkEndpoint,
                 observer: any UplinkTCPObserver) -> any UplinkTCPChannel {
        let channel = Channel(endpoint: endpoint, observer: observer)
        channels.append(channel)
        return channel
    }

    func openUDP(to endpoint: UplinkEndpoint,
                 observer: any UplinkUDPObserver) -> any UplinkUDPChannel {
        let channel = UDPChannel(endpoint: endpoint, observer: observer)
        udpChannels.append(channel)
        return channel
    }
}
