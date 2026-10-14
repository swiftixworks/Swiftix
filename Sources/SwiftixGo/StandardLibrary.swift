/// Compile-time catalogue of the Swiftix Go standard-library surface.

import SwiftixGoRuntime

enum GoBuiltinFunction: Sendable, Equatable {
    case fmtPrint
    case fmtPrintln
    case timeAfter
    case timeSleep
    case timeTick
    case netDial
    case netListen
    case netLookupHost
    case httpHandleFunc
    case httpListenAndServe
    case httpGet
    case runtimeGC
    case osExit
    case strconvAtoi
    case userlandReadInput
    case userlandReadStdin
    case userlandWriteFile
    case userlandSetRawMode
    case userlandWindowSize
    case strings(GoStringsFunction)
}

enum GoStandardLibrary {
    static let supportedPackages = [
        "fmt", "testing", "time", "sync", "runtime",
        "context", "errors", "io", "net", "net/http", "os", "sort", "strconv", "strings",
        "swiftix/userland",
        "math", "unicode", "unicode/utf8",
        "net/url",
        "log", "sync/atomic",
        "bufio", "bytes",
        "io/fs", "syscall",
        "encoding", "encoding/base64", "encoding/json",
        "flag", "os/signal", "path", "path/filepath", "math/rand",
        "container/list", "container/heap", "container/ring",
        "math/bits", "hash", "hash/crc32", "hash/fnv", "encoding/binary",
        "mime", "net/http/httputil", "crypto/tls",
    ]

    static func resolve(package: String, member: String) -> GoBuiltinFunction? {
        switch (package, member) {
        case ("fmt", "Print"): return .fmtPrint
        case ("fmt", "Println"): return .fmtPrintln
        case ("os", "Exit"): return .osExit
        case ("strconv", "Atoi"): return .strconvAtoi
        case ("userland", "ReadInput"): return .userlandReadInput
        case ("userland", "ReadStdin"): return .userlandReadStdin
        case ("userland", "WriteFile"): return .userlandWriteFile
        case ("userland", "SetRawMode"): return .userlandSetRawMode
        case ("userland", "WindowSize"): return .userlandWindowSize
        case ("time", "After"): return .timeAfter
        case ("time", "Sleep"): return .timeSleep
        case ("time", "Tick"): return .timeTick
        case ("net", "Dial"): return .netDial
        case ("net", "Listen"): return .netListen
        case ("net", "LookupHost"): return .netLookupHost
        case ("net/http", "HandleFunc"): return .httpHandleFunc
        case ("net/http", "ListenAndServe"): return .httpListenAndServe
        case ("net/http", "Get"): return .httpGet
        case ("http", "HandleFunc"): return .httpHandleFunc
        case ("http", "ListenAndServe"): return .httpListenAndServe
        case ("http", "Get"): return .httpGet
        case ("runtime", "GC"): return .runtimeGC
        case ("strings", let name):
            return GoStringsFunction(goName: name).map { .strings($0) }
        default: return nil
        }
    }

    static func integerConstant(package: String, member: String) -> Int64? {
        switch (package, member) {
        case ("time", "Nanosecond"): return 1
        case ("time", "Microsecond"): return 1_000
        case ("time", "Millisecond"): return 1_000_000
        case ("time", "Second"): return 1_000_000_000
        case ("time", "Minute"): return 60_000_000_000
        case ("time", "Hour"): return 3_600_000_000_000
        // Linux values, as Go uses on linux. The VM decodes the same numbers
        // in `GoFiles`.
        case ("os", "O_RDONLY"): return 0
        case ("os", "O_WRONLY"): return 1
        case ("os", "O_RDWR"): return 2
        case ("os", "O_CREATE"): return 0o100
        case ("os", "O_EXCL"): return 0o200
        case ("os", "O_TRUNC"): return 0o1000
        case ("os", "O_APPEND"): return 0o2000
        case ("io", "SeekStart"): return 0
        case ("io", "SeekCurrent"): return 1
        case ("io", "SeekEnd"): return 2
        default: return nil
        }
    }

