/// Compile-time catalogue of the Swiftix Go standard-library surface.

import SwiftixGoRuntime

enum GoBuiltinFunction: Sendable, Equatable {
    case fmtPrint
    case fmtPrintln
    case timeAfter
    case timeSleep
    case timeTick
    case contextBackground
    case contextWithCancel
    case contextWithTimeout
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
        case ("context", "Background"): return .contextBackground
        case ("context", "WithCancel"): return .contextWithCancel
        case ("context", "WithTimeout"): return .contextWithTimeout
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
    /// Go returns `(n, err)`; this dialect supports the call as a statement
    /// only.
    var isStatementOnly = false
    /// The variadic arguments are operands of `fmt` verbs, so a `[]byte`
    /// among them is boxed with its type for `%s` and `%x`.
    var formatsOperands = false
}

extension GoStandardLibrary {
    /// Native functions reached as `package.Member(...)`.
    static func nativeFunction(package: String, member: String) -> GoNativeFunction? {
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
        case ("fmt", "Fprint"):
            return GoNativeFunction(
                symbol: "$fmt.Fprint", goName: "fmt.Fprint", parameters: [file],
                isVariadic: true, isStatementOnly: true)
        case ("fmt", "Fprintln"):
            return GoNativeFunction(
                symbol: "$fmt.Fprintln", goName: "fmt.Fprintln", parameters: [file],
                isVariadic: true, isStatementOnly: true)
        case ("fmt", "Sprintf"):
            return GoNativeFunction(
                symbol: "$fmt.Sprintf", goName: "fmt.Sprintf", parameters: [.string],
                isVariadic: true, results: [.string], formatsOperands: true)
        case ("fmt", "Errorf"):
            return GoNativeFunction(
                symbol: "$fmt.Errorf", goName: "fmt.Errorf", parameters: [.string],
                isVariadic: true, results: [failure], formatsOperands: true)
        case ("fmt", "Printf"):
            return GoNativeFunction(
                symbol: "$fmt.Printf", goName: "fmt.Printf", parameters: [.string],
                isVariadic: true, isStatementOnly: true, formatsOperands: true)
        case ("fmt", "Fprintf"):
            return GoNativeFunction(
                symbol: "$fmt.Fprintf", goName: "fmt.Fprintf", parameters: [file, .string],
                isVariadic: true, isStatementOnly: true, formatsOperands: true)
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
                results: [.int])
        case ("time", "Unix"):
            return GoNativeFunction(
                symbol: "$time.Unix", goName: "time.Unix", parameters: [.int, .int],
                results: [GoPredeclared.time])
        default:
            return nil
        }
    }

    /// Native methods of the library types `*os.File` and `time.Time`. The
    /// receiver is the first parameter.
    static func method(of receiver: GoType, named member: String) -> GoNativeFunction? {
        if receiver == GoPredeclared.filePointer { return fileMethod(member) }
        if receiver == GoPredeclared.time { return timeMethod(member) }
        return nil
    }

    /// Native methods of `time.Time`. Durations are `int` nanoseconds.
    static func timeMethod(_ member: String) -> GoNativeFunction? {
        let time = GoPredeclared.time
        let parameters: [GoType]
        let result: GoType
        switch member {
        case "Unix", "UnixMilli", "UnixNano": (parameters, result) = ([time], .int)
        case "Sub": (parameters, result) = ([time, time], .int)
        case "Add": (parameters, result) = ([time, .int], time)
        case "Before", "After", "Equal": (parameters, result) = ([time, time], .bool)
        default: return nil
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
        case "ReadAt":
            return GoNativeFunction(
                symbol: "$os.File.ReadAt", goName: "os.File.ReadAt",
                parameters: [file, bytes, .int], results: results)
        case "WriteAt":
            return GoNativeFunction(
                symbol: "$os.File.WriteAt", goName: "os.File.WriteAt",
                parameters: [file, bytes, .int], results: results)
        case "Seek":
            return GoNativeFunction(
                symbol: "$os.File.Seek", goName: "os.File.Seek",
                parameters: [file, .int, .int], results: results)
        case "Close":
            return GoNativeFunction(
                symbol: "$os.File.Close", goName: "os.File.Close",
                parameters: [file], results: [GoPredeclared.errorType])
        case "Sync":
            return GoNativeFunction(
                symbol: "$os.File.Sync", goName: "os.File.Sync",
                parameters: [file], results: [GoPredeclared.errorType])
        default:
            return nil
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

    /// Whether the linker may leave `name` for the VM to resolve natively.
    static func isNativeCallName(_ name: String) -> Bool {
        nativeCallNames.contains(name)
    }

    private static let nativeCallNames: Set<String> = Set(
        GoBitwiseOperator.allCases.map(\.nativeName)
            + GoPredeclared.conversionCallNames
            + [
                GoPredeclared.copyElements, GoPredeclared.appendElements,
                "$sort.Strings", "$sort.Ints", "$strconv.Itoa", "$errors.New",
                "$fmt.Fprint", "$fmt.Fprintln",
                "$fmt.Sprintf", "$fmt.Errorf", "$fmt.Printf", "$fmt.Fprintf",
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

    /// Dynamic type name a `[]byte` operand of a `fmt` verb is boxed with.
    static let byteSliceTypeName = "[]uint8"

    /// Native call the builtin `copy` lowers to.
    static let copyElements = "$copy"

    /// Native call `append(slice, source...)` lowers to, with the element
    /// zero value as its third operand.
    static let appendElements = "$append"

    /// Method the compiler synthesizes so `err.Error()` works on the runtime's
    /// native error values, whose dynamic type name is `error`.
    static let nativeErrorMethod = "error.Error"

    /// Dynamic type name of the runtime's native error values.
    static let nativeErrorTypeName = "error"

    /// The type a predeclared name denotes when it is not a `GoType` case.
    static func namedType(_ name: String) -> GoType? {
        name == "byte" || name == "uint8" ? byte : nil
    }

    /// Underlying type of a predeclared named type.
    static func underlying(of name: String) -> GoType? {
        name == "byte" ? .int : nil
    }

    /// Go numeric types this toolchain does not implement.
    static let unsupportedNumericTypes: Set<String> = [
        "int8", "int16", "int32", "int64", "uint", "uint16", "uint32", "uint64", "uintptr",
        "float32", "float64", "complex64", "complex128", "rune",
    ]

    static func unsupportedTypeMessage(_ name: String) -> String {
        "type \(name) is not supported; the integer types are int, byte, and uint8"
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
