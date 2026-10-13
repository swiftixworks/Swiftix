/// Lowering of numbers: the operation for each operator, chosen by the type
/// the checker found the operator to work at.
///
/// The VM adds, multiplies, and compares 64-bit integers. That is every
/// operator of `int`, and enough of `int8` to `uint32` once a result is
/// brought back into its range. What 64-bit signed arithmetic gets wrong,
/// and all of floating point, are reserved calls (`$num.*`), like the
/// bitwise operators before them.
///
/// For `int` and for `byte` nothing here emits anything that was not
/// emitted before: a program without the newer types compiles to the
/// instructions it always did.

extension IRLowerer {
    func numericKind(_ type: GoType) -> GoNumericKind? {
        GoNumericKind.of(type, definitions: typeDefinitions)
    }

    /// The type of `expression` when the checker noted one: the type of an
    /// operator's result, and the type an untyped constant took. A rune
    /// literal that took none is the `int` it has always been to this pass.
    func notedType(of expression: GoExpression) -> GoType? {
        if let fact = numbers.fact(for: expression) {
            if case .binary(_, let binaryOperator, _, _) = expression {
                switch binaryOperator {
                case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: return .bool
                default: break
                }
            }
            return fact.type
        }
        if case .identifier(let name, _) = expression, GoLiteral.isRune(name) { return .int }
        return nil
    }

    /// Lowers `expression` when it is a number the checker noted something
    /// about; nil when it is compiled as it always was.
    mutating func lowerNumeric(_ expression: GoExpression) throws -> Int? {
        if case .identifier(let name, let position) = expression, GoLiteral.isSpelling(name),
            numbers.fact(for: expression) == nil
        {
            guard let rune = GoLiteral.runeValue(name) else {
                throw GoDiagnostic(position: position, message: "constant \(name) has no type")
            }
            return constant(.int(rune))
        }
        guard !numbers.isEmpty, let fact = numbers.fact(for: expression) else { return nil }
        if let bits = fact.bits {
            if let overflow = fact.overflow {
                throw GoDiagnostic(position: expression.startPosition, message: overflow)
            }
            return constant(.int(bits))
        }
        guard let kind = numericKind(fact.type) else { return nil }
        switch expression {
        case .unary(.minus, let operand, _):
            let source = try lower(operand)
            let destination = allocateRegister()
            if kind.isFloat {
                operations.append(
                    .call(function: "$num.fneg", arguments: [source], destinations: [destination]))
                return destination
            }
            operations.append(.unary(destination: destination, operator: .negate, operand: source))
            return wrap(destination, to: kind)
        case .binary(let left, let binaryOperator, let right, _):
            return try lowerNumericBinary(left, binaryOperator, right, at: kind)
        case .call:
            guard let operation = expression.bitwiseOperation else { return nil }
            return try lowerNumericBitwise(operation.operator, operation.operands, at: kind)
        default:
            return nil
        }
    }

    /// Brings `register`, a 64-bit result, into the range of `kind`.
    mutating func wrap(_ register: Int, to kind: GoNumericKind) -> Int {
        if kind == .uint8 { return wrapByte(register, type: GoPredeclared.byte) }
        guard let call = kind.wrapCall else { return register }
        let destination = allocateRegister()
        operations.append(.call(function: call, arguments: [register], destinations: [destination]))
        return destination
    }

