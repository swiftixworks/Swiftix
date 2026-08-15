/// The inbound path: `receive(_:on:)`, the L2/L3 dispatch, forwarding, and the
/// per-protocol handlers (ARP / ICMP / UDP / TCP).
///
/// Every refused frame funnels through `drop(_:stage:frameLength:on:)` so the
/// per-reason counters and the packet-path trace stay complete (R13.4).
///
/// Split out of `NetworkStack.swift`; see that file for the type's role and its
/// concurrency contract. Everything here runs on the single serial executor that
/// drives the stack and holds no locks.

extension NetworkStack {

    // MARK: - Ingress (consumer injects an inbound frame here)

    public func receive(_ frame: PacketBuffer, on interface: Interface) {
        guard lifecycleState == .active else { return }
        emitTrace(frame, on: interface, direction: .inbound)   // R14.3
        observability.emitPath(stage: .ingress,
                               frameLength: frame.count,
                               on: interface,
                               direction: .inbound,
                               interfaces: interfaceTable)
        // Every inbound frame reaches exactly one of two outcomes: it is accepted
        // (parsed and dispatched) or dropped (failed parsing/verification). The
        // dispatch returns that decision so the counting happens in one place and a
        // later task can turn a checksum-verification failure into a drop simply by
        // returning `false` from the relevant handler.
        if dispatchInbound(frame, on: interface) {
            interface.counters.rxPackets += 1            // R13.3
            interface.counters.rxBytes += frame.count
        } else {
            interface.counters.drops += 1                // R13.4
        }
    }

    public func receive(_ frame: PacketBuffer, on interface: any NetworkInterface) {
        guard let interface = interface as? Interface,
              interfaceTable.index(of: interface) != nil else { return }
        receive(frame, on: interface)
    }

    /// Parse and dispatch an inbound frame. Returns `true` when the frame is accepted
    /// (delivered to a protocol handler) and `false` when it is discarded due to a
    /// parse (or, in a later task, checksum-verification) failure.
    private func dispatchInbound(_ frame: PacketBuffer, on interface: Interface) -> Bool {
        guard let header = EthernetFrame.parseHeader(frame) else {
            return drop(.malformedEthernet, stage: .layer2, frameLength: frame.count, on: interface)
        }
        guard header.destination == interface.mac || header.destination.isMulticast else {
            return drop(.wrongDestinationMAC,
                        stage: .layer2,
                        frameLength: frame.count,
                        on: interface,
                        etherType: header.etherType)
        }
        let payload = EthernetFrame.payload(frame)
        observability.emitPath(stage: .layer2,
                               frameLength: frame.count,
                               on: interface,
                               direction: .inbound,
                               interfaces: interfaceTable,
                               etherType: header.etherType)
        switch header.etherType {
        case EtherType.arp.rawValue:
            if let reason = handleARP(payload, on: interface) {
                return drop(reason,
                            stage: .layer2,
                            frameLength: payload.count,
                            on: interface,
                            etherType: header.etherType)
            }
            return true
        case EtherType.ipv4.rawValue:
            guard let (ipHeader, ipPayload) = ipv4.parse(payload) else {
                return drop(.malformedIPv4,
                            stage: .layer3,
                            frameLength: payload.count,
                            on: interface,
                            etherType: header.etherType)
            }
            observability.emitPath(stage: .layer3,
                                   frameLength: payload.count,
                                   on: interface,
                                   direction: .inbound,
                                   interfaces: interfaceTable,
                                   etherType: header.etherType,
                                   ipProtocol: ipHeader.proto)
            if !isLocalDestination(ipHeader.destination) {
                // A real-network uplink (user-mode NAT) takes precedence over L3
                // forwarding: non-local traffic is TERMINATED and relayed to the
                // real network rather than routed to another interface. A pure NAT
                // gateway installs an uplink and (typically) has a single LAN, so
                // every non-local destination is upstream-bound (see UplinkNAT).
                if let uplink {
                    // Uplink termination still represents one routed hop. Do not
                    // let proxying bypass IPv4 TTL expiry merely because no raw
                    // packet is emitted onto the host network.
                    guard ipHeader.ttl > 1 else {
                        sendICMPError(type: .timeExceeded,
                                      code: 0,
                                      originalDatagram: Array(payload),
                                      to: ipHeader.source)
                        return drop(.ttlExpired,
                                    stage: .forward,
                                    frameLength: payload.count,
                                    on: interface,
                                    etherType: header.etherType,
                                    ipProtocol: ipHeader.proto)
                    }
                    if let reason = uplink.handleGuestDatagram(ipHeader, ipPayload) {
                        return drop(reason,
                                    stage: .forward,
                                    frameLength: payload.count,
                                    on: interface,
                                    etherType: header.etherType,
                                    ipProtocol: ipHeader.proto)
                    }
                    return true
                }
                guard ipForwardingEnabled else {
                    return drop(.notLocalDestination,
                                stage: .layer3,
                                frameLength: payload.count,
                                on: interface,
                                etherType: header.etherType,
                                ipProtocol: ipHeader.proto)
                }
                return forwardIPv4(ipHeader,
                                   payload: ipPayload,
                                   originalDatagram: Array(payload),
                                   ingressInterface: interface,
                                   etherType: header.etherType)
            }
            observability.emitPath(stage: .localDeliver,
                                   frameLength: ipPayload.count,
                                   on: interface,
                                   direction: .inbound,
                                   interfaces: interfaceTable,
                                   etherType: header.etherType,
                                   ipProtocol: ipHeader.proto)
            switch ipHeader.proto {
            case IPProtocol.icmp.rawValue:
                return deliverLayer4(ipHeader, ipPayload, on: interface, etherType: header.etherType) {
                    handleICMP(ipHeader, ipPayload)
                }
            case IPProtocol.udp.rawValue:
                return deliverLayer4(ipHeader, ipPayload, on: interface, etherType: header.etherType) {
                    handleUDP(ipHeader, ipPayload)
                }
            case IPProtocol.tcp.rawValue:
                return deliverLayer4(ipHeader, ipPayload, on: interface, etherType: header.etherType) {
                    handleTCP(ipHeader, ipPayload)
                }
            default: return true    // received at the IP layer; protocol simply unhandled
            }
        default:
            return true             // received at L2; ether type simply unhandled
        }
    }

