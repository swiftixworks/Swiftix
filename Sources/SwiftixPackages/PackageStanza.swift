/// The metadata syntax shared by the repository index, the installed database
/// and the archive header: blank-line-separated stanzas of `Field: value` lines.
///
/// It is deliberately the Debian `Packages`/`status` shape. The format is
/// line-oriented and human-readable, so a repository can be inspected (and
/// hand-repaired) with the tools that already exist in the shell — `cat`, `grep`,
/// line-oriented tools — and diffs stay reviewable. Continuation lines follow Debian control
/// syntax: they begin with whitespace, and a single `.` represents a blank line.

struct PackageStanza {

    /// Fields in file order. Repeated names are preserved, so `values(of:)` can
    /// return a list while `value(of:)` returns the first.
    private(set) var fields: [(name: String, value: String)] = []

    init() {}

    init(_ fields: [(name: String, value: String)]) {
        self.fields = fields
    }

    var isEmpty: Bool { fields.isEmpty }

    /// First value of `name` (case-insensitive), or `nil`.
    func value(of name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name.lowercased() == key }?.value
    }

    /// All values of `name` (case-insensitive), in file order.
    func values(of name: String) -> [String] {
        let key = name.lowercased()
        return fields.filter { $0.name.lowercased() == key }.map(\.value)
    }

    /// Append a field. Empty values are skipped so optional metadata does not
    /// produce noisy `Field:` lines in the rendered output.
    mutating func set(_ name: String, _ value: String) {
        guard !value.isEmpty else { return }
        fields.append((name: name, value: value))
    }

    mutating func append(_ name: String, _ values: [String]) {
        for value in values { set(name, value) }
    }

    private mutating func appendContinuation(_ value: String) throws {
        guard !fields.isEmpty else {
            throw PackageError.malformedDatabase(reason: "continuation without a field")
        }
        let continuation = value == "." ? "" : value
        fields[fields.count - 1].value += "\n" + continuation
    }

    /// Render as Debian control text (no trailing blank line).
    func rendered() -> String {
        fields.map { field in
            let lines = field.value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var text = "\(field.name): \(lines.first ?? "")\n"
            for line in lines.dropFirst() {
                text += " \(line.isEmpty ? "." : line)\n"
            }
            return text
        }.joined()
    }

    /// Split `text` into stanzas. `#` comments and blank runs are skipped; a
    /// line without a colon is a hard error so corrupt metadata is reported
    /// instead of silently half-parsed.
    static func parse(_ text: String) throws -> [PackageStanza] {
        var stanzas: [PackageStanza] = []
        var current = PackageStanza()
        var lineNumber = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let original = String(rawLine)
            if original.first == " " || original.first == "\t" {
                do {
                    try current.appendContinuation(PackageText.trim(original))
                } catch {
                    throw PackageError.malformedDatabase(
                        reason: "line \(lineNumber): continuation without a field")
                }
                continue
            }
            let line = PackageText.trim(original)
            if line.isEmpty {
                if !current.isEmpty { stanzas.append(current); current = PackageStanza() }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw PackageError.malformedDatabase(
                    reason: "line \(lineNumber): expected 'Field: value'")
            }
            let name = PackageText.trim(String(line[line.startIndex..<colon]))
            let value = PackageText.trim(String(line[line.index(after: colon)...]))
            guard !name.isEmpty else {
                throw PackageError.malformedDatabase(reason: "line \(lineNumber): empty field name")
            }
            current.set(name, value)
        }
        if !current.isEmpty { stanzas.append(current) }
        return stanzas
    }

    /// Join stanzas with the blank-line separator the parser expects.
    static func render(_ stanzas: [PackageStanza]) -> String {
        stanzas.map { $0.rendered() }.joined(separator: "\n")
    }
}

/// Small string helpers. The core forbids Foundation, and this target keeps the
/// same rule, so trimming and comma-splitting are spelled out here rather than
/// borrowed from `NSString`.
enum PackageText {

    static func trim(_ value: String) -> String {
        var characters = Substring(value)
        while let first = characters.first, first == " " || first == "\t" || first == "\r" {
            characters = characters.dropFirst()
        }
        while let last = characters.last, last == " " || last == "\t" || last == "\r" {
            characters = characters.dropLast()
        }
        return String(characters)
    }

    /// Split a comma-separated list, trimming each element and dropping empties
    /// (`"a, b ,"` → `["a", "b"]`).
    static func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: true)
            .map { trim(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Split on runs of spaces and tabs.
    static func whitespaceSeparated(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
    }

    /// Format a byte count for the transaction summary.
    static func humanBytes(_ bytes: Int) -> String {
        if bytes >= 1 << 20 { return "\(bytes >> 20) MB" }
        if bytes >= 1 << 10 { return "\(bytes >> 10) kB" }
        return "\(bytes) B"
    }

    /// Octal text for a permission bit pattern (`0o755` → `"0755"`).
    static func octal(_ mode: UInt16) -> String {
        let digits = [
            (mode >> 9) & 0o7, (mode >> 6) & 0o7, (mode >> 3) & 0o7, mode & 0o7,
        ]
        return digits.map { String($0) }.joined()
    }

    /// Parse octal permission text, bounded to the 12 bits a mode can hold.
    static func parseOctal(_ value: String) -> UInt16? {
        guard !value.isEmpty, value.count <= 5 else { return nil }
        var result: UInt16 = 0
        for character in value {
            guard let digit = character.wholeNumberValue, (0...7).contains(digit) else { return nil }
            let (shifted, overflow) = result.multipliedReportingOverflow(by: 8)
            guard !overflow else { return nil }
            result = shifted + UInt16(digit)
        }
        return result & 0o7777
    }
}
