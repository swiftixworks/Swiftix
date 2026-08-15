/// The outbound path: route lookup, ARP resolution, and handing frames to the
/// interface's egress seam.
///
/// A packet that cannot be resolved parks in the pending queue until ARP
/// completes or the retry budget runs out.
///
/// Split out of `NetworkStack.swift`; see that file for the type's role and its
/// concurrency contract. Everything here runs on the single serial executor that
/// drives the stack and holds no locks.

extension NetworkStack {

    // MARK: - Egress (route -> ARP -> wire)

    /// Resolve the egress interface + next hop using longest-prefix match. There
    /// is deliberately no implicit interface-0 route: off-link traffic requires
    /// an explicit route in the node configuration.
    func resolveEgress(to destination: IPv4Address) -> (interface: Interface, nextHop: IPv4Address, route: Route)? {
        guard let route = routeTable.lookup(destination: destination),
              let interface = interfaceTable.interface(at: route.interfaceIndex) else { return nil }
        return (interface, route.gateway ?? destination, route)
    }

    /// Build and send an IPv4 datagram. The source address is taken from the
    /// *egress* interface chosen by the route (so a multi-homed host uses the
    /// correct source per route), and the next hop's MAC is resolved via ARP
    /// (the packet is queued until resolution completes).
    @discardableResult
    func sendIPv4(proto: UInt8, to destination: IPv4Address, ttl: UInt8 = 64, payload: [UInt8]) -> Bool {
        sendIPv4(proto: proto, to: destination, ttl: ttl) { _ in payload }
    }

    /// Build and send an IPv4 datagram whose transport payload depends on the
    /// resolved egress *source* address (design.md §3 "Where compute happens").
    /// Routing chooses the egress interface — and thus the source IP — before the
    /// payload is finalized, so `buildPayload` is handed that source and can stamp
    /// a transport checksum computed over the IPv4 pseudo-header (R7.1, R7.2).
    /// The existing `payload:` form delegates here with a constant closure, so its
    /// behavior is unchanged.
    @discardableResult
    func sendIPv4(proto: UInt8, to destination: IPv4Address,
                          ttl: UInt8 = 64,
                          buildPayload: (_ source: IPv4Address) -> [UInt8]) -> Bool {
        guard let (interface, nextHop, route) = resolveEgress(to: destination) else { return false }
        let payload = buildPayload(interface.address)
        let packet = ipv4.build(source: interface.address,
                                destination: destination,
                                proto: proto,
                                ttl: ttl,
                                payload: payload)
        return egressIPv4Packet(packet,
                                destination: destination,
                                proto: proto,
                                interface: interface,
                                nextHop: nextHop,
                                route: route,
                                stage: .route)
    }

    /// Emit a transport segment toward `destination` (the guest) as though it
    /// originated from `source` (the real peer). Used by the uplink NAT engine to
    /// deliver segments to the guest on the peer's behalf: it stamps the transport
    /// checksum over the (source, destination) pseudo-header at `checksumOffset`,
    /// builds the IPv4 datagram with the explicit `source`, and egresses it via the
    /// route to the guest (ARP resolves the guest's already-cached MAC). Internal —
    /// this is the one place the stack forges a non-local source address, and only
    /// for a locally-terminated NAT flow.
    func emitUplinkTransport(source: IPv4Address,
                             destination: IPv4Address,
                             proto: UInt8,
                             segment: [UInt8],
                             checksumOffset: Int) {
        let checksummed = Self.transportChecksummed(segment,
                                                    source: source,
                                                    destination: destination,
                                                    proto: proto,
                                                    checksumOffset: checksumOffset)
        _ = sendIPv4(explicitSource: source, to: destination, proto: proto, payload: checksummed)
    }

    /// Build and send an IPv4 datagram with an explicit `source` address (instead
    /// of the egress interface's own address). Routing to `destination` still
    /// chooses the egress interface + next hop and ARP-resolves it as usual.
    @discardableResult
    func sendIPv4(explicitSource source: IPv4Address,
                          to destination: IPv4Address,
                          proto: UInt8,
                          ttl: UInt8 = 64,
                          payload: [UInt8]) -> Bool {
        guard let (interface, nextHop, route) = resolveEgress(to: destination) else { return false }
        let packet = ipv4.build(source: source,
                                destination: destination,
                                proto: proto,
                                ttl: ttl,
                                payload: payload)
        return egressIPv4Packet(packet,
                                destination: destination,
                                proto: proto,
                                interface: interface,
                                nextHop: nextHop,
                                route: route,
                                stage: .forward)
    }

