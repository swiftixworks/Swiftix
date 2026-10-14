/// What a Go program asks of its process besides files: the environment,
/// and who and where it is.
///
/// The environment is the one of the Swiftix process the program runs as,
/// never the host's. Go keeps a process's variables in the order they came:
/// those it started with, then each new one as it is set. A Swiftix process
/// has them as a dictionary, so the ones it started with are taken in the
/// order of their names, which is the same for every run, and the VM keeps
/// the order from there. A run without a process starts with none.
/// Pure values; no process or executor state.
struct GoEnvironment: Sendable {
    private var values: [String: String]
    /// The names in the order `os.Environ` lists them.
    private var order: [String]

    init(_ initial: [String: String]) {
        values = initial
        order = GoNative.sortedStrings(Array(initial.keys))
    }

    func value(of name: String) -> String? { values[name] }

    /// Go's `os.Setenv`: a variable that is there keeps its place.
    mutating func set(_ name: String, to value: String) {
        if values.updateValue(value, forKey: name) == nil { order.append(name) }
    }

    /// Go's `os.Unsetenv`. Whether the variable was there.
    mutating func unset(_ name: String) -> Bool {
        guard values.removeValue(forKey: name) != nil else { return false }
        order.removeAll { $0 == name }
        return true
    }

    /// Go's `os.Environ`: `name=value` for each variable.
    var entries: [String] {
        order.map { $0 + "=" + (values[$0] ?? "") }
    }
}

enum GoProcess {
    /// Reserved call names of the process natives, with the number of
    /// operands each one pops.
    static let argumentCounts: [String: Int] = [
        "$os.Getenv": 1,
        "$os.LookupEnv": 1,
        "$os.Setenv": 2,
        "$os.Unsetenv": 1,
        "$os.Environ": 0,
        "$os.Getpid": 0,
        "$os.Hostname": 0,
        "$os.Getwd": 0,
    ]

    /// What `os.Setenv` returns for a name or a value the system call
    /// refuses: an empty name, one with `=` or a NUL in it, a value with a
    /// NUL. Go's `EINVAL` under the name of the call.
    static let invalidVariable = "setenv: invalid argument"

    static func isSettable(name: String, value: String) -> Bool {
        !name.isEmpty && !name.utf8.contains(UInt8(ascii: "=")) && !name.utf8.contains(0)
            && !value.utf8.contains(0)
    }

    /// What a program that runs as no process is told it is.
    static let detachedProcessID: Int64 = 1
    static let detachedHostname = "localhost"
    static let detachedDirectory = "/"
}
