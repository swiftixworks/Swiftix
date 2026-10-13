/// Pointer types with a name, `type ptr *T`.
///
/// Such a type is a pointer in all but its name: `p.f` selects a field of
/// what it points to, `*p` is that value, and it compares with `nil` and
/// converts to and from `*T`. It has no methods, its own or those of `T`.
/// The checker and the compiler asked whether a type *is* a pointer; they
/// ask this, which looks beneath a name first.
extension GoType {
    /// What a value of this type points to: `T` for `*T`, and for a type
    /// that is `*T` underneath. A free function of the type and the
    /// definitions, so that asking it costs a caller no copy of itself.
    func pointee(in definitions: [String: GoTypeDefinition]) -> GoType? {
        if case .pointer(let pointee) = self { return pointee }
        guard case .named = self else { return nil }
        var current = self
        var seen: Set<String> = []
        while case .named(let name) = current, seen.insert(name).inserted,
            let underlying = definitions[name]?.underlying
        {
            current = underlying
        }
        if case .pointer(let pointee) = current { return pointee }
        return nil
    }
}
