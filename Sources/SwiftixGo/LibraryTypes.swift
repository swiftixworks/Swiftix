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
/// In Go the type is defined over `int64`. Here it is over `int`, which is
/// 64 bits wide as well.
enum GoLibraryTypes {
    static let durationName = "time.Duration"
    static let duration = GoType.named(durationName)

    /// What the library type `name` is defined as, or nil when `name` is no
    /// library type with an underlying type. `time.Time` and `os.File` are
    /// opaque and have none.
    static func underlying(of name: String) -> GoType? {
        name == durationName ? .int : nil
    }

    /// The library type `package.member` names when it is one a value
    /// converts to, `time.Duration(n)`.
    static func convertible(package: String, member: String) -> GoType? {
        let name = package + "." + member
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
        default: return nil
        }
    }

    /// What a native method takes for its receiver from `base`, an
    /// expression of type `type`: the value itself, or what it points to
    /// when it is a pointer to a type that has the method. Following a nil
    /// pointer panics, as the call does in Go.
    static func receiver(_ base: GoExpression, of type: GoType) -> GoExpression {
        guard case .pointer = type, methodOwner(type) != nil else { return base }
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
        guard let owner = methodOwner(type), case .named(let name) = owner,
            let native = GoStandardLibrary.method(of: owner, named: member)
        else { return nil }
        return Method(native: native, symbol: name + "." + member, receiver: owner)
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
        var sameTypes = true
        for wanted in methods {
            guard let found = method(of: duration, named: wanted.name),
                found.parameters.count == wanted.parameters.count,
                found.results.count == wanted.results.count
            else { return [] }
            if found.parameters != wanted.parameters || found.results != wanted.results {
                sameTypes = false
            }
        }
        return sameTypes ? [] : [refusalMark + durationName]
    }

    /// Reserved call names of the natives this file declares.
    static let nativeCallNames: Set<String> = Set(
        durationMethods.map { "$time.Duration." + $0 } + ["$time.Until", "$time.ParseDuration"])

    /// The methods of `time.Duration` that take and give integers, strings,
    /// and durations. `Seconds`, `Minutes`, and `Hours` give a `float64` and
    /// are left for when the dialect has one: each is a name here, a row in
    /// `durationMethod`, and in the runtime an entry of
    /// `GoNative.timeArgumentCounts` and a case of `GoNative.duration`.
    static let durationMethods = [
        "String", "Nanoseconds", "Microseconds", "Milliseconds", "Round", "Truncate", "Abs",
    ]

    /// Native methods of `time.Duration`. The receiver is the first
    /// parameter. Go gives `Nanoseconds`, `Microseconds`, and `Milliseconds`
    /// as `int64`, which is `int` here.
    static func durationMethod(_ member: String) -> GoNativeFunction? {
        let parameters: [GoType]
        let result: GoType
        switch member {
        case "String": (parameters, result) = ([duration], .string)
        case "Nanoseconds", "Microseconds", "Milliseconds": (parameters, result) = ([duration], .int)
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
