/// What `encoding/json` knows of a Go type at run time, from the descriptor
/// a value travels with: the fields a struct has in JSON (Go's
/// `typeFields`), zero values, the descriptor of a type a value is boxed
/// with for a method call, and Go's names. Pure value types; no executor
/// state.

/// One field of a struct as JSON has it.
struct GoJSONField {
    /// The key: the tag's name, or the field's.
    let name: String
    let nameBytes: [UInt8]
    /// The key with ASCII upper-cased and other letters folded, which a key
    /// of the input matches when no key matches exactly.
    let folded: [UInt8]
    let tagged: Bool
    /// The position of the field in each struct on the way to it, the
    /// first in the outermost.
    let index: [Int]
    /// The Go names of those fields.
    let goNames: [String]
    /// The field's type.
    let type: GoRuntimeType
    let omitEmpty: Bool
    let omitZero: Bool
    let quoted: Bool
}

/// The named types a walk has met, and what follows from them.
struct GoJSONTypes {
    var definitions: [String: GoRuntimeType] = [:]
    private var fieldCache: [String: [GoJSONField]] = [:]

    static let rawMessage = "encoding/json.RawMessage"
    static let number = "encoding/json.Number"
    static let time = "time.Time"

    /// The descriptor of the dynamic type `typeName` carries, whose
    /// definitions join those already known.
    mutating func adopt(_ descriptor: GoTypeDescriptor) {
        for (name, type) in descriptor.definitions where definitions[name] == nil {
            definitions[name] = type
        }
    }

    /// `type` with every defined type replaced by what it is defined as.
    func underlying(_ type: GoRuntimeType) -> GoRuntimeType {
        var current = type
        var steps = 0
        while case .named(let name) = current, steps < 64 {
            if let definition = definitions[name] {
                current = definition
            } else if let library = GoErrors.definitions[name] {
                current = library
            } else {
                break
            }
            steps += 1
        }
        return current
    }

    /// What reflect's `Name` says of a type: the name of a defined type
    /// without its package, or "".
    static func shortName(_ type: GoRuntimeType) -> String {
        switch type {
        case .named, .other:
            let goName = GoTypeDescriptor.name(of: type)
            return goName.split(separator: ".").last.map(String.init) ?? goName
        case .integer: return "int"
        case .byte: return "uint8"
        case .number(let kind): return kind.name
        case .string: return "string"
        case .boolean: return "bool"
        case .error: return "error"
        default: return ""
        }
    }

    /// Whether `type` has a name: reflect's `Name() != ""`.
    static func isNamed(_ type: GoRuntimeType) -> Bool {
        switch type {
        case .named, .other, .integer, .byte, .number, .string, .boolean, .error: return true
        default: return false
        }
    }

    // MARK: Kinds

    enum Kind: Equatable {
        case bool, signed(bits: Int), unsigned(bits: Int), float(bits: Int), string
        case interface(empty: Bool), pointer, slice, array, map, structure, time, other
    }

    func kind(_ type: GoRuntimeType) -> Kind {
        switch underlying(type) {
        case .integer: return .signed(bits: 64)
        case .byte: return .unsigned(bits: 8)
        case .number(let kind):
            switch kind {
            case .int8: return .signed(bits: 8)
            case .int16: return .signed(bits: 16)
            case .int32: return .signed(bits: 32)
            case .int64: return .signed(bits: 64)
            case .uint, .uint64, .uintptr: return .unsigned(bits: 64)
            case .uint16: return .unsigned(bits: 16)
            case .uint32: return .unsigned(bits: 32)
            case .float32: return .float(bits: 32)
            case .float64: return .float(bits: 64)
            }
        case .string: return .string
        case .boolean: return .bool
        case .error: return .interface(empty: false)
        case .interface(let text): return .interface(empty: text == "interface {}" || text == "any")
        case .pointer: return .pointer
        case .slice: return .slice
        case .array: return .array
        case .map: return .map
        case .structure: return .structure
        case .other(let name) where name == Self.time: return .time
        default: return .other
        }
    }

    // MARK: Zero values

    /// The zero value of `type` as the compiler lays it out.
    func zero(_ type: GoRuntimeType) -> GoValue {
        var name: String?
        if case .named(let symbol) = type { name = symbol }
        switch underlying(type) {
        case .integer, .byte, .number: return .int(0)
        case .string: return .string("")
        case .boolean: return .bool(false)
        case .array(let count, let element):
            return .array([GoValue](repeating: zero(element), count: max(0, count)))
        case .structure(let fields):
            return .structure(
                GoStructValue(
                    typeName: name,
                    fields: fields.map { GoStructFieldValue(name: $0.name, value: zero($0.type)) }))
        case .other(let name) where name == Self.time: return .int(0)
        default: return .nilValue
        }
    }

    // MARK: Fields

    /// Go's `typeFields` of the struct type `type`.
    mutating func fields(of type: GoRuntimeType) -> [GoJSONField] {
        let key = GoJSONDescriptor.key(type)
        if let cached = fieldCache[key] { return cached }
        let computed = typeFields(type)
        fieldCache[key] = computed
        return computed
    }

