/// A process's open file descriptors: small non-negative integers mapping to
/// open file objects. By convention fd 0/1/2 are stdin/stdout/stderr.
final class FileDescriptorTable {
    struct DiagnosticSnapshot: Equatable {
        let descriptor: Int
        let type: String
        let access: String
        let flags: String
        let offset: Int?
        let size: Int?
        let detail: String
    }
    /// One system-wide open-file description. Multiple descriptors created by
    /// `dup` or inherited by `spawn` share this object, and therefore share the
    /// file offset held by `object`, the access mode, and file-status flags.
    ///
    /// `FileObject.opened/closed` bracket the lifetime of this description, not
    /// each descriptor that points at it. This is what makes pipe endpoint counts,
    /// socket bindings, deferred deletion, and `flock` survive until the last
    /// duplicate descriptor is closed.
    private final class OpenFileDescription {
        let object: FileObject
        let access: FileAccessMode
        var statusFlags: FileStatusFlags
        private var descriptorReferences = 0

        init(object: FileObject,
             statusFlags: FileStatusFlags,
             access: FileAccessMode) {
            self.object = object
            self.statusFlags = statusFlags
            self.access = access
        }

        func retainDescriptor() {
            if descriptorReferences == 0 { object.opened() }
            descriptorReferences += 1
        }

        func releaseDescriptor() {
            guard descriptorReferences > 0 else { return }
            descriptorReferences -= 1
            if descriptorReferences == 0 { object.closed() }
        }
    }

    private struct Entry {
        let description: OpenFileDescription
    }

    private var table: [Int: Entry] = [:]
    private var isSealed = false

    /// Install `object` at the lowest free descriptor and return it.
    @discardableResult
    func allocate(_ object: FileObject,
                  flags: FileStatusFlags = [],
                  access: FileAccessMode = .readWrite) -> Int {
        guard !isSealed else { return -1 }
        let description = OpenFileDescription(object: object,
                                              statusFlags: flags,
                                              access: access)
        return allocate(description)
    }

    /// Install another descriptor for an existing open-file description.
    private func allocate(_ description: OpenFileDescription) -> Int {
        guard !isSealed else { return -1 }
        var fd = 0
        while table[fd] != nil { fd += 1 }
        table[fd] = Entry(description: description)
        description.retainDescriptor()
        return fd
    }

    /// Install `object` at a specific descriptor (used to wire up 0/1/2 and to
    /// implement `dup2`). Any object already at `fd` has its handle released
    /// first, matching `dup2` semantics.
    func install(_ object: FileObject,
                 at fd: Int,
                 flags: FileStatusFlags = [],
                 access: FileAccessMode = .readWrite) {
        guard !isSealed else { return }
        let description = OpenFileDescription(object: object,
                                              statusFlags: flags,
                                              access: access)
        install(description, at: fd)
    }

    private func install(_ description: OpenFileDescription, at fd: Int) {
        guard !isSealed else { return }
        table[fd]?.description.releaseDescriptor()
        table[fd] = Entry(description: description)
        description.retainDescriptor()
    }

    func object(_ fd: Int) -> FileObject? {
        table[fd]?.description.object
    }

    func flags(_ fd: Int) -> FileStatusFlags? {
        table[fd]?.description.statusFlags
    }

    func access(_ fd: Int) -> FileAccessMode? {
        table[fd]?.description.access
    }

    @discardableResult
    func setFlags(_ fd: Int, _ flags: FileStatusFlags) -> Bool {
        guard let description = table[fd]?.description else { return false }
        description.statusFlags = flags
        return true
    }

    func close(_ fd: Int) {
        table[fd]?.description.releaseDescriptor()
        table[fd] = nil
    }

    /// Duplicate `fd` to the lowest free descriptor while preserving the shared
    /// open-file description.
    func duplicate(_ fd: Int) -> Int? {
        guard let description = table[fd]?.description else { return nil }
        return allocate(description)
    }

    /// Duplicate `fd` onto `target` (`dup2`). Closing an existing target releases
    /// only that descriptor reference; the source description remains live.
    @discardableResult
    func duplicate(_ fd: Int, onto target: Int) -> Bool {
        guard let description = table[fd]?.description else { return false }
        if fd == target { return true }
        install(description, at: target)
        return true
    }

    /// Copy every descriptor from `other` into this (empty) table, sharing the
    /// same open-file descriptions and counting a new handle for each — the
    /// descriptor half of `fork`/`spawn` inheritance.
    func clone(from other: FileDescriptorTable) {
        guard !isSealed else { return }
        for (fd, entry) in other.table {
            table[fd] = entry
            entry.description.retainDescriptor()
        }
    }

    /// Release every descriptor (process exit): each object's handle is closed so
    /// reference-counted resources (pipes) see their writers/readers go away.
    func closeAll() {
        for entry in table.values { entry.description.releaseDescriptor() }
        table.removeAll()
        isSealed = true
    }

    var openDescriptors: [Int] { table.keys.sorted() }

    /// Immutable descriptor diagnostics for procfs/teaching tools. The snapshot
    /// intentionally exposes object kinds and state, not mutable file objects.
    /// A regular file has no canonical path because hard links give one inode
    /// multiple equally valid names.
    var diagnosticSnapshots: [DiagnosticSnapshot] {
        table.keys.sorted().compactMap { descriptor in
            guard let description = table[descriptor]?.description else { return nil }
            let object = description.object
            let type: String
            let detail: String
            switch object {
            case let endpoint as PipeEndpoint:
                type = "pipe"
                detail = endpoint.isWriteEnd ? "write-end" : "read-end"
            case let endpoint as FifoEndpoint:
                type = "fifo"
                detail = endpoint.isWriteEnd ? "write-end" : "read-end"
            case is RegularFileHandle:
                type = "file"
                detail = "-"
            case is PseudoTerminal.Slave:
                type = "tty"
                detail = "pty-slave"
            case let socket as UDPSocket:
                type = "udp"
                detail = socket.localPort == 0 ? "unbound" : "local=:\(socket.localPort)"
            case let socket as TCPSocket:
                type = "tcp"
                if let listener = socket.listener {
                    detail = "listen=:\(listener.port)"
                } else if let connection = socket.connection {
                    let snapshot = connection.snapshot
                    detail = "local=:\(snapshot.localPort),remote=\(snapshot.remoteIP):\(snapshot.remotePort),state=\(snapshot.state)"
                } else if let port = socket.boundPort {
                    detail = "bound=:\(port)"
                } else {
                    detail = "unbound"
                }
            case is NullDeviceHandle:
                type = "device"
                detail = "null"
            default:
                type = "other"
                detail = "-"
            }
            let access: String
            switch description.access {
            case .none: access = "none"
            case .readOnly: access = "read"
            case .writeOnly: access = "write"
            case .readWrite: access = "read-write"
            }
            let flags = description.statusFlags.contains(.nonBlocking)
                ? "nonblock" : "-"
            let seekable = object as? Seekable
            return DiagnosticSnapshot(
                descriptor: descriptor,
                type: type,
                access: access,
                flags: flags,
                offset: seekable?.seekOffset,
                size: seekable?.byteSize,
                detail: detail)
        }
    }
}