    /// The message of a package-level `error` value such as `io.EOF`. Such a
    /// value is a native error with that message, so it compares equal to the
    /// error a library call returns for the same condition.
    static func errorValue(package: String, member: String) -> String? {
        switch (package, member) {
        case ("io", "EOF"): return "EOF"
        default: return nil
        }
    }
}

/// A library function the VM executes natively through a reserved call name.
///
/// Calls lower to `call(symbol, argumentCount:)`: the arguments are pushed in
/// order (the `*os.File` receiver first for file methods) and the results are
/// pushed in order. No image-format change is involved.
struct GoNativeFunction: Sendable, Equatable {
    /// Reserved VM call name, such as `$sort.Strings`.
    let symbol: String
    /// Go spelling used in diagnostics, such as `sort.Strings`.
    let goName: String
    let parameters: [GoType]
    /// Accepts any number of further arguments of any type (`...any`).
    var isVariadic = false
    var results: [GoType] = []
    /// Call name used when the call is a statement, a `go`, or a `defer`,
    /// whose results nobody reads. The VM then pushes none, which keeps a
    /// statement's bytecode what it was before the results existed.
    var statementSymbol: String?
    /// The variadic arguments are `fmt` operands, which are boxed with their
    /// type when the VM could not tell it from the value.
    var formatsOperands = false
    /// The type of each further argument when the function says one:
    /// `errors.Join(errs ...error)`. Nil for `...any`.
    var variadicElement: GoType? = nil
}

