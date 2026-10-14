/// `time.Time` as Go has it: Go's zero time, the calendar, locations, and
/// `Format` and `Parse` with Go's reference layout.
///
/// An image holds a `time.Time` as one value. It was always the integer of
/// its nanoseconds since the Unix epoch, and the integers keep that meaning
/// for every instant in the local location they can name, so an image made
/// before this file runs as it did, `time.Now()` is the integer it was, and
/// an instant from a timer channel needs no conversion. Two integers change
/// meaning: `0` is Go's zero time, January 1 of year 1 in UTC, which is
/// what a variable, a field, and `time.Time{}` are zeroed to; and an
/// instant whose nanoseconds would be `0`, or would not fit in an `Int64`,
/// or that is in another location, is an array of five values: its seconds
/// since the epoch, its nanoseconds past them, the kind of its location
/// (UTC, local, or a fixed zone), and the zone's name and offset. Every
/// time has exactly one form, so `==` and a map key compare what Go's do:
/// the instant and the location.
///
/// A `*time.Location` is the array of its kind, name, and offset; `nil` is
/// Go's nil pointer, which reads as UTC. There is no time zone database:
/// `time.Local` is UTC, as Go's is when `TZ` is `UTC` (its name is `UTC`),
/// and a location is UTC, local, or a fixed zone. Times have no monotonic
/// reading, so `String` prints no `m=` part.
///
/// Pure functions of their operands and of the current instant; no process
/// or executor state.
struct GoTime: Equatable, Sendable {
    /// Seconds since the Unix epoch, and the nanoseconds past them.
    var seconds: Int64
    var nanoseconds: Int64
    var location: GoTimeLocation

    /// The Unix seconds of January 1 of year 1, Go's zero time.
    static let zeroSeconds: Int64 = -62_135_596_800
    static let zero = GoTime(seconds: zeroSeconds, nanoseconds: 0, location: .utc)
    static let nanosecondsPerSecond: Int64 = 1_000_000_000

    /// The instant `nanoseconds` after the epoch, in `location`.
    init(unixNanoseconds value: Int64, location: GoTimeLocation) {
        seconds = GoCalendar.floorDivide(value, Self.nanosecondsPerSecond)
        nanoseconds = GoCalendar.floorModulo(value, Self.nanosecondsPerSecond)
        self.location = location
    }