    mutating func lowerNumericBinary(
        _ left: GoExpression, _ binaryOperator: GoBinaryOperator, _ right: GoExpression,
        at kind: GoNumericKind
    ) throws -> Int {
        let leftRegister = try lower(left)
        let rightRegister = try lower(right)
        let destination = allocateRegister()
        var call: String?
        if kind.isFloat {
            switch binaryOperator {
            case .add: call = "$num.fadd"
            case .subtract: call = "$num.fsub"
            case .multiply: call = "$num.fmul"
            case .divide: call = "$num.fdiv"
            case .equal: call = "$num.feq"
            case .notEqual: call = "$num.fne"
            case .less: call = "$num.flt"
            case .lessEqual: call = "$num.fle"
            case .greater: call = "$num.fgt"
            case .greaterEqual: call = "$num.fge"
            default: break
            }
        } else if kind.isWideUnsigned {
            // The bits are those of the signed operation for everything
            // but these, which read the high bit as a sign.
            switch binaryOperator {
            case .divide: call = "$num.udiv"
            case .remainder: call = "$num.urem"
            case .less: call = "$num.ult"
            case .lessEqual: call = "$num.ule"
            case .greater: call = "$num.ugt"
            case .greaterEqual: call = "$num.uge"
            default: break
            }
        }
        if let call {
            operations.append(
                .call(
                    function: call, arguments: [leftRegister, rightRegister],
                    destinations: [destination]))
        } else {
            operations.append(
                .binary(
                    destination: destination, operator: map(binaryOperator),
                    left: leftRegister, right: rightRegister))
        }
        switch binaryOperator {
        case .add, .subtract, .multiply:
            return wrap(destination, to: kind)
        case .divide:
            // The least value of a signed type divided by -1 leaves it.
            return kind.isSigned ? wrap(destination, to: kind) : destination
        default:
            return destination
        }
    }

    mutating func lowerNumericBitwise(
        _ bitwiseOperator: GoBitwiseOperator, _ operands: [GoExpression], at kind: GoNumericKind
    ) throws -> Int {
        var registers = try operands.map { try lower($0) }
        if bitwiseOperator.isShift,
            let count = (try? type(of: operands[1])).flatMap(numericKind), count.isWideUnsigned
        {
            // A count with its high bit set is a large one, not a negative.
            let clamped = allocateRegister()
            operations.append(
                .call(function: "$num.ucount", arguments: [registers[1]], destinations: [clamped]))
            registers[1] = clamped
        }
        let destination = allocateRegister()
        let logicalShift = bitwiseOperator == .shiftRight && kind.isWideUnsigned
        operations.append(
            .call(
                function: logicalShift ? "$num.ushr" : bitwiseOperator.nativeName,
                arguments: registers, destinations: [destination]))
        switch bitwiseOperator {
        case .shiftLeft: return wrap(destination, to: kind)
        case .complement: return kind.isSigned ? destination : wrap(destination, to: kind)
        default: return destination
        }
    }

    /// Whether `expression` is a floating-point number.
    func isFloatingPoint(_ expression: GoExpression) -> Bool {
        (try? type(of: expression)).flatMap(numericKind)?.isFloat == true
    }

    /// `min` or `max` of numbers the instruction for `<` does not order:
    /// floating-point ones, where a NaN gives a NaN and negative zero is
    /// less than zero, and unsigned ones of 64 bits. Nil for any other.
    mutating func lowerNumericExtreme(
        isMinimum: Bool, of arguments: [GoExpression]
    ) throws -> Int? {
        let kinds = arguments.compactMap { (try? type(of: $0)).flatMap(numericKind) }
        guard let kind = kinds.first(where: { $0.isFloat || $0.isWideUnsigned }),
            let first = arguments.first
        else { return nil }
        var result = try lower(first)
        for argument in arguments.dropFirst() {
            let operand = try lower(argument)
            let next = allocateRegister()
            if kind.isFloat {
                operations.append(
                    .call(
                        function: isMinimum ? "$num.fmin" : "$num.fmax",
                        arguments: [result, operand], destinations: [next]))
            } else {
                // The lesser, or the greater, of two: one comparison and
                // the choice it makes.
                let isBetter = allocateRegister()
                let kept = allocateLabel()
                operations.append(.copy(destination: next, source: result))
                operations.append(
                    .call(
                        function: "$num.ult",
                        arguments: isMinimum ? [operand, result] : [result, operand],
                        destinations: [isBetter]))
                operations.append(.jumpIfFalse(condition: isBetter, target: kept))
                operations.append(.copy(destination: next, source: operand))
                operations.append(.label(kept))
            }
            result = next
        }
        return result
    }

