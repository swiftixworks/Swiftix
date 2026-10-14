/// The natives that `os/signal` and `syscall`'s signals are written on:
/// which signals the kernel hands to the program, the next one that
/// arrived, and sending one (see `GoSignals` in the runtime).
enum GoSignalNatives {
    static func textNative(package: String, name: String) -> GoNativeFunction? {
        let signature: (parameters: [GoType], results: [GoType])
        switch (package, name) {
        case ("signal", "enable"), ("signal", "ignore"), ("signal", "reset"): signature = ([.int], [])
        case ("signal", "wait"): signature = ([], [.int])
        case ("syscall", "kill"): signature = ([.int, .int], [])
        case ("syscall", "getpid"): signature = ([], [.int])
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$\(package).\(name)", goName: package + "." + name,
            parameters: signature.parameters, results: signature.results)
    }

    static let nativeCallNames = [
        "$signal.enable", "$signal.ignore", "$signal.reset", "$signal.wait", "$syscall.kill",
        "$syscall.getpid",
    ]
}