    init(seconds: Int64, nanoseconds: Int64, location: GoTimeLocation) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
        self.location = location
    }

    /// The time an operand holds, or nil when it holds none.
    init?(_ value: GoValue) {
        switch value {
        case .int(0): self = .zero
        case .int(let nanoseconds): self.init(unixNanoseconds: nanoseconds, location: .local)
        case .array(let parts) where parts.count == 5:
            guard case .int(let seconds) = parts[0], case .int(let nanoseconds) = parts[1],
                let location = GoTimeLocation(kind: parts[2], name: parts[3], offset: parts[4])
            else { return nil }
            self.init(seconds: seconds, nanoseconds: nanoseconds, location: location)
        default: return nil
        }
    }

    /// The one value that holds this time. See the type's comment.
    var value: GoValue {
        if self == .zero { return .int(0) }
        if location == .local {
            let (product, overflow) = seconds.multipliedReportingOverflow(
                by: Self.nanosecondsPerSecond)
            let (sum, carry) = product.addingReportingOverflow(nanoseconds)
            if !overflow, !carry, sum != 0 { return .int(sum) }
        }
        let (kind, name, offset) = location.parts
        return .array([.int(seconds), .int(nanoseconds), kind, name, offset])
    }

    var isZero: Bool { seconds == Self.zeroSeconds && nanoseconds == 0 }

    func isBefore(_ other: GoTime) -> Bool {
        seconds < other.seconds || (seconds == other.seconds && nanoseconds < other.nanoseconds)
    }

    func isEqual(_ other: GoTime) -> Bool {
        seconds == other.seconds && nanoseconds == other.nanoseconds
    }

    /// Go's `t.Add(d)`: seconds saturate where Go's do.
    func adding(_ duration: Int64) -> GoTime {
        var addedSeconds = duration / Self.nanosecondsPerSecond
        var sum = nanoseconds + duration % Self.nanosecondsPerSecond
        if sum >= Self.nanosecondsPerSecond {
            addedSeconds += 1
            sum -= Self.nanosecondsPerSecond
        } else if sum < 0 {
            addedSeconds -= 1
            sum += Self.nanosecondsPerSecond
        }
        var result = self
        result.nanoseconds = sum
        result.seconds = Self.saturatingAdd(seconds, addedSeconds)
        return result
    }

    private static func saturatingAdd(_ base: Int64, _ delta: Int64) -> Int64 {
        let (sum, overflow) = base.addingReportingOverflow(delta)
        guard overflow else { return sum }
        return delta > 0 ? Int64.max : -Int64.max
    }

    /// Go's `t.Sub(u)`: the duration, or the least or greatest one when it
    /// does not fit.
    func subtracting(_ other: GoTime) -> Int64 {
        let duration = (seconds &- other.seconds) &* Self.nanosecondsPerSecond
            &+ (nanoseconds - other.nanoseconds)
        if other.adding(duration).isEqual(self) { return duration }
        return isBefore(other) ? Int64.min : Int64.max
    }

    /// Seconds since the epoch on the clock of the time's location.
    var localSeconds: Int64 { seconds &+ location.offset }

    /// Days since the epoch, and seconds into the day, on that clock.
    var localDay: (days: Int64, second: Int64) {
        (
            GoCalendar.floorDivide(localSeconds, 86_400),
            GoCalendar.floorModulo(localSeconds, 86_400)
        )
    }

    var date: (year: Int64, month: Int64, day: Int64) {
        GoCalendar.civil(fromDays: localDay.days)
    }

    var clock: (hour: Int64, minute: Int64, second: Int64) {
        let second = localDay.second
        return (second / 3_600, second % 3_600 / 60, second % 60)
    }

    /// Sunday is 0. The epoch was a Thursday.
    var weekday: Int64 { GoCalendar.floorModulo(localDay.days &+ 4, 7) }

    /// The day of the year, from 1.
    var yearDay: Int64 {
        let days = localDay.days
        let year = GoCalendar.civil(fromDays: days).year
        return days - GoCalendar.days(year: year, month: 1, day: 1) + 1
    }

    /// Go's `ISOWeek`: the year and week of the Thursday of the time's
    /// week, which begins on a Monday.
    var isoWeek: (year: Int64, week: Int64) {
        let monday = (weekday + 6) % 7
        let thursday = localDay.days &+ (3 - monday)
        let year = GoCalendar.civil(fromDays: thursday).year
        let yearDay = thursday - GoCalendar.days(year: year, month: 1, day: 1)
        return (year, yearDay / 7 + 1)
    }

    /// The remainder of the time since Go's zero time divided by `divisor`,
    /// which is positive: Go's `div`.
    func remainder(dividingBy divisor: Int64) -> Int64 {
        var wholeSeconds = seconds &- Self.zeroSeconds
        var fraction = nanoseconds
        let negative = wholeSeconds < 0
        if negative {
            wholeSeconds = 0 &- wholeSeconds
            fraction = -fraction
            if fraction < 0 {
                fraction += Self.nanosecondsPerSecond
                wholeSeconds -= 1
            }
        }
        // The nanoseconds take more than 64 bits; their remainder does not.
        let product = UInt64(bitPattern: wholeSeconds).multipliedFullWidth(
            by: UInt64(Self.nanosecondsPerSecond))
        var (low, carry) = product.low.addingReportingOverflow(UInt64(fraction))
        var high = product.high
        if carry { high &+= 1 }
        let unsignedDivisor = UInt64(divisor)
        high %= unsignedDivisor
        let remainder = unsignedDivisor.dividingFullWidth((high, low)).remainder
        low = remainder
        var result = Int64(low)
        if negative, result != 0 { result = divisor - result }
        return result
    }

    func truncated(to duration: Int64) -> GoTime {
        guard duration > 0 else { return self }
        return adding(-remainder(dividingBy: duration))
    }

    func rounded(to duration: Int64) -> GoTime {
        guard duration > 0 else { return self }
        let remainder = remainder(dividingBy: duration)
        if UInt64(remainder) &+ UInt64(remainder) < UInt64(duration) {
            return adding(-remainder)
        }
        return adding(duration &- remainder)
    }

    func setting(_ location: GoTimeLocation) -> GoTime {
        var result = self
        result.location = location
        return result
    }

    /// Go's `time.Date`, with each field normalized into the next.
    static func make(
        year: Int64, month: Int64, day: Int64, hour: Int64, minute: Int64, second: Int64,
        nanosecond: Int64, location: GoTimeLocation
    ) -> GoTime {
        let (year, monthIndex) = GoCalendar.normalize(year, month &- 1, 12)
        var (second, nanosecond) = GoCalendar.normalize(second, nanosecond, nanosecondsPerSecond)
        var minute = minute
        var hour = hour
        var day = day
        (minute, second) = GoCalendar.normalize(minute, second, 60)
        (hour, minute) = GoCalendar.normalize(hour, minute, 60)
        (day, hour) = GoCalendar.normalize(day, hour, 24)
        let days = GoCalendar.days(year: year, month: monthIndex &+ 1, day: 1) &+ (day &- 1)
        let local = days &* 86_400 &+ hour &* 3_600 &+ minute &* 60 &+ second
        return GoTime(
            seconds: local &- location.offset, nanoseconds: nanosecond, location: location)
    }
}

