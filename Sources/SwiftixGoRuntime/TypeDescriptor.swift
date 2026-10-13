/// Go types at run time: the dynamic type of an interface value.
///
/// A VM value does not say whether an integer is an `int` or a `byte`, whether
/// a nil is a slice or a map, what a pointer points to, or what a struct's
/// fields are declared as. The compiler knows, so a value converted to an
/// interface, which is also what a `fmt` operand is, travels in an interface
/// value whose type name is `marker` followed by an encoded descriptor: the
/// type, then the underlying type of every named type it reaches. Only an
/// `int`, a `string`, and a `bool` travel bare, because the value shows them.
///
/// The descriptor is what `fmt` formats by, what a type assertion compares,
/// and where a method call through an interface finds the method's owner.
/// Named types are spelled as the VM names them (`point`, `path/to/lib.Point`,
/// which is how functions are named too) and printed in Go's spelling.
///
/// The encoding is prefix notation, one character per kind:
///
///     i int      b uint8     s string     t bool
///     e error    a interface {}           I<n>:<text> another interface
///     [T slice   A<n>;T array             MKV map       *T pointer
///     S<n>;(<n>:<field>T)... struct       N<n>:<name> named type
///         a field's T after `E` when it is embedded, and after
///         `G<n>:<tag>` when it has a tag
///     C<d>T channel (0 both ways, 1 send-only, 2 receive-only)
///     O<n>:<text> a type that only has a name here (functions, handles)
///
/// and each definition is a line `<n>:<name>` followed by the underlying type.
/// Pure value types and functions; no process or executor state.

indirect enum GoRuntimeType: Equatable, Sendable {
    case integer
    case byte
    case string
    case boolean
    /// The `error` interface.
    case error
    /// Any other interface, with the text Go prints for it.
    case interface(String)
    case slice(GoRuntimeType)
    case array(Int, GoRuntimeType)
    case map(GoRuntimeType, GoRuntimeType)
    case pointer(GoRuntimeType)
    case structure([Field])
    /// A defined type, by the name Go prints (`main.point`).
    case named(String)
    case channel(direction: Int, element: GoRuntimeType)
    /// A type known by name only.
    case other(String)

    struct Field: Equatable, Sendable {
        let name: String
        let type: GoRuntimeType
        /// Whether the field is embedded, and its tag: Go prints both with
        /// the type, of which they are part.
        var isEmbedded = false
        var tag: String? = nil
    }

    /// Whether a value of this type holds another value with its own type.
    var isInterface: Bool {
        switch self {
        case .error, .interface: return true
        default: return false
        }
    }
}

struct GoTypeDescriptor: Equatable, Sendable {
    /// Prefix of the type name that carries a descriptor. No Go type and no
    /// other reserved name starts with it.
    static let marker = "$T"

    /// Go's name for the element type of a string and a `[]byte`.
    static let byteName = "uint8"

    let type: GoRuntimeType
    /// Underlying type of every named type `type` reaches.
    let definitions: [String: GoRuntimeType]

    init(type: GoRuntimeType, definitions: [String: GoRuntimeType] = [:]) {
        self.type = type
        self.definitions = definitions
    }

    /// Decodes the type name of an interface value, or nil when it is not a
    /// well-formed descriptor.
    init?(typeName: String) {
        guard typeName.hasPrefix(Self.marker) else { return nil }
        var reader = Reader(bytes: Array(typeName.utf8.dropFirst(Self.marker.utf8.count)))
        guard let type = reader.type() else { return nil }
        var definitions: [String: GoRuntimeType] = [:]
        while !reader.isAtEnd {
            guard reader.take(0x0A), let name = reader.text(), let underlying = reader.type()
            else { return nil }
            definitions[name] = underlying
        }
        self.type = type
        self.definitions = definitions
    }

    /// `type` with every defined type replaced by what it is defined as.
    func underlying(_ type: GoRuntimeType) -> GoRuntimeType {
        var current = type
        var seen: Set<String> = []
        while case .named(let name) = current, seen.insert(name).inserted,
            let definition = definitions[name]
        {
            current = definition
        }
        return current
    }

