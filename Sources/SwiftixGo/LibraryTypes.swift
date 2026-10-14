/// Named types of the run-time library that are defined over another type.
///
/// `time.Duration` is an integer with a name and methods, as a program's
/// `type Celsius int` is, and everything that asks what a named type is made
/// of is told the same for both: `GoPredeclared.underlying(of:)` answers for
/// it, so the checker's rules for a named integer type (untyped constants
/// adopt it, an `int` variable does not), the lowerer's zero values, and the
/// conversions are the ones a program type has. It differs in two things a
/// program type gets from its declarations. Its methods are native: a call is
/// the reserved call `$time.Duration.<method>`, which costs one instruction.
/// And it has a definition nowhere in the program, so the descriptor an
/// interface value carries says what it is defined as (`GoTypeEncoder`); the
/// VM then formats, compares, and asserts it like any defined type, and
/// finds its methods under the names a program's methods have, where the
/// runtime provides them (`GoLibraryMethods` in `SwiftixGoRuntime`). `fmt`
/// prints it by the text of its `String` without calling a function.
///
/// The type is defined over `int64`, as in Go.
enum GoLibraryTypes {
    static let durationName = "time.Duration"
    static let duration = GoType.named(durationName)

    /// What the library type `name` is defined as, or nil when `name` is no
    /// library type with an underlying type. `time.Time` and `os.File` are
    /// opaque and have none.
    static func underlying(of name: String) -> GoType? {
        name == durationName ? GoNumericKind.int64.type : GoLibraryStructs.underlying(of: name)
    }

    /// The library type `package.member` names when it is one a value
    /// converts to, `time.Duration(n)`.
    static func convertible(package: String, member: String) -> GoType? {
        let name = package + "." + member
        // A type behind a value of the library has no name to convert to.
        guard GoModuleLinker.isExported(member) else { return nil }
        return underlying(of: name) == nil ? nil : .named(name)
    }

    /// The library type whose methods a value of `type` has, when they are
    /// methods the VM provides as functions too: those are found where a
    /// method is looked up by name at run time, by `fmt`, by a call through
    /// an interface, and by a call through a method value. The type has
    /// them and so does a pointer to it, as in Go's method sets.
    static func methodOwner(_ type: GoType) -> GoType? {
        switch type {
        case duration, .pointer(duration): return duration
        default: return GoLibraryStructs.methodOwner(type)
        }
    }

    /// What a native method takes for its receiver from `base`, an
    /// expression of type `type`: the value itself, or what it points to
    /// when it is a pointer to a type that has the method. Following a nil
    /// pointer panics, as the call does in Go.
    static func receiver(_ base: GoExpression, of type: GoType) -> GoExpression {
        if let receiver = GoLibraryStructs.receiver(base, of: type) { return receiver }
        // A `*os.File` is itself what its methods take.
        guard case .pointer = type, let owner = methodOwner(type), owner != type else {
            return base
        }
        return .unary(operator: .dereference, operand: base, position: base.position)
    }

    /// A method of a library type that a function of the VM stands for.
    struct Method {
        /// The native function, whose first parameter is the receiver.
        let native: GoNativeFunction
        /// The name of the VM's function, as a method of a program type
        /// would be named: `time.Duration.String`.
        let symbol: String
        /// The type the method is declared on.
        let receiver: GoType

        /// What the method takes besides its receiver.
        var parameters: [GoType] { Array(native.parameters.dropFirst()) }
        var results: [GoType] { native.results }
    }

    /// The method `member` of a value of `type`, or nil when `type` is no
    /// library type whose methods the VM provides as functions.
    static func method(of type: GoType, named member: String) -> Method? {
        guard let owner = methodOwner(type),
            let native = GoStandardLibrary.method(of: owner, named: member)
        else { return nil }
        // `time.Duration.String`, and `*sync.RWMutex.Lock` for a method
        // that takes a pointer.
        return Method(
            native: native, symbol: owner.legacyDescription + "." + member, receiver: owner)
    }

