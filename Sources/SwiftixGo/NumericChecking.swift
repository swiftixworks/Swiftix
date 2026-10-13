/// The checker's rules for numbers: the sized integer and floating-point
/// types, exact constants, and the type an untyped operand takes.
///
/// `FunctionChecker` asks here wherever a number can stand: the functions
/// below answer for operands that are numbers and return nil for anything
/// else, which the checker then treats as it always did. What they decide
/// they also write down for the lowerer; see `GoNumberFacts`.

extension FunctionChecker {
    func numericKind(_ type: GoType) -> GoNumericKind? {
        GoNumericKind.of(type, definitions: typeDefinitions)
    }

    func isFloat(_ type: GoType) -> Bool { numericKind(type)?.isFloat ?? false }
    func isNumeric(_ type: GoType) -> Bool { numericKind(type) != nil }

    // MARK: Constants

    /// The numeric constant `expression` is, typed or untyped, or nil when
    /// it is none. An operation that has no value throws Go's report of it:
    /// a division by zero, a value outside its type.
    func constant(of expression: GoExpression) throws -> GoConstant? {
        switch expression {
        case .integer(let value, _):
            return .untyped(GoBigInt(value), isPlain: true)
        case .identifier(let name, let position):
            if GoLiteral.isSpelling(name) { return try literalConstant(name, at: position) }
            return lookup(name)?.constant
        case .selector(let base, let member, _):
            guard let package = importedPackage(named: base) else { return nil }
            return GoNumberLibrary.constant(package: package, member: member)
        case .unary(.plus, let operand, _):
            return try constant(of: operand)
        case .unary(.minus, let operand, _):
            guard var folded = try constant(of: operand) else { return nil }
            folded.value = -folded.value
            folded.isPlain = folded.isPlain && folded.value.truncated.int64 != nil
            return try checked(folded, at: expression.startPosition)
        case .binary:
            return try constantOfBinary(expression)
        case .call:
            return try constantOfCall(expression)
        default:
            return nil
        }
    }

    // Each kind that has operands is folded by a function of its own: the
    // evaluator calls itself for every operand, and its frame is what each
    // level of a nested expression costs.

    func constantOfBinary(_ expression: GoExpression) throws -> GoConstant? {
        guard case .binary(let left, let binaryOperator, let right, _) = expression else {
            return nil
        }
        switch binaryOperator {
        case .add, .subtract, .multiply, .divide, .remainder: break
        default: return nil
        }
        // The right operand first: in `a + b + 1 + 2` it is the leaf, so a
        // chain of variables is given up at once instead of at its far end.
        guard let rhs = try constant(of: right), let lhs = try constant(of: left) else {
            return nil
        }
        return try folded(lhs, binaryOperator, rhs, of: expression, right: right)
    }

    func constantOfCall(_ expression: GoExpression) throws -> GoConstant? {
        guard case .call(let callee, let arguments, _) = expression else { return nil }
        if let operation = expression.bitwiseOperation {
            return try foldedBitwise(operation.operator, operation.operands, of: expression)
        }
        guard arguments.count == 1, let target = try? conversionTarget(callee),
            isNumeric(target), let operand = try constant(of: arguments[0])
        else { return nil }
        return try converted(operand, to: target, at: arguments[0].startPosition)
    }

    func literalConstant(_ spelling: String, at position: GoSourcePosition) throws -> GoConstant {
        if let rune = GoLiteral.runeValue(spelling) {
            return .untyped(GoBigInt(rune), kind: .rune, isPlain: true)
        }
        guard let literal = GoNumberLiteral.value(of: spelling) else {
            throw GoDiagnostic(position: position, message: "excessively large constant")
        }
        return GoConstant(
            value: literal.value, kind: literal.isFloat ? .float : .integer, type: nil,
            isPlain: false)
    }

