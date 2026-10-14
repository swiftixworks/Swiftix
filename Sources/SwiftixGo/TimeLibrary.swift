/// `time.Time` as Go has it, on the compiler's side: the calendar, `Format`
/// and `Parse`, locations, and the types `time.Month`, `time.Weekday`, and
/// `*time.Location`.
///
/// A `time.Time` stays what it was, an opaque type of the library whose
/// value the VM alone looks into (`GoCalendar` in `SwiftixGoRuntime` says
/// what it is), so a program that used a time before compiles to what it
/// did: every method is a native call, `$time.Time.<method>`, of one
/// instruction, as `Unix` and `Sub` always were. Its zero value is the
/// integer it always was, which the VM now reads as Go's zero time.
///
/// `time.Month` and `time.Weekday` are `int`s with a name and a native
/// `String`, as `time.Duration` is an `int64` with them, and `GoLibraryTypes`
/// treats the three alike. A `*time.Location` is opaque like a time. The
/// constants of the package (`time.RFC3339`, `time.January`) and its
/// variables `time.UTC` and `time.Local` are Go text of the library
/// (`Sources/SwiftixGoLibrary/time`), linked where a program names them.
enum GoTimeLibrary {
    static let monthName = "time.Month"
    static let weekdayName = "time.Weekday"
    static let locationName = "time.Location"
    static let month = GoType.named(monthName)
    static let weekday = GoType.named(weekdayName)
    static let location = GoType.pointer(.named(locationName))

    /// Whether a program can name `name` as a type of this file.
    static func isTypeName(_ name: String) -> Bool {
        name == monthName || name == weekdayName || name == locationName
    }

    /// What `time.Month` and `time.Weekday` are defined as. A location is
    /// opaque and has no definition.
    static func underlying(of name: String) -> GoType? {
        name == monthName || name == weekdayName ? .int : nil
    }

    /// The type whose natives the methods of a value of `type` are: a
    /// month, a weekday, or a time, for the value and a pointer to it, and
    /// a location for a pointer to one.
    static func methodOwner(_ type: GoType) -> GoType? {
        switch type {
        case month, .pointer(month): return month
        case weekday, .pointer(weekday): return weekday
        case GoPredeclared.time, .pointer(GoPredeclared.time): return GoPredeclared.time
        case location: return location
        default: return nil
        }
    }

    private static func native(
        _ symbol: String, _ parameters: [GoType], _ results: [GoType]
    ) -> GoNativeFunction {
        GoNativeFunction(
            symbol: "$" + symbol, goName: symbol, parameters: parameters, results: results)
    }

    /// The functions of the package this file adds.
    static func nativeFunction(package: String, member: String) -> GoNativeFunction? {
        guard package == "time" else { return nil }
        let time = GoPredeclared.time
        let int64 = GoNumericKind.int64.type
        let failure = GoPredeclared.errorType
        switch member {
        case "UnixMilli", "UnixMicro": return native("time." + member, [int64], [time])
        case "Date":
            return native(
                "time.Date", [.int, month, .int, .int, .int, .int, .int, location], [time])
        case "Parse": return native("time.Parse", [.string, .string], [time, failure])
        case "ParseInLocation":
            return native("time.ParseInLocation", [.string, .string, location], [time, failure])
        case "FixedZone": return native("time.FixedZone", [.string, .int], [location])
        case "LoadLocation": return native("time.LoadLocation", [.string], [location, failure])
        default: return nil
        }
    }

    /// The native the library's text calls as `native.location(kind)`:
    /// `time.UTC` for 0, `time.Local` for 1.
    static func textNative(_ name: String) -> GoNativeFunction? {
        name == "location" ? native("time.location", [.int], [location]) : nil
    }

    /// The methods of `time.Time` this file adds; `GoStandardLibrary`
    /// declares those it always had.
    static func timeMethod(_ member: String) -> GoNativeFunction? {
        let time = GoPredeclared.time
        let duration = GoLibraryTypes.duration
        let bytes = GoType.slice(GoPredeclared.byte)
        let parameters: [GoType]
        let results: [GoType]
        switch member {
        case "IsZero": (parameters, results) = ([], [.bool])
        case "UnixMicro": (parameters, results) = ([], [GoNumericKind.int64.type])
        case "Compare": (parameters, results) = ([time], [.int])
        case "Year", "Day", "Hour", "Minute", "Second", "Nanosecond", "YearDay":
            (parameters, results) = ([], [.int])
        case "Month": (parameters, results) = ([], [month])
        case "Weekday": (parameters, results) = ([], [weekday])
        case "Date": (parameters, results) = ([], [.int, month, .int])
        case "Clock": (parameters, results) = ([], [.int, .int, .int])
        case "ISOWeek": (parameters, results) = ([], [.int, .int])
        case "AddDate": (parameters, results) = ([.int, .int, .int], [time])
        case "Truncate", "Round": (parameters, results) = ([duration], [time])
        case "Format": (parameters, results) = ([.string], [.string])
        case "AppendFormat": (parameters, results) = ([bytes, .string], [bytes])
        case "String", "GoString": (parameters, results) = ([], [.string])
        case "MarshalText": (parameters, results) = ([], [bytes, GoPredeclared.errorType])
        case "UTC", "Local": (parameters, results) = ([], [time])
        case "In": (parameters, results) = ([location], [time])
        case "Location": (parameters, results) = ([], [location])
        case "Zone": (parameters, results) = ([], [.string, .int])
        default: return nil
        }
        return native("time.Time." + member, [time] + parameters, results)
    }

    /// The method names of `time.Time` this file adds, which a struct that
    /// embeds a time is lent.
    static let addedTimeMethods = [
        "IsZero", "UnixMicro", "Compare", "Year", "Month", "Day", "Hour", "Minute", "Second",
        "Nanosecond", "Weekday", "YearDay", "Date", "Clock", "ISOWeek", "AddDate", "Truncate",
        "Round", "Format", "AppendFormat", "String", "GoString", "MarshalText", "UTC", "Local",
        "In", "Location", "Zone",
    ]

    /// The methods of a month, a weekday, and a location.
    static func method(of receiver: GoType, named member: String) -> GoNativeFunction? {
        guard member == "String" else { return nil }
        switch receiver {
        case month: return native("time.Month.String", [month], [.string])
        case weekday: return native("time.Weekday.String", [weekday], [.string])
        case location: return native("time.Location.String", [location], [.string])
        default: return nil
        }
    }

    /// The reserved call names of the natives this file declares.
    static let nativeCallNames: Set<String> = Set(
        addedTimeMethods.map { "$time.Time." + $0 }
            + [
                "$time.UnixMilli", "$time.UnixMicro", "$time.Date", "$time.Parse",
                "$time.ParseInLocation", "$time.FixedZone", "$time.LoadLocation",
                "$time.location", "$time.Month.String", "$time.Weekday.String",
                "$time.Location.String", "$time.Until",
            ])
}

extension FunctionChecker {
    /// Checks `time.Time{...}`, which is Go's zero time when empty. Go's
    /// struct has only unexported fields, so anything inside is an error.
    func checkTimeLiteral(_ elements: [GoCompositeElement]) throws {
        guard let first = elements.first else { return }
        let type = "struct literal of type time.Time"
        if let key = first.key {
            let unexported = ["wall", "ext", "loc"].contains(key)
            throw GoDiagnostic(
                position: first.position,
                message: unexported
                    ? "cannot refer to unexported field \(key) in \(type)"
                    : "unknown field \(key) in \(type)")
        }
        throw GoDiagnostic(
            position: first.value.startPosition,
            message: "implicit assignment to unexported field wall in \(type)")
    }
}