    /// The text Go prints for a type: `reflect.Type.String()`.
    static func name(of type: GoRuntimeType) -> String {
        switch type {
        case .integer: return "int"
        case .byte: return byteName
        case .string: return "string"
        case .boolean: return "bool"
        case .error: return "error"
        case .interface(let text), .other(let text): return text
        case .named(let symbol): return goName(symbol)
        case .slice(let element): return "[]" + name(of: element)
        case .array(let count, let element): return "[\(count)]" + name(of: element)
        case .map(let key, let value): return "map[" + name(of: key) + "]" + name(of: value)
        case .pointer(let pointee): return "*" + name(of: pointee)
        case .structure(let fields):
            if fields.isEmpty { return "struct {}" }
            return "struct { "
                + fields.map { field in
                    (field.isEmbedded ? "" : field.name + " ") + name(of: field.type)
                        + (field.tag.map { " " + GoFormat.quote($0, asciiOnly: false) } ?? "")
                }.joined(separator: "; ") + " }"
        case .channel(let direction, let element):
            let prefix = direction == 1 ? "chan<- " : (direction == 2 ? "<-chan " : "chan ")
            return prefix + name(of: element)
        }
    }

    /// The type a value shows by itself, for an operand that arrived without
    /// a descriptor: an `int`, a `string`, a `bool`, or a struct by its name.
    static func inferred(from value: GoValue) -> GoRuntimeType? {
        switch value {
        case .int: return .integer
        case .string: return .string
        case .bool: return .boolean
        case .structure(let structure):
            return structure.typeName.map { .named($0) }
        default: return nil
        }
    }

    /// What identifies a dynamic type: a descriptor without its definitions,
    /// since a named type is its name. The names earlier compilers boxed a
    /// call argument with (`int`, `point`, `*point`) are spelled the same
    /// way, so both compare equal.
    static func identity(ofTypeName typeName: String) -> String {
        if typeName.hasPrefix(marker) {
            return typeName.firstIndex(of: "\n").map { String(typeName[..<$0]) } ?? typeName
        }
        func encoded(_ name: Substring) -> String {
            switch name {
            case "int": return "i"
            case "string": return "s"
            case "bool": return "t"
            case "byte": return "b"
            default: break
            }
            if name.hasPrefix("*") { return "*" + encoded(name.dropFirst()) }
            return "N\(name.utf8.count):" + name
        }
        // A library error is boxed under its own name.
        return typeName == "error" ? typeName : marker + encoded(typeName[...])
    }

    /// The identity of the type a bare value shows, or nil when it shows none.
    static func identity(of value: GoValue) -> String? {
        switch value {
        case .int: return marker + "i"
        case .string: return marker + "s"
        case .bool: return marker + "t"
        case .structure(let structure):
            return structure.typeName.map { identity(ofTypeName: $0) }
        case .interface(let boxed): return identity(ofTypeName: boxed.typeName)
        default: return nil
        }
    }

    /// The receiver type name methods of a dynamic type are registered
    /// under, `T` or `*T`, or nil for a type that has no methods.
    static func methodOwner(ofTypeName typeName: String) -> String? {
        guard typeName.hasPrefix(marker) else {
            return typeName.isEmpty || typeName == "unknown" ? nil : typeName
        }
        guard let descriptor = GoTypeDescriptor(typeName: typeName) else { return nil }
        switch descriptor.type {
        case .named(let symbol): return symbol
        case .pointer(.named(let symbol)): return "*" + symbol
        default: return nil
        }
    }

    /// The type an interface value names when it was boxed for a call
    /// argument rather than for `fmt`: `int`, `*point`, a linker symbol.
    static func dynamicType(named typeName: String) -> GoRuntimeType? {
        switch typeName {
        case "int": return .integer
        case "string": return .string
        case "bool": return .boolean
        case "byte": return .byte
        case "unknown", "": return nil
        default: break
        }
        if typeName.hasPrefix("*") {
            return dynamicType(named: String(typeName.dropFirst())).map { .pointer($0) }
        }
        return .named(typeName)
    }