    /// `constant` when its value is one its type has, or the report that it
    /// is not. A floating-point constant is rounded to its type, as Go
    /// rounds it. An untyped constant has no limit but the one that keeps
    /// the compiler from building a number without end.
    func checked(_ constant: GoConstant, at position: GoSourcePosition) throws -> GoConstant {
        guard let type = constant.type, let kind = numericKind(type) else {
            guard constant.value.numerator.bitWidth <= 8192,
                constant.value.denominator.bitWidth <= 8192
            else { throw GoDiagnostic(position: position, message: "constant overflow") }
            return constant
        }
        var result = constant
        if kind.isFloat {
            let rounded =
                kind == .float32 ? constant.value.nearestSingle : constant.value.nearestDouble
            guard rounded.isFinite, let exact = GoRational(exactly: rounded) else {
                throw GoDiagnostic(
                    position: position, message: "constant \(constant.text) overflows \(type)")
            }
            result.value = exact
            result.kind = .float
            result.isPlain = false
            return result
        }
        guard constant.value.isInteger else {
            throw GoDiagnostic(
                position: position, message: "constant \(constant.text) truncated to \(type)")
        }
        guard kind.integerRange.contains(constant.value.truncated) else {
            throw GoDiagnostic(
                position: position, message: "constant \(constant.text) overflows \(type)")
        }
        if result.kind == .float { result.kind = .integer }
        result.isPlain = constant.isPlain && kind.isOriginal
        return result
    }

    /// `constant` as a value of `type`: what a conversion makes of it, and
    /// what an untyped constant becomes where a typed one is wanted.
    func converted(
        _ constant: GoConstant, to type: GoType, at position: GoSourcePosition
    ) throws -> GoConstant {
        var result = constant
        result.type = type
        return try checked(result, at: position)
    }

    /// Two constants as operands of one operator: an untyped one takes the
    /// type of a typed one. Nil when both are typed and differ, which the
    /// rule for operand types reports.
    func matched(
        _ lhs: GoConstant, _ rhs: GoConstant, left: GoSourcePosition, right: GoSourcePosition
    ) throws -> (GoConstant, GoConstant)? {
        switch (lhs.type, rhs.type) {
        case (let leftType?, let rightType?):
            return leftType == rightType ? (lhs, rhs) : nil
        case (let leftType?, nil):
            return (lhs, try converted(rhs, to: leftType, at: right))
        case (nil, let rightType?):
            return (try converted(lhs, to: rightType, at: left), rhs)
        case (nil, nil):
            return (lhs, rhs)
        }
    }

    func folded(
        _ lhs: GoConstant, _ binaryOperator: GoBinaryOperator, _ rhs: GoConstant,
        of expression: GoExpression, right: GoExpression
    ) throws -> GoConstant? {
        guard
            let (lhs, rhs) = try matched(
                lhs, rhs, left: expression.startPosition, right: right.startPosition)
        else { return nil }
        let isFloat = lhs.type.map(isFloat) ?? (max(lhs.kind, rhs.kind) == .float)
        var value: GoRational
        switch binaryOperator {
        case .add: value = lhs.value + rhs.value
        case .subtract: value = lhs.value - rhs.value
        case .multiply: value = lhs.value * rhs.value
        case .divide, .remainder:
            guard rhs.value.signum != 0 else {
                throw GoDiagnostic(position: right.startPosition, message: "division by zero")
            }
            if isFloat {
                guard binaryOperator == .divide, let quotient = lhs.value.divided(by: rhs.value)
                else { return nil }
                value = quotient
            } else {
                guard
                    let division = lhs.value.truncated.quotientAndRemainder(
                        dividingBy: rhs.value.truncated)
                else { return nil }
                value = GoRational(
                    binaryOperator == .divide ? division.quotient : division.remainder)
            }
        default:
            return nil
        }
        let result = GoConstant(
            value: value, kind: max(lhs.kind, rhs.kind), type: lhs.type,
            isPlain: lhs.isPlain && rhs.isPlain && !isFloat && value.truncated.int64 != nil)
        return try checked(result, at: expression.startPosition)
    }

