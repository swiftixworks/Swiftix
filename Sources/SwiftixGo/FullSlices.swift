/// Full slice expressions `a[low:high:max]`, whose result has the capacity
/// `max - low`, on slices, arrays, and pointers to arrays.
///
/// `GoExpression.slicing` has room for two indexes only and is frozen, so
/// the third is carried in the second: `high` is a call of the reserved
/// name `$slice3` with `high` and `max` as its operands, a call no source
/// can write (see `GoFullSlice.bounds`). A pass that walks every operand of
/// an expression walks both, and the passes that give a slice expression
/// its meaning (the checker, the lowerer, and what prints one) ask
/// `fullSliceBounds` first.
///
/// The VM makes the slice with the native `$slice.full`, which tests the
/// bounds in Go's order and panics with Go's text: `max` against the
/// capacity (`[::5] with capacity 4`, `with length` for an array), then
/// `high` against `max` (`[:3:2]`), then `low` against `high` (`[3:2:]`).
enum GoFullSlice {
    /// The callee that marks the second index of a slice expression as
    /// `high` and `max`.
    static let calleeName = "$slice3"
    /// The native that makes the slice: the slice, or the pointer to the
    /// array, then `low`, `high`, `max`, the zero value of an element of an
    /// array (nil for a slice), and whether it is an array.
    static let nativeName = "$slice.full"

    /// The second index of `a[low:high:max]`.
    static func bounds(high: GoExpression, max: GoExpression) -> GoExpression {
        .call(
            callee: .identifier(calleeName, position: high.position), arguments: [high, max],
            position: high.position)
    }
}

extension GoExpression {
    /// `high` and `max` when this is the second index of a full slice
    /// expression.
    var fullSliceBounds: (high: GoExpression, max: GoExpression)? {
        guard case .call(.identifier(GoFullSlice.calleeName, _), let arguments, _) = self,
            arguments.count == 2
        else { return nil }
        return (arguments[0], arguments[1])
    }

    /// The indexes of a slice expression after the first as a source has
    /// them: `high`, or `high` and `max`.
    var sliceIndexesAfterLow: [GoExpression] {
        fullSliceBounds.map { [$0.high, $0.max] } ?? [self]
    }
}

extension FunctionChecker {
    /// The type of `base[low:high:max]`, checked as Go checks it: what is
    /// sliced first, then each index, then the order of the constant ones.
    mutating func typeOfFullSlice(
        base: GoExpression, low: GoExpression?, high: GoExpression, max: GoExpression
    ) throws -> GoType {
        let sliced = try indexedType(of: base)
        let resultType: GoType
        var length: Int64?
        switch sliced {
        case .array(let count, let element):
            resultType = .slice(element)
            length = Int64(count)
        case .slice(let element):
            resultType = .slice(element)
        case .string:
            throw GoDiagnostic(
                position: Self.start(of: max, in: namePositions),
                message: "invalid operation: 3-index slice of string")
        default:
            throw try invalidOperand("cannot slice", base, ofType: type(of: base))
        }
        try checkSliceIndexes([low, high, max], length: length)
        return resultType
    }

    /// Each index of a slice expression is an integer, and a constant one
    /// is not negative and not past the length of an array; constant
    /// indexes are in order. `length` is nil where it is not known.
    mutating func checkSliceIndexes(_ indexes: [GoExpression?], length: Int64?) throws {
        var values: [(value: Int64, index: GoExpression)?] = []
        for index in indexes {
            guard let index else {
                values.append(nil)
                continue
            }
            let indexType = try type(of: index)
            let constant = try constant(of: index)
            if let constant, constant.isUntyped, !constant.value.isInteger {
                throw GoDiagnostic(
                    position: Self.start(of: index, in: namePositions),
                    message: "\(describe(index, ofType: indexType)) truncated to int")
            }
            guard isInteger(indexType) else { throw nonIntegerIndex(index) }
            guard let constant, let value = constant.value.truncated.int64 else {
                values.append(nil)
                continue
            }
            let shown = constant.isUntyped
                ? "\(spelling(of: index)) (constant of type int)" : describe(index, ofType: indexType)
            if value < 0 {
                throw GoDiagnostic(
                    position: Self.start(of: index, in: namePositions),
                    message: "invalid argument: index \(shown) must not be negative")
            }
            if let length, value > length {
                throw GoDiagnostic(
                    position: Self.start(of: index, in: namePositions),
                    message: "invalid argument: index \(spelling(of: index)) out of bounds "
                        + "[0:\(length + 1)]")
            }
            values.append((value, index))
        }
        // Go reports the first index that is less than one before it.
        for (offset, earlier) in values.enumerated() {
            guard let earlier, earlier.value > 0 else { continue }
            for later in values[(offset + 1)...] {
                if let later, later.value < earlier.value {
                    throw GoDiagnostic(
                        position: Self.start(of: later.index, in: namePositions),
                        message: "invalid slice indices: \(later.value) < \(earlier.value)")
                }
            }
        }
    }
}

extension IRLowerer {
    /// `base[low:high:max]`: what is sliced is read first, then the indexes
    /// in order, and the VM makes the slice.
    mutating func lowerFullSlice(
        base: GoExpression, low: GoExpression?, high: GoExpression, max: GoExpression,
        position: GoSourcePosition
    ) throws -> Int {
        let baseType = try type(of: base)
        let sliced: Int
        let zero: Int
        let isArray: Bool
        if case .array(_, let elementType) = underlying(baseType) {
            isArray = true
            sliced = try lowerAddress(of: base)
            zero = try zeroValue(for: elementType, position: position)
        } else {
            isArray = false
            sliced = try lower(base)
            zero = constant(.nilValue)
        }
        let lowRegister = try low.map { try lower($0) } ?? constant(.int(0))
        let highRegister = try lower(high)
        let maxRegister = try lower(max)
        let destination = allocateRegister()
        operations.append(
            .call(
                function: GoFullSlice.nativeName,
                arguments: [
                    sliced, lowRegister, highRegister, maxRegister, zero,
                    constant(.bool(isArray)),
                ],
                destinations: [destination]))
        return destination
    }
}

extension FunctionChecker {
    /// The constant indexes of `base[low:high]` are not negative, not past
    /// the length of an array, and in order.
    mutating func checkConstantSliceIndexes(
        of base: GoExpression, _ indexes: [GoExpression?]
    ) throws {
        var length: Int64?
        if case .array(let count, _) = try indexedType(of: base) { length = Int64(count) }
        try checkSliceIndexes(indexes, length: length)
    }
}
