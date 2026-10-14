/// `Format` and `Parse` of `time.Time` with Go's reference layout, as Go's
/// `time/format.go` has them: the same chunks of a layout, the same
/// padding, the same errors. A zone abbreviation that is not `UTC` names a
/// zone of no offset, as Go's does when its local location does not know
/// the abbreviation, which here it never does. Pure functions; no process
/// or executor state.
enum GoTimeFormat {
    static let rfc3339 = "2006-01-02T15:04:05Z07:00"
    static let rfc3339Nano = "2006-01-02T15:04:05.999999999Z07:00"

    // The chunks of a layout, numbered as Go numbers them.
    private static let needDate = 1 << 8
    private static let needYearDay = 1 << 9
    private static let needClock = 1 << 10
    private static let argumentShift = 16
    private static let separatorShift = 28
    private static let mask = 1 << argumentShift - 1

    private static let longMonth = 1 + needDate
    private static let month = 2 + needDate
    private static let numMonth = 3 + needDate
    private static let zeroMonth = 4 + needDate
    private static let longWeekDay = 5 + needDate
    private static let weekDay = 6 + needDate
    private static let day = 7 + needDate
    private static let underDay = 8 + needDate
    private static let zeroDay = 9 + needDate
    private static let underYearDay = 10 + needYearDay
    private static let zeroYearDay = 11 + needYearDay
    private static let hour = 12 + needClock
    private static let hour12 = 13 + needClock
    private static let zeroHour12 = 14 + needClock
    private static let minute = 15 + needClock
    private static let zeroMinute = 16 + needClock
    private static let second = 17 + needClock
    private static let zeroSecond = 18 + needClock
    private static let longYear = 19 + needDate
    private static let year = 20 + needDate
    private static let pm = 21 + needClock
    private static let lowerPM = 22 + needClock
    private static let tz = 23
    private static let iso8601TZ = 24
    private static let iso8601SecondsTZ = 25
    private static let iso8601ShortTZ = 26
    private static let iso8601ColonTZ = 27
    private static let iso8601ColonSecondsTZ = 28
    private static let numTZ = 29
    private static let numSecondsTZ = 30
    private static let numShortTZ = 31
    private static let numColonTZ = 32
    private static let numColonSecondsTZ = 33
    private static let fracSecond0 = 34
    private static let fracSecond9 = 35

    private static let zeroX = [zeroMonth, zeroDay, zeroHour12, zeroMinute, zeroSecond, year]

    private static let shortDayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let shortMonthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private typealias Bytes = ArraySlice<UInt8>

    private static func matches(_ layout: Bytes, at index: Int, _ text: String) -> Bool {
        let wanted = Array(text.utf8)
        guard layout.endIndex - index >= wanted.count else { return false }
        return layout[index..<index + wanted.count].elementsEqual(wanted)
    }