    private func isLocalDestination(_ destination: IPv4Address) -> Bool {
        if interfaceTable.contains(address: destination) || destination.raw == UInt32.max {
            return true
        }
        return interfaces.contains { interface in
            let mask = NetworkRouteTable.mask(interface.prefixLength)
            return destination.raw == (interface.address.raw & mask) | ~mask
        }
    }

    private func forwardIPv4(_ header: IPv4Packet.Header,
                             payload: ArraySlice<UInt8>,
                             originalDatagram: [UInt8],
                             ingressInterface: Interface,
                             etherType: UInt16) -> Bool {
        guard header.ttl > 1 else {
            sendICMPError(type: .timeExceeded,
                          code: 0,
                          originalDatagram: originalDatagram,
                          to: header.source)
            return drop(.ttlExpired,
                        stage: .forward,
                        frameLength: originalDatagram.count,
                        on: ingressInterface,
                        etherType: etherType,
                        ipProtocol: header.proto)
        }
        guard let (egressInterface, nextHop, route) = resolveEgress(to: header.destination) else {
            sendICMPError(type: .destinationUnreachable,
                          code: 0,
                          originalDatagram: originalDatagram,
                          to: header.source)
            return drop(.noRoute,
                        stage: .route,
                        frameLength: originalDatagram.count,
                        on: ingressInterface,
                        etherType: etherType,
                        ipProtocol: header.proto)
        }
        let forwarded = ipv4.build(source: header.source,
                                   destination: header.destination,
                                   proto: header.proto,
                                   ttl: header.ttl - 1,
                                   payload: Array(payload))
        ingressInterface.counters.forwarded += 1
        return egressIPv4Packet(forwarded,
                                destination: header.destination,
                                proto: header.proto,
                                interface: egressInterface,
                                nextHop: nextHop,
                                route: route,
                                stage: .forward)
    }

    private func deliverLayer4(_ ipHeader: IPv4Packet.Header,
                               _ ipPayload: ArraySlice<UInt8>,
                               on interface: Interface,
                               etherType: UInt16,
                               _ handler: () -> PacketDropReason?) -> Bool {
        observability.emitPath(stage: .layer4,
                               frameLength: ipPayload.count,
                               on: interface,
                               direction: .inbound,
                               interfaces: interfaceTable,
                               etherType: etherType,
                               ipProtocol: ipHeader.proto)
        if let reason = handler() {
            return drop(reason,
                        stage: .layer4,
                        frameLength: ipPayload.count,
                        on: interface,
                        etherType: etherType,
                        ipProtocol: ipHeader.proto)
        }
        return true
    }

