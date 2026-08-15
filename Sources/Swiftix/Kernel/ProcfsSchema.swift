/// Stable field schemas shared by procfs renderers and contract tests.
enum ProcfsSchema {
    static func render(_ lines: [String], header: String? = nil) -> [UInt8] {
        var allLines: [String] = []
        if let header {
            allLines.append(header)
        }
        allLines.append(contentsOf: lines)
        guard !allLines.isEmpty else { return [] }
        return Array((allLines.joined(separator: "\n") + "\n").utf8)
    }

    enum Processes {
        static let path = "/proc/processes"
        // TICKS (scheduler steps ≈ CPU activity) and FDS (open descriptors ≈
        // footprint) sit before NAME so NAME stays the final, space-tolerant column.
        static let fields = ["PID", "PPID", "PGID", "SID", "STATE", "TICKS", "FDS", "NAME"]
        static let header = fields.joined(separator: " ")

        static func line(pid: PID, ppid: PID, pgid: PID, sid: PID,
                         state: String, ticks: Int, fds: Int, name: String) -> String {
            "\(pid) \(ppid) \(pgid) \(sid) \(state) \(ticks) \(fds) \(name)"
        }
    }

    enum NetDev {
        static let path = "/proc/net/dev"
        static let fields = ["IFACE", "ADDR", "MAC", "RX_PACKETS", "TX_PACKETS", "RX_BYTES", "TX_BYTES", "DROPS", "FORWARDED"]

        static func line(name: String,
                         address: IPv4Address,
                         mac: MACAddress,
                         counters: NetworkStack.InterfaceCounters) -> String {
            "\(name) \(address) \(mac)"
                + " rx_packets=\(counters.rxPackets) tx_packets=\(counters.txPackets)"
                + " rx_bytes=\(counters.rxBytes) tx_bytes=\(counters.txBytes)"
                + " drops=\(counters.drops) forwarded=\(counters.forwarded)"
        }
    }

    enum NetRoute {
        static let path = "/proc/net/route"
        static let fields = ["DESTINATION", "GATEWAY", "INTERFACE"]

        static func line(network: IPv4Address,
                         prefixLength: Int,
                         gateway: IPv4Address?,
                         interface: String) -> String {
            "\(network)/\(prefixLength) \(gateway.map { "\($0)" } ?? "*") \(interface)"
        }
    }

    enum NetARP {
        static let path = "/proc/net/arp"
        static let fields = ["ADDRESS", "HWADDRESS"]

        static func line(ip: IPv4Address, mac: MACAddress) -> String {
            "\(ip) \(mac)"
        }
    }

    enum NetUDP {
        static let path = "/proc/net/udp"
        static let fields = ["LOCAL_PORT"]

        static func line(port: UInt16) -> String {
            "\(port)"
        }
    }

    enum NetTCP {
        static let path = "/proc/net/tcp"
        static let fields = ["LOCAL_PORT", "REMOTE", "STATE", "CWND", "SSTHRESH", "SRTT", "RTTVAR", "RTO", "RWND", "PEERWND"]

        static func line(_ snapshot: TCPSnapshot) -> String {
            "\(snapshot.localPort) \(snapshot.remoteIP):\(snapshot.remotePort) \(snapshot.state)"
                + " cwnd=\(snapshot.cwnd) ssthresh=\(snapshot.ssthresh)"
                + " srtt=\(snapshot.srtt) rttvar=\(snapshot.rttvar) rto=\(snapshot.rto)"
                + " rwnd=\(snapshot.rwnd) peerwnd=\(snapshot.peerwnd)"
        }
    }

    enum NetTrace {
        static let tracePath = "/proc/net/trace"
        static let dropPath = "/proc/net/drop"
        static let fields = ["SEQ", "DIRECTION", "INTERFACE", "STAGE", "DETAILS"]

        static func line(_ entry: PacketPathSnapshotEntry) -> String {
            let event = entry.event
            var parts = [
                "\(entry.sequence)",
                event.direction.rawValue,
                event.interfaceName,
                event.stage.rawValue,
                "len=\(event.packetLength)",
            ]
            if let etherType = event.etherType {
                parts.append("ether=\(etherTypeName(etherType))")
            }
            if let proto = event.ipProtocol {
                parts.append("proto=\(ipProtocolName(proto))")
            }
            if let decision = event.routeDecision {
                parts.append("route=\(decision.destination)")
                parts.append("via=\(decision.nextHop)")
                parts.append("dev=\(decision.interfaceName)")
                parts.append("network=\(decision.network)/\(decision.prefixLength)")
                if let gateway = decision.gateway {
                    parts.append("gateway=\(gateway)")
                }
            }
            if let drop = event.dropReason {
                parts.append("drop=\(drop.rawValue)")
            }
            return parts.joined(separator: " ")
        }

        private static func etherTypeName(_ value: UInt16) -> String {
            switch value {
            case EtherType.ipv4.rawValue: return "ipv4"
            case EtherType.arp.rawValue: return "arp"
            default: return "0x" + String(value, radix: 16)
            }
        }

        private static func ipProtocolName(_ value: UInt8) -> String {
            switch value {
            case IPProtocol.icmp.rawValue: return "icmp"
            case IPProtocol.tcp.rawValue: return "tcp"
            case IPProtocol.udp.rawValue: return "udp"
            default: return "\(value)"
            }
        }
    }
}
