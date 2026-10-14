/// The zero value of a value's dynamic type, which Go's library makes with
/// `reflect.Zero` or `reflect.New`: `flag` compares a flag's default with
/// the text of a zero value of its type. The type is the descriptor the
/// value was boxed with, so the result is boxed the same way and its methods
/// are the type's.
enum GoZeroValues {
    static let native = "$flag.zero"

    /// The zero of `value`'s dynamic type; for a pointer type, a pointer to
    /// a new zero of what it points to. Nil when the type is unknown.
    static func zero(
        of value: GoValue,
        descriptor: (String) -> GoTypeDescriptor?,
        allocate: (GoValue) throws -> Int
    ) throws -> GoValue {
        guard case .interface(let boxed) = value else { return .nilValue }
        var types = GoJSONTypes()
        let type: GoRuntimeType
        if let found = descriptor(boxed.typeName) {
            types.adopt(found)
            type = found.type
        } else if let named = GoTypeDescriptor.dynamicType(named: boxed.typeName) {
            type = named
        } else {
            return .nilValue
        }
        let made: GoValue
        if case .pointer(let pointee) = types.underlying(type) {
            made = .pointer(GoPointer(cell: try allocate(types.zero(pointee))))
        } else {
            made = types.zero(type)
        }
        return .interface(GoInterfaceValue(typeName: boxed.typeName, value: made))
    }
}
