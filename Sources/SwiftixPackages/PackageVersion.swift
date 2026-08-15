/// Debian package version parsing and ordering.
///
/// Versions use `[epoch:]upstream[-revision]` and compare with the same
/// digit/non-digit algorithm as dpkg, including the special ordering of `~`.

public struct PackageVersion: Sendable, Hashable, Comparable, CustomStringConvertible {

    public let epoch: Int
    public let upstream: String
    public let revision: String
    public let text: String

    public init?(_ text: String) {
        guard !text.isEmpty, text.count <= 128,
            !text.contains(" "), !text.contains("\t"), !text.contains("\n")
        else { return nil }

        let epoch: Int
        let body: Substring
        if let colon = text.firstIndex(of: ":") {
            let epochText = text[..<colon]
            guard !epochText.isEmpty,
                epochText.allSatisfy({ $0.isASCII && $0.isNumber }),
                let parsed = Int(epochText)
            else { return nil }
            epoch = parsed
            body = text[text.index(after: colon)...]
        } else {
            epoch = 0
            body = Substring(text)
        }

        guard !body.isEmpty else { return nil }
        let upstream: Substring
        let revision: Substring
        if let dash = body.lastIndex(of: "-") {
            upstream = body[..<dash]
            revision = body[body.index(after: dash)...]
            guard !revision.isEmpty,
                revision.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "~")
                })
            else { return nil }
        } else {
            upstream = body
            revision = "0"
        }

        guard let first = upstream.first, first.isASCII, first.isNumber,
            upstream.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" || $0 == "~")
            })
        else { return nil }

        self.epoch = epoch
        self.upstream = String(upstream)
        self.revision = String(revision)
        self.text = text
    }

    public var description: String { text }

    public static func < (lhs: PackageVersion, rhs: PackageVersion) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        let upstreamOrder = comparePart(lhs.upstream, rhs.upstream)
        if upstreamOrder != 0 { return upstreamOrder < 0 }
        return comparePart(lhs.revision, rhs.revision) < 0
    }

    public static func == (lhs: PackageVersion, rhs: PackageVersion) -> Bool {
        lhs.epoch == rhs.epoch
            && comparePart(lhs.upstream, rhs.upstream) == 0
            && comparePart(lhs.revision, rhs.revision) == 0
    }

    public func hash(into hasher: inout Hasher) {
        // Different spellings such as `1.01` and `1.1` compare equal under dpkg.
        // A constant hash preserves Hashable's equality contract; package sets are
        // tiny, while comparison correctness is externally visible and paramount.
        hasher.combine(0)
    }

    private static func comparePart(_ left: String, _ right: String) -> Int {
        let lhs = Array(left)
        let rhs = Array(right)
        var li = 0
        var ri = 0

        while li < lhs.count || ri < rhs.count {
            while (li < lhs.count && !isDigit(lhs[li]))
                || (ri < rhs.count && !isDigit(rhs[ri]))
            {
                let lc = li < lhs.count && !isDigit(lhs[li]) ? lhs[li] : nil
                let rc = ri < rhs.count && !isDigit(rhs[ri]) ? rhs[ri] : nil
                let lo = order(lc)
                let ro = order(rc)
                if lo != ro { return lo < ro ? -1 : 1 }
                if lc != nil { li += 1 }
                if rc != nil { ri += 1 }
            }

            while li < lhs.count, lhs[li] == "0" { li += 1 }
            while ri < rhs.count, rhs[ri] == "0" { ri += 1 }
            let leftStart = li
            let rightStart = ri
            while li < lhs.count, isDigit(lhs[li]) { li += 1 }
            while ri < rhs.count, isDigit(rhs[ri]) { ri += 1 }

            let leftCount = li - leftStart
            let rightCount = ri - rightStart
            if leftCount != rightCount { return leftCount < rightCount ? -1 : 1 }
            if leftCount > 0 {
                for offset in 0..<leftCount where lhs[leftStart + offset] != rhs[rightStart + offset] {
                    return lhs[leftStart + offset] < rhs[rightStart + offset] ? -1 : 1
                }
            }
        }
        return 0
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func order(_ character: Character?) -> Int {
        guard let character else { return 0 }
        if character == "~" { return -1 }
        let value = Int(character.asciiValue ?? 0)
        return character.isLetter ? value : value + 256
    }
}
