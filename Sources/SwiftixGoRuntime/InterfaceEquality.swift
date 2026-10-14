/// Go's panic for `==` between two interface values that hold values of one
/// type that is not comparable: `runtime error: comparing uncomparable type
/// []int`. Values of two different types are unequal whatever they are,
/// and an interface that holds a comparable type compares as it always did.
///
/// The type is read from the descriptor the two values were boxed with
/// (see `GoTypeDescriptor`): a slice, a map, a function, and a struct or an
/// array with one of those in it are not comparable. Pure functions; no
/// process or executor state.
enum GoInterfaceEquality {
    /// Throws Go's panic when `left == right` compares two interface values
    /// of one type that is not comparable.
    static func requireComparable(_ left: GoValue, _ right: GoValue) throws {
        guard case .interface(let lhs) = left, case .interface(let rhs) = right,
            lhs.typeName == rhs.typeName,
            let descriptor = GoTypeDescriptor(typeName: lhs.typeName),
            !isComparable(descriptor.type, in: descriptor)
        else { return }
        throw GoRuntimePanic(
            GoErrors.runtimeErrorType,
            "runtime error: comparing uncomparable type "
                + GoTypeDescriptor.name(of: descriptor.type))
    }

    private static func isComparable(
        _ type: GoRuntimeType, in descriptor: GoTypeDescriptor, depth: Int = 0
    ) -> Bool {
        // A type defined by itself is reached through a pointer, a slice, or
        // a map, which settle the question before this does.
        guard depth < 64 else { return true }
        switch descriptor.underlying(type) {
        case .slice, .map: return false
        case .other(let text): return !text.hasPrefix("func")
        case .array(_, let element):
            return isComparable(element, in: descriptor, depth: depth + 1)
        case .structure(let fields):
            return fields.allSatisfy { isComparable($0.type, in: descriptor, depth: depth + 1) }
        default: return true
        }
    }
}
