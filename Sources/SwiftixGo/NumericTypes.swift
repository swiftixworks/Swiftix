/// The numeric types of the dialect, and how each is held in a VM value.
///
/// `GoType` and `GoValue` are frozen: a type is `.int` or a name, and a
/// number at run time is one `Int64`. `int` is `GoType.int`, `byte` and
/// `uint8` are the named type `byte` as before, and every other numeric type
/// is the named type of its own name (`rune` is `int32`). What the 64 bits
/// mean is decided by the type alone, at compile time:
///
/// - a signed integer is its value, sign-extended;
/// - an unsigned integer narrower than 64 bits is its value, zero-extended;
/// - `uint`, `uint64`, and `uintptr` are their bit pattern, so a value with
///   the high bit set reads as a negative `Int64` and must be divided,
///   compared, shifted right, and printed by operations that know;
/// - a `float64` is its IEEE 754 bit pattern, and a `float32` is the bit
///   pattern of the `float64` with the same value, which exists for each.
///
/// The compiler therefore picks the operation for every operator from the
/// static type, and keeps every value normalized: an operation whose result
/// can leave the range of its type is followed by one that brings it back.

enum GoNumericKind: String, CaseIterable, Sendable {
    case int
    case int8
    case int16
    case int32
    case int64
    case uint
    case uint8
    case uint16
    case uint32
    case uint64
    case uintptr
    case float32
    case float64

    /// Whether the floating-point types, literals, and constants are part
    /// of the dialect.
    static let floatsAreSupported = false

    /// The kind a predeclared type name denotes, with `byte` and `rune`
    /// for the types they are other names of.
    init?(typeName: String) {
        switch typeName {
        case "byte": self = .uint8
        case "rune": self = .int32
        default:
            guard let kind = GoNumericKind(rawValue: typeName),
                kind.isInteger || Self.floatsAreSupported
            else { return nil }
            self = kind
        }
    }

    /// The type itself. `uint8` keeps the name it had when it was the only
    /// sized type, which images and descriptors already carry.
    var type: GoType {
        switch self {
        case .int: return .int
        case .uint8: return GoPredeclared.byte
        default: return .named(rawValue)
        }
    }

    var isFloat: Bool { self == .float32 || self == .float64 }
    var isInteger: Bool { !isFloat }

    var isSigned: Bool {
        switch self {
        case .int, .int8, .int16, .int32, .int64, .float32, .float64: return true
        default: return false
        }
    }

    /// Width in bits.
    var bits: Int {
        switch self {
        case .int8, .uint8: return 8
        case .int16, .uint16: return 16
        case .int32, .uint32, .float32: return 32
        default: return 64
        }
    }

    /// An unsigned integer that fills the 64 bits: held as its bit pattern.
    var isWideUnsigned: Bool { !isSigned && bits == 64 }

    /// Whether this is a type the dialect had before the sized types: what
    /// is compiled for it must stay what it was.
    var isOriginal: Bool { self == .int || self == .uint8 }

    /// The call that brings a 64-bit result back into the range of a type
    /// narrower than 64 bits, or nil when every 64-bit value is one of the
    /// type. `uint8` is masked, as it always was.
    var wrapCall: String? {
        switch self {
        case .int8: return "$num.i8"
        case .int16: return "$num.i16"
        case .int32: return "$num.i32"
        case .uint16: return "$num.u16"
        case .uint32: return "$num.u32"
        case .float32: return "$num.f32"
        default: return nil
        }
    }

    /// The character that stands for the type in the descriptor of an
    /// interface value, which the VM decodes (`GoNumberKind`). `int` and
    /// `uint8` have had theirs since there were descriptors.
    var descriptorCode: String? {
        switch self {
        case .int, .uint8: return nil
        case .int8: return "j"
        case .int16: return "k"
        case .int32: return "l"
        case .int64: return "m"
        case .uint: return "u"
        case .uint16: return "v"
        case .uint32: return "w"
        case .uint64: return "x"
        case .uintptr: return "p"
        case .float32: return "f"
        case .float64: return "d"
        }
    }

    /// The least and the greatest value of an integer kind.
    var integerRange: ClosedRange<GoBigInt> {
        if isSigned {
            let bound = GoBigInt.one.shiftedLeft(bits - 1)
            return (-bound)...(bound - .one)
        }
        return .zero...(GoBigInt.one.shiftedLeft(bits) - .one)
    }

    /// The 64 bits that hold the integer `value` of this kind, which is in
    /// its range.
    func bitPattern(ofInteger value: GoBigInt) -> Int64 {
        Int64(bitPattern: value.truncatedBits)
    }

    /// The kind of `type`: its own, or that of the numeric type a chain of
    /// definitions ends in. Nil for a type that is no number.
    static func of(_ type: GoType, definitions: [String: GoTypeDefinition]) -> GoNumericKind? {
        var current = type
        var visited: Set<String> = []
        while true {
            switch current {
            case .int:
                return .int
            case .named(let name):
                if let definition = definitions[name] {
                    guard visited.insert(name).inserted else { return nil }
                    current = definition.underlying
                } else if let library = GoLibraryTypes.underlying(of: name) {
                    // A defined type of the library, `time.Duration`.
                    current = library
                } else {
                    return GoNumericKind(typeName: name)
                }
            default:
                return nil
            }
        }
    }
}

extension GoPredeclared {
    /// The numeric type a predeclared name denotes besides `int`, which is
    /// a `GoType` case.
    static func numericType(_ name: String) -> GoType? {
        guard name != "int", let kind = GoNumericKind(typeName: name) else { return nil }
        return kind.type
    }

    /// The default type of a floating-point constant.
    static let float64 = GoNumericKind.float64.type
    /// `rune`, another name for `int32`: the default type of a rune literal
    /// and what a `range` over a string yields.
    static let rune = GoNumericKind.int32.type
}

/// A numeric literal that is not an integer of 64 bits written in digits:
/// a floating-point literal, an integer too large for `Int64`, and a rune
/// literal.
///
/// `GoTokenKind` and `GoExpression` are frozen and have an integer and a
/// string. Such a literal is therefore an `.identifier` whose name is the
/// literal as the source spells it. No Go identifier starts with a digit, a
/// period, or a quote, so the name meets no declaration, and a pass that only
/// walks the tree carries it along as the leaf it is. The checker gives it a
/// constant value and a type; the lowerer emits that constant.
enum GoLiteral {
    /// Whether `name`, of an `.identifier`, is a literal.
    static func isSpelling(_ name: String) -> Bool {
        var bytes = name.utf8.makeIterator()
        guard let first = bytes.next() else { return false }
        if first == 0x27 { return true }
        if first >= 0x30 && first <= 0x39 { return true }
        // `...` is the spread, which is also an identifier token.
        guard first == 0x2E, let second = bytes.next() else { return false }
        return second >= 0x30 && second <= 0x39
    }

    /// Whether `name` is a rune literal.
    static func isRune(_ name: String) -> Bool { name.utf8.first == 0x27 }

    /// The code point of the rune literal `spelling`.
    static func runeValue(_ spelling: String) -> Int64? {
        guard isRune(spelling) else { return nil }
        return GoLexer.runeValue(ofLiteral: spelling)
    }
}