    func foldedBitwise(
        _ bitwiseOperator: GoBitwiseOperator, _ operands: [GoExpression],
        of expression: GoExpression
    ) throws -> GoConstant? {
        if operands.count == 2, try constant(of: operands[1]) == nil { return nil }
        guard var lhs = try constant(of: operands[0]) else { return nil }
        let start = expression.startPosition
        if bitwiseOperator == .complement {
            guard lhs.kind != .float, lhs.value.isInteger else { return nil }
            var value = ~lhs.value.truncated
            if let kind = lhs.type.flatMap(numericKind), !kind.isSigned {
                // For an unsigned type the complement is taken in its bits.
                value = kind.integerRange.upperBound - lhs.value.truncated
            }
            lhs.value = GoRational(value)
            lhs.isPlain = lhs.isPlain && value.int64 != nil
            return try checked(lhs, at: start)
        }
        guard var rhs = try constant(of: operands[1]) else { return nil }
        if bitwiseOperator.isShift {
            // The count is a number of its own; the result has the type of
            // what is shifted, and an untyped constant with an integer
            // value is shifted as an integer.
            guard lhs.value.isInteger, rhs.value.isInteger, rhs.value.signum >= 0,
                let count = rhs.value.truncated.int64, count <= 4096
            else { return nil }
            if lhs.isUntyped, lhs.kind == .float { lhs.kind = .integer }
            let shifted =
                bitwiseOperator == .shiftLeft
                ? lhs.value.truncated.shiftedLeft(Int(count))
                : lhs.value.truncated.shiftedRight(Int(count))
            lhs.value = GoRational(shifted)
            lhs.isPlain = lhs.isPlain && rhs.isPlain && shifted.int64 != nil
            return try checked(lhs, at: start)
        }
        guard
            let matched = try matched(
                lhs, rhs, left: start, right: operands[1].startPosition)
        else { return nil }
        (lhs, rhs) = matched
        guard lhs.kind != .float, rhs.kind != .float, lhs.value.isInteger, rhs.value.isInteger
        else { return nil }
        let (left, right) = (lhs.value.truncated, rhs.value.truncated)
        let value: GoBigInt
        switch bitwiseOperator {
        case .and: value = left & right
        case .or: value = left | right
        case .xor: value = left ^ right
        case .andNot: value = left.andNot(right)
        default: return nil
        }
        let result = GoConstant(
            value: GoRational(value), kind: max(lhs.kind, rhs.kind), type: lhs.type,
            isPlain: lhs.isPlain && rhs.isPlain && value.int64 != nil)
        return try checked(result, at: start)
    }

    /// The legacy question, for the callers that still ask it: the value of
    /// an untyped integer constant that fits 64 bits.
    func untypedInteger(_ expression: GoExpression) -> Int64? {
        guard let constant = try? constant(of: expression), constant.isUntyped,
            constant.value.isInteger
        else { return nil }
        return constant.value.truncated.int64
    }

    // MARK: Facts

    var ledger: GoNumberLedger? { isProbing ? nil : GoNumberLedger.current }

    /// The 64 bits of `constant` as a value of `type`.
    func bits(of constant: GoConstant, as type: GoType) -> Int64? {
        guard let kind = numericKind(type) else { return nil }
        switch kind {
        case .float64: return Int64(bitPattern: constant.value.nearestDouble.bitPattern)
        case .float32: return Int64(bitPattern: constant.value.nearestSingle.bitPattern)
        default: return kind.bitPattern(ofInteger: constant.value.truncated)
        }
    }

    /// What the lowerer is told of a constant node of type `type`: its bits,
    /// or nothing when it is compiled as it always was.
    func entry(for constant: GoConstant, as type: GoType) -> GoNumberFacts.Entry {
        guard let kind = numericKind(type), !(constant.isPlain && kind.isOriginal) else {
            return .original
        }
        var fact = GoNumberFact(type: type, bits: bits(of: constant, as: type))
        do {
            _ = try converted(constant, to: type, at: syntheticPosition())
        } catch let diagnostic as GoDiagnostic {
            fact.overflow = diagnostic.message
        } catch {
            fact.overflow = "constant \(constant.text) overflows \(type)"
        }
        return .fact(fact)
    }

    /// Requires `expression`, when it is an untyped constant, to be a value
    /// of its default type: it is about to be used as one.
    func requireDefaultValue(_ expression: GoExpression) throws {
        guard let constant = try constant(of: expression), constant.isUntyped else { return }
        _ = try converted(constant, to: constant.kind.defaultType, at: expression.startPosition)
    }

    /// Notes the value of a named untyped constant where it is read, so
    /// that the lowerer emits it and need not trust the variable that
    /// stands for the constant to hold it.
    func noteConstantUse(_ expression: GoExpression, _ binding: Binding) {
        guard let constant = binding.constant, constant.isUntyped else { return }
        _ = noteDefault(constant, for: expression)
    }

