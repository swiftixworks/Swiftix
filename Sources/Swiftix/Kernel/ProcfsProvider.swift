/// Builds synthetic procfs nodes from immutable snapshots of live kernel state.
enum ProcfsProvider {
    /// Mount the synthetic /proc tree. Providers compute live bytes when opened,
    /// so process/network observability stays current without persisting procfs
    /// files in filesystem snapshots.
    static func mount(on vfs: VirtualFileSystem,
                      networkNamespace: NetworkNamespace,
                      processIntrospection: ProcessIntrospection) {
        vfs.createSyntheticFile(ProcfsSchema.NetDev.path) {
            // Interface identity plus live traffic counters keyed by the same
            // "eth<index>" names as the interface snapshot.
            let counters = Dictionary(uniqueKeysWithValues:
                networkNamespace.stack.snapshotInterfaceCounters().map { ($0.name, $0.counters) })
            let lines = networkNamespace.stack.snapshotInterfaces().map { interface in
                let c = counters[interface.name] ?? NetworkStack.InterfaceCounters()
                return ProcfsSchema.NetDev.line(name: interface.name,
                                                address: interface.address,
                                                mac: interface.mac,
                                                counters: c)
            }
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.NetRoute.path) {
            let lines = networkNamespace.stack.snapshotRoutes().map { route in
                ProcfsSchema.NetRoute.line(network: route.network,
                                           prefixLength: route.prefixLength,
                                           gateway: route.gateway,
                                           interface: route.interface)
            }
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.NetARP.path) {
            let lines = networkNamespace.stack.snapshotARP().map { entry in
                ProcfsSchema.NetARP.line(ip: entry.ip, mac: entry.mac)
            }
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.NetUDP.path) {
            let lines = networkNamespace.stack.snapshotUDPPorts().map(ProcfsSchema.NetUDP.line)
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.NetTCP.path) {
            let lines = networkNamespace.stack.snapshotTCP().map { conn in
                ProcfsSchema.NetTCP.line(conn)
            }
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.NetTrace.tracePath) {
            let lines = networkNamespace.stack.snapshotPacketPathEvents().map(ProcfsSchema.NetTrace.line)
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.NetTrace.dropPath) {
            let lines = networkNamespace.stack.snapshotPacketDrops().map(ProcfsSchema.NetTrace.line)
            return ProcfsSchema.render(lines)
        }
        vfs.createSyntheticFile(ProcfsSchema.Processes.path) {
            let lines = processIntrospection.snapshotProcesses().map { entry in
                ProcfsSchema.Processes.line(pid: entry.pid,
                                            ppid: entry.ppid,
                                            pgid: entry.pgid,
                                            sid: entry.sid,
                                            state: entry.state,
                                            ticks: entry.ticks,
                                            fds: entry.fds,
                                            name: entry.name)
            }
            return ProcfsSchema.render(lines, header: ProcfsSchema.Processes.header)
        }
    }

    /// Mount the live per-process tree: `/proc/<pid>/status` and
    /// `/proc/<pid>/cmdline`, resolved from the process table each time they are
    /// listed or opened (so processes appear at spawn and disappear at reap). The
    /// `/proc` directory becomes a *dynamic directory* whose computed children are
    /// retained live and zombie pids.
    static func mountPerProcess(on vfs: VirtualFileSystem, processIntrospection: ProcessIntrospection) {
        guard let procDirectory = vfs.lookup("/proc") else { return }
        procDirectory.dynamicChildNames = {
            processIntrospection.snapshotProcesses().map { String($0.pid) }
        }
        procDirectory.resolveDynamicChild = { name in
            guard let pid = Int(name), let row = processIntrospection.row(for: PID(pid)) else { return nil }
            return makePidDirectory(row)
        }
    }

    /// Build a transient `/proc/<pid>` directory holding this process's synthetic
    /// `status` and `cmdline` files. Rebuilt on each lookup — procfs content is
    /// always computed, never persisted.
    private static func makePidDirectory(_ row: ProcessSnapshotRow) -> VNode {
        let directory = VNode(directory: String(row.pid))

        let status = VNode(file: "status")
        status.provider = { Array(statusText(row).utf8) }
        directory.addChild(name: "status", node: status)

        let cmdline = VNode(file: "cmdline")
        cmdline.provider = { Array(row.command.utf8) }
        directory.addChild(name: "cmdline", node: cmdline)

        return directory
    }

    /// The `/proc/<pid>/status` body — a small, Linux-flavored subset.
    private static func statusText(_ row: ProcessSnapshotRow) -> String {
        "Name:\t\(row.name)\n"
            + "State:\t\(row.state) \(stateDescription(row.state))\n"
            + "Pid:\t\(row.pid)\n"
            + "PPid:\t\(row.ppid)\n"
            + "PGid:\t\(row.pgid)\n"
            + "Sid:\t\(row.sid)\n"
            + "FDSize:\t\(row.fds)\n"
    }

    private static func stateDescription(_ state: String) -> String {
        switch state {
        case "R": return "(running)"
        case "S": return "(sleeping)"
        case "T": return "(stopped)"
        case "Z": return "(zombie)"
        default:  return ""
        }
    }
}
