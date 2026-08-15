/// Amortized-O(1) byte queues used by TCP send and receive flow control.
struct TCPSendBuffer {
    private var bytes = FIFOQueue<UInt8>()

    var isEmpty: Bool { bytes.isEmpty }
    var count: Int { bytes.count }

    mutating func append(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    mutating func popPrefix(_ count: Int) -> [UInt8] {
        bytes.popFirst(count)
    }
}

struct TCPReceiveBuffer {
    private var bytes = FIFOQueue<UInt8>()
    private(set) var capacity: Int

    init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
    }

    var isEmpty: Bool { bytes.isEmpty }
    var count: Int { bytes.count }

    var advertisedWindow: UInt16 {
        let free = Swift.min(Swift.max(capacity - bytes.count, 0), capacity)
        return UInt16(clamping: free)
    }

    /// The true (unscaled) advertised window as a full-width integer. Used by
    /// `TCPConnection` to apply window-scale shifting before placing the value in
    /// the 16-bit header field.
    var trueAdvertisedWindow: UInt32 {
        UInt32(Swift.min(Swift.max(capacity - bytes.count, 0), capacity))
    }

    mutating func setCapacity(_ capacity: Int) {
        self.capacity = Swift.max(1, capacity)
    }

    mutating func append(_ payload: [UInt8]) {
        bytes.append(contentsOf: payload)
    }

    mutating func read(max: Int) -> [UInt8] {
        bytes.popFirst(max)
    }
}