    /// `x++` and `x--` for a number that is no `int` and no `byte`; false
    /// for those, which are compiled as before.
    mutating func lowerNumericIncrement(_ statement: GoStatement) throws -> Bool {
        guard case .increment(let target, let incrementOperator, _) = statement,
            let kind = (try? type(of: target)).flatMap(numericKind), !kind.isOriginal
        else { return false }
        let current = try lower(target)
        let result = allocateRegister()
        if kind.isFloat {
            let one = constant(.int(Int64(bitPattern: (1.0 as Double).bitPattern)))
            operations.append(
                .call(
                    function: incrementOperator == .increment ? "$num.fadd" : "$num.fsub",
                    arguments: [current, one], destinations: [result]))
        } else {
            let one = constant(.int(1))
            operations.append(
                .binary(
                    destination: result,
                    operator: incrementOperator == .increment ? .add : .subtract,
                    left: current, right: one))
        }
        try store(wrap(result, to: kind), to: target)
        return true
    }

    /// The conversion `T(argument)` where a number of the newer types is on
    /// either side, or a slice of runes; nil for the conversions that were
    /// there before.
    mutating func lowerNumericConversion(to target: GoType, argument: GoExpression) throws -> Int? {
        let source = try? type(of: argument)
        let sourceKind = source.flatMap(numericKind)
        if let targetKind = numericKind(target) {
            guard let sourceKind, !(targetKind.isOriginal && sourceKind.isOriginal) else {
                return nil
            }
            return convert(try lower(argument), from: sourceKind, to: targetKind)
        }
        var call: String?
        if case .slice(let element) = underlying(target), numericKind(element) == .int32,
            source.map({ underlying($0) }) == .string
        {
            call = "$num.runes"
        } else if underlying(target) == .string, case .slice(let element)? = source.map({ underlying($0) }),
            numericKind(element) == .int32
        {
            call = "$num.string"
        }
        guard let call else { return nil }
        let value = try lower(argument)
        let destination = allocateRegister()
        operations.append(.call(function: call, arguments: [value], destinations: [destination]))
        return destination
    }

    /// `register`, a number of kind `source`, as one of kind `target`.
    mutating func convert(
        _ register: Int, from source: GoNumericKind, to target: GoNumericKind
    ) -> Int {
        func call(_ name: String, _ operand: Int) -> Int {
            let destination = allocateRegister()
            operations.append(.call(function: name, arguments: [operand], destinations: [destination]))
            return destination
        }
        switch (source.isFloat, target.isFloat) {
        case (false, false):
            // The bits stay; a narrower type keeps its low ones.
            let (from, to) = (source.integerRange, target.integerRange)
            if target.bits == 64 || (from.lowerBound >= to.lowerBound && from.upperBound <= to.upperBound) {
                return register
            }
            return wrap(register, to: target)
        case (false, true):
            let float = call(source.isWideUnsigned ? "$num.utof" : "$num.itof", register)
            return target == .float32 ? call("$num.f32", float) : float
        case (true, false):
            // What is before the point. For a number the type has no
            // integer for, the reference machine decides: it stops at the
            // ends of 64 bits, or of 32 for a type of 32 bits or fewer,
            // except `uint32`, which keeps the low bits of the 64.
            if target.isWideUnsigned { return call("$num.ftou", register) }
            if target.bits == 64 { return call("$num.ftoi", register) }
            if target == .uint32 { return wrap(call("$num.ftoi", register), to: target) }
            let narrow = call("$num.ftoi32", register)
            return target == .int32 ? narrow : wrap(narrow, to: target)
        case (true, true):
            return source == .float64 && target == .float32 ? call("$num.f32", register) : register
        }
    }

    /// Declares the constant of a `const` declaration whose value the
    /// checker noted: the value is emitted, and nothing is computed. False
    /// for a constant that is computed as before.
    mutating func lowerNotedConstant(_ statement: GoStatement) -> Bool {
        guard case .declaration(let name, _, _, true, let position) = statement,
            let fact = numbers.constant(named: name, declaredAt: position), let bits = fact.bits
        else { return false }
        let variable = allocateRegister()
        let value = constant(.int(bits))
        startVariable(variable, named: name, type: fact.type)
        operations.append(.copy(destination: variable, source: value))
        scopes[scopes.count - 1][name] = LoweredBinding(register: variable, type: fact.type)
        return true
    }

    /// The value of the package-level constant `declaration` when the
    /// checker noted it.
    mutating func notedConstant(_ declaration: GoGlobalDeclaration) -> Int? {
        guard declaration.isConstant,
            let bits = numbers.constant(
                named: declaration.name, declaredAt: declaration.position)?.bits
        else { return nil }
        return constant(.int(bits))
    }
}
