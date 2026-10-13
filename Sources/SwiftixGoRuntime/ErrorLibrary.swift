/// The error values of Go's `errors.New` and `fmt.Errorf`, as the VM holds them.
///
/// Go's are pointers to small structs: `*errors.errorString`, `*fmt.wrapError`
/// for one `%w`, and `*fmt.wrapErrors` for several. Here each is an interface
/// value of that type name around a pointer to such a struct in the managed
/// heap, so two errors are equal only when they are the same error, `%T` and
/// `%#v` print what Go prints, and `errors.Unwrap`, `Is`, and `As` have a
/// chain to follow.
///
/// A failed library call still yields the older form, an `error` around its
/// message, which compares by text; `io.EOF` relies on that.
/// Constants and pure functions; no process or executor state.

enum GoErrors {
    /// Reserved call names of the `errors` natives that walk a chain, with
    /// the number of operands each one pops.
    static let argumentCounts: [String: Int] = [
        "$errors.Unwrap": 1,
        "$errors.Is": 2,
        "$errors.As": 3,
    ]

    /// Type name of the older form of a library error.
    static let legacyTypeName = "error"

    static let plainType = "*errors.errorString"
    static let wrappingType = "*fmt.wrapError"
    static let joiningType = "*fmt.wrapErrors"

    /// The struct behind each error type, for `fmt`.
    static let definitions: [String: GoRuntimeType] = [
        "errors.errorString": .structure([.init(name: "s", type: .string)]),
        "fmt.wrapError": .structure([
            .init(name: "msg", type: .string), .init(name: "err", type: .error),
        ]),
        "fmt.wrapErrors": .structure([
            .init(name: "msg", type: .string), .init(name: "errs", type: .slice(.error)),
        ]),
    ]

    /// Whether `typeName` is one of the pointer types above.
    static func isLibraryType(_ typeName: String) -> Bool {
        typeName == plainType || typeName == wrappingType || typeName == joiningType
    }

    /// Prefix of the third operand of `$errors.As`, and of the target of a
    /// type assertion, when the target is an interface. See `InterfaceTarget`.
    static let interfaceTarget = "$I"

    /// Methods of the errors above, for a target that is an interface. Each
    /// takes no argument and returns one value.
    static func methods(ofLibraryType typeName: String) -> Set<String> {
        typeName == plainType || typeName == legacyTypeName ? ["Error"] : ["Error", "Unwrap"]
    }

    /// An interface a value is tested against at run time: the methods it
    /// asks for, each by its name and how many parameters and results it has,
    /// the interface's name for a message, and the types of the program that
    /// implement it. The VM keeps no method types, so the compiler, which
    /// does, lists those types; the methods serve the errors the library
    /// makes and the message that names a missing one.
    ///
    /// Written `$I<name>:<parameters>:<results>,...;<type name>`, with the
    /// methods in name order and an empty type name for a literal interface,
    /// followed by one line per implementing type, `T` or `*T`.
    struct InterfaceTarget: Equatable, Sendable {
        struct Method: Equatable, Sendable {
            let name: String
            let parameterCount: Int
            let resultCount: Int
        }

        let methods: [Method]
        let typeName: String
        let implementers: Set<String>

        init?(_ specification: String) {
            guard specification.hasPrefix(GoErrors.interfaceTarget) else { return nil }
            let lines = specification.dropFirst(GoErrors.interfaceTarget.utf8.count)
                .split(separator: "\n", omittingEmptySubsequences: false)
            implementers = Set(lines.dropFirst().map(String.init))
            let parts = (lines.first ?? "")
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            var methods: [Method] = []
            for entry in (parts.first ?? "").split(separator: ",") {
                let fields = entry.split(separator: ":")
                guard fields.count == 3, let parameters = Int(fields[1]),
                    let results = Int(fields[2])
                else { return nil }
                methods.append(
                    Method(
                        name: String(fields[0]), parameterCount: parameters, resultCount: results))
            }
            self.methods = methods
            typeName = parts.count > 1 ? String(parts[1]) : ""
        }
    }
}
