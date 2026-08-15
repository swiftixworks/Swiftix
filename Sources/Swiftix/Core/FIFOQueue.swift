/// An amortized-O(1) FIFO backed by an array plus a read cursor.
///
/// Swift `Array.removeFirst` shifts every remaining element. Stream buffers and
/// scheduler queues drain from the front frequently, so keeping a cursor avoids
/// quadratic behavior while occasional compaction bounds retained storage.
struct FIFOQueue<Element> {
    private var storage: [Element] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { head == storage.count }
    var first: Element? { isEmpty ? nil : storage[head] }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        storage.append(contentsOf: elements)
    }

    mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        let element = storage[head]
        head += 1
        compactIfNeeded()
        return element
    }

    mutating func popFirst(_ maximumCount: Int) -> [Element] {
        let amount = Swift.min(Swift.max(maximumCount, 0), count)
        guard amount > 0 else { return [] }
        let end = head + amount
        let result = Array(storage[head..<end])
        head = end
        compactIfNeeded()
        return result
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    private mutating func compactIfNeeded() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

/// A fixed-capacity FIFO that rejects newest elements when full.
///
/// Protocol queues use this wrapper to make memory growth explicit while keeping
/// the same amortized-O(1) drain behavior as ``FIFOQueue``. The high-water and
/// rejection counters are cheap, deterministic observability for soak tests.
struct BoundedFIFOQueue<Element> {
    let capacity: Int
    private var storage = FIFOQueue<Element>()
    private(set) var highWaterMark = 0
    private(set) var rejectedCount = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var first: Element? { storage.first }
    var remainingCapacity: Int { capacity - count }

    @discardableResult
    mutating func append(_ element: Element) -> Bool {
        guard count < capacity else {
            rejectedCount += 1
            return false
        }
        storage.append(element)
        highWaterMark = max(highWaterMark, count)
        return true
    }

    /// Append as many elements as fit, dropping the newest overflow.
    @discardableResult
    mutating func append<S: Sequence>(contentsOf elements: S) -> Int where S.Element == Element {
        var accepted = 0
        for element in elements {
            if append(element) { accepted += 1 }
        }
        return accepted
    }

    mutating func popFirst() -> Element? {
        storage.popFirst()
    }

    mutating func popFirst(_ maximumCount: Int) -> [Element] {
        storage.popFirst(maximumCount)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }
}

/// A fixed-capacity circular history. Appending at capacity overwrites the
/// oldest element without shifting the retained entries.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var start = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ element: Element) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(element)
            return
        }
        storage[start] = element
        start = (start + 1) % capacity
    }

    func elements() -> [Element] {
        guard start != 0 else { return storage }
        var result: [Element] = []
        result.reserveCapacity(storage.count)
        result.append(contentsOf: storage[start...])
        result.append(contentsOf: storage[..<start])
        return result
    }
}
