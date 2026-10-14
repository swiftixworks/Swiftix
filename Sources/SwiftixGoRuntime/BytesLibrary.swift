/// The natives of the library's `bytes` and `bufio`, which are written in
/// Go: what they do with every byte of a slice, done in one call. The
/// compiler's side is `GoStandardLibrary.bytesNativeFunction`.
///
/// Pure value transformation; no executor state.
enum GoBytes {
    /// Reserved call names with their operand counts.
    static let argumentCounts: [String: Int] = [
        "$bufio.indexByte": 2,
        "$bytes.indexByte": 2,
        "$bytes.index": 2,
        "$bytes.equal": 2,
        "$bytes.compare": 2,
    ]

    /// The result of the native `name` for the elements of its two slices,
    /// or of its slice and `byte`.
    static func result(
        _ name: String, _ first: ArraySlice<GoValue>, _ second: ArraySlice<GoValue>,
        byte: GoValue
    ) -> GoValue? {
        switch name {
        case "$bufio.indexByte", "$bytes.indexByte":
            return .int(Int64(first.firstIndex(of: byte).map { $0 - first.startIndex } ?? -1))
        case "$bytes.index":
            return .int(Int64(index(of: second, in: first)))
        case "$bytes.equal":
            return .bool(first.elementsEqual(second))
        case "$bytes.compare":
            for (left, right) in zip(first, second) where left != right {
                guard case .int(let a) = left, case .int(let b) = right else { return nil }
                return .int(a < b ? -1 : 1)
            }
            return .int(first.count == second.count ? 0 : first.count < second.count ? -1 : 1)
        default:
            return nil
        }
    }

    /// Where `part` first lies in `whole`, or -1. An empty part lies at 0.
    private static func index(of part: ArraySlice<GoValue>, in whole: ArraySlice<GoValue>) -> Int {
        guard let head = part.first else { return 0 }
        guard part.count <= whole.count else { return -1 }
        var at = whole.startIndex
        let last = whole.endIndex - part.count
        while at <= last {
            guard let found = whole[at...last].firstIndex(of: head) else { return -1 }
            if whole[found..<(found + part.count)].elementsEqual(part) {
                return found - whole.startIndex
            }
            at = found + 1
        }
        return -1
    }
}
