/// Numeric constants, and what the checker tells the lowerer about numbers.
///
/// A constant of Go is an exact number of any size: `1 << 100` and `1.0 / 3`
/// lose nothing until they are given a type. The checker folds constant
/// expressions with exact arithmetic (`GoBigInt`, `GoRational`), by Go's
/// rules for untyped and typed operands, and decides the type each one
/// takes where it is used.
///
/// A VM value does not say what kind of number it is, so the operation for
/// every operator is chosen at compile time. The checker is the one that
/// knows the types; what it finds it writes down by the place of the node
/// (`GoNumberFacts`), and the lowerer reads it there: the type an operator
/// works at, and the bits of a constant that must not be computed at run
/// time. Nothing is written for a node of type `int`, nor for a constant that
/// 64-bit integer arithmetic computes exactly at type `int` or `byte`: such a
/// program compiles as it did before there was anything else.

/// A numeric constant.
struct GoConstant: Equatable, Sendable {
    /// What an untyped constant is, in the order Go ranks the kinds: an
    /// operation on two kinds gives the later one.
    enum Kind: Int, Comparable, Sendable {
        case integer
        case rune
        case float

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The type an untyped constant of this kind has where nothing
        /// gives it another.
        var defaultType: GoType {
            switch self {
            case .integer: return .int
            case .rune: return GoPredeclared.rune
            case .float: return GoPredeclared.float64
            }
        }
    }

    var value: GoRational
    var kind: Kind
    /// The constant's type; nil while it is untyped.
    var type: GoType?
    /// Whether the expression is one the dialect compiled before it had
    /// exact constants: integer and rune literals, and operators that keep
    /// every intermediate value within 64 bits. Evaluating it at run time
    /// gives the same value, and that is how it stays compiled.
    var isPlain: Bool

    var isUntyped: Bool { type == nil }

    /// The text of the value in a diagnostic.
    var text: String {
        if kind != .float, value.isInteger { return value.truncated.description }
        let nearest = value.nearestDouble
        if nearest.isFinite {
            // An integer as Go writes one, without the `.0` of Swift.
            let text = nearest.description
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        // Too large for any type: its first digits and its exponent.
        let digits = Array(value.truncated.description.drop { $0 == "-" })
        var mantissa = String(digits.prefix(6))
        while mantissa.count > 1, mantissa.hasSuffix("0") { mantissa.removeLast() }
        if mantissa.count > 1 { mantissa.insert(".", at: mantissa.index(after: mantissa.startIndex)) }
        return (value.signum < 0 ? "-" : "") + mantissa + "e+" + String(digits.count - 1)
    }

    static func untyped(_ value: GoBigInt, kind: Kind = .integer, isPlain: Bool) -> GoConstant {
        GoConstant(value: GoRational(value), kind: kind, type: nil, isPlain: isPlain)
    }
}

/// A constant behind a reference, for a value that is copied often and
/// seldom holds one.
final class GoConstantBox: Sendable {
    /// A number.
    let constant: GoConstant?
    /// A string or a truth value.
    let word: GoWordConstant?

    init(_ constant: GoConstant) {
        self.constant = constant
        word = nil
    }

    init(word: GoWordConstant) {
        constant = nil
        self.word = word
    }
}

extension Binding {
    var constant: GoConstant? {
        get { constantBox?.constant }
        set { constantBox = newValue.map(GoConstantBox.init) }
    }

    var word: GoWordConstant? {
        get { constantBox?.word }
        set { constantBox = newValue.map(GoConstantBox.init(word:)) }
    }
}

/// What the checker found out about one node.
struct GoNumberFact: Equatable, Sendable {
    /// The name of the node when it is an identifier, and empty otherwise:
    /// two nodes of one place are told apart by it.
    var name = ""
    /// The type the node's operator works at. For a comparison that is the
    /// type of its operands.
    var type: GoType
    /// The value, when the node is a constant: the 64 bits of it at `type`.
    var bits: Int64?
    /// The report for a constant that is no value of `type`: an untyped
    /// constant is exact, and may be larger than its default type until it
    /// is used as a value of it. The bits are then what is left of it.
    var overflow: String?
}

/// The facts of a program, by where each node is.
struct GoNumberFacts: Equatable, Sendable {
    struct Place: Hashable, Sendable {
        let path: String
        let offset: Int

