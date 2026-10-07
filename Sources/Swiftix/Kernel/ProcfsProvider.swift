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
                                            memoryBytes: entry.memoryBytes,
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
            processIntrospection.snapshotProcesses().map { String($0.pid) } + ["self"]
        }
        procDirectory.resolveDynamicChild = { [weak vfs] name in
            // /proc/self: a link to the directory of whichever process is
            // resolving the path (see `VirtualFileSystem.reader`).
            if name == "self" {
                guard let reader = vfs?.reader,
                      processIntrospection.row(for: reader.pid) != nil else { return nil }
                return VNode(symlink: "self", target: String(reader.pid))
            }
            guard let pid = Int(name), let row = processIntrospection.row(for: PID(pid)) else { return nil }
            return makePidDirectory(row)
        }
    }

    /// Build a transient `/proc/<pid>` directory holding this process's synthetic
    /// status, command line, descriptor diagnostics, and bounded completed-call
    /// history. Rebuilt on each lookup — procfs content is always computed, never
    /// persisted.
    private static func makePidDirectory(_ row: ProcessSnapshotRow) -> VNode {
        let directory = VNode(directory: String(row.pid))

        let status = VNode(file: "status")
        status.provider = { Array(statusText(row).utf8) }
        directory.addChild(name: "status", node: status)

        let cmdline = VNode(file: "cmdline")
        cmdline.provider = { Array(row.command.utf8) }
        directory.addChild(name: "cmdline", node: cmdline)

        let fdinfo = VNode(file: "fdinfo")
        fdinfo.provider = { Array(descriptorText(row).utf8) }
        directory.addChild(name: "fdinfo", node: fdinfo)

        let syscalls = VNode(file: "syscalls")
        syscalls.provider = { Array(syscallText(row).utf8) }
        directory.addChild(name: "syscalls", node: syscalls)

        let stat = VNode(file: "stat")
        stat.provider = {
            ProcfsSchema.render([ProcfsSchema.PidStat.line(
                pid: row.pid, name: row.name, state: row.state,
                ppid: row.ppid, pgid: row.pgid, sid: row.sid,
                terminalIndex: row.terminalIndex,
                foregroundGroup: row.terminalForegroundGroup)])
        }
        directory.addChild(name: "stat", node: stat)

        let comm = VNode(file: "comm")
        comm.provider = { Array((row.name + "\n").utf8) }
        directory.addChild(name: "comm", node: comm)

        // environ: NUL-terminated NAME=VALUE records in a stable (sorted) order,
        // readable only by the process's owner and root, like Linux.
        let environ = VNode(file: "environ")
        environ.uid = row.uid
        environ.gid = row.gid
        environ.mode = [.ownerRead]
        environ.provider = {
            var bytes: [UInt8] = []
            for (name, value) in row.environment.sorted(by: { $0.key < $1.key }) {
                bytes.append(contentsOf: Array("\(name)=\(value)".utf8))
                bytes.append(0)
            }
            return bytes
        }
        directory.addChild(name: "environ", node: environ)

        // cwd: a link to the process's working directory. It usually points at
        // an ancestor of /proc; the built-in tree walkers (`find`, `du`, `tree`,
        // `ls -R`, `grep -r`, `rm -r`, `cp -r`, `tar`) do not follow links met
        // during a walk, so a whole-tree traversal still terminates. A zombie
        // has no working directory. `exe` stays absent: a Swiftix process is a
        // native closure, not a file-backed image.
        if row.state != "Z" {
            let cwd = VNode(symlink: "cwd", target: row.workingDirectory)
            cwd.uid = row.uid
            cwd.gid = row.gid
            directory.addChild(name: "cwd", node: cwd)
        }

        // fd/: one node per open descriptor. Opening one duplicates that
        // open-file description into the opener, so only the owner and root may.
        let descriptors = VNode(directory: "fd")
        descriptors.uid = row.uid
        descriptors.gid = row.gid
        descriptors.mode = [.ownerRead, .ownerExecute]
        let globalPID = row.globalPID
        let owner = (uid: row.uid, gid: row.gid)
        let numbers = row.descriptorNumbers
        descriptors.dynamicChildNames = { numbers.map(String.init) }
        descriptors.resolveDynamicChild = { name in
            guard let fd = Int(name), String(fd) == name, numbers.contains(fd) else { return nil }
            let node = VNode(file: name)
            node.deviceKind = .descriptor(pid: globalPID, fd: fd)
            node.uid = owner.uid
            node.gid = owner.gid
            node.mode = [.ownerRead, .ownerWrite]
            return node
        }
        directory.addChild(name: "fd", node: descriptors)

        return directory
    }

    private static func descriptorText(_ row: ProcessSnapshotRow) -> String {
        var lines = ["FD TYPE ACCESS FLAGS OFFSET SIZE DETAIL"]
        for descriptor in row.descriptors {
            lines.append([
                String(descriptor.descriptor),
                descriptor.type,
                descriptor.access,
                descriptor.flags,
                descriptor.offset.map(String.init) ?? "-",
                descriptor.size.map(String.init) ?? "-",
                descriptor.detail,
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func syscallText(_ row: ProcessSnapshotRow) -> String {
        var lines = ["SEQ TICKS SYSCALL RESULT DETAIL"]
        for entry in row.syscalls {
            lines.append([
                String(entry.sequence),
                String(entry.ticks),
                entry.name,
                entry.result,
                entry.detail,
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
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
            + "RuntimeMemory:\t\(row.memoryBytes) bytes\n"
            + "RuntimeMemoryLimit:\t\(row.memoryLimitBytes) bytes\n"
            + "RuntimeHeapCells:\t\(row.heapCells)\n"
            + "RuntimeGCs:\t\(row.garbageCollections)\n"
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