    /// Notes what `expression`, a constant, is where nothing gives it
    /// another type, and returns that type.
    func noteDefault(_ constant: GoConstant, for expression: GoExpression) -> GoType {
        let type = constant.type ?? constant.kind.defaultType
        if let ledger {
            // A value its default type cannot hold is reported where the
            // constant is given that type; here it wraps.
            if case .fact(let fact) = entry(for: constant, as: type) {
                ledger.facts.setDefault(fact, for: expression)
            } else {
                ledger.facts.setDefault(nil, for: expression)
            }
        }
        return type
    }

    /// Notes that the operator of `expression`, which is no constant, works
    /// at `type`.
    func noteOperation(_ expression: GoExpression, at type: GoType) {
        guard let ledger, let kind = numericKind(type) else { return }
        ledger.facts.setDefault(
            kind == .int ? nil : GoNumberFact(type: type, bits: nil), for: expression)
    }

    // MARK: Untyped operands

    /// Whether `expression` is a shift that is no constant and whose left
    /// operand is an untyped constant, or is made of such shifts and of
    /// untyped constants. Go gives the constant the type the whole
    /// expression is used at: in `var mask uint64 = 1 << n` the `1` is a
    /// `uint64`, and so is every operator between it and the variable.
    func isUntypedShift(_ expression: GoExpression) throws -> Bool {
        switch expression {
        case .unary(.plus, let operand, _), .unary(.minus, let operand, _):
            return try isUntypedShift(operand)
        case .binary(let left, let binaryOperator, let right, _):
            switch binaryOperator {
            case .add, .subtract, .multiply, .divide, .remainder: break
            default: return false
            }
            return try isUntypedShiftPair(left, right)
        case .call:
            guard let operation = expression.bitwiseOperation else { return false }
            switch operation.operator {
            case .shiftLeft, .shiftRight:
                guard let shifted = try constant(of: operation.operands[0]) else {
                    return try isUntypedShift(operation.operands[0])
                }
                return try shifted.isUntyped && constant(of: operation.operands[1]) == nil
            case .complement:
                return try isUntypedShift(operation.operands[0])
            case .and, .or, .xor, .andNot:
                return try isUntypedShiftPair(operation.operands[0], operation.operands[1])
            }
        default:
            return false
        }
    }

    private func isUntypedShiftPair(_ left: GoExpression, _ right: GoExpression) throws -> Bool {
        // The right operand first, like the evaluator: it is the leaf of a
        // chain, and a variable there settles the question.
        let rightShift = try isUntypedShift(right)
        guard try rightShift || constant(of: right)?.isUntyped == true else { return false }
        let leftShift = try isUntypedShift(left)
        guard leftShift || rightShift else { return false }
        return try leftShift || constant(of: left)?.isUntyped == true
    }

    /// Whether `expression` has no type of its own yet: an untyped constant
    /// or an untyped shift.
    func isUntyped(_ expression: GoExpression) throws -> Bool {
        if let constant = try constant(of: expression) { return constant.isUntyped }
        return try isUntypedShift(expression)
    }

    /// Gives `expression`, which is untyped, the type `type`: a constant
    /// must be a value of it, and a shift must be of an integer.
    func adopt(_ expression: GoExpression, as type: GoType) throws {
        if let constant = try constant(of: expression) {
            guard constant.isUntyped else { return }
            let typed = try converted(constant, to: type, at: expression.startPosition)
            ledger?.facts.adopt(entry(for: typed, as: type), for: expression)
            return
        }
        guard let kind = numericKind(type) else { return }
        guard kind.isInteger else {
            throw GoDiagnostic(
                position: expression.startPosition,
                message: "invalid operation: shifted operand (type \(type)) must be integer")
        }
        ledger?.facts.adopt(
            kind == .int ? .original : .fact(GoNumberFact(type: type, bits: nil)),
            for: expression)
        switch expression {
        case .unary(_, let operand, _):
            try adopt(operand, as: type)
        case .binary(let left, _, let right, _):
            try adopt(left, as: type)
            try adopt(right, as: type)
        case .call:
            guard let operation = expression.bitwiseOperation else { return }
            try adopt(operation.operands[0], as: type)
            if !operation.operator.isShift, operation.operands.count == 2 {
                try adopt(operation.operands[1], as: type)
            }
        default:
            break
        }
    }