extension GoStandardLibrary {
    /// Native functions reached as `package.Member(...)`.
    static func nativeFunction(package: String, member: String) -> GoNativeFunction? {
        // A reserved call of the library's own Go text.
        if member.hasPrefix("$") { return GoSourceLibrary.native(package: package, member: member) }
        let file = GoPredeclared.filePointer
        let bytes = GoType.slice(GoPredeclared.byte)
        let failure = GoPredeclared.errorType
        switch (package, member) {
        case ("sort", "Strings"):
            return GoNativeFunction(
                symbol: "$sort.Strings", goName: "sort.Strings", parameters: [.slice(.string)])
        case ("sort", "Ints"):
            return GoNativeFunction(
                symbol: "$sort.Ints", goName: "sort.Ints", parameters: [.slice(.int)])
        case ("strconv", "Itoa"):
            return GoNativeFunction(
                symbol: "$strconv.Itoa", goName: "strconv.Itoa", parameters: [.int],
                results: [.string])
        case ("errors", "New"):
            return GoNativeFunction(
                symbol: "$errors.New", goName: "errors.New", parameters: [.string],
                results: [failure])
        case ("errors", "Unwrap"):
            return GoNativeFunction(
                symbol: "$errors.Unwrap", goName: "errors.Unwrap", parameters: [failure],
                results: [failure])
        case ("errors", "Is"):
            return GoNativeFunction(
                symbol: "$errors.Is", goName: "errors.Is", parameters: [failure, failure],
                results: [.bool])
        case ("errors", "As"):
            return GoNativeFunction(
                symbol: GoPredeclared.errorsAs, goName: "errors.As",
                parameters: [failure, .interface([])], results: [.bool])
        case ("strings", "ToUpper"), ("strings", "ToLower"):
            return GoNativeFunction(
                symbol: "$strings.\(member)", goName: "strings.\(member)",
                parameters: [.string], results: [.string])
        case ("strings", "Fields"):
            return GoNativeFunction(
                symbol: "$strings.Fields", goName: "strings.Fields",
                parameters: [.string], results: [.slice(.string)])
        case ("strings", "TrimPrefix"), ("strings", "TrimSuffix"):
            return GoNativeFunction(
                symbol: "$strings.\(member)", goName: "strings.\(member)",
                parameters: [.string, .string], results: [.string])
        case ("fmt", "Fprint"), ("fmt", "Fprintln"):
            return GoNativeFunction(
                symbol: "$fmt.\(member).n", goName: "fmt.\(member)", parameters: [file],
                isVariadic: true, results: [.int, failure],
                statementSymbol: "$fmt.\(member)", formatsOperands: true)
        case ("fmt", "Sprintf"):
            return GoNativeFunction(
                symbol: "$fmt.Sprintf", goName: "fmt.Sprintf", parameters: [.string],
                isVariadic: true, results: [.string], formatsOperands: true)
        case ("fmt", "Sprint"), ("fmt", "Sprintln"):
            return GoNativeFunction(
                symbol: "$fmt.\(member)", goName: "fmt.\(member)", parameters: [],
                isVariadic: true, results: [.string], formatsOperands: true)
        case ("fmt", "Errorf"):
            return GoNativeFunction(
                symbol: "$fmt.Errorf", goName: "fmt.Errorf", parameters: [.string],
                isVariadic: true, results: [failure], formatsOperands: true)
        case ("fmt", "Printf"):
            return GoNativeFunction(
                symbol: "$fmt.Printf.n", goName: "fmt.Printf", parameters: [.string],
                isVariadic: true, results: [.int, failure],
                statementSymbol: "$fmt.Printf", formatsOperands: true)
        case ("fmt", "Fprintf"):
            return GoNativeFunction(
                symbol: "$fmt.Fprintf.n", goName: "fmt.Fprintf", parameters: [file, .string],
                isVariadic: true, results: [.int, failure],
                statementSymbol: "$fmt.Fprintf", formatsOperands: true)
        case ("os", "ReadFile"):
            return GoNativeFunction(
                symbol: "$os.ReadFile", goName: "os.ReadFile", parameters: [.string],
                results: [bytes, failure])
        case ("os", "WriteFile"):
            return GoNativeFunction(
                symbol: "$os.WriteFile", goName: "os.WriteFile",
                parameters: [.string, bytes, .int], results: [failure])
        case ("os", "Open"):
            return GoNativeFunction(
                symbol: "$os.Open", goName: "os.Open", parameters: [.string],
                results: [file, failure])
        case ("os", "Create"):
            return GoNativeFunction(
                symbol: "$os.Create", goName: "os.Create", parameters: [.string],
                results: [file, failure])
        case ("os", "OpenFile"):
            return GoNativeFunction(
                symbol: "$os.OpenFile", goName: "os.OpenFile",
                parameters: [.string, .int, .int], results: [file, failure])
        case ("os", "Remove"):
            return GoNativeFunction(
                symbol: "$os.Remove", goName: "os.Remove", parameters: [.string],
                results: [failure])
        case ("os", "Rename"):
            return GoNativeFunction(
                symbol: "$os.Rename", goName: "os.Rename", parameters: [.string, .string],
                results: [failure])
        case ("os", "Mkdir"):
            return GoNativeFunction(
                symbol: "$os.Mkdir", goName: "os.Mkdir", parameters: [.string, .int],
                results: [failure])
        case ("time", "Now"):
            return GoNativeFunction(
                symbol: "$time.Now", goName: "time.Now", parameters: [],
                results: [GoPredeclared.time])
        case ("time", "Since"):
            return GoNativeFunction(
                symbol: "$time.Since", goName: "time.Since", parameters: [GoPredeclared.time],
                results: [GoLibraryTypes.duration])
        case ("time", "Until"):
            return GoNativeFunction(
                symbol: "$time.Until", goName: "time.Until", parameters: [GoPredeclared.time],
                results: [GoLibraryTypes.duration])
        case ("time", "ParseDuration"):
            return GoNativeFunction(
                symbol: "$time.ParseDuration", goName: "time.ParseDuration",
                parameters: [.string], results: [GoLibraryTypes.duration, failure])
        case ("time", "Unix"):
            return GoNativeFunction(
                symbol: "$time.Unix", goName: "time.Unix",
                parameters: [GoNumericKind.int64.type, GoNumericKind.int64.type],
                results: [GoPredeclared.time])
        default:
            return GoNumberLibrary.nativeFunction(package: package, member: member)
                ?? GoLibraryStructs.nativeFunction(package: package, member: member)
                ?? GoProcessLibrary.nativeFunction(package: package, member: member)
                ?? GoTimeLibrary.nativeFunction(package: package, member: member)
        }
    }

