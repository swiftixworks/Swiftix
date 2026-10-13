/// Hash-indexed storage behind a Swiftix Go map.
///
/// Entries keep their insertion order, which is the order `range` visits them
/// in, so a program's output never depends on the host's hash seed: the hash
/// index is only ever probed by key, never iterated. Lookup, insertion, and
/// deletion are O(1) amortized. A value type with no process or executor state.

/// A map key with the hash the index needs. Equality is `GoValue` equality, and
/// the hash covers only what that equality compares, so equal keys always meet
/// in one bucket.
struct GoMapKey: Hashable, Sendable {
    let value: GoValue

    static func == (lhs: GoMapKey, rhs: GoMapKey) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        Self.combine(value, into: &hasher)
    }

    private static func combine(_ value: GoValue, into hasher: inout Hasher) {
        switch value {
        case .int(let integer):
            hasher.combine(0 as UInt8)
            hasher.combine(integer)
        case .string(let string):
            hasher.combine(1 as UInt8)
            hasher.combine(string)
        case .bool(let boolean):
            hasher.combine(2 as UInt8)
            hasher.combine(boolean)
        case .nilValue:
            hasher.combine(3 as UInt8)
        case .structure(let structure):
            hasher.combine(4 as UInt8)
            hasher.combine(structure.fields.count)
            for field in structure.fields { combine(field.value, into: &hasher) }
        case .pointer(let pointer):
            hasher.combine(5 as UInt8)
            hasher.combine(pointer.cell)
            hasher.combine(pointer.path.count)
        case .array(let values):
            hasher.combine(6 as UInt8)
            hasher.combine(values.count)
            for element in values { combine(element, into: &hasher) }
        case .interface(let interface):
            hasher.combine(7 as UInt8)
            hasher.combine(interface.typeName)
            combine(interface.value, into: &hasher)
        case .channel(let channel):
            hasher.combine(8 as UInt8)
            hasher.combine(channel.storage.cell)
        case .slice, .map, .mapStorage, .channelStorage, .mutex, .mutexStorage, .waitGroup,
            .waitGroupStorage, .context, .contextStorage, .netConn, .netListener:
            // Not Go map keys. They share one bucket and equality decides.
            hasher.combine(9 as UInt8)
        }
    }
}

public struct GoMapStorage: Sendable, Equatable {
    /// Entries in insertion order. A deleted entry leaves a `nil` slot, so the
    /// positions in `slotIndex` stay valid until the next compaction.
    private var slots: [(key: GoValue, value: GoValue)?]
    /// Slot of every live key.
    private var slotIndex: [GoMapKey: Int]

    /// Deleted slots tolerated before a compaction is considered.
    private static let minimumCompactionVacancies = 32

    /// The live entries in insertion order. Assigning replaces the whole map;
    /// a key that repeats keeps its first position and its last value.
    public var entries: [(key: GoValue, value: GoValue)] {
        get { slots.compactMap { $0 } }
        set {
            slots = []
            slotIndex = [:]
            reserveCapacity(newValue.count)
            for entry in newValue { set(entry.key, entry.value) }
        }
    }

    /// Number of live entries.
    public var count: Int { slotIndex.count }

    public init(entries: [(key: GoValue, value: GoValue)] = []) {
        slots = []
        slotIndex = [:]
        self.entries = entries
    }

    public func get(_ key: GoValue) -> GoValue? {
        entry(for: key)?.value
    }

    public mutating func set(_ key: GoValue, _ value: GoValue) {
        let hashed = GoMapKey(value: key)
        if let slot = slotIndex[hashed] {
            slots[slot]?.value = value
        } else {
            slotIndex[hashed] = slots.count
            slots.append((key: key, value: value))
        }
    }

    public mutating func delete(_ key: GoValue) {
        guard let slot = slotIndex.removeValue(forKey: GoMapKey(value: key)) else { return }
        slots[slot] = nil
        while let last = slots.last, last == nil { slots.removeLast() }
        let vacancies = slots.count - slotIndex.count
        if vacancies >= Self.minimumCompactionVacancies, vacancies > slotIndex.count {
            compact()
        }
    }

    public static func == (lhs: GoMapStorage, rhs: GoMapStorage) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var left = lhs.slots.makeIterator()
        var right = rhs.slots.makeIterator()
        while true {
            switch (Self.nextEntry(&left), Self.nextEntry(&right)) {
            case (nil, nil):
                return true
            case (let l?, let r?):
                if l.key != r.key || l.value != r.value { return false }
            default:
                return false
            }
        }
    }

    /// The stored entry for `key`. Its key is the one first inserted, which
    /// can differ in representation from an equal `key`.
    func entry(for key: GoValue) -> (key: GoValue, value: GoValue)? {
        guard let slot = slotIndex[GoMapKey(value: key)] else { return nil }
        return slots[slot]
    }

    /// The live keys in insertion order.
    var keys: [GoValue] {
        var result: [GoValue] = []
        result.reserveCapacity(slotIndex.count)
        for case let entry? in slots { result.append(entry.key) }
        return result
    }

    /// Visit the live entries in insertion order without copying them.
    func forEachEntry(_ body: (_ key: GoValue, _ value: GoValue) throws -> Void) rethrows {
        for case let entry? in slots { try body(entry.key, entry.value) }
    }

    mutating func reserveCapacity(_ minimumCapacity: Int) {
        slots.reserveCapacity(minimumCapacity)
        slotIndex.reserveCapacity(minimumCapacity)
    }

    /// Drop the deleted slots and renumber the index.
    private mutating func compact() {
        var live: [(key: GoValue, value: GoValue)?] = []
        live.reserveCapacity(slotIndex.count)
        for case let entry? in slots {
            slotIndex[GoMapKey(value: entry.key)] = live.count
            live.append(entry)
        }
        slots = live
    }

    private static func nextEntry(
        _ iterator: inout IndexingIterator<[(key: GoValue, value: GoValue)?]>
    ) -> (key: GoValue, value: GoValue)? {
        while let slot = iterator.next() {
            if let entry = slot { return entry }
        }
        return nil
    }
}