    // MARK: - Ingress: per-protocol handlers
    //
    // Reached from `dispatchInbound` above. `drop` is the shared accounting
    // path every handler funnels a refused frame through (R13.4).

    func drop(_ reason: PacketDropReason,
                      stage: PacketPathStage,
                      frameLength: Int,
                      on interface: Interface,
                      etherType: UInt16? = nil,
                      ipProtocol: UInt8? = nil) -> Bool {
        interface.counters.dropsByReason[reason.rawValue, default: 0] += 1
        observability.emitPath(stage: stage,
                               frameLength: frameLength,
                               on: interface,
                               direction: .inbound,
                               interfaces: interfaceTable,
                               etherType: etherType,
                               ipProtocol: ipProtocol,
                               dropReason: reason)
        return false
    }

    func handleARP(_ payload: ArraySlice<UInt8>, on interface: Interface) -> PacketDropReason? {
        guard let packet = ARPPacket.parse(payload) else { return .malformedARP }
        neighborCache.set(ip: packet.senderIP, mac: packet.senderMAC)
        if packet.opcode == ARPPacket.Opcode.request.rawValue, packet.targetIP == interface.address {
            let reply = ARPPacket.build(opcode: .reply,
                                        senderMAC: interface.mac,
                                        senderIP: interface.address,
                                        targetMAC: packet.senderMAC,
                                        targetIP: packet.senderIP)
            transmit(reply, etherType: EtherType.arp.rawValue, to: packet.senderMAC, from: interface)
        }
        flushPending(to: packet.senderIP, on: interface)
        return nil
    }

    func handleICMP(_ ipHeader: IPv4Packet.Header, _ ipPayload: ArraySlice<UInt8>) -> PacketDropReason? {
        // Verify the ICMP checksum over the message before processing; a corrupted
        // echo is dropped (R8.6) and counted as a drop (R13.4) by the caller.
        guard TransportChecksum.verifyICMP(ipPayload) else { return .invalidICMPChecksum }
        let base = ipPayload.startIndex
        guard ipPayload.count >= ICMPMessage.headerLength else { return .malformedICMP }
        let type = ipPayload[base]

        // ICMP error messages (time-exceeded, destination-unreachable) carry the
        // original datagram's IP header + first 8 bytes of transport payload after
        // the 8-byte ICMP header. If that original was an ICMP echo request, we
        // extract the identifier+sequence and complete the echo waiter with the
        // error source address — this is what makes traceroute work.
        if type == ICMPMessage.MessageType.timeExceeded.rawValue
            || type == ICMPMessage.MessageType.destinationUnreachable.rawValue {
            // Quoted original: starts at byte 8 of the ICMP message.
            let quotedStart = base + ICMPMessage.headerLength
            // Need at least an IPv4 header (20 bytes) + 8 bytes ICMP id+seq.
            guard ipPayload.count >= ICMPMessage.headerLength + IPv4Packet.headerLength + ICMPMessage.headerLength else {
                return nil   // too short to extract; not a drop, just ignore
            }
            let quotedProto = ipPayload[quotedStart + 9]
            guard quotedProto == IPProtocol.icmp.rawValue else { return nil }
            // The quoted ICMP header starts right after the quoted IPv4 header.
            let quotedICMPStart = quotedStart + IPv4Packet.headerLength
            let quotedType = ipPayload[quotedICMPStart]
            guard quotedType == ICMPMessage.MessageType.echoRequest.rawValue else { return nil }
            let identifier = (UInt16(ipPayload[quotedICMPStart + 4]) << 8) | UInt16(ipPayload[quotedICMPStart + 5])
            let sequence = (UInt16(ipPayload[quotedICMPStart + 6]) << 8) | UInt16(ipPayload[quotedICMPStart + 7])
            let key = Self.echoKey(identifier, sequence)
            if let onReply = transport.echoWaiters[key] {
                transport.echoWaiters[key] = nil
                // A time-exceeded/unreachable is reported to the waiter as if it
                // were the "reply"; its TTL is the error packet's own TTL.
                onReply(ipHeader.source, ipHeader.ttl)
            }
            return nil
        }

        guard let echo = ICMPMessage.parseEcho(ipPayload) else { return .malformedICMP }
        if echo.type == ICMPMessage.MessageType.echoRequest.rawValue {
            let reply = ICMPMessage.buildEcho(type: .echoReply,
                                            identifier: echo.identifier,
                                            sequence: echo.sequence,
                                            payload: echo.payload)
            _ = sendIPv4(proto: IPProtocol.icmp.rawValue, to: ipHeader.source, payload: reply)
        } else if echo.type == ICMPMessage.MessageType.echoReply.rawValue {
            let key = Self.echoKey(echo.identifier, echo.sequence)
            if let onReply = transport.echoWaiters[key] {
                transport.echoWaiters[key] = nil
                onReply(ipHeader.source, ipHeader.ttl)
            }
        }
        return nil
    }