    /// Native methods of the library types `*os.File`, `time.Time`, and
    /// `time.Duration`. The receiver is the first parameter.
    static func method(of receiver: GoType, named member: String) -> GoNativeFunction? {
        if receiver == GoPredeclared.filePointer { return fileMethod(member) }
        if receiver == GoPredeclared.time { return timeMethod(member) }
        if receiver == GoLibraryTypes.duration { return GoLibraryTypes.durationMethod(member) }
        if let method = GoTimeLibrary.method(of: receiver, named: member) { return method }
        return GoLibraryStructs.method(of: receiver, named: member)
    }

    /// Native methods of `time.Time`.
    static func timeMethod(_ member: String) -> GoNativeFunction? {
        let time = GoPredeclared.time
        let duration = GoLibraryTypes.duration
        let parameters: [GoType]
        let result: GoType
        switch member {
        case "Unix", "UnixMilli", "UnixNano":
            (parameters, result) = ([time], GoNumericKind.int64.type)
        case "Sub": (parameters, result) = ([time, time], duration)
        case "Add": (parameters, result) = ([time, duration], time)
        case "Before", "After", "Equal": (parameters, result) = ([time, time], .bool)
        default: return GoTimeLibrary.timeMethod(member)
        }
        return GoNativeFunction(
            symbol: "$time.Time.\(member)", goName: "time.Time.\(member)",
            parameters: parameters, results: [result])
    }

    /// Native methods of `*os.File`. The receiver is the first parameter.
    static func fileMethod(_ member: String) -> GoNativeFunction? {
        let file = GoPredeclared.filePointer
        let bytes = GoType.slice(GoPredeclared.byte)
        let results = [GoType.int, GoPredeclared.errorType]
        switch member {
        case "Write":
            return GoNativeFunction(
                symbol: "$os.File.Write", goName: "os.File.Write",
                parameters: [file, bytes], results: results)
        case "WriteString":
            return GoNativeFunction(
                symbol: "$os.File.WriteString", goName: "os.File.WriteString",
                parameters: [file, .string], results: results)
        case "Read":
            return GoNativeFunction(
                symbol: "$os.File.Read", goName: "os.File.Read",
                parameters: [file, bytes], results: results)
        // Offsets are int64, as in Go.
        case "ReadAt":
            return GoNativeFunction(
                symbol: "$os.File.ReadAt", goName: "os.File.ReadAt",
                parameters: [file, bytes, GoNumericKind.int64.type], results: results)
        case "WriteAt":
            return GoNativeFunction(
                symbol: "$os.File.WriteAt", goName: "os.File.WriteAt",
                parameters: [file, bytes, GoNumericKind.int64.type], results: results)
        case "Seek":
            return GoNativeFunction(
                symbol: "$os.File.Seek", goName: "os.File.Seek",
                parameters: [file, GoNumericKind.int64.type, .int],
                results: [GoNumericKind.int64.type, GoPredeclared.errorType])
        case "Close":
            return GoNativeFunction(
                symbol: "$os.File.Close", goName: "os.File.Close",
                parameters: [file], results: [GoPredeclared.errorType])
        case "Sync":
            return GoNativeFunction(
                symbol: "$os.File.Sync", goName: "os.File.Sync",
                parameters: [file], results: [GoPredeclared.errorType])
        case "Name":
            return GoNativeFunction(
                symbol: "$os.File.name", goName: "os.File.Name", parameters: [file], results: [.string])
        default:
            return GoFileTextMethods.method(member)
        }
    }

    /// File descriptor behind `os.Stdin`, `os.Stdout`, and `os.Stderr`. Those
    /// `*os.File` values are the descriptor number at run time.
    static func standardFileDescriptor(member: String) -> Int64? {
        switch member {
        case "Stdin": return 0
        case "Stdout": return 1
        case "Stderr": return 2
        default: return nil
        }
    }

    /// Call name of `fmt.Print` or `fmt.Println` where its `(n, err)` is
    /// read. As a statement each is the `print` instruction.
    static func printCountSymbol(newline: Bool) -> String {
        newline ? "$fmt.Println.n" : "$fmt.Print.n"
    }