    private struct Pending {
        let type: GoRuntimeType
        let index: [Int]
        let goNames: [String]
    }

    private func typeFields(_ root: GoRuntimeType) -> [GoJSONField] {
        var current: [Pending] = []
        var next = [Pending(type: root, index: [], goNames: [])]
        var count: [String: Int] = [:]
        var nextCount: [String: Int] = [:]
        var visited: Set<String> = []
        var found: [GoJSONField] = []
        while !next.isEmpty {
            current = next
            next = []
            count = nextCount
            nextCount = [:]
            for f in current {
                let fKey = GoJSONDescriptor.key(f.type)
                if visited.contains(fKey) { continue }
                visited.insert(fKey)
                guard case .structure(let structFields) = underlying(f.type) else { continue }
                for (i, sf) in structFields.enumerated() {
                    let exported = Self.isExported(sf.name)
                    if sf.isEmbedded {
                        var t = sf.type
                        if case .pointer(let pointee) = underlying(t) { t = pointee }
                        if !exported, kind(t) != .structure { continue }
                    } else if !exported {
                        continue
                    }
                    let tag = Self.lookup(tag: sf.tag ?? "", key: "json")
                    if tag == "-" { continue }
                    var (name, options) = Self.parse(tag: tag)
                    if !Self.isValidTag(name) { name = "" }
                    let index = f.index + [i]
                    let goNames = f.goNames + [sf.name]
                    var ft = sf.type
                    if !Self.isNamed(ft), case .pointer(let pointee) = ft { ft = pointee }
                    var quoted = false
                    if Self.hasOption(options, "string") {
                        switch kind(ft) {
                        case .bool, .signed, .unsigned, .float, .string: quoted = true
                        default: break
                        }
                    }
                    if !name.isEmpty || !sf.isEmbedded || kind(ft) != .structure {
                        let tagged = !name.isEmpty
                        if name.isEmpty { name = sf.name }
                        let bytes = Array(name.utf8)
                        let field = GoJSONField(
                            name: name, nameBytes: bytes, folded: Self.fold(bytes), tagged: tagged,
                            index: index, goNames: goNames, type: sf.type,
                            omitEmpty: Self.hasOption(options, "omitempty"),
                            omitZero: Self.hasOption(options, "omitzero"), quoted: quoted)
                        found.append(field)
                        if (count[fKey] ?? 0) > 1 { found.append(field) }
                        continue
                    }
                    let ftKey = GoJSONDescriptor.key(ft)
                    nextCount[ftKey, default: 0] += 1
                    if nextCount[ftKey] == 1 {
                        next.append(Pending(type: ft, index: index, goNames: goNames))
                    }
                }
            }
        }
        found.sort { a, b in
            if a.nameBytes != b.nameBytes { return a.nameBytes.lexicographicallyPrecedes(b.nameBytes) }
            if a.index.count != b.index.count { return a.index.count < b.index.count }
            if a.tagged != b.tagged { return a.tagged }
            return a.index.lexicographicallyPrecedes(b.index)
        }
        var out: [GoJSONField] = []
        var i = 0
        while i < found.count {
            var advance = 1
            while i + advance < found.count, found[i + advance].name == found[i].name { advance += 1 }
            if advance == 1 {
                out.append(found[i])
            } else {
                let first = found[i]
                let second = found[i + 1]
                if !(first.index.count == second.index.count && first.tagged == second.tagged) {
                    out.append(first)
                }
            }
            i += advance
        }
        out.sort { $0.index.lexicographicallyPrecedes($1.index) }
        return out
    }