    /// Go's spelling of a type name the VM carries: a type of the main
    /// package gains `main.`, and a linker symbol `path/to/pkg.Name` keeps its
    /// last path component, or the package name the linker wrote after an
    /// `@`. What the compiler adds after a middle dot keeps apart two types a
    /// source names alike, and is no part of the name.
    static func goName(_ typeName: String) -> String {
        var name = typeName[...]
        var prefix = ""
        while name.hasPrefix("*") {
            prefix += "*"
            name = name.dropFirst()
        }
        func member(_ text: Substring) -> Substring {
            text.firstIndex(of: "\u{B7}").map { text[..<$0] } ?? text
        }
        guard let dot = name.lastIndex(of: ".") else { return prefix + "main." + member(name) }
        let package = name[..<dot]
        let type = "." + member(name[name.index(after: dot)...])
        // The linker writes a package's name after its path where the path
        // does not end in it.
        if let mark = package.lastIndex(of: "@") {
            return prefix + package[package.index(after: mark)...] + type
        }
        guard let slash = package.lastIndex(of: "/") else { return prefix + package + type }
        return prefix + package[package.index(after: slash)...] + type
    }

    /// The path of the package that declares the defined type `typeName`
    /// names or points to; nil when it is no defined type.
    static func packagePath(ofTypeName typeName: String) -> String? {
        var symbol: Substring
        if typeName.hasPrefix(marker) {
            guard var type = GoTypeDescriptor(typeName: typeName)?.type else { return nil }
            while case .pointer(let pointee) = type { type = pointee }
            guard case .named(let name) = type else { return nil }
            symbol = name[...]
        } else {
            symbol = typeName[...]
            while symbol.hasPrefix("*") { symbol = symbol.dropFirst() }
        }
        guard let dot = symbol.lastIndex(of: ".") else { return "main" }
        return String(symbol[..<dot])
    }

    /// Decoder for the encoding in the file header.
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        /// Nesting allowed before a descriptor is rejected as malformed.
        var depthBudget = 256

        var isAtEnd: Bool { index >= bytes.count }

        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        /// A decimal number of at most 18 digits followed by `terminator`.
        mutating func number(terminatedBy terminator: UInt8) -> Int? {
            var value = 0
            var digits = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]), digits < 18 {
                value = value * 10 + Int(bytes[index] - 0x30)
                digits += 1
                index += 1
            }
            guard digits > 0, take(terminator) else { return nil }
            return value
        }

        /// `<n>:` followed by `n` bytes of UTF-8.
        mutating func text() -> String? {
            guard let count = number(terminatedBy: 0x3A), count <= bytes.count - index else {
                return nil
            }
            defer { index += count }
            return String(decoding: bytes[index..<(index + count)], as: UTF8.self)
        }

        mutating func type() -> GoRuntimeType? {
            guard index < bytes.count, depthBudget > 0 else { return nil }
            depthBudget -= 1
            defer { depthBudget += 1 }
            let kind = bytes[index]
            index += 1
            switch kind {
            case UInt8(ascii: "i"): return .integer
            case UInt8(ascii: "b"): return .byte
            case UInt8(ascii: "s"): return .string
            case UInt8(ascii: "t"): return .boolean
            case UInt8(ascii: "e"): return .error
            case UInt8(ascii: "a"): return .interface("interface {}")
            case UInt8(ascii: "I"): return text().map { .interface($0) }
            case UInt8(ascii: "O"): return text().map { .other($0) }
            case UInt8(ascii: "N"): return text().map { .named($0) }
            case UInt8(ascii: "["): return type().map { .slice($0) }
            case UInt8(ascii: "*"): return type().map { .pointer($0) }
            case UInt8(ascii: "A"):
                guard let count = number(terminatedBy: 0x3B), let element = type() else {
                    return nil
                }
                return .array(count, element)
            case UInt8(ascii: "M"):
                guard let key = type(), let value = type() else { return nil }
                return .map(key, value)
            case UInt8(ascii: "S"):
                guard let count = number(terminatedBy: 0x3B), count <= bytes.count else {
                    return nil
                }
                var fields: [GoRuntimeType.Field] = []
                for _ in 0..<count {
                    guard let name = text() else { return nil }
                    let isEmbedded = take(UInt8(ascii: "E"))
                    var tag: String?
                    if take(UInt8(ascii: "G")) {
                        guard let found = text() else { return nil }
                        tag = found
                    }
                    guard let fieldType = type() else { return nil }
                    fields.append(
                        GoRuntimeType.Field(
                            name: name, type: fieldType, isEmbedded: isEmbedded, tag: tag))
                }
                return .structure(fields)
            case UInt8(ascii: "C"):
                guard index < bytes.count, (0x30...0x32).contains(bytes[index]) else { return nil }
                let direction = Int(bytes[index] - 0x30)
                index += 1
                return type().map { .channel(direction: direction, element: $0) }
            default:
                return nil
            }
        }
    }
}