    /// Whether the linker may leave `name` for the VM to resolve natively.
    static func isNativeCallName(_ name: String) -> Bool {
        nativeCallNames.contains(name) || name.hasPrefix(GoPredeclared.freshVariable)
            || name.hasPrefix(GoPredeclared.bindVariable)
            || name == GoPredeclared.callFunctionValue
            || name == GoPredeclared.requireValue
            || name == GoFullSlice.nativeName
            || name.hasPrefix(GoPredeclared.liveResults)
            || GoLibraryTypes.nativeCallNames.contains(name)
            || GoProcessLibrary.nativeCallNames.contains(name)
            || GoNumberLibrary.isCallName(name)
            || GoTimeLibrary.nativeCallNames.contains(name)
            || GoBuiltinPrint.nativeCallNames.contains(name)
    }

    private static let nativeCallNames: Set<String> = Set(
        GoBitwiseOperator.allCases.map(\.nativeName)
            + GoPredeclared.conversionCallNames
            + GoSourceLibrary.nativeCallNames
            + [
                GoPredeclared.copyElements, GoPredeclared.appendElements,
                GoPredeclared.newVariable, GoPredeclared.clearElements,
                "$sort.Strings", "$sort.Ints", "$strconv.Itoa", "$errors.New", GoOSArgs.setter,
                "$errors.Unwrap", "$errors.Is", GoPredeclared.errorsAs,
                "$fmt.Fprint", "$fmt.Fprintln", "$fmt.Fprint.n", "$fmt.Fprintln.n",
                "$fmt.Sprintf", "$fmt.Errorf", "$fmt.Sprint", "$fmt.Sprintln",
                "$fmt.Printf", "$fmt.Fprintf", "$fmt.Printf.n", "$fmt.Fprintf.n",
                printCountSymbol(newline: false), printCountSymbol(newline: true),
                "$strings.ToUpper", "$strings.ToLower", "$strings.Fields",
                "$strings.TrimPrefix", "$strings.TrimSuffix",
                "$os.File.Write", "$os.File.WriteString", "$os.File.Read",
                "$os.ReadFile", "$os.WriteFile",
                "$os.Open", "$os.Create", "$os.OpenFile", "$os.Remove", "$os.Rename", "$os.Mkdir",
                "$os.File.ReadAt", "$os.File.WriteAt", "$os.File.Seek", "$os.File.Close",
                "$os.File.Sync",
                "$time.Now", "$time.Since", "$time.Unix",
                "$time.Time.Unix", "$time.Time.UnixMilli", "$time.Time.UnixNano",
                "$time.Time.Sub", "$time.Time.Add",
                "$time.Time.Before", "$time.Time.After", "$time.Time.Equal",
            ])
}

/// Predeclared and standard-library types that are not `GoType` cases.
///
/// `byte` (and its alias `uint8`) is the named type `byte` whose underlying
/// type is `int`; its values stay within 0...255 because the compiler masks
/// every operation that could leave that range. `time.Time` and `os.File` are
/// opaque named types without an underlying type; a `time.Time` is its
/// nanoseconds since the Unix epoch at run time.
enum GoPredeclared {
    static let byte = GoType.named("byte")
    static let time = GoType.named("time.Time")
    static let filePointer = GoType.pointer(.named("os.File"))
    static let errorType = GoType.interface([GoInterfaceMethod(name: "Error", results: [.string])])

    static let bytesToString = "$conv.bytesToString"
    static let stringToBytes = "$conv.stringToBytes"
    static let runeToString = "$conv.runeToString"
    static let conversionCallNames = [bytesToString, stringToBytes, runeToString]

    /// Prefix of the type name a value converted to an interface is boxed
    /// with: a descriptor of its type follows. The VM decodes it as
    /// `GoTypeDescriptor`.
    static let typeDescriptorMarker = "$T"

    /// Type name that marks a `[]any` given as `values...` to a `...any`
    /// parameter of the library.
    static let spreadOperandsTypeName = "$spread"

    /// Native call of `errors.As`. Its target is a pointer, which stays bare,
    /// and the compiler adds what the target's type is as a third operand.
    static let errorsAs = "$errors.As"

    /// Prefix of that operand, and of the target of a type assertion, when
    /// the target is an interface: `<name>:<parameters>:<results>` of each
    /// method follow in name order, separated by commas, then `;` and the
    /// interface's type name, then a line for each type that implements it.
    static let interfaceTarget = "$I"

    /// Native call the builtin `copy` lowers to.
    static let copyElements = "$copy"