    private static func isDigit(_ text: Bytes, _ offset: Int) -> Bool {
        let index = text.startIndex + offset
        guard index < text.endIndex else { return false }
        return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[index])
    }

    private static func startsWithLowerCase(_ text: Bytes) -> Bool {
        guard let first = text.first else { return false }
        return (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
    }

    /// Go's `nextStdChunk`: the text before the first chunk, the chunk
    /// (0 for none), and the text after it.
    private static func nextChunk(_ layout: Bytes) -> (prefix: Bytes, chunk: Int, suffix: Bytes) {
        let start = layout.startIndex
        var index = start
        func cut(_ chunk: Int, _ length: Int, keep: Int = 0) -> (Bytes, Int, Bytes) {
            (layout[start..<index + keep], chunk, layout[(index + length)...])
        }
        while index < layout.endIndex {
            let rest = layout[index...]
            switch layout[index] {
            case UInt8(ascii: "J"):
                if matches(layout, at: index, "Jan") {
                    if matches(layout, at: index, "January") { return cut(longMonth, 7) }
                    if !startsWithLowerCase(layout[(index + 3)...]) { return cut(month, 3) }
                }
            case UInt8(ascii: "M"):
                if matches(layout, at: index, "Mon") {
                    if matches(layout, at: index, "Monday") { return cut(longWeekDay, 6) }
                    if !startsWithLowerCase(layout[(index + 3)...]) { return cut(weekDay, 3) }
                }
                if matches(layout, at: index, "MST") { return cut(tz, 3) }
            case UInt8(ascii: "0"):
                if rest.count >= 2, (UInt8(ascii: "1")...UInt8(ascii: "6")).contains(rest[index + 1]) {
                    return cut(zeroX[Int(rest[index + 1] - UInt8(ascii: "1"))], 2)
                }
                if matches(layout, at: index, "002") { return cut(zeroYearDay, 3) }
            case UInt8(ascii: "1"):
                if matches(layout, at: index, "15") { return cut(hour, 2) }
                return cut(numMonth, 1)
            case UInt8(ascii: "2"):
                if matches(layout, at: index, "2006") { return cut(longYear, 4) }
                return cut(day, 1)
            case UInt8(ascii: "_"):
                if matches(layout, at: index, "_2") {
                    // `_2006` is a literal `_` and then the year.
                    if matches(layout, at: index, "_2006") { return cut(longYear, 5, keep: 1) }
                    return cut(underDay, 2)
                }
                if matches(layout, at: index, "__2") { return cut(underYearDay, 3) }
            case UInt8(ascii: "3"): return cut(hour12, 1)
            case UInt8(ascii: "4"): return cut(minute, 1)
            case UInt8(ascii: "5"): return cut(second, 1)
            case UInt8(ascii: "P"):
                if matches(layout, at: index, "PM") { return cut(pm, 2) }
            case UInt8(ascii: "p"):
                if matches(layout, at: index, "pm") { return cut(lowerPM, 2) }
            case UInt8(ascii: "-"):
                if matches(layout, at: index, "-070000") { return cut(numSecondsTZ, 7) }
                if matches(layout, at: index, "-07:00:00") { return cut(numColonSecondsTZ, 9) }
                if matches(layout, at: index, "-0700") { return cut(numTZ, 5) }
                if matches(layout, at: index, "-07:00") { return cut(numColonTZ, 6) }
                if matches(layout, at: index, "-07") { return cut(numShortTZ, 3) }
            case UInt8(ascii: "Z"):
                if matches(layout, at: index, "Z070000") { return cut(iso8601SecondsTZ, 7) }
                if matches(layout, at: index, "Z07:00:00") {
                    return cut(iso8601ColonSecondsTZ, 9)
                }
                if matches(layout, at: index, "Z0700") { return cut(iso8601TZ, 5) }
                if matches(layout, at: index, "Z07:00") { return cut(iso8601ColonTZ, 6) }
                if matches(layout, at: index, "Z07") { return cut(iso8601ShortTZ, 3) }
            case UInt8(ascii: "."), UInt8(ascii: ","):
                if index + 1 < layout.endIndex,
                    layout[index + 1] == UInt8(ascii: "0") || layout[index + 1] == UInt8(ascii: "9")
                {
                    let digit = layout[index + 1]
                    var end = index + 1
                    while end < layout.endIndex, layout[end] == digit { end += 1 }
                    // Only a fractional second is all digits.
                    if !isDigit(layout[end...], 0) {
                        let code = digit == UInt8(ascii: "9") ? fracSecond9 : fracSecond0
                        var chunk = code | ((end - (index + 1)) & 0xfff) << argumentShift
                        if layout[index] == UInt8(ascii: ",") { chunk |= 1 << separatorShift }
                        return cut(chunk, end - index)
                    }
                }
            default: break
            }
            index += 1
        }
        return (layout, 0, layout[layout.endIndex...])
    }

    /// Go's `appendInt`: `value` in decimal, padded with zeros to `width`.
    private static func append(_ value: Int64, width: Int, to bytes: inout [UInt8]) {
        var magnitude = value.magnitude
        if value < 0 { bytes.append(UInt8(ascii: "-")) }
        var digits: [UInt8] = []
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(magnitude % 10))
            magnitude /= 10
        } while magnitude > 0
        if digits.count < width {
            bytes.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: width - digits.count))
        }
        bytes.append(contentsOf: digits.reversed())
    }

    private static func append(_ text: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: text.utf8)
    }

    private static func appendFraction(_ nanoseconds: Int64, chunk: Int, to bytes: inout [UInt8]) {
        let trim = chunk & mask == fracSecond9
        let digits = (chunk >> argumentShift) & 0xfff
        if trim, digits == 0 || nanoseconds == 0 { return }
        let dot = chunk >> separatorShift == 0 ? UInt8(ascii: ".") : UInt8(ascii: ",")
        var fraction: [UInt8] = []
        append(nanoseconds, width: 9, to: &fraction)
        if digits < 9 { fraction.removeLast(9 - digits) }
        if trim {
            while fraction.last == UInt8(ascii: "0") { fraction.removeLast() }
            if fraction.isEmpty { return }
        }
        bytes.append(dot)
        bytes.append(contentsOf: fraction)
    }

    /// `t.Format(layout)`.
    static func format(_ time: GoTime, layout text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var layout = Array(text.utf8)[...]
        let date = time.date
        let clock = time.clock
        let offset = time.location.offset
        while !layout.isEmpty {
            let (prefix, chunk, suffix) = nextChunk(layout)
            bytes.append(contentsOf: prefix)
            if chunk == 0 { break }
            layout = suffix
            switch chunk & mask {
            case year: append(Int64(date.year.magnitude % 100), width: 2, to: &bytes)
            case longYear: append(date.year, width: 4, to: &bytes)
            case month: append(shortMonthNames[Int(date.month - 1)], to: &bytes)
            case longMonth: append(GoCalendar.monthName(date.month), to: &bytes)
            case numMonth: append(date.month, width: 0, to: &bytes)
            case zeroMonth: append(date.month, width: 2, to: &bytes)
            case weekDay: append(shortDayNames[Int(time.weekday)], to: &bytes)
            case longWeekDay: append(GoCalendar.weekdayName(time.weekday), to: &bytes)
            case day: append(date.day, width: 0, to: &bytes)
            case underDay:
                if date.day < 10 { bytes.append(UInt8(ascii: " ")) }
                append(date.day, width: 0, to: &bytes)
            case zeroDay: append(date.day, width: 2, to: &bytes)
            case underYearDay:
                let yearDay = time.yearDay
                if yearDay < 100 {
                    bytes.append(UInt8(ascii: " "))
                    if yearDay < 10 { bytes.append(UInt8(ascii: " ")) }
                }
                append(yearDay, width: 0, to: &bytes)
            case zeroYearDay: append(time.yearDay, width: 3, to: &bytes)
            case hour: append(clock.hour, width: 2, to: &bytes)
            case hour12, zeroHour12:
                // Noon is 12PM, midnight is 12AM.
                let twelve = clock.hour % 12 == 0 ? 12 : clock.hour % 12
                append(twelve, width: chunk == zeroHour12 ? 2 : 0, to: &bytes)
            case minute: append(clock.minute, width: 0, to: &bytes)
            case zeroMinute: append(clock.minute, width: 2, to: &bytes)
            case second: append(clock.second, width: 0, to: &bytes)
            case zeroSecond: append(clock.second, width: 2, to: &bytes)
            case pm: append(clock.hour >= 12 ? "PM" : "AM", to: &bytes)
            case lowerPM: append(clock.hour >= 12 ? "pm" : "am", to: &bytes)
            case iso8601TZ, iso8601ColonTZ, iso8601SecondsTZ, iso8601ShortTZ,
                iso8601ColonSecondsTZ, numTZ, numColonTZ, numSecondsTZ, numShortTZ,
                numColonSecondsTZ:
                let iso = [
                    iso8601TZ, iso8601ColonTZ, iso8601SecondsTZ, iso8601ShortTZ,
                    iso8601ColonSecondsTZ,
                ].contains(chunk)
                if offset == 0, iso {
                    bytes.append(UInt8(ascii: "Z"))
                    break
                }
                var zone = offset / 60
                var absolute = offset
                if zone < 0 {
                    bytes.append(UInt8(ascii: "-"))
                    zone = -zone
                    absolute = -absolute
                } else {
                    bytes.append(UInt8(ascii: "+"))
                }
                append(zone / 60, width: 2, to: &bytes)
                if [iso8601ColonTZ, numColonTZ, iso8601ColonSecondsTZ, numColonSecondsTZ]
                    .contains(chunk)
                {
                    bytes.append(UInt8(ascii: ":"))
                }
                if chunk != numShortTZ, chunk != iso8601ShortTZ {
                    append(zone % 60, width: 2, to: &bytes)
                }
                if [iso8601SecondsTZ, numSecondsTZ, numColonSecondsTZ, iso8601ColonSecondsTZ]
                    .contains(chunk)
                {
                    if chunk == numColonSecondsTZ || chunk == iso8601ColonSecondsTZ {
                        bytes.append(UInt8(ascii: ":"))
                    }
                    append(absolute % 60, width: 2, to: &bytes)
                }
            case tz:
                let name = time.location.zoneName
                if !name.isEmpty {
                    append(name, to: &bytes)
                    break
                }
                // No name: the `-0700` form.
                var zone = offset / 60
                if zone < 0 {
                    bytes.append(UInt8(ascii: "-"))
                    zone = -zone
                } else {
                    bytes.append(UInt8(ascii: "+"))
                }
                append(zone / 60, width: 2, to: &bytes)
                append(zone % 60, width: 2, to: &bytes)
            case fracSecond0, fracSecond9:
                appendFraction(time.nanoseconds, chunk: chunk, to: &bytes)
            default: break
            }
        }
        return bytes
    }

    /// `t.String()`.
    static func string(_ time: GoTime) -> String {
        String(decoding: format(time, layout: "2006-01-02 15:04:05.999999999 -0700 MST"), as: UTF8.self)
    }

    /// `t.GoString()`, which `%#v` prints.
    static func goString(_ time: GoTime) -> String {
        let date = time.date
        let clock = time.clock
        var text = "time.Date(\(date.year), "
        text += (1...12).contains(date.month)
            ? "time." + GoCalendar.monthName(date.month) : "\(date.month)"
        text += ", \(date.day), \(clock.hour), \(clock.minute), \(clock.second), "
        text += "\(time.nanoseconds), "
        switch time.location {
        case .utc: text += "time.UTC"
        case .local: text += "time.Local"
        case .fixed(let name, _): text += "time.Location(" + quote(name) + ")"
        }
        return text + ")"
    }

    /// What `fmt` prints of Go's struct of `time` where it calls no method
    /// (behind an unexported field): its `wall` and `ext` as Go has them
    /// for a time without a monotonic reading, and a `loc` that is nil for
    /// UTC. Another location has an address of its own in Go.
    static func fields(of time: GoTime, labeled: Bool, goSyntax: Bool) -> String {
        let wall = String(time.nanoseconds)
        let ext = String(time.seconds &- GoTime.zeroSeconds)
        let isUTC = time.location == .utc
        if goSyntax {
            let location = isUTC ? "(*time.Location)(nil)" : "(*time.Location)(0xc000010000)"
            return "time.Time{wall:0x" + String(time.nanoseconds, radix: 16) + ", ext:" + ext
                + ", loc:" + location + "}"
        }
        let location = isUTC ? "<nil>" : "0xc000010000"
        if labeled { return "{wall:" + wall + " ext:" + ext + " loc:" + location + "}" }
        return "{" + wall + " " + ext + " " + location + "}"
    }

    /// Why `MarshalText` cannot write `time` as RFC 3339, or nil.
    static func strictRFC3339Failure(_ time: GoTime) -> String? {
        let year = time.date.year
        if year < 0 || year > 9_999 { return "year outside of range [0,9999]" }
        let offset = time.location.offset
        if offset != 0, (offset / 60).magnitude / 60 >= 24 {
            return "timezone hour outside of range [0,23]"
        }
        return nil
    }

    // MARK: Parsing

    struct Failure: Error {
        let message: String
    }

    /// Go's `quote` of `time`: non-ASCII bytes as `\x` escapes.
    static func quote(_ text: String) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = [UInt8(ascii: "\"")]
        for byte in text.utf8 {
            if byte >= 0x80 || byte < 0x20 {
                bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "x")])
                bytes.append(hex[Int(byte >> 4)])
                bytes.append(hex[Int(byte & 0xf)])
            } else {
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") {
                    bytes.append(UInt8(ascii: "\\"))
                }
                bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func text(_ bytes: Bytes) -> String { String(decoding: bytes, as: UTF8.self) }

    /// Go's `getnum`: one or two digits (`fixed` wants two).
    private static func number(_ value: inout Bytes, fixed: Bool) -> Int64? {
        guard isDigit(value, 0) else { return nil }
        let first = Int64(value[value.startIndex] - UInt8(ascii: "0"))
        guard isDigit(value, 1) else {
            if fixed { return nil }
            value = value.dropFirst()
            return first
        }
        let result = first * 10 + Int64(value[value.startIndex + 1] - UInt8(ascii: "0"))
        value = value.dropFirst(2)
        return result
    }

    /// Go's `getnum3`.
    private static func number3(_ value: inout Bytes, fixed: Bool) -> Int64? {
        var result: Int64 = 0
        var count = 0
        while count < 3, isDigit(value, count) {
            result = result * 10 + Int64(value[value.startIndex + count] - UInt8(ascii: "0"))
            count += 1
        }
        if count == 0 || (fixed && count != 3) { return nil }
        value = value.dropFirst(count)
        return result
    }

    /// Go's `atoi`: a sign and digits, all of `text`.
    private static func integer(_ text: Bytes) -> Int64? {
        var text = text
        var negative = false
        if let first = text.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
            negative = first == UInt8(ascii: "-")
            text = text.dropFirst()
        }
        guard let (value, rest) = leadingInteger(text), rest.isEmpty else { return nil }
        return negative ? -value : value
    }

    /// Go's `leadingInt`: the leading digits, which must fit in an `int64`.
    private static func leadingInteger(_ text: Bytes) -> (Int64, Bytes)? {
        var value: Int64 = 0
        var index = text.startIndex
        while index < text.endIndex, isDigit(text[index...], 0) {
            let (product, overflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, carry) = product.addingReportingOverflow(Int64(text[index] - UInt8(ascii: "0")))
            if overflow || carry { return nil }
            value = sum
            index += 1
        }
        return (value, text[index...])
    }

    /// Go's `skip`: `prefix` off `value`, a run of spaces matching any run.
    private static func skip(_ value: inout Bytes, _ prefix: Bytes) -> Bool {
        var prefix = prefix
        let space = UInt8(ascii: " ")
        while let first = prefix.first {
            if first == space {
                if let next = value.first, next != space { return false }
                while prefix.first == space { prefix = prefix.dropFirst() }
                while value.first == space { value = value.dropFirst() }
                continue
            }
            guard value.first == first else { return false }
            prefix = prefix.dropFirst()
            value = value.dropFirst()
        }
        return true
    }

    private static func lookup(_ table: [String], _ value: inout Bytes) -> Int64? {
        for (index, name) in table.enumerated() {
            let wanted = Array(name.utf8)
            guard value.count >= wanted.count else { continue }
            let candidate = value.prefix(wanted.count)
            let same = zip(candidate, wanted).allSatisfy { first, second in
                if first == second { return true }
                let lower = first | 0x20
                return lower == second | 0x20 && lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
            }
            if same {
                value = value.dropFirst(wanted.count)
                return Int64(index)
            }
        }
        return nil
    }

    private static func isCommaOrPeriod(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ".") || byte == UInt8(ascii: ",")
    }

    /// Go's `parseNanoseconds`: the separator and digits of `value[..<count]`.
    private static func nanoseconds(_ value: Bytes, _ count: Int) -> (Int64, String?)? {
        guard let first = value.first, isCommaOrPeriod(first) else { return nil }
        let count = min(count, 10)
        guard let fraction = integer(value.dropFirst().prefix(count - 1)) else { return nil }
        if fraction < 0 { return (0, "fractional second") }
        var result = fraction
        for _ in 0..<(10 - count) { result *= 10 }
        return (result, nil)
    }

    /// Go's `parseTimeZone`: the length of the zone abbreviation `value`
    /// begins with.
    private static func timeZoneLength(_ value: Bytes) -> Int? {
        guard value.count >= 3 else { return nil }
        if matches(value, at: value.startIndex, "ChST") || matches(value, at: value.startIndex, "MeST") {
            return 4
        }
        if matches(value, at: value.startIndex, "GMT") {
            let rest = value.dropFirst(3)
            return rest.isEmpty ? 3 : 3 + signedOffsetLength(rest)
        }
        if value.first == UInt8(ascii: "+") || value.first == UInt8(ascii: "-") {
            let length = signedOffsetLength(value)
            return length > 0 ? length : nil
        }
        var upper = 0
        while upper < 6, upper < value.count {
            let byte = value[value.startIndex + upper]
            if byte < UInt8(ascii: "A") || byte > UInt8(ascii: "Z") { break }
            upper += 1
        }
        switch upper {
        case 5 where value[value.startIndex + 4] == UInt8(ascii: "T"): return 5
        case 4 where value[value.startIndex + 3] == UInt8(ascii: "T")
            || matches(value, at: value.startIndex, "WITA"):
            return 4
        case 3: return 3
        default: return nil
        }
    }

    /// Go's `parseSignedOffset`: a sign and an hour from -23 to +23.
    private static func signedOffsetLength(_ value: Bytes) -> Int {
        guard let sign = value.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+"),
            let (hours, rest) = leadingInteger(value.dropFirst()), rest.count < value.count - 1,
            hours <= 23
        else { return 0 }
        return value.count - rest.count
    }

    /// `time.Parse` and `time.ParseInLocation`.
    static func parse(
        layout fullLayout: String, value fullValue: String, defaultLocation: GoTimeLocation,
        local: GoTimeLocation
    ) -> Result<GoTime, Failure> {
        if fullLayout == rfc3339 || fullLayout == rfc3339Nano,
            let parsed = parseRFC3339(Array(fullValue.utf8)[...], local: local)
        {
            return .success(parsed)
        }
        func failure(_ layoutElement: Bytes, _ valueElement: Bytes, _ message: String) -> Result<GoTime, Failure> {
            if message.isEmpty {
                return .failure(
                    Failure(
                        message: "parsing time " + quote(fullValue) + " as " + quote(fullLayout)
                            + ": cannot parse " + quote(text(valueElement)) + " as "
                            + quote(text(layoutElement))))
            }
            return .failure(Failure(message: "parsing time " + quote(fullValue) + message))
        }
        var layout = Array(fullLayout.utf8)[...]
        var value = Array(fullValue.utf8)[...]
        var rangeError = ""
        var amSet = false
        var pmSet = false
        var year: Int64 = 0
        var month: Int64 = -1
        var day: Int64 = -1
        var yearDay: Int64 = -1
        var hour: Int64 = 0
        var minute: Int64 = 0
        var second: Int64 = 0
        var nanosecond: Int64 = 0
        var zone: GoTimeLocation?
        var zoneOffset: Int64 = -1
        var zoneName = ""
        while true {
            let (prefix, chunk, suffix) = nextChunk(layout)
            let chunkText = layout[prefix.endIndex..<suffix.startIndex]
            if !skip(&value, prefix) { return failure(prefix, value, "") }
            if chunk == 0 {
                if !value.isEmpty {
                    return failure(Bytes(), value, ": extra text: " + quote(text(value)))
                }
                break
            }
            layout = suffix
            let hold = value
            var bad = false
            switch chunk & mask {
            case self.year:
                guard value.count >= 2, let parsed = integer(value.prefix(2)) else {
                    bad = true
                    break
                }
                value = value.dropFirst(2)
                year = parsed >= 69 ? parsed + 1900 : parsed + 2000
            case longYear:
                guard value.count >= 4, isDigit(value, 0), let parsed = integer(value.prefix(4))
                else {
                    bad = true
                    break
                }
                value = value.dropFirst(4)
                year = parsed
            case self.month:
                if let found = lookup(shortMonthNames, &value) { month = found + 1 } else { bad = true }
            case longMonth:
                if let found = lookup(GoCalendar.longMonthNames, &value) {
                    month = found + 1
                } else {
                    bad = true
                }
            case numMonth, zeroMonth:
                if let parsed = number(&value, fixed: chunk == zeroMonth) {
                    month = parsed
                    if month <= 0 || month > 12 { rangeError = "month" }
                } else {
                    bad = true
                }
            case weekDay: bad = lookup(shortDayNames, &value) == nil
            case longWeekDay: bad = lookup(GoCalendar.longDayNames, &value) == nil
            case self.day, underDay, zeroDay:
                if chunk == underDay, value.first == UInt8(ascii: " ") { value = value.dropFirst() }
                if let parsed = number(&value, fixed: chunk == zeroDay) { day = parsed } else { bad = true }
            case underYearDay, zeroYearDay:
                for _ in 0..<2 where chunk == underYearDay && value.first == UInt8(ascii: " ") {
                    value = value.dropFirst()
                }
                if let parsed = number3(&value, fixed: chunk == zeroYearDay) {
                    yearDay = parsed
                } else {
                    bad = true
                }
            case self.hour:
                if let parsed = number(&value, fixed: false) {
                    hour = parsed
                    if hour >= 24 { rangeError = "hour" }
                } else {
                    bad = true
                }
            case hour12, zeroHour12:
                if let parsed = number(&value, fixed: chunk == zeroHour12) {
                    hour = parsed
                    if hour > 12 { rangeError = "hour" }
                } else {
                    bad = true
                }
            case self.minute, zeroMinute:
                if let parsed = number(&value, fixed: chunk == zeroMinute) {
                    minute = parsed
                    if minute >= 60 { rangeError = "minute" }
                } else {
                    bad = true
                }
            case self.second, zeroSecond:
                guard let parsed = number(&value, fixed: chunk == zeroSecond) else {
                    bad = true
                    break
                }
                second = parsed
                if second >= 60 {
                    rangeError = "second"
                    break
                }
                // A fractional second the layout does not have.
                if value.count >= 2, isCommaOrPeriod(value[value.startIndex]), isDigit(value, 1) {
                    let next = nextChunk(layout).chunk & mask
                    if next == fracSecond0 || next == fracSecond9 { break }
                    var count = 2
                    while count < value.count, isDigit(value, count) { count += 1 }
                    if let (parsed, range) = nanoseconds(value, count) {
                        nanosecond = parsed
                        rangeError = range ?? ""
                    } else {
                        bad = true
                    }
                    value = value.dropFirst(count)
                }
            case pm, lowerPM:
                guard value.count >= 2 else {
                    bad = true
                    break
                }
                let marker = text(value.prefix(2))
                value = value.dropFirst(2)
                let (afternoon, morning) = chunk == pm ? ("PM", "AM") : ("pm", "am")
                if marker == afternoon {
                    pmSet = true
                } else if marker == morning {
                    amSet = true
                } else {
                    bad = true
                }
            case iso8601TZ, iso8601ShortTZ, iso8601ColonTZ, iso8601SecondsTZ,
                iso8601ColonSecondsTZ, numTZ, numShortTZ, numColonTZ, numSecondsTZ,
                numColonSecondsTZ:
                let iso = [
                    iso8601TZ, iso8601ShortTZ, iso8601ColonTZ, iso8601SecondsTZ,
                    iso8601ColonSecondsTZ,
                ].contains(chunk)
                if iso, value.first == UInt8(ascii: "Z") {
                    value = value.dropFirst()
                    zone = .utc
                    break
                }
                let bytes = Array(value)
                var parts: (sign: UInt8, hour: [UInt8], minute: [UInt8], second: [UInt8])
                let zeros = Array("00".utf8)
                if chunk == iso8601ColonTZ || chunk == numColonTZ {
                    guard bytes.count >= 6, bytes[3] == UInt8(ascii: ":") else {
                        bad = true
                        break
                    }
                    parts = (bytes[0], Array(bytes[1..<3]), Array(bytes[4..<6]), zeros)
                    value = value.dropFirst(6)
                } else if chunk == numShortTZ || chunk == iso8601ShortTZ {
                    guard bytes.count >= 3 else {
                        bad = true
                        break
                    }
                    parts = (bytes[0], Array(bytes[1..<3]), zeros, zeros)
                    value = value.dropFirst(3)
                } else if chunk == iso8601ColonSecondsTZ || chunk == numColonSecondsTZ {
                    guard bytes.count >= 9, bytes[3] == UInt8(ascii: ":"),
                        bytes[6] == UInt8(ascii: ":")
                    else {
                        bad = true
                        break
                    }
                    parts = (bytes[0], Array(bytes[1..<3]), Array(bytes[4..<6]), Array(bytes[7..<9]))
                    value = value.dropFirst(9)
                } else if chunk == iso8601SecondsTZ || chunk == numSecondsTZ {
                    guard bytes.count >= 7 else {
                        bad = true
                        break
                    }
                    parts = (bytes[0], Array(bytes[1..<3]), Array(bytes[3..<5]), Array(bytes[5..<7]))
                    value = value.dropFirst(7)
                } else {
                    guard bytes.count >= 5 else {
                        bad = true
                        break
                    }
                    parts = (bytes[0], Array(bytes[1..<3]), Array(bytes[3..<5]), zeros)
                    value = value.dropFirst(5)
                }
                var hourText = parts.hour[...]
                var minuteText = parts.minute[...]
                var secondText = parts.second[...]
                guard let hours = number(&hourText, fixed: true),
                    let minutes = number(&minuteText, fixed: true),
                    let seconds = number(&secondText, fixed: true)
                else {
                    bad = true
                    break
                }
                // `>`, not `>=`: some write offsets of 24 hours.
                if hours > 24 { rangeError = "time zone offset hour" }
                if minutes > 60 { rangeError = "time zone offset minute" }
                if seconds > 60 { rangeError = "time zone offset second" }
                zoneOffset = (hours * 60 + minutes) * 60 + seconds
                switch parts.sign {
                case UInt8(ascii: "+"): break
                case UInt8(ascii: "-"): zoneOffset = -zoneOffset
                default: bad = true
                }
            case tz:
                if matches(value, at: value.startIndex, "UTC") {
                    zone = .utc
                    value = value.dropFirst(3)
                    break
                }
                guard let length = timeZoneLength(value) else {
                    bad = true
                    break
                }
                zoneName = text(value.prefix(length))
                value = value.dropFirst(length)
            case fracSecond0:
                // As many digits as the layout has.
                let count = 1 + (chunk >> argumentShift) & 0xfff
                guard value.count >= count, let (parsed, range) = nanoseconds(value, count) else {
                    bad = true
                    break
                }
                nanosecond = parsed
                rangeError = range ?? ""
                value = value.dropFirst(count)
            case fracSecond9:
                guard value.count >= 2, isCommaOrPeriod(value[value.startIndex]), isDigit(value, 1)
                else { break }
                // Any number of digits, as a second without a fraction in the
                // layout would take.
                var digits = 0
                while digits + 1 < value.count, isDigit(value, digits + 1) { digits += 1 }
                guard let (parsed, range) = nanoseconds(value, 1 + digits) else {
                    bad = true
                    break
                }
                nanosecond = parsed
                rangeError = range ?? ""
                value = value.dropFirst(1 + digits)
            default: break
            }
            if !rangeError.isEmpty {
                return failure(chunkText, value, ": " + rangeError + " out of range")
            }
            if bad { return failure(chunkText, hold, "") }
        }
        if pmSet, hour < 12 {
            hour += 12
        } else if amSet, hour == 12 {
            hour = 0
        }
        if yearDay >= 0 {
            var foundMonth: Int64 = 0
            var foundDay: Int64 = 0
            var yearDay = yearDay
            if GoCalendar.isLeap(year) {
                if yearDay == 31 + 29 {
                    foundMonth = 2
                    foundDay = 29
                } else if yearDay > 31 + 29 {
                    yearDay -= 1
                }
            }
            if yearDay < 1 || yearDay > 365 {
                return failure(Bytes(), value, ": day-of-year out of range")
            }
            if foundMonth == 0 {
                let before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365] as [Int64]
                foundMonth = (yearDay - 1) / 31 + 1
                if before[Int(foundMonth)] < yearDay { foundMonth += 1 }
                foundDay = yearDay - before[Int(foundMonth - 1)]
            }
            if month >= 0, month != foundMonth {
                return failure(Bytes(), value, ": day-of-year does not match month")
            }
            month = foundMonth
            if day >= 0, day != foundDay {
                return failure(Bytes(), value, ": day-of-year does not match day")
            }
            day = foundDay
        } else {
            if month < 0 { month = 1 }
            if day < 0 { day = 1 }
        }
        if day < 1 || day > GoCalendar.daysIn(month: month, year: year) {
            return failure(Bytes(), value, ": day out of range")
        }
        func date(_ location: GoTimeLocation) -> GoTime {
            GoTime.make(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                nanosecond: nanosecond, location: location)
        }
        if let zone { return .success(date(zone)) }
        if zoneOffset != -1 {
            var time = date(.utc)
            time.seconds &-= zoneOffset
            // The local location, when it has this offset; here that is
            // UTC.
            if zoneOffset == local.offset, zoneName.isEmpty || zoneName == local.zoneName {
                return .success(time.setting(local))
            }
            return .success(time.setting(.fixed(name: zoneName, offset: zoneOffset)))
        }
        if !zoneName.isEmpty {
            var time = date(.utc)
            if zoneName == local.zoneName {
                time.seconds &-= local.offset
                return .success(time.setting(local))
            }
            var offset: Int64 = 0
            if zoneName.count > 3, zoneName.hasPrefix("GMT") {
                offset = (integer(Array(zoneName.utf8).dropFirst(3)) ?? 0) * 3_600
            }
            return .success(time.setting(.fixed(name: zoneName, offset: offset)))
        }
        return .success(date(defaultLocation))
    }

    /// Go's `parseRFC3339`, which `Parse` tries first for the two RFC 3339
    /// layouts: nil when `text` is not exactly that.
    private static func parseRFC3339(_ text: Bytes, local: GoTimeLocation) -> GoTime? {
        var ok = true
        func unsigned(_ range: Range<Int>, _ minimum: Int64, _ maximum: Int64) -> Int64 {
            var result: Int64 = 0
            for byte in text[(text.startIndex + range.lowerBound)..<(text.startIndex + range.upperBound)] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    ok = false
                    return minimum
                }
                result = result * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            if result < minimum || result > maximum {
                ok = false
                return minimum
            }
            return result
        }
        func byte(_ offset: Int) -> UInt8 { text[text.startIndex + offset] }
        guard text.count >= 19 else { return nil }
        let year = unsigned(0..<4, 0, 9_999)
        let month = unsigned(5..<7, 1, 12)
        let day = unsigned(8..<10, 1, GoCalendar.daysIn(month: month, year: year))
        let hour = unsigned(11..<13, 0, 23)
        let minute = unsigned(14..<16, 0, 59)
        let second = unsigned(17..<19, 0, 59)
        guard ok, byte(4) == UInt8(ascii: "-"), byte(7) == UInt8(ascii: "-"),
            byte(10) == UInt8(ascii: "T"), byte(13) == UInt8(ascii: ":"),
            byte(16) == UInt8(ascii: ":")
        else { return nil }
        var rest = text.dropFirst(19)
        var nanosecond: Int64 = 0
        if rest.count >= 2, rest.first == UInt8(ascii: "."), isDigit(rest, 1) {
            var count = 2
            while count < rest.count, isDigit(rest, count) { count += 1 }
            nanosecond = nanoseconds(rest, count)?.0 ?? 0
            rest = rest.dropFirst(count)
        }
        var time = GoTime.make(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second,
            nanosecond: nanosecond, location: .utc)
        if rest.count == 1, rest.first == UInt8(ascii: "Z") { return time }
        guard rest.count == 6 else { return nil }
        let zone = Array(rest)[...]
        let hours = { () -> Int64 in
            var result: Int64 = 0
            for byte in zone[1..<3] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { ok = false; return 0 }
                result = result * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            if result > 23 { ok = false; return 0 }
            return result
        }()
        let minutes = { () -> Int64 in
            var result: Int64 = 0
            for byte in zone[4..<6] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { ok = false; return 0 }
                result = result * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            if result > 59 { ok = false; return 0 }
            return result
        }()
        guard ok, zone[0] == UInt8(ascii: "-") || zone[0] == UInt8(ascii: "+"),
            zone[3] == UInt8(ascii: ":")
        else { return nil }
        var offset = (hours * 60 + minutes) * 60
        if zone[0] == UInt8(ascii: "-") { offset = -offset }
        time.seconds &-= offset
        if offset == local.offset { return time.setting(local) }
        return time.setting(.fixed(name: "", offset: offset))
    }
}
