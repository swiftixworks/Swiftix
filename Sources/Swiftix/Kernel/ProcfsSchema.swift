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
        // TICKS (scheduler steps ≈ CPU activity), FDS, and exact managed-runtime
        // memory sit before NAME so NAME stays the final, space-tolerant column.
        static let fields = ["PID", "PPID", "PGID", "SID", "STATE", "TICKS", "FDS", "MEM", "NAME"]
        static let header = fields.joined(separator: " ")

        static func line(pid: PID, ppid: PID, pgid: PID, sid: PID,
                         state: String, ticks: Int, fds: Int,
                         memoryBytes: Int, name: String) -> String {
            "\(pid) \(ppid) \(pgid) \(sid) \(state) \(ticks) \(fds) \(memoryBytes) \(name)"
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

    /// `/proc/<pid>/stat`: the leading, Linux-ordered fields that have a real
    /// source of truth here. Linux appends some forty further counters (fault
    /// counts, CPU times, memory sizes) that Swiftix does not model; they are
    /// omitted rather than filled with invented zeros, so consumers must parse
    /// by position from the left and not assume the Linux field count.
    enum PidStat {
        static let fields = ["PID", "COMM", "STATE", "PPID", "PGRP", "SESSION", "TTY_NR", "TPGID"]

        /// `ttyNumber` uses the Linux device-number encoding for a UNIX98 pty
        /// (major 136), or 0 without a controlling terminal; `foregroundGroup`
        /// is -1 without one.
        static func line(pid: PID, name: String, state: String,
                         ppid: PID, pgid: PID, sid: PID,
                         terminalIndex: Int?, foregroundGroup: PID?) -> String {
            let ttyNumber = terminalIndex.map { (136 << 8) | $0 } ?? 0
            return "\(pid) (\(name)) \(state) \(ppid) \(pgid) \(sid)"
                + " \(ttyNumber) \(foregroundGroup ?? -1)"
        }
    }

    /// `/proc/loadavg`, in the Linux layout: three load averages, then
    /// `runnable/total` scheduling entities and the most recent pid.
    enum LoadAverage {
        static let path = "/proc/loadavg"
        static let fields = ["LOAD1", "LOAD5", "LOAD15", "RUNNABLE/TOTAL", "LAST_PID"]

        static func line(running: Int, total: Int, lastPID: PID) -> String {
            "0.00 0.00 0.00 \(running)/\(total) \(lastPID)"
        }
    }

    /// `/proc/stat`: the subset of Linux's keys this kernel maintains.
    enum Stat {
        static let path = "/proc/stat"
        static let keys = ["ctxt", "btime", "processes", "procs_running", "procs_blocked"]

        static func lines(contextSwitches: UInt64, bootEpoch: Int64, processesCreated: Int,
                          running: Int, blocked: Int) -> [String] {
            [
                "ctxt \(contextSwitches)",
                "btime \(bootEpoch)",
                "processes \(processesCreated)",
                "procs_running \(running)",
                "procs_blocked \(blocked)",
            ]
        }
    }

    /// `/proc/filesystems`: every type is virtual (`nodev`).
    enum Filesystems {
        static let path = "/proc/filesystems"
        static let types = ["tmpfs", "proc"]
        static var lines: [String] { types.map { "nodev\t\($0)" } }
    }

    /// `/proc/sys/kernel`: read-only kernel identity.
    enum SysKernel {
        static let hostnamePath = "/proc/sys/kernel/hostname"
        static let ostypePath = "/proc/sys/kernel/ostype"
        static let osreleasePath = "/proc/sys/kernel/osrelease"
        /// Matches `uname -s`.
        static let ostype = "Swiftix"
    }

    /// Names present in every `/proc/<pid>` directory.
    enum PidDirectory {
        static let entries = ["cmdline", "comm", "cwd", "environ", "fd", "fdinfo",
                              "stat", "status", "syscalls"]
    }
}