    /// Prefix of the native call that starts a new variable in a local of
    /// the executing function, whose index follows: what a declaration does
    /// each time a loop reaches it, when a pointer could outlive the
    /// iteration. See `GoAddressedVariables`.
    static let freshVariable = "$fresh."

    /// Native call that puts its operand in a variable of its own and
    /// returns a pointer to it: `&T{...}`, where every evaluation makes a
    /// new variable.
    static let newVariable = "$new"

    /// Prefix of the call that makes a local of the executing frame the
    /// variable a pointer points to: `$bind.<local>`, with the pointer as
    /// its argument. A function literal begins with one for each variable
    /// it captures, which is thereby the same variable in both functions.
    static let bindVariable = "$bind."

    /// The call through a function value: the value, then the arguments.
    static let callFunctionValue = "$call"

    /// The call that panics as a nil pointer dereference does when its
    /// argument is nil: selecting a method of an interface value that holds
    /// nothing panics where the method is selected, called or not.
    static let requireValue = "$nonnil"

    /// Prefix of the call a function begins with when what it returns is
    /// what its result variables hold once every deferred call has run, as
    /// in Go: `$results.<local>.<local>`, the locals of the results in
    /// order. A deferred call may have changed them, or recovered a panic
    /// that left them as they were.
    static let liveResults = "$results."

    /// The type a function value has in the VM, which has no value of its
    /// own for one: a struct whose first field names the function and whose
    /// others are passed to it before the arguments of a call.
    static let functionValueTypeName = "$func"
    static let functionValueSymbolField = "f"

    /// Native call `append(slice, source...)` lowers to, with the element
    /// zero value as its third operand.
    static let appendElements = "$append"

    /// Native call the builtin `clear` lowers to: a map, which loses its
    /// entries, or a slice and the zero value every element of it gets.
    static let clearElements = "$clear"

    /// Method the compiler synthesizes so `err.Error()` works on the runtime's
    /// native error values, whose dynamic type name is `error`.
    static let nativeErrorMethod = "error.Error"

    /// Dynamic type name of the runtime's native error values.
    static let nativeErrorTypeName = "error"

    /// The type a predeclared name denotes when it is not a `GoType` case.
    static func namedType(_ name: String) -> GoType? {
        numericType(name)
    }

    /// Underlying type of a predeclared named type.
    static func underlying(of name: String) -> GoType? {
        // An integer of any size is held as an `int` is. A floating-point
        // type is its own underlying type: it is no integer.
        GoNumericKind(typeName: name).flatMap { $0.isInteger ? .int : nil }
            ?? GoLibraryTypes.underlying(of: name)
            ?? GoLibraryTypes.handleInterface(of: name)
    }

    /// Go numeric types this toolchain does not implement.
    static let unsupportedNumericTypes: Set<String> =
        GoNumericKind.floatsAreSupported
        ? ["complex64", "complex128"] : ["float32", "float64", "complex64", "complex128"]

    static func unsupportedTypeMessage(_ name: String) -> String {
        GoNumericKind.floatsAreSupported
            ? "type \(name) is not supported; the numeric types are the integer and floating-point types"
            : "type \(name) is not supported; the numeric types are the integer types"
    }

    /// Whether `type` is `byte` or a named type defined in terms of it.
    static func isByte(_ type: GoType, definitions: [String: GoTypeDefinition]) -> Bool {
        var current = type
        var visited: Set<String> = []
        while case .named(let name) = current, visited.insert(name).inserted {
            if let definition = definitions[name] {
                current = definition.underlying
            } else {
                return name == "byte"
            }
        }
        return false
    }
}

extension GoStringsFunction {
    /// Parameter and result types of the Go signature.
    var signature: (parameters: [GoType], result: GoType) {
        switch self {
        case .contains, .hasPrefix, .hasSuffix: return ([.string, .string], .bool)
        case .count, .index, .lastIndex: return ([.string, .string], .int)
        case .join: return ([.slice(.string), .string], .string)
        case .repeatString: return ([.string, .int], .string)
        case .split: return ([.string, .string], .slice(.string))
        case .trimSpace: return ([.string], .string)
        }
    }
}