/// Where a time is: Go's UTC (a nil location), `time.Local`, which is UTC
/// here, or a zone of `time.FixedZone`.
enum GoTimeLocation: Equatable, Sendable {
    case utc
    case local
    case fixed(name: String, offset: Int64)

    init?(kind: GoValue, name: GoValue, offset: GoValue) {
        guard case .int(let kind) = kind, case .string(let name) = name,
            case .int(let offset) = offset
        else { return nil }
        switch kind {
        case 0: self = .utc
        case 1: self = .local
        default: self = .fixed(name: name, offset: offset)
        }
    }

    /// The location a `*time.Location` operand points to, where `nil`
    /// stands for UTC; nil when the operand is no location.
    init?(pointer value: GoValue) {
        switch value {
        case .nilValue: self = .utc
        case .array(let parts) where parts.count == 3:
            self.init(kind: parts[0], name: parts[1], offset: parts[2])
        default: return nil
        }
    }

    var parts: (kind: GoValue, name: GoValue, offset: GoValue) {
        switch self {
        case .utc: return (.int(0), .string(""), .int(0))
        case .local: return (.int(1), .string(""), .int(0))
        case .fixed(let name, let offset): return (.int(2), .string(name), .int(offset))
        }
    }

    /// The `*time.Location` that points here.
    var pointerValue: GoValue {
        let (kind, name, offset) = parts
        return .array([kind, name, offset])
    }

    /// What `String` gives: the name `LoadLocation` or `FixedZone` had.
    var name: String {
        if case .fixed(let name, _) = self { return name }
        return "UTC"
    }

    /// The abbreviation of the zone and its seconds east of UTC.
    var zoneName: String { name }

    var offset: Int64 {
        if case .fixed(_, let offset) = self { return offset }
        return 0
    }
}

/// The calendar and the natives of `time.Time`, `*time.Location`,
/// `time.Month`, and `time.Weekday`.
enum GoCalendar {
    static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    static func floorModulo(_ value: Int64, _ divisor: Int64) -> Int64 {
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }

    /// Go's `norm`: `low` brought into `0..<base`, the difference carried
    /// into `high`.
    static func normalize(_ high: Int64, _ low: Int64, _ base: Int64) -> (Int64, Int64) {
        var high = high
        var low = low
        if low < 0 {
            let carried = (-(low &+ 1)) / base + 1
            high &-= carried
            low &+= carried &* base
        }
        if low >= base {
            let carried = low / base
            high &+= carried
            low &-= carried &* base
        }
        return (high, low)
    }

    /// Days since the epoch of a day of the proleptic Gregorian calendar,
    /// with `month` in 1...12 and `day` counted on from the month's first.
    static func days(year: Int64, month: Int64, day: Int64) -> Int64 {
        let year = month <= 2 ? year &- 1 : year
        let era = (year >= 0 ? year : year &- 399) / 400
        let yearOfEra = year &- era &* 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 &+ day &- 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 &+ dayOfYear
        return era &* 146_097 &+ dayOfEra &- 719_468
    }

    /// The day `days` after the epoch.
    static func civil(fromDays days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days &+ 719_468
        let era = (shifted >= 0 ? shifted : shifted &- 146_096) / 146_097
        let dayOfEra = shifted &- era &* 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra &+ era &* 400
        return (month <= 2 ? year &+ 1 : year, month, day)
    }

