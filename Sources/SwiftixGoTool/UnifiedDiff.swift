/// Unified-diff rendering used by `gofmt -d`.

enum GoSourceDiff {
    static func unified(original: String, formatted: String, path: String) -> String {
        guard original != formatted else { return "" }
        let originalLines = sourceLines(original)
        let formattedLines = sourceLines(formatted)
        let operations = diffOperations(originalLines, formattedLines)
        let changed = operations.indices.filter { !operations[$0].isContext }
        guard !changed.isEmpty else { return "" }

        var output = "diff \(path).orig \(path)\n"
        output += "--- \(path).orig\n"
        output += "+++ \(path)\n"
        for hunk in hunkRanges(changed: changed, operationCount: operations.count) {
            output += renderHunk(Array(operations[hunk]), before: operations[..<hunk.lowerBound])
        }
        return output
    }

    private static func sourceLines(_ source: String) -> [SourceLine] {
        let bytes = Array(source.utf8)
        var lines: [SourceLine] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            lines.append(
                SourceLine(
                    text: String(decoding: bytes[start..<index], as: UTF8.self),
                    terminated: true))
            start = index + 1
        }
        if start < bytes.count {
            lines.append(
                SourceLine(
                    text: String(decoding: bytes[start...], as: UTF8.self),
                    terminated: false))
        }
        return lines
    }

    private static func diffOperations(
        _ original: [SourceLine],
        _ formatted: [SourceLine]
    ) -> [Operation] {
        var prefixCount = 0
        while prefixCount < original.count, prefixCount < formatted.count,
            original[prefixCount] == formatted[prefixCount]
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < original.count - prefixCount,
            suffixCount < formatted.count - prefixCount,
            original[original.count - suffixCount - 1]
                == formatted[formatted.count - suffixCount - 1]
        {
            suffixCount += 1
        }

        var operations = original.prefix(prefixCount).map(Operation.context)
        let originalMiddle = Array(original[prefixCount..<(original.count - suffixCount)])
        let formattedMiddle = Array(formatted[prefixCount..<(formatted.count - suffixCount)])
        operations.append(contentsOf: align(originalMiddle, formattedMiddle))
        operations.append(contentsOf: original.suffix(suffixCount).map(Operation.context))
        return operations
    }

    private static func align(
        _ original: [SourceLine],
        _ formatted: [SourceLine]
    ) -> [Operation] {
        guard !original.isEmpty else { return formatted.map(Operation.insertion) }
        guard !formatted.isEmpty else { return original.map(Operation.deletion) }

        let (cellCount, overflow) = (original.count + 1).multipliedReportingOverflow(
            by: formatted.count + 1)
        guard !overflow, cellCount <= 1_000_000 else {
            return original.map(Operation.deletion) + formatted.map(Operation.insertion)
        }

        let width = formatted.count + 1
        var lengths = [Int](repeating: 0, count: cellCount)
        for left in stride(from: original.count - 1, through: 0, by: -1) {
            for right in stride(from: formatted.count - 1, through: 0, by: -1) {
                let position = left * width + right
                if original[left] == formatted[right] {
                    lengths[position] = lengths[(left + 1) * width + right + 1] + 1
                } else {
                    lengths[position] = max(
                        lengths[(left + 1) * width + right],
                        lengths[left * width + right + 1])
                }
            }
        }

        var operations: [Operation] = []
        var left = 0
        var right = 0
        while left < original.count, right < formatted.count {
            if original[left] == formatted[right] {
                operations.append(.context(original[left]))
                left += 1
                right += 1
            } else if lengths[(left + 1) * width + right]
                >= lengths[left * width + right + 1]
            {
                operations.append(.deletion(original[left]))
                left += 1
            } else {
                operations.append(.insertion(formatted[right]))
                right += 1
            }
        }
        while left < original.count {
            operations.append(.deletion(original[left]))
            left += 1
        }
        while right < formatted.count {
            operations.append(.insertion(formatted[right]))
            right += 1
        }
        return operations
    }

    private static func hunkRanges(
        changed: [Int],
        operationCount: Int
    ) -> [Range<Int>] {
        let contextLines = 3
        var groups: [(first: Int, last: Int)] = []
        for index in changed {
            if let last = groups.indices.last,
                index - groups[last].last - 1 <= contextLines * 2
            {
                groups[last].last = index
            } else {
                groups.append((first: index, last: index))
            }
        }
        return groups.map { group in
            max(0, group.first - contextLines)..<min(operationCount, group.last + contextLines + 1)
        }
    }

    private static func renderHunk(
        _ operations: [Operation],
        before: ArraySlice<Operation>
    ) -> String {
        var oldLine = 1
        var newLine = 1
        for operation in before {
            if operation.consumesOriginal { oldLine += 1 }
            if operation.consumesFormatted { newLine += 1 }
        }

        let oldCount = operations.lazy.filter(\.consumesOriginal).count
        let newCount = operations.lazy.filter(\.consumesFormatted).count
        let oldStart = oldCount == 0 ? oldLine - 1 : oldLine
        let newStart = newCount == 0 ? newLine - 1 : newLine
        var output = "@@ -\(range(start: oldStart, count: oldCount))"
        output += " +\(range(start: newStart, count: newCount)) @@\n"
        for operation in operations {
            output += operation.marker + operation.line.text + "\n"
            if !operation.line.terminated {
                output += "\\ No newline at end of file\n"
            }
        }
        return output
    }

    private static func range(start: Int, count: Int) -> String {
        "\(start),\(count)"
    }
}

private struct SourceLine: Equatable {
    let text: String
    let terminated: Bool
}

private enum Operation {
    case context(SourceLine)
    case deletion(SourceLine)
    case insertion(SourceLine)

    var line: SourceLine {
        switch self {
        case .context(let line), .deletion(let line), .insertion(let line): return line
        }
    }

    var marker: String {
        switch self {
        case .context: return " "
        case .deletion: return "-"
        case .insertion: return "+"
        }
    }

    var isContext: Bool {
        if case .context = self { return true }
        return false
    }

    var consumesOriginal: Bool {
        switch self {
        case .context, .deletion: return true
        case .insertion: return false
        }
    }

    var consumesFormatted: Bool {
        switch self {
        case .context, .insertion: return true
        case .deletion: return false
        }
    }
}