    /// Whether `expression`, of type `actual`, may be used where the number
    /// type `expected` is wanted, when that is for the rules of untyped
    /// operands to say; nil when it is not.
    func numericAssignable(
        _ expression: GoExpression, ofType actual: GoType, to expected: GoType
    ) throws -> Bool? {
        guard isNumeric(actual) else { return nil }
        guard isNumeric(expected) else {
            // An untyped constant given to an interface has its default type.
            if isInterface(expected), let constant = try constant(of: expression),
                constant.isUntyped
            {
                _ = try converted(constant, to: actual, at: expression.startPosition)
            }
            return nil
        }
        guard try isUntyped(expression) else { return nil }
        try adopt(expression, as: expected)
        return true
    }

    /// The type two numeric operands of one operator share.
    func commonNumericType(
        _ left: GoExpression, _ leftType: GoType, _ right: GoExpression, _ rightType: GoType,
        at position: GoSourcePosition
    ) throws -> GoType {
        let leftUntyped = try isUntyped(left)
        let rightUntyped = try isUntyped(right)
        if leftUntyped, !rightUntyped {
            try adopt(left, as: rightType)
            return rightType
        }
        if rightUntyped, !leftUntyped {
            try adopt(right, as: leftType)
            return leftType
        }
        if leftUntyped, rightUntyped, let lhs = try constant(of: left),
            let rhs = try constant(of: right)
        {
            return max(lhs.kind, rhs.kind).defaultType
        }
        guard leftType == rightType else {
            throw GoDiagnostic(
                position: position, message: "mismatched types \(leftType) and \(rightType)")
        }
        return leftType
    }

    // MARK: Operators

    /// The types of the operands of a binary operator: those the rule for
    /// numbers found when it left the operator to the rest, or else found
    /// here.
    mutating func operandTypes(
        _ left: GoExpression, _ right: GoExpression
    ) throws -> (GoType, GoType) {
        if let found = operandTypesInHand {
            operandTypesInHand = nil
            return found
        }
        return (try type(of: left), try type(of: right))
    }

    /// The type of a binary operator on two numbers, or nil when an operand
    /// is no number. The operands are typed here, in a frame much smaller
    /// than that of the rules for every other operand: this is the frame
    /// each level of a nested expression costs. What is found of the
    /// operands is kept for those rules when they are the ones to apply.
    mutating func numericBinaryType(_ expression: GoExpression) throws -> GoType? {
        guard case .binary(let left, let binaryOperator, let right, let position) = expression
        else { return nil }
        let leftType = try type(of: left)
        let rightType = try type(of: right)
        guard binaryOperator != .logicalAnd, binaryOperator != .logicalOr,
            isNumeric(leftType), isNumeric(rightType)
        else {
            operandTypesInHand = (leftType, rightType)
            return nil
        }
        return try numericBinaryType(
            expression, left, binaryOperator, right, leftType, rightType, position)
    }

    func numericBinaryType(
        _ expression: GoExpression, _ left: GoExpression, _ binaryOperator: GoBinaryOperator,
        _ right: GoExpression, _ leftType: GoType, _ rightType: GoType,
        _ position: GoSourcePosition
    ) throws -> GoType {
        let operandType = try commonNumericType(left, leftType, right, rightType, at: position)
        switch binaryOperator {
        case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual:
            // Two untyped constants are compared at their default type.
            if try isUntyped(left), try isUntyped(right) {
                try adopt(left, as: operandType)
                try adopt(right, as: operandType)
            }
            noteOperation(expression, at: operandType)
            return .bool
        case .remainder where isFloat(operandType):
            throw GoDiagnostic(
                position: position, message: "operator % not defined on \(operandType)")
        default:
            break
        }
        if let folded = try constant(of: expression) {
            return noteDefault(folded, for: expression)
        }
        if binaryOperator == .divide || binaryOperator == .remainder,
            let divisor = try constant(of: right), divisor.value.signum == 0
        {
            throw GoDiagnostic(position: right.startPosition, message: "division by zero")
        }
        noteOperation(expression, at: operandType)
        return operandType
    }