    static func isLeap(_ year: Int64) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    static func daysIn(month: Int64, year: Int64) -> Int64 {
        if month == 2 { return isLeap(year) ? 29 : 28 }
        return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][Int(month - 1)]
    }

    static let longMonthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December",
    ]
    static let longDayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    /// `Month.String`: a name, or Go's mark for a number that is none.
    static func monthName(_ month: Int64) -> String {
        guard (1...12).contains(month) else { return "%!Month(\(UInt64(bitPattern: month)))" }
        return longMonthNames[Int(month - 1)]
    }

    static func weekdayName(_ day: Int64) -> String {
        guard (0...6).contains(day) else { return "%!Weekday(\(UInt64(bitPattern: day)))" }
        return longDayNames[Int(day)]
    }

    // MARK: Natives

    /// Type names the methods below are found under at run time.
    static let timeTypeName = "time.Time"
    static let locationTypeName = "*time.Location"
    static let monthTypeName = "time.Month"
    static let weekdayTypeName = "time.Weekday"

    /// The reserved call names of the natives here, with how many operands
    /// each takes and how many results it gives.
    static let natives: [String: (operands: Int, results: Int)] = [
        "$time.Now": (0, 1),
        "$time.Since": (1, 1),
        "$time.Until": (1, 1),
        "$time.Unix": (2, 1),
        "$time.UnixMilli": (1, 1),
        "$time.UnixMicro": (1, 1),
        "$time.Date": (8, 1),
        "$time.Parse": (2, 2),
        "$time.ParseInLocation": (3, 2),
        "$time.FixedZone": (2, 1),
        "$time.LoadLocation": (1, 2),
        "$time.location": (1, 1),
        "$time.Time.Unix": (1, 1),
        "$time.Time.UnixMilli": (1, 1),
        "$time.Time.UnixMicro": (1, 1),
        "$time.Time.UnixNano": (1, 1),
        "$time.Time.Sub": (2, 1),
        "$time.Time.Add": (2, 1),
        "$time.Time.Before": (2, 1),
        "$time.Time.After": (2, 1),
        "$time.Time.Equal": (2, 1),
        "$time.Time.Compare": (2, 1),
        "$time.Time.IsZero": (1, 1),
        "$time.Time.Year": (1, 1),
        "$time.Time.Month": (1, 1),
        "$time.Time.Day": (1, 1),
        "$time.Time.Hour": (1, 1),
        "$time.Time.Minute": (1, 1),
        "$time.Time.Second": (1, 1),
        "$time.Time.Nanosecond": (1, 1),
        "$time.Time.Weekday": (1, 1),
        "$time.Time.YearDay": (1, 1),
        "$time.Time.Date": (1, 3),
        "$time.Time.Clock": (1, 3),
        "$time.Time.ISOWeek": (1, 2),
        "$time.Time.AddDate": (4, 1),
        "$time.Time.Truncate": (2, 1),
        "$time.Time.Round": (2, 1),
        "$time.Time.Format": (2, 1),
        "$time.Time.AppendFormat": (3, 1),
        "$time.Time.String": (1, 1),
        "$time.Time.GoString": (1, 1),
        "$time.Time.MarshalText": (1, 2),
        "$time.Time.UTC": (1, 1),
        "$time.Time.Local": (1, 1),
        "$time.Time.In": (2, 1),
        "$time.Time.Location": (1, 1),
        "$time.Time.Zone": (1, 2),
        "$time.Location.String": (1, 1),
        "$time.Month.String": (1, 1),
        "$time.Weekday.String": (1, 1),
    ]

    /// A result of a native: a value, the bytes of a new `[]byte`, or an
    /// `error` with this message (none for nil).
    enum Result {
        case value(GoValue)
        case bytes([UInt8])
        case error(String?)
    }

    /// The results of the native `name` on `operands` when the current
    /// instant is `now`. `bytes` reads a `[]byte` operand.
    static func call(
        _ name: String, _ operands: [GoValue], now: Int64,
        bytes: (GoValue) throws -> [UInt8]
    ) throws -> [Result] {
        func time(_ index: Int) throws -> GoTime {
            guard let time = GoTime(operands[index]) else { throw GoRuntimeError.typeMismatch }
            return time
        }
        func integer(_ index: Int) throws -> Int64 {
            guard case .int(let value) = operands[index] else {
                throw GoRuntimeError.typeMismatch
            }
            return value
        }
        func text(_ index: Int) throws -> String {
            guard case .string(let value) = operands[index] else {
                throw GoRuntimeError.typeMismatch
            }
            return value
        }
        func location(_ index: Int) throws -> GoTimeLocation {
            guard let location = GoTimeLocation(pointer: operands[index]) else {
                throw GoRuntimeError.typeMismatch
            }
            return location
        }
        func one(_ value: GoValue) -> [Result] { [.value(value)] }
        let current = GoTime(unixNanoseconds: now, location: .local)
        switch name {
        case "$time.Now": return one(current.value)
        case "$time.Since": return one(.int(current.subtracting(try time(0))))
        case "$time.Until": return one(.int(try time(0).subtracting(current)))
        case "$time.Unix": return one(unix(try integer(0), try integer(1)).value)
        case "$time.UnixMilli":
            let value = try integer(0)
            return one(unix(value / 1_000, value % 1_000 * 1_000_000).value)
        case "$time.UnixMicro":
            let value = try integer(0)
            return one(unix(value / 1_000_000, value % 1_000_000 * 1_000).value)
        case "$time.Date":
            if operands[7] == .nilValue {
                throw GoRuntimePanic(text: "time: missing Location in call to Date")
            }
            return one(
                GoTime.make(
                    year: try integer(0), month: try integer(1), day: try integer(2),
                    hour: try integer(3), minute: try integer(4), second: try integer(5),
                    nanosecond: try integer(6), location: try location(7)
                ).value)
        case "$time.Parse", "$time.ParseInLocation":
            let defaultLocation: GoTimeLocation =
                name == "$time.Parse" ? .utc : try location(2)
            let local: GoTimeLocation = name == "$time.Parse" ? .local : defaultLocation
            switch GoTimeFormat.parse(
                layout: try text(0), value: try text(1), defaultLocation: defaultLocation,
                local: local)
            {
            case .success(let parsed): return [.value(parsed.value), .error(nil)]
            case .failure(let failure): return [.value(.int(0)), .error(failure.message)]
            }
        case "$time.FixedZone":
            return one(GoTimeLocation.fixed(name: try text(0), offset: try integer(1)).pointerValue)
        case "$time.LoadLocation":
            switch try text(0) {
            case "", "UTC": return [.value(GoTimeLocation.utc.pointerValue), .error(nil)]
            case "Local": return [.value(GoTimeLocation.local.pointerValue), .error(nil)]
            case let other:
                return [.value(.nilValue), .error("unknown time zone " + other)]
            }
        case "$time.location":
            // `time.UTC` and `time.Local` of the library's text.
            return one((try integer(0) == 0 ? GoTimeLocation.utc : .local).pointerValue)
        case "$time.Location.String": return one(.string(try location(0).name))
        case "$time.Month.String": return one(.string(monthName(try integer(0))))
        case "$time.Weekday.String": return one(.string(weekdayName(try integer(0))))
        case "$time.Time.AppendFormat":
            let formatted = GoTimeFormat.format(try time(0), layout: try text(2))
            return [.bytes(try bytes(operands[1]) + formatted)]
        case "$time.Time.MarshalText":
            let time = try time(0)
            if let failure = GoTimeFormat.strictRFC3339Failure(time) {
                return [.value(.nilValue), .error("Time.MarshalText: " + failure)]
            }
            return [.bytes(GoTimeFormat.format(time, layout: GoTimeFormat.rfc3339Nano)), .error(nil)]
        default:
            return try method(name, operands, time: time, integer: integer, location: location)
                .map(Result.value)
        }
    }

    /// Go's `time.Unix`: nanoseconds out of range carried into seconds.
    static func unix(_ seconds: Int64, _ nanoseconds: Int64) -> GoTime {
        var seconds = seconds
        var nanoseconds = nanoseconds
        if nanoseconds < 0 || nanoseconds >= GoTime.nanosecondsPerSecond {
            let carried = nanoseconds / GoTime.nanosecondsPerSecond
            seconds &+= carried
            nanoseconds -= carried * GoTime.nanosecondsPerSecond
            if nanoseconds < 0 {
                nanoseconds += GoTime.nanosecondsPerSecond
                seconds &-= 1
            }
        }
        return GoTime(seconds: seconds, nanoseconds: nanoseconds, location: .local)
    }

    /// The methods of a time whose results are values alone.
    private static func method(
        _ name: String, _ operands: [GoValue], time: (Int) throws -> GoTime,
        integer: (Int) throws -> Int64, location: (Int) throws -> GoTimeLocation
    ) throws -> [GoValue] {
        let receiver = try time(0)
        let nanosecond = GoTime.nanosecondsPerSecond
        switch name {
        case "$time.Time.Unix": return [.int(receiver.seconds)]
        case "$time.Time.UnixMilli":
            return [.int(receiver.seconds &* 1_000 &+ receiver.nanoseconds / 1_000_000)]
        case "$time.Time.UnixMicro":
            return [.int(receiver.seconds &* 1_000_000 &+ receiver.nanoseconds / 1_000)]
        case "$time.Time.UnixNano":
            return [.int(receiver.seconds &* nanosecond &+ receiver.nanoseconds)]
        case "$time.Time.Sub": return [.int(receiver.subtracting(try time(1)))]
        case "$time.Time.Add": return [receiver.adding(try integer(1)).value]
        case "$time.Time.Before": return [.bool(receiver.isBefore(try time(1)))]
        case "$time.Time.After": return [.bool(try time(1).isBefore(receiver))]
        case "$time.Time.Equal": return [.bool(receiver.isEqual(try time(1)))]
        case "$time.Time.Compare":
            let other = try time(1)
            if receiver.isBefore(other) { return [.int(-1)] }
            return [.int(other.isBefore(receiver) ? 1 : 0)]
        case "$time.Time.IsZero": return [.bool(receiver.isZero)]
        case "$time.Time.Year": return [.int(receiver.date.year)]
        case "$time.Time.Month": return [.int(receiver.date.month)]
        case "$time.Time.Day": return [.int(receiver.date.day)]
        case "$time.Time.Hour": return [.int(receiver.clock.hour)]
        case "$time.Time.Minute": return [.int(receiver.clock.minute)]
        case "$time.Time.Second": return [.int(receiver.clock.second)]
        case "$time.Time.Nanosecond": return [.int(receiver.nanoseconds)]
        case "$time.Time.Weekday": return [.int(receiver.weekday)]
        case "$time.Time.YearDay": return [.int(receiver.yearDay)]
        case "$time.Time.Date":
            let date = receiver.date
            return [.int(date.year), .int(date.month), .int(date.day)]
        case "$time.Time.Clock":
            let clock = receiver.clock
            return [.int(clock.hour), .int(clock.minute), .int(clock.second)]
        case "$time.Time.ISOWeek":
            let week = receiver.isoWeek
            return [.int(week.year), .int(week.week)]
        case "$time.Time.AddDate":
            let date = receiver.date
            let clock = receiver.clock
            return [
                GoTime.make(
                    year: date.year &+ (try integer(1)), month: date.month &+ (try integer(2)),
                    day: date.day &+ (try integer(3)), hour: clock.hour, minute: clock.minute,
                    second: clock.second, nanosecond: receiver.nanoseconds,
                    location: receiver.location
                ).value
            ]
        case "$time.Time.Truncate": return [receiver.truncated(to: try integer(1)).value]
        case "$time.Time.Round": return [receiver.rounded(to: try integer(1)).value]
        case "$time.Time.Format":
            guard case .string(let layout) = operands[1] else { throw GoRuntimeError.typeMismatch }
            return [.string(String(decoding: GoTimeFormat.format(receiver, layout: layout), as: UTF8.self))]
        case "$time.Time.String": return [.string(GoTimeFormat.string(receiver))]
        case "$time.Time.GoString": return [.string(GoTimeFormat.goString(receiver))]
        case "$time.Time.UTC": return [receiver.setting(.utc).value]
        case "$time.Time.Local": return [receiver.setting(.local).value]
        case "$time.Time.In":
            if operands[1] == .nilValue {
                throw GoRuntimePanic(text: "time: missing Location in call to Time.In")
            }
            return [receiver.setting(try location(1)).value]
        case "$time.Time.Location":
            return [receiver.location.pointerValue]
        case "$time.Time.Zone":
            return [.string(receiver.location.zoneName), .int(receiver.location.offset)]
        default: throw GoRuntimeError.missingFunction(name)
        }
    }

    // MARK: Methods at run time

    /// What `fmt` prints for `value` of the library type `owner` by its
    /// `String`, or nil when `owner` is none of these types.
    static func text(of value: GoValue, owner: String) -> String? {
        switch owner {
        case timeTypeName: return GoTime(value).map(GoTimeFormat.string)
        case locationTypeName: return GoTimeLocation(pointer: value)?.name
        case monthTypeName:
            guard case .int(let month) = value else { return nil }
            return monthName(month)
        case weekdayTypeName:
            guard case .int(let day) = value else { return nil }
            return weekdayName(day)
        default: return nil
        }
    }

    /// The methods of these types as functions of every program, under the
    /// names a method of a program type has, for a call through an
    /// interface or a method value.
    static let functions: [String: GoBytecodeFunction] = {
        var functions: [String: GoBytecodeFunction] = [:]
        for (native, counts) in natives {
            let name: String
            if native.hasPrefix("$time.Location.") {
                name = "*time.Location." + native.dropFirst("$time.Location.".count)
            } else if native.hasPrefix("$time.Time.") || native.hasPrefix("$time.Month.")
                || native.hasPrefix("$time.Weekday.")
            {
                name = String(native.dropFirst())
            } else {
                continue
            }
            functions[name] = GoBytecodeFunction(
                name: name,
                parameterCount: counts.operands,
                returnCount: counts.results,
                localCount: counts.operands,
                instructions: (0..<counts.operands).map(GoInstruction.load)
                    + [
                        .call(native, argumentCount: counts.operands),
                        .returnValues(count: counts.results),
                    ])
        }
        return functions
    }()

    /// Whether `owner` is one of these types.
    static func isOwner(_ owner: String) -> Bool {
        owner == timeTypeName || owner == locationTypeName || owner == monthTypeName
            || owner == weekdayTypeName
    }
}
