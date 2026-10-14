/// The scheduler's tables, which it uses on every switch between goroutines.
///
/// While more than one goroutine is runnable the VM switches after every
/// instruction: the running goroutine's context is stored, its identifier
/// queued, and the next one taken out. A `Dictionary` hashes each identifier
/// with SipHash and an `Array` shifts on `removeFirst`; these do neither, and
/// keep the same order of service.

/// A map from goroutine identifiers to values: open addressing with linear
/// probing, a multiplicative hash, and backward-shift deletion.
struct GoIntTable<Value> {
    private struct Entry {
        let key: Int
        var value: Value
    }

    private var entries: [Entry?] = []
    private(set) var count = 0

    private var mask: Int { entries.count - 1 }

    private func home(of key: Int) -> Int {
        let mixed = UInt64(bitPattern: Int64(key)) &* 0x9E37_79B9_7F4A_7C15
        return Int(truncatingIfNeeded: mixed >> 32) & mask
    }

    private func slot(of key: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        var index = home(of: key)
        while let entry = entries[index] {
            if entry.key == key { return index }
            index = (index + 1) & mask
        }
        return nil
    }

    subscript(key: Int) -> Value? {
        get {
            guard let index = slot(of: key) else { return nil }
            return entries[index]?.value
        }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            if let index = slot(of: key) {
                entries[index] = Entry(key: key, value: newValue)
                return
            }
            if (count + 1) * 4 > entries.count * 3 { grow() }
            var index = home(of: key)
            while entries[index] != nil { index = (index + 1) & mask }
            entries[index] = Entry(key: key, value: newValue)
            count += 1
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Int) -> Value? {
        guard var hole = slot(of: key) else { return nil }
        let removed = entries[hole].take()?.value
        count -= 1
        // Move later entries of the probe run back into the hole, so a
        // lookup never stops early at it.
        var index = hole
        while true {
            index = (index + 1) & mask
            guard let key = entries[index]?.key else { break }
            let distanceFromHome = (index - home(of: key)) & mask
            let distanceFromHole = (index - hole) & mask
            if distanceFromHome >= distanceFromHole {
                entries[hole] = entries[index].take()
                hole = index
            }
        }
        return removed
    }

    /// Every value, in no particular order.
    var values: [Value] {
        entries.compactMap { $0?.value }
    }

    private mutating func grow() {
        let old = entries
        entries = Array(repeating: nil, count: max(16, old.count * 2))
        for case let entry? in old {
            var index = home(of: entry.key)
            while entries[index] != nil { index = (index + 1) & mask }
            entries[index] = entry
        }
    }
}

/// The runnable goroutines, first in first out, with a `removeFirst` that
/// does not shift the rest.
///
/// A goroutine the scheduler switches away from while it can still run is
/// queued with its context, so the switch does not store it in the table of
/// parked goroutines only to take it out again; one woken from the table is
/// queued by identifier alone.
struct GoRunQueue<Context> {
    /// A ring of `capacity` entries, `count` of them in use from `head`.
    private var slots: [(id: Int, context: Context?)] = []
    private var head = 0
    private var count = 0
    /// How many queued entries carry their context.
    private(set) var contextCount = 0

    var isEmpty: Bool { count == 0 }

    mutating func append(_ id: Int) {
        enqueue((id, nil))
    }

    mutating func append(_ id: Int, context: Context) {
        enqueue((id, context))
        contextCount += 1
    }

    private mutating func enqueue(_ entry: (id: Int, context: Context?)) {
        if count == slots.count {
            // Unroll the ring into a buffer twice the size.
            var grown: [(id: Int, context: Context?)] = []
            grown.reserveCapacity(max(8, slots.count * 2))
            for offset in 0..<count {
                grown.append(slots[(head + offset) % slots.count])
            }
            while grown.count < max(8, slots.count * 2) { grown.append((0, nil)) }
            slots = grown
            head = 0
        }
        slots[(head + count) % slots.count] = entry
        count += 1
    }

    mutating func removeFirst() -> (id: Int, context: Context?) {
        precondition(count > 0, "removeFirst from an empty run queue")
        // Move the entry out, leaving an empty slot, without a copy.
        var first: (id: Int, context: Context?) = (0, nil)
        swap(&first, &slots[head])
        head = (head + 1) % slots.count
        count -= 1
        if first.context != nil { contextCount -= 1 }
        return first
    }

    /// The contexts the queue holds, for the collector's roots.
    var contexts: [Context] {
        (0..<count).compactMap { slots[(head + $0) % slots.count].context }
    }
}
