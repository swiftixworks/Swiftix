/// Copies of the values that hold a `sync.Mutex` or a `sync.WaitGroup`.
///
/// Both are handles: the variable holds a pointer to the lock's state, and a
/// call of `Lock` reaches the state through whatever copy of the handle it
/// was given. In Go the state is in the variable, so a copy of a struct that
/// holds a mutex is a second mutex, in the state the first was in. The VM
/// makes that copy wherever a value is copied into a place of its own: the
/// compiler calls `$sync.copy` where a program copies such a value, and the
/// VM's own copies, the elements of `make([]T, n)`, a slice that grows, and
/// `copy`, go through here too. Only the handles are new; everything else is
/// the value as it was.
enum GoLockCopies {
    /// The reserved call that copies its operand so.
    static let copyName = "$sync.copy"

    /// Whether `value` holds a handle of a lock by value: in a field, an
    /// element of an array, at any depth. A pointer, a slice, a map, and an
    /// interface share what they refer to, as in Go.
    static func holdsLock(_ value: GoValue) -> Bool {
        switch value {
        case .mutex, .waitGroup: return true
        case .structure(let structure): return structure.fields.contains { holdsLock($0.value) }
        case .array(let elements): return elements.contains(where: holdsLock)
        default: return false
        }
    }

    /// `value` with a new handle for each it holds, in the state of the old
    /// one: locked or not, with the same count. Nobody waits on the new one.
    /// `read` gives the cell a handle points to, `allocate` makes a cell.
    static func copied(
        _ value: GoValue, read: (GoPointer) throws -> GoValue,
        allocate: (GoValue) throws -> Int
    ) throws -> GoValue {
        switch value {
        case .mutex(let mutex):
            guard case .mutexStorage(let state) = try read(mutex.storage) else {
                throw GoRuntimeError.typeMismatch
            }
            let cell = try allocate(.mutexStorage(GoMutexStorage(locked: state.locked)))
            return .mutex(GoMutexValue(storage: GoPointer(cell: cell)))
        case .waitGroup(let group):
            guard case .waitGroupStorage(let state) = try read(group.storage) else {
                throw GoRuntimeError.typeMismatch
            }
            let cell = try allocate(.waitGroupStorage(GoWaitGroupStorage(count: state.count)))
            return .waitGroup(GoWaitGroupValue(storage: GoPointer(cell: cell)))
        case .structure(var structure):
            guard holdsLock(value) else { return value }
            for index in structure.fields.indices {
                structure.fields[index].value = try copied(
                    structure.fields[index].value, read: read, allocate: allocate)
            }
            return .structure(structure)
        case .array(var elements):
            guard holdsLock(value) else { return value }
            for index in elements.indices {
                elements[index] = try copied(elements[index], read: read, allocate: allocate)
            }
            return .array(elements)
        default:
            return value
        }
    }
}