        init(_ position: GoSourcePosition) {
            path = position.path
            offset = position.offset
        }
    }

    enum Entry: Equatable, Sendable {
        case fact(GoNumberFact)
        /// Compiled as before: there is nothing to know.
        case original
    }

    /// What a node is where it stands by itself.
    private var defaults: [Place: GoNumberFact] = [:]
    /// What a node is made by the place it is used in: an untyped constant
    /// takes the type of the variable it is assigned to. This is the last
    /// word on a node.
    private var adopted: [Place: Entry] = [:]
    /// The value of each declared constant, by the declaration and the name.
    /// A specification of a `const` group that repeats the one before it
    /// shares its nodes, so the nodes cannot say.
    private var declared: [Place: [String: GoNumberFact]] = [:]

    var isEmpty: Bool { defaults.isEmpty && adopted.isEmpty && declared.isEmpty }

    private static func name(of expression: GoExpression) -> String {
        if case .identifier(let name, _) = expression { return name }
        return ""
    }

    func fact(for expression: GoExpression) -> GoNumberFact? {
        let place = Place(expression.position)
        let name = Self.name(of: expression)
        switch adopted[place] {
        case .fact(let fact)? where fact.name == name: return fact
        case .original?: return nil
        default: break
        }
        guard let fact = defaults[place], fact.name == name else { return nil }
        return fact
    }

    func constant(named name: String, declaredAt position: GoSourcePosition) -> GoNumberFact? {
        declared[Place(position)]?[name]
    }

    mutating func setDefault(_ fact: GoNumberFact?, for expression: GoExpression) {
        var named = fact
        named?.name = Self.name(of: expression)
        defaults[Place(expression.position)] = named
    }

    mutating func adopt(_ entry: Entry, for expression: GoExpression) {
        var named = entry
        if case .fact(var fact) = entry {
            fact.name = Self.name(of: expression)
            named = .fact(fact)
        }
        adopted[Place(expression.position)] = named
    }

    mutating func declare(
        _ fact: GoNumberFact, named name: String, at position: GoSourcePosition
    ) {
        declared[Place(position), default: [:]][name] = fact
    }

    /// Forgets what the nodes of `expression` are. The initializer of a
    /// constant is known by its declaration: the specifications of a
    /// `const` group that repeat one another share their nodes, and each
    /// gives them another value.
    mutating func forget(_ expression: GoExpression) {
        let place = Place(expression.position)
        defaults[place] = nil
        adopted[place] = nil
        switch expression {
        case .unary(_, let operand, _):
            forget(operand)
        case .binary(let left, _, let right, _):
            forget(left)
            forget(right)
        case .call(let callee, let arguments, _):
            forget(callee)
            arguments.forEach { forget($0) }
        case .selector(let base, _, _):
            forget(base)
        default:
            break
        }
    }
}

/// Where the checkers of one package write the facts they find. A checker
/// is a value that is copied and made anew for every function; the facts
/// are of the package, so they are behind a reference that the check of the
/// package holds for as long as it runs.
final class GoNumberLedger: @unchecked Sendable {
    var facts = GoNumberFacts()

    @TaskLocal static var current: GoNumberLedger?

    /// Runs `check`, a check of one package, and gives the package the
    /// facts its checkers found.
    static func recording(_ check: () throws -> GoTypedPackage) rethrows -> GoTypedPackage {
        let ledger = GoNumberLedger()
        var package = try $current.withValue(ledger, operation: check)
        package.numberFacts = ledger.facts
        return package
    }
}
