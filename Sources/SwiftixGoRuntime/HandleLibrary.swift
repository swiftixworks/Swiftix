/// The handle types of the run-time library as values of interfaces.
///
/// A `net.Conn`, a `net.Listener`, and a `*os.File` are what the VM made
/// them: a connection, a listener, and a number that names an open file. Go
/// lets each be a value of any interface its methods satisfy (`io.Reader`,
/// `io.Closer`, one of the program's own), and a call through such an
/// interface looks the method up by the name of the dynamic type. This file
/// gives each handle that name and its methods as functions of every
/// program, each one instruction or native call, as `GoLibraryMethods` does
/// for a duration. They are no part of an image. Constants and pure
/// functions; no process or executor state.
extension GoLibraryMethods {
    /// What a `net.Conn` and a `net.Listener` hold, as Go names the types.
    static let connectionTypeName = "*net.TCPConn"
    static let listenerTypeName = "*net.TCPListener"
    static let fileTypeName = "*os.File"

    /// The handle types that are interfaces only the library has values of,
    /// by the name of the interface, with the type of that value.
    static let handleInterfaces = [
        "net.Conn": connectionTypeName,
        "net.Listener": listenerTypeName,
    ]

    /// Named types of the library that have no definition anywhere: an
    /// interface value that holds one names it as a type known by name
    /// only, and so must what it is compared with.
    static let opaqueTypeNames: Set<String> = [
        "os.File", "time.Time", "sync.Mutex", "sync.WaitGroup", "testing.T", "time.Location",
    ]

    /// The type the methods of `value` are looked up under when it is a
    /// handle that travels without a type name: a connection or a listener.
    static func owner(ofHandle value: GoValue) -> String? {
        switch value {
        case .netConn: return connectionTypeName
        case .netListener: return listenerTypeName
        default: return nil
        }
    }

    /// The methods of the handles as functions, by the name a method of a
    /// program type would have: `*net.TCPConn.Read`, `*os.File.Write`.
    static let handleFunctions: [String: GoBytecodeFunction] = {
        var functions: [String: GoBytecodeFunction] = [:]
        func add(_ owner: String, _ method: String, operands: Int, results: Int, _ body: GoInstruction) {
            let name = owner + "." + method
            functions[name] = GoBytecodeFunction(
                name: name,
                parameterCount: operands,
                returnCount: results,
                localCount: operands,
                instructions: (0..<operands).map(GoInstruction.load)
                    + [body, .returnValues(count: results)])
        }
        add(connectionTypeName, "Read", operands: 2, results: 2, .netRead)
        add(connectionTypeName, "Write", operands: 2, results: 2, .netWrite)
        add(connectionTypeName, "Close", operands: 1, results: 1, .netClose)
        add(listenerTypeName, "Accept", operands: 1, results: 2, .netAccept)
        add(listenerTypeName, "Close", operands: 1, results: 1, .netClose)
        for (method, operands, results) in [
            ("Write", 2, 2), ("WriteString", 2, 2), ("Read", 2, 2), ("ReadAt", 3, 2),
            ("WriteAt", 3, 2), ("Seek", 3, 2), ("Close", 1, 1), ("Sync", 1, 1),
        ] {
            add(
                fileTypeName, method, operands: operands, results: results,
                .call("$os.File." + method, argumentCount: operands))
        }
        add(fileTypeName, "Name", operands: 1, results: 1, .call("$os.File.name", argumentCount: 1))
        // The methods that are Go text of `os` (`GoFileTextMethods`), when a
        // program is linked with them.
        add(fileTypeName, "Stat", operands: 1, results: 2, .call("os.fileMethodStat", argumentCount: 1))
        for (method, function) in [
            ("ReadDir", "os.fileMethodReadDir"), ("Readdir", "os.fileMethodReaddir"),
            ("Readdirnames", "os.fileMethodReaddirnames"),
        ] {
            add(fileTypeName, method, operands: 2, results: 2, .call(function, argumentCount: 2))
        }
        return functions
    }()

    /// Whether the dynamic type `owner` is one of the library's, whose
    /// methods are the functions here and in `functions`.
    static func isLibraryType(_ owner: String) -> Bool {
        owner == durationTypeName || owner == "*" + durationTypeName
            || owner == connectionTypeName || owner == listenerTypeName || owner == fileTypeName
            || GoCalendar.isOwner(owner) || owner == GoFormatState.typeName
    }
}
