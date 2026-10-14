/// Struct types of the run-time library whose methods the VM runs.
///
/// `sync.RWMutex`, `sync.Cond`, `time.Timer`, and `time.Ticker` are structs
/// in Go, and here: each has the fields Go gives it, so a variable, a field,
/// an element of `make([]shard, n)`, and `sync.RWMutex{}` are zeroed, copied,
/// compared, and printed by what every struct is zeroed, copied, compared,
/// and printed by, and `t.C` is a field like any other. What the VM adds is
/// behind the methods. Each is a reserved native call, `$sync.RWMutex.RLock`,
/// that takes a pointer to the struct, as the method does in Go: the lock is
/// where the variable is, and two shards have two.
///
/// `GoLibraryTypes` asks here what such a type is defined as and which
/// methods it has, and from there on the checker and the lowerer treat one
/// like `time.Duration`: a library type with a definition, whose methods are
/// natives the compiler calls by name and functions the VM provides under
/// the names a program's methods have (`*sync.RWMutex.RLock`), for a call
/// through an interface and for a method value.
///
/// `sync.Mutex` is older and stays what it was, a handle the VM keeps the
/// lock behind: its `Lock` and `Unlock` are instructions. `TryLock` and its
/// being a `sync.Locker` are declared here.
enum GoLibraryStructs {
    static let rwMutexName = "sync.RWMutex"
    static let mutexName = "sync.Mutex"
    static let lockerName = "sync.Locker"
    static let timerName = "time.Timer"
    static let tickerName = "time.Ticker"
    static let condName = "sync.Cond"
    /// The type behind `(*sync.RWMutex).RLocker`, which no program names.
    static let readLockerName = "sync.rlocker"
    /// The types of the errors that wrap others, which no program names
    /// either: they differ in what `Unwrap` gives, one error or several.
    static let wrappingErrorName = "fmt.wrapError"
    static let joiningErrorName = "fmt.wrapErrors"
    static let joinedErrorName = "errors.joinError"

    static let locker = GoType.named(lockerName)
    static let mutex = GoType.named(mutexName)

    /// Reserved call of `(*sync.RWMutex).RLocker`: the compiler adds the
    /// descriptor of `*sync.rlocker` as a second operand, which the VM
    /// boxes the pointer with.
    static let readLocker = "$sync.RWMutex.RLocker"

    /// The types a program names that this file declares.
    static func isTypeName(_ name: String) -> Bool {
        switch name {
        case rwMutexName, lockerName, timerName, tickerName, condName: return true
        default: return false
        }
    }

    /// The struct types among them: those whose fields belong to the
    /// library, exported or not.
    static func isStruct(_ name: String) -> Bool {
        name != lockerName && (isTypeName(name) || name == readLockerName)
    }

    private static func field(_ name: String, _ type: GoType) -> GoStructFieldType {
        GoStructFieldType(name: name, type: type)
    }

    /// Go's `atomic.Int32`: a struct that may not be copied around a number.
    private static let atomicInt32 = GoType.structure([
        field("_", .structure([])), field("v", GoNumericKind.int32.type),
    ])

    /// What the type `name` is defined as, with the fields Go has, or nil
    /// when `name` is no type of this file.
    static func underlying(of name: String) -> GoType? {
        let uint32 = GoNumericKind.uint32.type
        let ticks = GoType.channel(direction: .receiveOnly, element: GoPredeclared.time)
        switch name {
        case lockerName:
            return .interface([GoInterfaceMethod(name: "Lock"), GoInterfaceMethod(name: "Unlock")])
        case rwMutexName, readLockerName:
            // `w` is Go's `sync.Mutex`, itself a struct there.
            let state = GoType.structure([
                field("state", GoNumericKind.int32.type), field("sema", uint32),
            ])
            return .structure([
                field("w", .structure([field("_", .structure([])), field("mu", state)])),
                field("writerSem", uint32), field("readerSem", uint32),
                field("readerCount", atomicInt32), field("readerWait", atomicInt32),
            ])
        case timerName: return .structure([field("C", ticks), field("initTimer", .bool)])
        case tickerName: return .structure([field("C", ticks), field("initTicker", .bool)])
        case condName:
            // Go's list of waiters has more, and a check against copying
            // follows it; the VM keeps who waits by where the struct is.
            return .structure([
                field("noCopy", .structure([])), field("L", locker),
                field("notify", .structure([field("wait", uint32), field("notify", uint32)])),
            ])
        default: return nil
        }
    }

