/// `==` and `!=` between an interface value and a value of another type:
/// `a == 5` where `a` is an `any`, `err == target` where `target` is a
/// `*MyError`, an `any` compared with an `error`, and a `switch` on an
/// interface with cases of concrete types.
///
/// Go converts the operand that is no interface to the type of the other,
/// as an assignment would, and compares two interface values: equal when
/// they hold values of one dynamic type that are equal. So does this
/// compiler: the operand is boxed with its type, as `converted` boxes any
/// value given to an interface, and the VM compares the two boxes. Two
/// boxes of one type that is not comparable (a slice, a map, a function, a
/// struct or an array of one) panic in the VM, as Go's do.
///
/// An untyped constant takes its default type, so `a == 5` is true for an
/// `int` 5 only. Comparisons of two operands of one type are lowered as they
/// always were.

extension FunctionChecker {
    /// `.bool` for `left == right` or `left != right` when one operand is an
    /// interface and the other is a comparable value of a type that may be
    /// assigned to it, or both are interfaces and one may be assigned to the
    /// other; nil for every other operation, which the rules for operators
    /// check, and report as Go does when it is wrong.
    mutating func interfaceComparisonType(
        _ expression: GoExpression, _ leftType: GoType, _ rightType: GoType
    ) throws -> GoType? {
        guard case .binary(let left, let binaryOperator, let right, _) = expression,
            binaryOperator == .equal || binaryOperator == .notEqual,
            try comparesAsInterfaces(left, leftType, right, rightType)
        else { return nil }
        return .bool
    }

    /// Whether `left` and `right` compare as two interface values: the
    /// one that is no interface has a comparable type the other's has room
    /// for. An untyped constant is given its default type here.
    mutating func comparesAsInterfaces(
        _ left: GoExpression, _ leftType: GoType, _ right: GoExpression, _ rightType: GoType
    ) throws -> Bool {
        guard leftType != rightType, leftType != .nilType, rightType != .nilType,
            leftType != .void, rightType != .void
        else { return false }
        switch (isInterface(leftType), isInterface(rightType)) {
        case (true, true):
            return isAssignable(leftType, to: rightType) || isAssignable(rightType, to: leftType)
        case (true, false):
            return try concreteComparand(right, rightType, against: leftType)
        case (false, true):
            return try concreteComparand(left, leftType, against: rightType)
        case (false, false):
            return false
        }
    }

    private mutating func concreteComparand(
        _ operand: GoExpression, _ operandType: GoType, against interfaceType: GoType
    ) throws -> Bool {
        guard isComparable(operandType),
            try isAssignable(operand, ofType: operandType, to: interfaceType)
        else { return false }
        if try isUntyped(operand) { try adopt(operand, as: operandType) }
        return true
    }
}

extension IRLowerer {
    /// `register`, the lowered `operand` of `==` or `!=` (or a case of a
    /// switch), boxed as an interface value when the other operand is an
    /// interface and this one is not; `register` itself otherwise.
    mutating func interfaceComparand(
        _ register: Int, _ operand: GoExpression, against other: GoExpression?,
        by binaryOperator: GoBinaryOperator
    ) -> Int {
        guard binaryOperator == .equal || binaryOperator == .notEqual, let other,
            let operandType = staticType(of: operand), operandType != .nilType,
            !isInterfaceType(operandType),
            let otherType = staticType(of: other), isInterfaceType(otherType)
        else { return register }
        return converted(register, from: operandType, to: otherType)
    }
}