    @discardableResult
    func egressIPv4Packet(_ packet: [UInt8],
                                  destination: IPv4Address,
                                  proto: UInt8,
                                  interface: Interface,
                                  nextHop: IPv4Address,
                                  route: Route,
                                  stage: PacketPathStage) -> Bool {
        let interfaceName = interfaceTable.name(for: route.interfaceIndex)
        observability.emitPath(stage: stage,
                               frameLength: packet.count,
                               on: interface,
                               direction: .outbound,
                               interfaces: interfaceTable,
                               ipProtocol: proto,
                               routeDecision: PacketRouteDecision(destination: destination,
                                                                  nextHop: nextHop,
                                                                  interfaceName: interfaceName,
                                                                  network: IPv4Address(raw: route.network),
                                                                  prefixLength: route.prefixLength,
                                                                  gateway: route.gateway))
        if let mac = neighborCache.mac(for: nextHop) {
            transmit(packet, etherType: EtherType.ipv4.rawValue, to: mac, from: interface)
        } else {
            guard neighborCache.enqueue(packet, waitingFor: nextHop) else {
                observability.emitPath(stage: .route,
                                       frameLength: packet.count,
                                       on: interface,
                                       direction: .outbound,
                                       interfaces: interfaceTable,
                                       ipProtocol: proto,
                                       routeDecision: PacketRouteDecision(
                                           destination: destination,
                                           nextHop: nextHop,
                                           interfaceName: interfaceName,
                                           network: IPv4Address(raw: route.network),
                                           prefixLength: route.prefixLength,
                                           gateway: route.gateway),
                                       dropReason: .arpPendingQueueFull)
                return false
            }
            // Broadcast the request and arm the retry chain only for the *first*
            // packet waiting on this next hop; later packets ride the same in-flight
            // resolution (dedup), exactly as a real host issues one ARP burst.
            if let epoch = neighborCache.beginResolution(for: nextHop) {
                sendARPRequest(target: nextHop, on: interface)
                scheduleARPRetry(target: nextHop, on: interface, epoch: epoch,
                                 attemptsRemaining: arpMaxAttempts - 1)
            }
        }
        return true
    }

    func sendICMPError(type: ICMPMessage.MessageType,
                               code: UInt8,
                               originalDatagram: [UInt8],
                               to destination: IPv4Address) {
        let message = ICMPMessage.buildError(type: type, code: code, originalDatagram: originalDatagram)
        _ = sendIPv4(proto: IPProtocol.icmp.rawValue, to: destination, payload: message)
    }

    /// Stamp a TCP/UDP transport checksum into `segment` at `checksumOffset` now
    /// that the egress `source` is known. The 16-bit field is zeroed, the checksum
    /// is computed over the IPv4 pseudo-header + segment, and the result is written
    /// big-endian into the field (R7.1, R7.2). For UDP a computed value of 0 is
    /// transmitted as 0xFFFF (RFC 768) so it is not read as "checksum not present".
    static func transportChecksummed(_ segment: [UInt8],
                                             source: IPv4Address,
                                             destination: IPv4Address,
                                             proto: UInt8,
                                             checksumOffset: Int) -> [UInt8] {
        var out = segment
        guard out.count >= checksumOffset + 2 else { return out }
        out[checksumOffset] = 0
        out[checksumOffset + 1] = 0
        var checksum = TransportChecksum.transport(source: source,
                                                   destination: destination,
                                                   proto: proto,
                                                   segment: out)
        if proto == IPProtocol.udp.rawValue && checksum == 0 { checksum = 0xFFFF }
        out[checksumOffset] = UInt8((checksum >> 8) & 0xFF)
        out[checksumOffset + 1] = UInt8(checksum & 0xFF)
        return out
    }