    /// The type of `+x` or `-x` for a number, or nil for anything else.
    func numericUnaryType(_ expression: GoExpression, operandType: GoType) throws -> GoType? {
        guard isNumeric(operandType) else { return nil }
        if let folded = try constant(of: expression) {
            return noteDefault(folded, for: expression)
        }
        noteOperation(expression, at: operandType)
        return operandType
    }

    /// The type of a bitwise operator on numbers, or nil when an operand is
    /// no number.
    mutating func numericBitwiseType(
        _ bitwiseOperator: GoBitwiseOperator, operands: [GoExpression],
        of expression: GoExpression, position: GoSourcePosition
    ) throws -> GoType? {
        let leftType = try type(of: operands[0])
        guard let leftKind = numericKind(leftType) else { return nil }
        if bitwiseOperator == .complement {
            guard leftKind.isInteger else {
                throw GoDiagnostic(
                    position: position, message: "operator ^ not defined on \(leftType)")
            }
            if let folded = try constant(of: expression) {
                return noteDefault(folded, for: expression)
            }
            noteOperation(expression, at: leftType)
            return leftType
        }
        let rightType = try type(of: operands[1])
        guard let rightKind = numericKind(rightType) else { return nil }
        let mistake = GoDiagnostic(
            position: position,
            message: "operator \(bitwiseOperator.spelling) requires integer operands")
        guard bitwiseOperator.isShift else {
            guard leftKind.isInteger, rightKind.isInteger else { throw mistake }
            let operandType = try commonNumericType(
                operands[0], leftType, operands[1], rightType, at: position)
            if let folded = try constant(of: expression) {
                return noteDefault(folded, for: expression)
            }
            noteOperation(expression, at: operandType)
            return operandType
        }
        // A shift count is a number of its own: any integer, or a constant
        // with an integer value that is not negative.
        if let count = try constant(of: operands[1]) {
            guard count.value.isInteger else { throw mistake }
            guard count.value.signum >= 0 else {
                throw GoDiagnostic(
                    position: operands[1].position,
                    message: "invalid negative shift count \(count.text)")
            }
            if count.isUntyped { try adopt(operands[1], as: .int) }
        } else {
            guard rightKind.isInteger else { throw mistake }
        }
        if let shifted = try constant(of: operands[0]) {
            guard shifted.value.isInteger, shifted.type.map(isFloat) != true else { throw mistake }
            if let folded = try constant(of: expression) {
                return noteDefault(folded, for: expression)
            }
            guard shifted.isUntyped else {
                noteOperation(expression, at: leftType)
                return leftType
            }
            // An untyped constant shifted by a variable: an integer of its
            // default type, until the place it is used gives it another.
            guard shifted.kind != .float else {
                throw GoDiagnostic(
                    position: operands[0].startPosition,
                    message: "invalid operation: shifted operand (type float64) must be integer")
            }
            let type = shifted.kind.defaultType
            try adopt(operands[0], as: type)
            noteOperation(expression, at: type)
            return type
        }
        guard leftKind.isInteger else { throw mistake }
        noteOperation(expression, at: leftType)
        return leftType
    }

    /// The type of a literal that is spelled as an identifier.
    func literalType(_ expression: GoExpression) throws -> GoType? {
        guard case .identifier(let name, _) = expression, GoLiteral.isSpelling(name),
            let literal = try constant(of: expression)
        else { return nil }
        return noteDefault(literal, for: expression)
    }

    /// The type of a numeric constant of the library, `math.Pi`.
    func libraryConstantType(_ expression: GoExpression) throws -> GoType? {
        guard case .selector(.identifier, _, _) = expression,
            let constant = try constant(of: expression)
        else { return nil }
        return noteDefault(constant, for: expression)
    }

    // MARK: Conversions