    func handleUDP(_ ipHeader: IPv4Packet.Header, _ ipPayload: ArraySlice<UInt8>) -> PacketDropReason? {
        // Verify the UDP checksum only when the datagram carries one. The checksum
        // field is bytes 6-7 of the UDP datagram; a value of 0 means "no checksum"
        // and the datagram is accepted without verification (R8.4). A non-zero field
        // that does not verify is a corrupted datagram and is dropped (R8.3). Either
        // way every datagram reaches a binary accept/drop decision (R8.5).
        if ipPayload.count >= 8 {
            let base = ipPayload.startIndex
            let checksumField = (UInt16(ipPayload[base + 6]) << 8) | UInt16(ipPayload[base + 7])
            if checksumField != 0,
               !TransportChecksum.verifyTransport(source: ipHeader.source,
                                                  destination: ipHeader.destination,
                                                  proto: IPProtocol.udp.rawValue,
                                                  segment: ipPayload) {
                return .invalidUDPChecksum
            }
        }
        guard let (udpHeader, udpPayload) = UDPDatagram.parse(ipPayload) else { return .malformedUDP }
        // A valid datagram with no bound socket is still a received frame, not a drop.
        guard let socket = transport.udpSockets[udpHeader.destinationPort] else { return nil }
        guard socket.deliver(Datagram(payload: Array(udpPayload),
                                      sourceAddress: ipHeader.source,
                                      sourcePort: udpHeader.sourcePort)) else {
            return .udpReceiveQueueFull
        }
        return nil
    }

    func handleTCP(_ ipHeader: IPv4Packet.Header, _ ipPayload: ArraySlice<UInt8>) -> PacketDropReason? {
        // Verify the TCP checksum over the IPv4 pseudo-header before processing. A
        // corrupted segment is dropped WITHOUT altering connection state (R8.1, R8.2)
        // and counted as a drop (R13.4) by the caller — no connection is looked up,
        // created, or fed a segment when verification fails.
        guard TransportChecksum.verifyTransport(source: ipHeader.source,
                                                destination: ipHeader.destination,
                                                proto: IPProtocol.tcp.rawValue,
                                                segment: ipPayload) else { return .invalidTCPChecksum }
        guard let (header, payload) = TCPSegment.parse(ipPayload) else { return .malformedTCP }
        let key = TCPKey(localPort: header.destinationPort,
                        remoteIP: ipHeader.source.raw,
                        remotePort: header.sourcePort)
        if let connection = transport.tcpConnections[key] {
            connection.receiveSegment(header, Array(payload))
        } else if header.flags.contains(.syn), let listener = transport.tcpListeners[header.destinationPort] {
            let connection = TCPConnection(stack: self,
                                        localPort: header.destinationPort,
                                        remoteIP: ipHeader.source,
                                        remotePort: header.sourcePort)
            transport.tcpConnections[key] = connection
            connection.acceptSYN(header, listener: listener)
        } else if !header.flags.contains(.rst) {
            // A non-RST segment that matches no connection and no listener (or a
            // non-SYN segment with no match) gets a RST so the peer learns the port
            // or connection is unavailable (R9.1, R9.2). A segment that itself
            // carries RST is dropped silently to avoid RST loops.
            if header.flags.contains(.ack) {
                // The triggering segment acknowledges data: seed the RST's sequence
                // from that ack and send a bare RST (no ACK flag) (R9.3).
                sendRST(to: ipHeader.source,
                        localPort: header.destinationPort,
                        remotePort: header.sourcePort,
                        seq: header.acknowledgment,
                        ack: 0,
                        ackFlag: false)
            } else {
                // No ack to mirror: acknowledge the triggering segment's sequence
                // space (payload + SYN/FIN control bits) and set the ACK flag (R9.4).
                let segmentLength = payload.count
                    + (header.flags.contains(.syn) ? 1 : 0)
                    + (header.flags.contains(.fin) ? 1 : 0)
                sendRST(to: ipHeader.source,
                        localPort: header.destinationPort,
                        remotePort: header.sourcePort,
                        seq: 0,
                        ack: header.sequence &+ UInt32(segmentLength),
                        ackFlag: true)
            }
        }
        return nil
    }
}
