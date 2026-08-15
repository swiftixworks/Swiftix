/// A process's open file descriptors: small non-negative integers mapping to
/// open file objects. By convention fd 0/1/2 are stdin/stdout/stderr.
final class FileDescriptorTable {
    private struct Entry {
        let object: FileObject
        var flags: FileStatusFlags
        let access: FileAccessMode
    }

    private var table: [Int: Entry] = [:]

    /// Install `object` at the lowest free descriptor and return it.
    @discardableResult
    func allocate(_ object: FileObject,
                  flags: FileStatusFlags = [],
                  access: FileAccessMode = .readWrite) -> Int {
        var fd = 0
        while table[fd] != nil { fd += 1 }
        table[fd] = Entry(object: object, flags: flags, access: access)
        object.opened()
        return fd
    }

    /// Install `object` at a specific descriptor (used to wire up 0/1/2 and to
    /// implement `dup2`). Any object already at `fd` has its handle released
    /// first, matching `dup2` semantics.
    func install(_ object: FileObject,
                 at fd: Int,
                 flags: FileStatusFlags = [],
                 access: FileAccessMode = .readWrite) {
        table[fd]?.object.closed()
        table[fd] = Entry(object: object, flags: flags, access: access)
        object.opened()
    }

    func object(_ fd: Int) -> FileObject? {
        table[fd]?.object
    }

    func flags(_ fd: Int) -> FileStatusFlags? {
        table[fd]?.flags
    }

    func access(_ fd: Int) -> FileAccessMode? {
        table[fd]?.access
    }

    @discardableResult
    func setFlags(_ fd: Int, _ flags: FileStatusFlags) -> Bool {
        guard var entry = table[fd] else { return false }
        entry.flags = flags
        table[fd] = entry
        return true
    }

    func close(_ fd: Int) {
        table[fd]?.object.closed()
        table[fd] = nil
    }

    /// Copy every descriptor from `other` into this (empty) table, sharing the
    /// same open-file descriptions and counting a new handle for each — the
    /// descriptor half of `fork`/`spawn` inheritance.
    func clone(from other: FileDescriptorTable) {
        for (fd, entry) in other.table {
            table[fd] = entry
            entry.object.opened()
        }
    }

    /// Release every descriptor (process exit): each object's handle is closed so
    /// reference-counted resources (pipes) see their writers/readers go away.
    func closeAll() {
        for entry in table.values { entry.object.closed() }
        table.removeAll()
    }

    var openDescriptors: [Int] { table.keys.sorted() }
}