    /// Mark of a line among the implementers of an interface target that
    /// names a library type which does not implement the interface. The
    /// VM reads it as `GoLibraryMethods.refusalMark`.
    static let refusalMark = "!"

    /// The lines an assertion to an interface with `methods` carries for
    /// the library types. The VM keeps no method types: it takes a library
    /// type to implement an interface when the type has a method of each
    /// name with as many parameters and results, which is right unless the
    /// types of one differ (`interface{ Abs() int }`). Only then is there a
    /// line, so an assertion that involves no such interface is compiled
    /// to what it always was.
    static func refusals(of methods: [GoInterfaceMethod]) -> [String] {
        var lines: [String] = []
        for (name, find) in dynamicTypes {
            var sameTypes = true
            var sameCounts = true
            for wanted in methods {
                guard let found = find(wanted.name),
                    found.parameters.count == wanted.parameters.count,
                    found.results.count == wanted.results.count
                else {
                    sameCounts = false
                    break
                }
                if found.parameters != wanted.parameters || found.results != wanted.results {
                    sameTypes = false
                }
            }
            if sameCounts, !sameTypes { lines.append(refusalMark + name) }
        }
        return lines
    }

    /// The types of the library a value in an interface can have, by the
    /// name the VM knows each by, with the methods of each: a duration, a
    /// file, and what a `net.Conn` and a `net.Listener` hold.
    private static let dynamicTypes: [(name: String, method: @Sendable (String) -> GoInterfaceMethod?)] = [
        (durationName, { libraryMethod(of: duration, named: $0) }),
        ("*os.File", { libraryMethod(of: GoPredeclared.filePointer, named: $0) }),
        (connectionTypeName, { handleMethod(of: connectionName, named: $0) }),
        (listenerTypeName, { handleMethod(of: listenerName, named: $0) }),
    ]

    private static func libraryMethod(of type: GoType, named name: String) -> GoInterfaceMethod? {
        interfaceMethod(of: type, named: name)
    }

    /// The method `name` a value of `type` has for an interface to ask
    /// for, when `type` is a type of the library whose methods are found
    /// by name at run time: a duration, and a `*os.File`. A method of a
    /// file that is selected and not called stays what it was, a function
    /// made for the purpose, so only what a file is assigned to asks here.
    static func interfaceMethod(of type: GoType, named name: String) -> GoInterfaceMethod? {
        if let library = method(of: type, named: name) {
            return GoInterfaceMethod(
                name: name, parameters: library.parameters, results: library.results)
        }
        guard type == GoPredeclared.filePointer, let native = GoStandardLibrary.fileMethod(name)
        else { return nil }
        return GoInterfaceMethod(
            name: name, parameters: Array(native.parameters.dropFirst()), results: native.results)
    }

    private static func handleMethod(of handle: String, named name: String) -> GoInterfaceMethod? {
        guard case .interface(let methods)? = handleInterface(of: handle) else { return nil }
        return methods.first { $0.name == name }
    }

    // MARK: Handles

    static let connectionName = "net.Conn"
    static let listenerName = "net.Listener"
    /// What a `net.Conn` and a `net.Listener` hold, as Go names the types
    /// and as the VM names the owners of their methods.
    static let connectionTypeName = "*net.TCPConn"
    static let listenerTypeName = "*net.TCPListener"

    /// The interface a handle type of the library is: `net.Conn` and
    /// `net.Listener` are interfaces in Go, and are here, with the methods
    /// the VM has for the one thing each can hold. So a handle has `nil` for
    /// its zero value, compares with `nil`, is asserted and switched on, is
    /// a value of every interface that asks for no more than its methods
    /// (`io.ReadWriteCloser`), and lends its methods to a struct that embeds
    /// it. A call the compiler sees stays the instruction it was.
    ///
    /// Go's interfaces have more methods (`LocalAddr`, `SetDeadline`), which
    /// the dialect lacks and no type of a program can declare, so nothing
    /// but the library's own value is one: see `isHandle`.
    static func handleInterface(of name: String) -> GoType? {
        let bytes = GoType.slice(GoPredeclared.byte)
        let failure = GoPredeclared.errorType
        switch name {
        case connectionName:
            return .interface([
                GoInterfaceMethod(name: "Close", results: [failure]),
                GoInterfaceMethod(name: "Read", parameters: [bytes], results: [.int, failure]),
                GoInterfaceMethod(name: "Write", parameters: [bytes], results: [.int, failure]),
            ])
        case listenerName:
            return .interface([
                GoInterfaceMethod(name: "Accept", results: [.named(connectionName), failure]),
                GoInterfaceMethod(name: "Close", results: [failure]),
            ])
        default:
            return nil
        }
    }

