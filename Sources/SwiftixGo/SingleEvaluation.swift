/// A compound assignment and `++`/`--` evaluate their target once.
///
/// The parser writes `x op= y` as `x = x op y`, the one target node in both
/// places, and `x++` keeps its target once but is lowered as a load and a
/// store of it. Either reads the target's operands twice, which is the same
/// as reading them once when they contain no call and no channel receive:
/// those targets are lowered as they always were. A target that has one,
/// `m[f()] += 1`, `a[<-ch]++`, `p().x -= 2`, first has its operands read
/// and named, as a parallel assignment does (`pinned`); what is left reads a
/// variable twice and calls nothing.

extension GoExpression {
    /// The operation of `target op= value` when this is the expression the
    /// parser made of it: an operator whose left operand is `target`, the
    /// node itself and so at its position. A source that writes
    /// `x = x + 1` has two nodes at two positions.
    func compoundOperation(of target: GoExpression) -> GoCompoundOperation? {
        switch self {
        case .binary(let left, let binaryOperator, let right, let position) where left == target:
            return GoCompoundOperation(
                compound: .arithmetic(binaryOperator), value: right, position: position)
        case .call:
            guard let operation = bitwiseOperation, operation.operands.count == 2,
                operation.operands[0] == target
            else { return nil }
            return GoCompoundOperation(
                compound: .bitwise(operation.operator), value: operation.operands[1],
                position: position)
        default:
            return nil
        }
    }
}

/// `op value` of a compound assignment, to be applied to another target.
struct GoCompoundOperation {
    let compound: GoCompoundAssignment
    let value: GoExpression
    let position: GoSourcePosition

    func apply(to target: GoExpression) -> GoExpression {
        compound.apply(to: target, value, position: position)
    }
}

extension IRLowerer {
    /// Lowers a compound assignment or an increment whose target has a call
    /// or a receive in it, with that target's operands read once; false for
    /// any other statement, which is lowered as it always was.
    mutating func lowerOnceEvaluatedTarget(_ statement: GoStatement) throws -> Bool {
        switch statement {
        case .assignment(let target, let expression, let position):
            guard !target.isRepeatable, let operation = expression.compoundOperation(of: target)
            else { return false }
            let named = try onceEvaluated(target)
            try lowerAssignment(
                .assignment(target: named, expression: operation.apply(to: named), position: position))
            return true
        case .increment(let target, let incrementOperator, let position):
            guard !target.isRepeatable else { return false }
            try lowerIncrement(
                .increment(
                    target: try onceEvaluated(target), operator: incrementOperator,
                    position: position))
            return true
        default:
            return false
        }
    }

    /// `target` with its calls and receives made, as `pinned` makes them for
    /// a parallel assignment. Every target the checker lets through is left
    /// with none, so the statement it is put in is not taken here again.
    private mutating func onceEvaluated(_ target: GoExpression) throws -> GoExpression {
        let named = try pinned(target)
        guard named.isRepeatable else {
            throw GoDiagnostic(
                position: target.position,
                message: "cannot assign to \(target.spelled(in: [:])) (neither addressable nor a map index expression)")
        }
        return named
    }
}

extension FunctionChecker {
    /// The type of `base` in `base.f = v` when it is a pointer that only a
    /// call or a receive gives, `p().x`: the field is a variable though
    /// what points at it is not. Nil for every other base, which must be a
    /// variable itself as it always had to.
    mutating func pointerBaseType(of base: GoExpression) throws -> GoType? {
        guard !base.isRepeatable else { return nil }
        let baseType = try type(of: base)
        return baseType.pointee(in: typeDefinitions) == nil ? nil : baseType
    }
}

extension IRLowerer {
    /// `base[low:]` with a call or a receive in `base`, with that part read
    /// once and named: the slice expression reads `base` for its length
    /// and again to slice it. Nil for every other slice expression, which is
    /// lowered as it always was.
    mutating func onceEvaluatedSliceBase(_ expression: GoExpression) throws -> GoExpression? {
        guard case .slicing(let base, let low, nil, let position) = expression,
            !base.isRepeatable
        else { return nil }
        let named: GoExpression
        if case .unary(.dereference, let pointer, let at) = base {
            // `p()[1:]` of a pointer to an array, which is `(*p())[1:]`.
            named = .unary(operator: .dereference, operand: try pin(pointer), position: at)
        } else if case .array = underlying(try type(of: base)) {
            return nil
        } else {
            named = try pin(base)
        }
        return .slicing(base: named, low: low, high: nil, position: position)
    }
}

extension FunctionChecker {
    /// Refuses a store in a field of a struct that is an element of a map,
    /// `m[k].f = v`, as Go does: the element is a copy, no variable, and
    /// neither is a field deeper in it, `m[k].a.b`. A field reached through
    /// a pointer on the way is a variable.
    mutating func refuseFieldOfMapElement(_ target: GoExpression) throws {
        var current = target
        var depth = 0
        while case .selector(let base, _, _) = current {
            // What has no type here is for the rule for any target to report.
            guard let baseType = try? type(of: base),
                baseType.pointee(in: typeDefinitions) == nil
            else { return }
            current = base
            depth += 1
        }
        guard depth > 0, case .index(let collection, _, _) = current,
            let collectionType = try? type(of: collection), case .map = underlying(collectionType)
        else { return }
        guard depth == 1 else { throw unassignable(target) }
        throw GoDiagnostic(
            position: Self.start(of: target, in: namePositions),
            message: "cannot assign to struct field \(spelling(of: target)) in map")
    }
}
