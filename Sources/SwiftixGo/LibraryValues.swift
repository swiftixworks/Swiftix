/// Functions of the run-time library as values.
///
/// `f := strings.ToUpper` and `done := wg.Done` are function values in Go.
/// The VM runs a library function as an instruction or a native call, which
/// is nothing a value can name, so the value names a function the compiler
/// synthesizes around the call: its parameters are the library function's,
/// a bound receiver first, and its body is the call, lowered the way a call
/// the program wrote is. What is needed here is what each function takes
/// and gives, as Go declares it. A native function carries that; the calls
/// the checker types by hand are listed.

import SwiftixGoRuntime

/// What a function of the run-time library takes and gives. The receiver of
/// a method is the value its function value holds.
struct GoLibrarySignature: Equatable {
    var receiver: GoType?
    let parameters: [GoType]
    let results: [GoType]

    /// The type of the function as a value.
    var type: GoType { .function(parameters: parameters, results: results) }
}

enum GoLibraryValue {
    /// The marker type of a `...any` parameter.
    private static let operands = GoType.array(
        length: GoSpread.variadicLength, element: .interface([]))

    /// The signature of `package.member`, a function of the run-time
    /// library named by its package's own name, or nil when the package has
    /// no such function or it cannot be a value.
    ///
    /// Three kinds cannot. `errors.As` is compiled with the static type of
    /// its target, which a function that takes any target does not have.
    /// The functions of `net/http` name their handler in the instruction.
    /// And a reserved member, which only the library's own Go code calls,
    /// is no function of Go's.
    static func function(package: String, member: String) -> GoLibrarySignature? {
        guard !member.hasPrefix("$") else { return nil }
        if let native = GoStandardLibrary.nativeFunction(package: package, member: member) {
            guard native.symbol != GoPredeclared.errorsAs else { return nil }
            let variadic = native.variadicElement.map {
                GoType.array(length: GoSpread.variadicLength, element: $0)
            }
            return GoLibrarySignature(
                parameters: native.parameters + (native.isVariadic ? [variadic ?? operands] : []),
                results: native.results)
        }
        guard let builtin = GoStandardLibrary.resolve(package: package, member: member) else {
            return nil
        }
        let failure = GoPredeclared.errorType
        let ticks = GoType.channel(direction: .receiveOnly, element: GoPredeclared.time)
        let signature: (parameters: [GoType], results: [GoType])
        switch builtin {
        case .fmtPrint, .fmtPrintln: signature = ([operands], [.int, failure])
        case .timeAfter, .timeTick: signature = ([GoLibraryTypes.duration], [ticks])
        case .timeSleep: signature = ([GoLibraryTypes.duration], [])
        case .netDial: signature = ([.string, .string], [.named("net.Conn"), failure])
        case .netListen: signature = ([.string, .string], [.named("net.Listener"), failure])
        case .netLookupHost: signature = ([.string], [.slice(.string), failure])
        case .httpHandleFunc, .httpListenAndServe, .httpGet: return nil
        case .runtimeGC: signature = ([], [])
        case .osExit: signature = ([.int], [])
        case .strconvAtoi: signature = ([.string], [.int, failure])
        case .userlandReadInput: signature = ([.string, .slice(.string)], [.string, .int])
        case .userlandReadStdin: signature = ([], [.string, .int])
        case .userlandWriteFile: signature = ([.string, .string], [.int])
        case .userlandSetRawMode: signature = ([.bool], [.bool])
        case .userlandWindowSize: signature = ([], [.int, .int])
        case .strings(let function):
            signature = (function.signature.parameters, [function.signature.result])
        }
        return GoLibrarySignature(parameters: signature.parameters, results: signature.results)
    }

    /// The signature of the method `member` of a value of the library type
    /// `type`, or of a pointer to one, with the receiver its function value
    /// holds: the file or the instant itself, and for the types the VM keeps
    /// behind a handle, the handle.
    static func method(of type: GoType, named member: String) -> GoLibrarySignature? {
        if let native = GoStandardLibrary.method(of: type, named: member) {
            return GoLibrarySignature(
                receiver: type, parameters: Array(native.parameters.dropFirst()),
                results: native.results)
        }
        let owner: String
        switch type {
        case .named(let name), .pointer(.named(let name)): owner = name
        default: return nil
        }
        let failure = GoPredeclared.errorType
        let signature: (parameters: [GoType], results: [GoType])
        switch (owner, member) {
        case ("sync.Mutex", "Lock"), ("sync.Mutex", "Unlock"),
            ("sync.WaitGroup", "Done"), ("sync.WaitGroup", "Wait"):
            signature = ([], [])
        case ("sync.WaitGroup", "Add"): signature = ([.int], [])
        case ("context.Context", "Done"):
            signature = ([], [.channel(direction: .receiveOnly, element: .int)])
        case ("context.Context", "Err"): signature = ([], [failure])
        case ("net.Conn", "Read"), ("net.Conn", "Write"):
            signature = ([.slice(GoPredeclared.byte)], [.int, failure])
        case ("net.Conn", "Close"), ("net.Listener", "Close"): signature = ([], [failure])
        case ("net.Listener", "Accept"): signature = ([], [.named("net.Conn"), failure])
        default: return nil
        }
        return GoLibrarySignature(
            receiver: .named(owner), parameters: signature.parameters, results: signature.results)
    }
}