    /// Whether `type` is a handle type: an interface only the library has
    /// values of. Nothing but `nil` and a value of the type itself is
    /// assignable to it.
    static func isHandle(_ type: GoType) -> Bool {
        guard case .named(let name) = type else { return false }
        return handleInterface(of: name) != nil
    }

    /// The methods Go's interface of the name has, those the dialect lacks
    /// among them: what a type that is no `net.Conn` is said to lack or to
    /// have otherwise, as Go says it.
    static func goMethods(ofHandle name: String) -> [GoInterfaceMethod] {
        guard case .interface(let provided)? = handleInterface(of: name) else { return [] }
        let address = GoType.named("net.Addr")
        let failure = GoPredeclared.errorType
        switch name {
        case connectionName:
            return provided + [
                GoInterfaceMethod(name: "LocalAddr", results: [address]),
                GoInterfaceMethod(name: "RemoteAddr", results: [address]),
                GoInterfaceMethod(
                    name: "SetDeadline", parameters: [GoPredeclared.time], results: [failure]),
                GoInterfaceMethod(
                    name: "SetReadDeadline", parameters: [GoPredeclared.time], results: [failure]),
                GoInterfaceMethod(
                    name: "SetWriteDeadline", parameters: [GoPredeclared.time], results: [failure]),
            ]
        case listenerName:
            return provided + [GoInterfaceMethod(name: "Addr", results: [address])]
        default:
            return provided
        }
    }

    /// Those lines for every library type: the durations, then the struct
    /// types whose methods take a pointer.
    static func refusals(ofAll methods: [GoInterfaceMethod]) -> [String] {
        refusals(of: methods) + GoLibraryStructs.refusals(of: methods)
    }

    /// Reserved call names of the natives this file declares.
    static let nativeCallNames: Set<String> = Set(
        durationMethods.map { "$time.Duration." + $0 } + ["$time.Until", "$time.ParseDuration"]
    ).union(GoLibraryStructs.nativeCallNames)

    /// The methods of `time.Duration`. Each is a name here, a row in
    /// `durationMethod`, and in the runtime an entry of
    /// `GoNative.timeArgumentCounts` and a case of `GoNative.duration`.
    static let durationMethods = [
        "String", "Nanoseconds", "Microseconds", "Milliseconds", "Round", "Truncate", "Abs",
        "Seconds", "Minutes", "Hours",
    ]

    /// Native methods of `time.Duration`. The receiver is the first
    /// parameter. `Nanoseconds`, `Microseconds`, and `Milliseconds` give an
    /// `int64`, as in Go.
    static func durationMethod(_ member: String) -> GoNativeFunction? {
        let parameters: [GoType]
        let result: GoType
        switch member {
        case "String": (parameters, result) = ([duration], .string)
        case "Nanoseconds", "Microseconds", "Milliseconds":
            (parameters, result) = ([duration], GoNumericKind.int64.type)
        case "Seconds", "Minutes", "Hours":
            (parameters, result) = ([duration], GoPredeclared.float64)
        case "Round", "Truncate": (parameters, result) = ([duration, duration], duration)
        case "Abs": (parameters, result) = ([duration], duration)
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$time.Duration.\(member)", goName: "time.Duration.\(member)",
            parameters: parameters, results: [result])
    }

    /// The type of a constant the library declares: a duration for the
    /// units of `time`, an `int` for every other.
    static func constantType(package: String, member: String) -> GoType {
        package == "time" ? duration : .int
    }
}