    /// The type of the conversion `T(argument)` when `T` or the argument is
    /// a number and the rules for numbers decide; nil when they do not.
    mutating func numericConversionType(
        _ target: GoType, argument: GoExpression, at position: GoSourcePosition
    ) throws -> GoType? {
        let source = try type(of: argument)
        let failure = GoDiagnostic(
            position: argument.position, message: "cannot convert \(source) to type \(target)")
        if isNumeric(target) {
            guard isNumeric(source) else { return nil }
            if let operand = try constant(of: argument) {
                // The node of the conversion: a call where its `(` is.
                let converted = try converted(operand, to: target, at: argument.startPosition)
                _ = noteDefault(
                    converted, for: .call(callee: argument, arguments: [], position: position))
                return target
            }
            if try isUntypedShift(argument) { try adopt(argument, as: target) }
            return target
        }
        guard let sourceKind = numericKind(source) else {
            // `[]rune(s)` and `string(runes)`.
            if case .slice(let element) = underlying(target), numericKind(element) == .int32,
                !isByte(element), underlying(source) == .string
            {
                return target
            }
            if underlying(target) == .string, case .slice(let element) = underlying(source),
                numericKind(element) == .int32
            {
                return target
            }
            return nil
        }
        // `string(x)` takes an integer, which is a code point.
        if underlying(target) == .string {
            guard sourceKind.isInteger else { throw failure }
            if let constant = try constant(of: argument), constant.isUntyped {
                try adopt(argument, as: constant.kind == .float ? .int : constant.kind.defaultType)
            }
            return target
        }
        return nil
    }

    // MARK: Declarations

    /// Notes the constant a `const` declaration declares, so that later
    /// constant expressions fold it, and checks the value a variable takes
    /// from an untyped constant.
    mutating func noteDeclaration(
        _ name: String, declared: GoType?, expression: GoExpression?, isConstant: Bool,
        position: GoSourcePosition
    ) throws {
        guard let expression, let value = try constant(of: expression) else { return }
        guard isConstant else {
            if declared == nil, value.isUntyped {
                _ = try converted(
                    value, to: value.kind.defaultType, at: expression.startPosition)
            }
            return
        }
        var constant = value
        if let declared, isNumeric(declared), value.isUntyped {
            constant = try converted(value, to: declared, at: expression.startPosition)
        }
        ledger?.facts.forget(expression)
        guard name != GoValueList.blank else { return }
        scopes[scopes.count - 1][name]?.constant = constant
        noteDeclaredConstant(constant, named: name, at: position)
    }

    /// Tells the lowerer the value of the declared constant `name`.
    func noteDeclaredConstant(
        _ constant: GoConstant, named name: String, at position: GoSourcePosition
    ) {
        let type = constant.type ?? constant.kind.defaultType
        if case .fact(let fact) = entry(for: constant, as: type) {
            ledger?.facts.declare(fact, named: name, at: position)
        }
    }
}

extension GoTypeChecker {
    /// Gives each package-level constant its value. A constant may be
    /// defined by one declared after it, so the declarations are gone
    /// through until none gains a value.
    static func resolveConstants(
        _ globals: [GoGlobalDeclaration],
        bindings: inout [String: Binding],
        checker: (GoGlobalDeclaration, [String: Binding]) -> FunctionChecker
    ) throws {
        var pending = globals.filter { $0.isConstant && $0.expression != nil }
        var failure: Error?
        while !pending.isEmpty {
            var next: [GoGlobalDeclaration] = []
            failure = nil
            for declaration in pending {
                guard let expression = declaration.expression,
                    let binding = bindings[declaration.name]
                else { continue }
                let scope = checker(declaration, bindings)
                do {
                    guard var constant = try scope.constant(of: expression) else {
                        next.append(declaration)
                        continue
                    }
                    if declaration.explicitType != nil, scope.isNumeric(binding.type),
                        constant.isUntyped
                    {
                        constant = try scope.converted(
                            constant, to: binding.type, at: expression.startPosition)
                    }
                    bindings[declaration.name]?.constant = constant
                    scope.noteDeclaredConstant(
                        constant, named: declaration.name, at: declaration.position)
                } catch {
                    // It may depend on a constant that has no value yet.
                    failure = failure ?? error
                    next.append(declaration)
                }
            }
            guard next.count < pending.count else { break }
            pending = next
        }
        if let failure { throw failure }
    }

    /// Forgets the nodes of the initializers of the package-level
    /// constants, once nothing checks them again: each is known to the
    /// lowerer by its declaration.
    static func forgetConstantNodes(_ globals: [GoGlobalDeclaration], bindings: [String: Binding]) {
        for declaration in globals where declaration.isConstant {
            guard let expression = declaration.expression,
                bindings[declaration.name]?.constant != nil
            else { continue }
            GoNumberLedger.current?.facts.forget(expression)
        }
    }
}