    /// The type whose methods a value of `type` has, when they are natives
    /// of this file: the pointer for a struct and a pointer to it, since
    /// every method takes one, and `sync.Mutex` itself for a mutex and a
    /// pointer to one, whose handle `TryLock` takes.
    static func methodOwner(_ type: GoType) -> GoType? {
        var base = type
        if case .pointer(let pointee) = type { base = pointee }
        guard case .named(let name) = base else { return nil }
        if name == mutexName { return mutex }
        return isStruct(name) && name != readLockerName ? .pointer(base) : nil
    }

    /// What the method `member` of the struct type `name` takes besides its
    /// receiver, and what it gives.
    static func signature(
        of member: String, in name: String
    ) -> (parameters: [GoType], results: [GoType])? {
        let duration = GoLibraryTypes.duration
        switch (name, member) {
        case (rwMutexName, "Lock"), (rwMutexName, "Unlock"), (rwMutexName, "RLock"),
            (rwMutexName, "RUnlock"):
            return ([], [])
        case (rwMutexName, "TryLock"), (rwMutexName, "TryRLock"): return ([], [.bool])
        case (rwMutexName, "RLocker"): return ([], [locker])
        case (timerName, "Stop"): return ([], [.bool])
        case (timerName, "Reset"): return ([duration], [.bool])
        case (tickerName, "Stop"): return ([], [])
        case (tickerName, "Reset"): return ([duration], [])
        case (condName, "Wait"), (condName, "Signal"), (condName, "Broadcast"): return ([], [])
        default: return nil
        }
    }

    /// The names of the methods of each type, for what asks which a type
    /// has without naming one: embedding, and an interface a value is
    /// asserted to.
    static func methodNames(of name: String) -> [String] {
        switch name {
        case rwMutexName:
            return ["Lock", "Unlock", "RLock", "RUnlock", "TryLock", "TryRLock", "RLocker"]
        case timerName, tickerName: return ["Stop", "Reset"]
        case condName: return ["Wait", "Signal", "Broadcast"]
        default: return []
        }
    }

    /// Gives `shape` what a struct that embeds the type `name` is lent:
    /// the fields and the methods of a struct of this file, all of which
    /// take a pointer, or the methods of `sync.Locker`. Whether `name` is
    /// such a type.
    static func lend(_ name: String, to shape: inout GoEmbeddedShape) -> Bool {
        guard isTypeName(name) else { return false }
        switch underlying(of: name) {
        case .structure(let fields)?:
            shape.fields = fields.map(GoEmbeddedShape.Field.init)
            for method in methodNames(of: name) { shape.methods[method] = true }
        case .interface(let methods)?:
            shape.kind = .interface
            for method in methods { shape.methods[method.name] = false }
        default:
            return false
        }
        return true
    }

    /// The native method `member` of `receiver`, which is what
    /// `methodOwner` gives: its first parameter.
    static func method(of receiver: GoType, named member: String) -> GoNativeFunction? {
        if receiver == mutex {
            guard member == "TryLock" else { return nil }
            return GoNativeFunction(
                symbol: "$sync.Mutex.TryLock", goName: "sync.Mutex.TryLock",
                parameters: [mutex], results: [.bool])
        }
        guard case .pointer(.named(let name)) = receiver,
            let signature = signature(of: member, in: name)
        else { return nil }
        return GoNativeFunction(
            symbol: "$\(name).\(member)", goName: "\(name).\(member)",
            parameters: [receiver] + signature.parameters, results: signature.results)
    }

    /// What a native method takes for its receiver from `base`, an
    /// expression of type `type`, or nil when `type` has no method of this
    /// file: the pointer, which is the value's address when `base` is the
    /// struct itself, and for a mutex the handle a pointer points to.
    static func receiver(_ base: GoExpression, of type: GoType) -> GoExpression? {
        guard let owner = methodOwner(type) else { return nil }
        if owner == type { return base }
        let isPointer: Bool
        if case .pointer = type { isPointer = true } else { isPointer = false }
        return .unary(
            operator: isPointer ? .dereference : .address, operand: base, position: base.position)
    }

