/// The natives of `os` that read and change what a process has besides its
/// files, and `errors.Join`.
///
/// `os.Getenv`, `LookupEnv`, `Setenv`, `Unsetenv`, and `Environ` work on the
/// environment of the Swiftix process the program is, `os.Getpid`,
/// `Hostname`, and `Getwd` ask the process who and where it is, and none of
/// them reaches the host. Each is a reserved call the VM runs (`GoProcess` in
/// the runtime). `errors.Join` takes any number of errors, which the checker
/// checks as it checks the variadic parameter of a function of the program.
enum GoProcessLibrary {
    /// Native functions reached as `package.Member(...)`.
    static func nativeFunction(package: String, member: String) -> GoNativeFunction? {
        let failure = GoPredeclared.errorType
        func function(_ parameters: [GoType], _ results: [GoType]) -> GoNativeFunction {
            let name = package + "." + member
            return GoNativeFunction(
                symbol: "$" + name, goName: name, parameters: parameters, results: results)
        }
        switch (package, member) {
        case ("os", "Getenv"): return function([.string], [.string])
        case ("os", "LookupEnv"): return function([.string], [.string, .bool])
        case ("os", "Setenv"): return function([.string, .string], [failure])
        case ("os", "Unsetenv"): return function([.string], [failure])
        case ("os", "Environ"): return function([], [.slice(.string)])
        case ("os", "Getpid"): return function([], [.int])
        case ("os", "Hostname"), ("os", "Getwd"): return function([], [.string, failure])
        case ("errors", "Join"):
            var join = function([], [failure])
            join.isVariadic = true
            join.variadicElement = failure
            return join
        default: return nil
        }
    }

    /// Reserved call names of the natives this file declares.
    static let nativeCallNames: Set<String> = [
        "$os.Getenv", "$os.LookupEnv", "$os.Setenv", "$os.Unsetenv", "$os.Environ", "$os.Getpid",
        "$os.Hostname", "$os.Getwd", "$errors.Join",
    ]
}
