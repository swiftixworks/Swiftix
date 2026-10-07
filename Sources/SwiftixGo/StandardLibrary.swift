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
        "context", "net", "net/http", "os", "sort", "strconv", "strings", "swiftix/userland",
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
        case ("fmt", "Fprint"):
            return GoNativeFunction(
                symbol: "$fmt.Fprint", goName: "fmt.Fprint", parameters: [file],
                isVariadic: true)
        case ("fmt", "Fprintln"):
            return GoNativeFunction(
                symbol: "$fmt.Fprintln", goName: "fmt.Fprintln", parameters: [file],
                isVariadic: true)
        case ("os", "ReadFile"):
            return GoNativeFunction(
                symbol: "$os.ReadFile", goName: "os.ReadFile", parameters: [.string],
                results: [bytes, failure])
        case ("os", "WriteFile"):
            return GoNativeFunction(
                symbol: "$os.WriteFile", goName: "os.WriteFile",
                parameters: [.string, bytes, .int], results: [failure])
        default:
            return nil
        }
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
                "$sort.Strings", "$sort.Ints", "$strconv.Itoa",
                "$fmt.Fprint", "$fmt.Fprintln",
                "$os.File.Write", "$os.File.WriteString", "$os.File.Read",
                "$os.ReadFile", "$os.WriteFile",
            ])
}

/// Predeclared and standard-library types that are not `GoType` cases.
///
/// `byte` (and its alias `uint8`) is the named type `byte` whose underlying
/// type is `int`; its values stay within 0...255 because the compiler masks
/// every operation that could leave that range. `time.Time` and `os.File` are
/// opaque named types without an underlying type.
enum GoPredeclared {
    static let byte = GoType.named("byte")
    static let time = GoType.named("time.Time")
    static let filePointer = GoType.pointer(.named("os.File"))
    static let errorType = GoType.interface([GoInterfaceMethod(name: "Error", results: [.string])])

    static let bytesToString = "$conv.bytesToString"
    static let stringToBytes = "$conv.stringToBytes"
    static let runeToString = "$conv.runeToString"
    static let conversionCallNames = [bytesToString, stringToBytes, runeToString]

    /// Method the compiler synthesizes so `err.Error()` works on the runtime's
    /// native error values, whose dynamic type name is `error`.
    static let nativeErrorMethod = "error.Error"

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