    /// Go's `foldName`.
    static func fold(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c < 0x80 {
                out.append(c >= 0x61 && c <= 0x7A ? c - 0x20 : c)
                i += 1
                continue
            }
            let (scalar, size) = GoJSONText.decodeRune(bytes, at: i)
            let folded = scalar.map(foldRune) ?? Unicode.Scalar(0xFFFD)!
            out += Array(String(Character(folded)).utf8)
            i += size
        }
        return out
    }

    /// The least rune of the case orbit of `r`, as Go's `foldRune` finds it
    /// with `unicode.SimpleFold`.
    private static func foldRune(_ r: Unicode.Scalar) -> Unicode.Scalar {
        let candidates = [
            r, GoUnicode.toUpper(r), GoUnicode.toLower(r), GoUnicode.toUpper(GoUnicode.toLower(r)),
            GoUnicode.toLower(GoUnicode.toUpper(r)),
        ]
        return candidates.min { $0.value < $1.value } ?? r
    }

    static func isExported(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return GoUnicodeCategories.isUpper(Int64(first.value))
    }

    /// `reflect.StructTag.Get(key)`.
    static func lookup(tag: String, key: String) -> String {
        var tag = Array(tag.utf8)[...]
        while !tag.isEmpty {
            while let c = tag.first, c == 0x20 { tag = tag.dropFirst() }
            if tag.isEmpty { break }
            var i = tag.startIndex
            while i < tag.endIndex, tag[i] > 0x20, tag[i] != 0x3A, tag[i] != 0x22, tag[i] != 0x7F {
                i += 1
            }
            if i == tag.startIndex || i + 1 >= tag.endIndex || tag[i] != 0x3A || tag[i + 1] != 0x22 {
                break
            }
            let name = String(decoding: tag[tag.startIndex..<i], as: UTF8.self)
            tag = tag[(i + 1)...]
            i = tag.startIndex + 1
            while i < tag.endIndex, tag[i] != 0x22 {
                if tag[i] == 0x5C { i += 1 }
                i += 1
            }
            if i >= tag.endIndex { break }
            let quoted = tag[tag.startIndex...i]
            tag = tag[(i + 1)...]
            if key == name {
                return unquoteGo(Array(quoted)) ?? ""
            }
        }
        return ""
    }

    /// `strconv.Unquote` of a double-quoted Go string, for a tag.
    private static func unquoteGo(_ text: [UInt8]) -> String? {
        guard text.count >= 2, text.first == 0x22, text.last == 0x22 else { return nil }
        let body = text[1..<(text.count - 1)]
        if !body.contains(0x5C) { return String(decoding: body, as: UTF8.self) }
        var out: [UInt8] = []
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c != 0x5C {
                out.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < body.endIndex else { return nil }
            switch body[i] {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case 0x5C, 0x22, 0x27: out.append(body[i])
            default: out += [0x5C, body[i]]
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Go's `parseTag`: the name, and the options after it.
    static func parse(tag: String) -> (String, String) {
        if let comma = tag.firstIndex(of: ",") {
            return (String(tag[..<comma]), String(tag[tag.index(after: comma)...]))
        }
        return (tag, "")
    }

    static func hasOption(_ options: String, _ name: String) -> Bool {
        options.split(separator: ",", omittingEmptySubsequences: false).contains { $0 == name }
    }

    /// Go's `isValidTag`.
    static func isValidTag(_ name: String) -> Bool {
        if name.isEmpty { return false }
        let punctuation = Set("!#$%&()*+-./:;<=>?@[]^_{|}~ ".unicodeScalars)
        for scalar in name.unicodeScalars {
            if punctuation.contains(scalar) { continue }
            let rune = Int64(scalar.value)
            if !GoUnicodeCategories.isLetter(rune) && !GoUnicodeCategories.isDigit(rune) {
                return false
            }
        }
        return true
    }
}

/// Descriptors written back from types: the text a value is boxed with in an
/// interface, as the compiler writes it (`GoTypeEncoder`).
enum GoJSONDescriptor {
    /// The type alone, which names it among the types of one program.
    static func key(_ type: GoRuntimeType) -> String {
        var text = ""
        var reached: [String] = []
        encode(type, into: &text, reached: &reached)
        return text
    }

    /// The type name of an interface value that holds a value of `type`.
    static func typeName(_ type: GoRuntimeType, definitions: [String: GoRuntimeType]) -> String {
        var reached: [String] = []
        var text = GoTypeDescriptor.marker
        encode(type, into: &text, reached: &reached)
        var next = 0
        while next < reached.count {
            let name = reached[next]
            next += 1
            guard let definition = definitions[name] else { continue }
            text += "\n" + counted(name)
            encode(definition, into: &text, reached: &reached)
        }
        return text
    }

    private static func counted(_ text: String) -> String { "\(text.utf8.count):" + text }

    private static func encode(_ type: GoRuntimeType, into text: inout String, reached: inout [String]) {
        switch type {
        case .integer: text += "i"
        case .byte: text += "b"
        case .number(let kind): text += String(Unicode.Scalar(kind.rawValue))
        case .string: text += "s"
        case .boolean: text += "t"
        case .error: text += "e"
        case .interface(let description):
            if description == "interface {}" { text += "a" } else { text += "I" + counted(description) }
        case .other(let name): text += "O" + counted(name)
        case .named(let name):
            if !reached.contains(name) { reached.append(name) }
            text += "N" + counted(name)
        case .slice(let element):
            text += "["
            encode(element, into: &text, reached: &reached)
        case .pointer(let pointee):
            text += "*"
            encode(pointee, into: &text, reached: &reached)
        case .array(let count, let element):
            text += "A\(count);"
            encode(element, into: &text, reached: &reached)
        case .map(let key, let value):
            text += "M"
            encode(key, into: &text, reached: &reached)
            encode(value, into: &text, reached: &reached)
        case .structure(let fields):
            text += "S\(fields.count);"
            for field in fields {
                text += counted(field.name) + (field.isEmbedded ? "E" : "")
                    + (field.tag.map { "G" + counted($0) } ?? "")
                encode(field.type, into: &text, reached: &reached)
            }
        case .channel(let direction, let element):
            text += "C\(direction)"
            encode(element, into: &text, reached: &reached)
        }
    }
}
