/// Copies of values that hold a `sync.Mutex` or a `sync.WaitGroup`.
///
/// Both are handles in the VM: a variable holds a pointer to the lock's
/// state, and `Lock` reaches the state through the copy of the handle it is
/// given, which is how `s.mu.Lock()` locks the mutex in `s`. In Go the state
/// is in the variable, so `t := s` makes a second mutex, locked if the first
/// was. Where a program copies a value that holds a lock out of a variable,
/// a field, an element, or what a pointer points to, into a place of its
/// own (an assignment, an argument, a result, an element of a literal, a
/// value sent or appended, a value receiver), the copy is the reserved call
/// `$sync.copy`, which gives it handles of its own in the state of the old.
/// A value made fresh, by a literal or a call, needs none, and nothing else
/// changes: a program that copies no lock compiles to what it did.
///
/// The copies the VM makes itself, the elements of `make([]T, n)`, of a
/// slice that grows, and of `copy`, it makes so on its own.
extension IRLowerer {
    static let lockCopyName = "$sync.copy"

    /// `register`, the value of `expression` of type `type`, or its copy
    /// with locks of its own when `expression` names a place that keeps the
    /// value and the type holds a lock.
    mutating func copyingLocks(_ register: Int, of expression: GoExpression, type: GoType?) -> Int {
        guard let type, isCopiedPlace(expression), holdsLock(type) else { return register }
        let destination = allocateRegister()
        operations.append(
            .call(function: Self.lockCopyName, arguments: [register], destinations: [destination]))
        return destination
    }

    /// `copyingLocks` for the receiver of a method with a value receiver.
    /// A method of `sync.Mutex` itself has none in Go: it takes a pointer,
    /// which the handle stands for, so the handle is passed as it is.
    mutating func copyingReceiverLocks(
        _ register: Int, of expression: GoExpression, type: GoType
    ) -> Int {
        if type == .named("sync.Mutex") || type == .named("sync.WaitGroup") { return register }
        return copyingLocks(register, of: expression, type: type)
    }

    /// Gives the value in `register`, a copy of type `type` the VM made
    /// (the value variable of a `range`), locks of its own if it holds any.
    mutating func copyLocks(in register: Int, type: GoType) {
        guard holdsLock(type) else { return }
        operations.append(
            .call(function: Self.lockCopyName, arguments: [register], destinations: [register]))
    }

    /// Whether a value of `type` holds a `sync.Mutex` or a `sync.WaitGroup`
    /// itself: as a field or an element, at any depth, embedded or not.
    func holdsLock(_ type: GoType, visiting: Set<String> = []) -> Bool {
        switch type {
        case .named(let name):
            if name == "sync.Mutex" || name == "sync.WaitGroup" { return true }
            guard !visiting.contains(name),
                let definition = typeDefinitions[name]?.underlying
                    ?? GoPredeclared.underlying(of: name)
            else { return false }
            return holdsLock(definition, visiting: visiting.union([name]))
        case .structure(let fields):
            return fields.contains { holdsLock($0.type, visiting: visiting) }
        case .array(let length, let element):
            return length > 0 && holdsLock(element, visiting: visiting)
        default:
            return false
        }
    }

    /// Whether the value of `expression` stays where it is when it is used:
    /// a variable, a field, an element, a map's value, what a pointer points
    /// to, the value in an interface, or a conversion of one of those.
    func isCopiedPlace(_ expression: GoExpression) -> Bool {
        switch expression {
        case .identifier, .selector, .index, .typeAssertion, .unary(.dereference, _, _):
            return true
        case .call(let callee, let arguments, _):
            guard arguments.count == 1, conversionTarget(callee) != nil else { return false }
            return isCopiedPlace(arguments[0])
        default:
            return false
        }
    }
}

extension FunctionChecker {
    /// Whether the `sync.Mutex` or `sync.WaitGroup` that `base` names has an
    /// address for `Lock` to take: it is addressable, or a field of a struct
    /// reached through a pointer, as `shardFor(key).mu` is.
    mutating func hasLockAddress(_ base: GoExpression) -> Bool {
        if isAddressable(base) { return true }
        guard case .selector(let inner, _, _) = base, let innerType = try? type(of: inner)
        else { return false }
        return innerType.pointee(in: typeDefinitions) != nil || hasLockAddress(inner)
    }
}