    func transmit(_ payload: [UInt8], etherType: UInt16, to mac: MACAddress, from interface: Interface) {
        guard lifecycleState == .active else { return }
        let frame = EthernetFrame.build(destination: mac,
                                        source: interface.mac,
                                        etherType: etherType,
                                        payload: payload)
        interface.counters.txPackets += 1                // R13.2
        interface.counters.txBytes += frame.count
        emitTrace(frame, on: interface, direction: .outbound)   // R14.2
        observability.emitPath(stage: .egress,
                               frameLength: frame.count,
                               on: interface,
                               direction: .outbound,
                               interfaces: interfaceTable,
                               etherType: etherType)
        interface.onEgress?(frame)
    }

    /// Best-effort per-frame trace (R14). When a hook is installed, hand it the frame
    /// by value (so it cannot mutate the bytes the stack transmits/delivers, R14.5),
    /// the interface index, and the direction. When unset this is a no-op (R14.4). The
    /// hook's result is ignored and the caller proceeds regardless, so the trace call
    /// cannot alter or block frame processing (R14.6). `PacketBuffer` value semantics
    /// give byte isolation; in pure Swift a hook that traps cannot be caught, so this
    /// wraps the call as defensively as the language allows.
    func emitTrace(_ frame: PacketBuffer, on interface: Interface, direction: PacketDirection) {
        observability.emitTrace(frame, on: interface, direction: direction, interfaces: interfaceTable)
    }

    private func sendARPRequest(target: IPv4Address, on interface: Interface) {
        let request = ARPPacket.build(opcode: .request,
                                    senderMAC: interface.mac,
                                    senderIP: interface.address,
                                    targetMAC: MACAddress([0, 0, 0, 0, 0, 0])!,
                                    targetIP: target)
        transmit(request, etherType: EtherType.arp.rawValue, to: .broadcast, from: interface)
    }

    /// Re-broadcast the ARP request for `target` after `arpRetryInterval` if it is
    /// still unresolved, up to `arpMaxAttempts` total attempts, then give up and
    /// discard the queued packets. Each fire is guarded by the resolution `epoch`
    /// (see `NetworkNeighborCache`): once the reply lands (which clears the epoch)
    /// or the resolution is superseded/torn down, the timer is a no-op — so a
    /// resolved next hop never keeps re-broadcasting, and the loop always
    /// terminates instead of probing forever (mirrors the TCP retransmit cap).
    private func scheduleARPRetry(target: IPv4Address,
                                  on interface: Interface,
                                  epoch: Int,
                                  attemptsRemaining: Int) {
        schedule(after: arpRetryInterval) { [weak self, weak interface] in
            guard let self, let interface else { return }
            // Superseded, resolved, or torn down: the captured epoch is no longer
            // the current one for this target.
            guard self.neighborCache.resolutionEpoch(for: target) == epoch else { return }
            guard attemptsRemaining > 0 else {
                self.abandonResolution(target: target, on: interface)
                return
            }
            self.sendARPRequest(target: target, on: interface)
            self.scheduleARPRetry(target: target, on: interface, epoch: epoch,
                                  attemptsRemaining: attemptsRemaining - 1)
        }
    }

    /// Give up resolving `target`: drop the packets queued behind it and clear the
    /// resolution state. The discards are surfaced as `arpResolutionFailed` on the
    /// packet path (for `drops`/`trace`), but the *interface* rx/drop counters are
    /// left untouched — those account for inbound frames, and conflating an egress
    /// L2-unreachable with an inbound drop would break the rx conservation
    /// invariant (`rxPackets + drops == frames received`).
    private func abandonResolution(target: IPv4Address, on interface: Interface) {
        let dropped = neighborCache.drainPending(waitingFor: target)
        neighborCache.endResolution(for: target)
        for packet in dropped {
            observability.emitPath(stage: .route,
                                   frameLength: packet.count,
                                   on: interface,
                                   direction: .outbound,
                                   interfaces: interfaceTable,
                                   dropReason: .arpResolutionFailed)
        }
    }

    func flushPending(to ip: IPv4Address, on interface: Interface) {
        guard let mac = neighborCache.mac(for: ip) else { return }
        for packet in neighborCache.drainPending(waitingFor: ip) {
            transmit(packet, etherType: EtherType.ipv4.rawValue, to: mac, from: interface)
        }
    }
}