    /// Whether the method set of `type` has `method` exactly, for the types
    /// whose methods take a pointer; nil for every other type. A pointer
    /// has them and the value has none, as in Go, so `&mu` is a
    /// `sync.Locker` and `mu` is not.
    static func lends(_ type: GoType, _ method: GoInterfaceMethod) -> Bool? {
        var base = type
        var isPointer = false
        if case .pointer(let pointee) = type { (base, isPointer) = (pointee, true) }
        guard case .named(let name) = base, name == mutexName || isStruct(name) else { return nil }
        guard isPointer, let found = interfaceMethod(method.name, of: name) else { return false }
        return found.parameters == method.parameters && found.results == method.results
    }

    /// The method `member` of a pointer to the type `name`, as an interface
    /// asks for it.
    static func interfaceMethod(
        _ member: String, of name: String
    ) -> (parameters: [GoType], results: [GoType])? {
        switch (name, member) {
        case (mutexName, "Lock"), (mutexName, "Unlock"): return ([], [])
        case (mutexName, "TryLock"): return ([], [.bool])
        case (readLockerName, "Lock"), (readLockerName, "Unlock"): return ([], [])
        // The errors the library makes: `fmt.Errorf` with one `%w`, with
        // several, and `errors.Join`.
        case (wrappingErrorName, "Error"), (joiningErrorName, "Error"), (joinedErrorName, "Error"):
            return ([], [.string])
        case (wrappingErrorName, "Unwrap"): return ([], [GoPredeclared.errorType])
        case (joiningErrorName, "Unwrap"), (joinedErrorName, "Unwrap"):
            return ([], [.slice(GoPredeclared.errorType)])
        default: return signature(of: member, in: name)
        }
    }

    /// The pointer types a value in an interface may have that the VM finds
    /// methods for by name, with the names of the methods of each.
    static let interfaceOwners: [(name: String, methods: [String])] = [
        (mutexName, ["Lock", "Unlock", "TryLock"]),
        (readLockerName, ["Lock", "Unlock"]),
        (rwMutexName, methodNames(of: rwMutexName)),
        (timerName, methodNames(of: timerName)),
        (tickerName, methodNames(of: tickerName)),
        (condName, methodNames(of: condName)),
        (wrappingErrorName, ["Error", "Unwrap"]),
        (joiningErrorName, ["Error", "Unwrap"]),
        (joinedErrorName, ["Error", "Unwrap"]),
    ]

    /// The lines an assertion to an interface with `methods` carries for
    /// these types: `!*T` for each whose methods have the names and the
    /// numbers of parameters and results the interface asks for, which is
    /// all the VM compares, and other types. See `GoLibraryTypes.refusals`.
    static func refusals(of methods: [GoInterfaceMethod]) -> [String] {
        var refused: [String] = []
        for owner in interfaceOwners {
            var sameTypes = true
            var hasAll = true
            for wanted in methods {
                guard let found = interfaceMethod(wanted.name, of: owner.name),
                    found.parameters.count == wanted.parameters.count,
                    found.results.count == wanted.results.count
                else {
                    hasAll = false
                    break
                }
                if found.parameters != wanted.parameters || found.results != wanted.results {
                    sameTypes = false
                }
            }
            if hasAll, !sameTypes { refused.append(GoLibraryTypes.refusalMark + "*" + owner.name) }
        }
        return refused
    }

    /// The functions that make a value of these types, reached as
    /// `package.Member(...)`.
    static func nativeFunction(package: String, member: String) -> GoNativeFunction? {
        let duration = GoLibraryTypes.duration
        let timer = GoType.pointer(.named(timerName))
        let signature: (parameters: [GoType], result: GoType)
        switch (package, member) {
        case ("sync", "NewCond"): signature = ([locker], .pointer(.named(condName)))
        case ("time", "NewTimer"): signature = ([duration], timer)
        case ("time", "NewTicker"): signature = ([duration], .pointer(.named(tickerName)))
        case ("time", "AfterFunc"):
            signature = ([duration, .function(parameters: [], results: [])], timer)
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$\(package).\(member)", goName: "\(package).\(member)",
            parameters: signature.parameters, results: [signature.result])
    }

    /// Reserved call names of the natives this file declares.
    static let nativeCallNames: Set<String> = {
        var names: Set<String> = [
            "$sync.Mutex.TryLock", "$sync.NewCond", "$time.NewTimer", "$time.NewTicker",
            "$time.AfterFunc",
        ]
        for name in [rwMutexName, timerName, tickerName, condName] {
            for member in methodNames(of: name) { names.insert("$\(name).\(member)") }
        }
        return names
    }()
}
