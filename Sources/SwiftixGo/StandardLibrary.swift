/// Compile-time catalogue of the Swiftix Go standard-library surface.

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
}

enum GoStandardLibrary {
    static let supportedPackages = [
        "fmt", "testing", "time", "sync", "runtime",
        "context", "net", "net/http", "os", "strconv", "swiftix/userland",
    ]

    static func resolve(package: String, member: String) -> GoBuiltinFunction? {
        switch (package, member) {
        case ("fmt", "Print"): return .fmtPrint
        case ("fmt", "Println"): return .fmtPrintln
        case ("os", "Exit"): return .osExit
        case ("strconv", "Atoi"): return .strconvAtoi
        case ("userland", "ReadInput"): return .userlandReadInput
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
