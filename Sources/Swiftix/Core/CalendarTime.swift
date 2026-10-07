/// Foundation-free civil-calendar arithmetic: converts a Unix epoch instant plus
/// a fixed UTC offset into proleptic-Gregorian calendar fields, and renders them
/// with a small `strftime` subset.
///
/// This is the presentation half of the wall-clock seam. The kernel stores and
/// reports instants as epoch seconds (`Kernel.wallClock`); `date`, `cal`,
/// `ls -l`, `stat`, and `who` turn them into text here. There is no time-zone
/// database: a zone is a fixed offset and an abbreviation supplied by the host.
///
/// Concurrency: a pure `Sendable` value type with no shared state.
struct CalendarTime: Sendable, Equatable {
    /// The UTC instant these fields describe, in whole seconds since 1970-01-01.
    let epochSeconds: Int64
    /// Offset of the displayed zone east of UTC, in seconds.
    let utcOffsetSeconds: Int
    /// Abbreviation printed for `%Z` (for example `UTC` or `CST`).
    let zone: String

    let year: Int
    /// 1...12
    let month: Int
    /// 1...31
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    /// 0 = Sunday ... 6 = Saturday.
    let weekday: Int
    /// 1...366
    let dayOfYear: Int

    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let weekdayFullNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
    static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    static let monthFullNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    init(epochSeconds: Int64, utcOffsetSeconds: Int = 0, zone: String = "UTC") {
        self.epochSeconds = epochSeconds
        self.utcOffsetSeconds = utcOffsetSeconds
        self.zone = zone

        let local = epochSeconds &+ Int64(utcOffsetSeconds)
        let days = Self.floorDivide(local, 86_400)
        let secondOfDay = Int(local - days * 86_400)
        let civil = Self.civil(fromDays: days)
        year = civil.year
        month = civil.month
        day = civil.day
        hour = secondOfDay / 3_600
        minute = (secondOfDay % 3_600) / 60
        second = secondOfDay % 60
        // 1970-01-01 was a Thursday (weekday 4).
        weekday = Int(Self.floorModulo(days + 4, 7))
        dayOfYear = Int(days - Self.daysFromCivil(year: civil.year, month: 1, day: 1)) + 1
    }

    /// Convenience for fractional epoch values (file timestamps, the kernel
    /// clock). Non-finite or out-of-range inputs clamp to the epoch.
    init(epoch: Double, utcOffsetSeconds: Int = 0, zone: String = "UTC") {
        let clamped: Int64
        if epoch.isFinite, abs(epoch) < 4.0e15 {
            clamped = Int64(epoch.rounded(.down))
        } else {
            clamped = 0
        }
        self.init(epochSeconds: clamped, utcOffsetSeconds: utcOffsetSeconds, zone: zone)
    }

    // MARK: - Civil arithmetic

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days in `month` (1...12) of `year`; 0 for an out-of-range month.
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    /// Days since 1970-01-01 for a proleptic-Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = floorDivide(y, 400)
        let yearOfEra = y - era * 400
        let shiftedMonth = Int64(month > 2 ? month - 3 : month + 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Inverse of `daysFromCivil`.
    static func civil(fromDays days: Int64) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = floorDivide(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (Int(year), Int(month), Int(day))
    }

    /// The UTC epoch second for a civil date-time expressed in a zone
    /// `utcOffsetSeconds` east of UTC.
    static func epochSeconds(year: Int, month: Int, day: Int,
                             hour: Int = 0, minute: Int = 0, second: Int = 0,
                             utcOffsetSeconds: Int = 0) -> Int64 {
        daysFromCivil(year: year, month: month, day: day) * 86_400
            + Int64(hour * 3_600 + minute * 60 + second)
            - Int64(utcOffsetSeconds)
    }

    /// 0 = Sunday ... 6 = Saturday for a civil date.
    static func weekday(year: Int, month: Int, day: Int) -> Int {
        Int(floorModulo(daysFromCivil(year: year, month: month, day: day) + 4, 7))
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    private static func floorModulo(_ value: Int64, _ divisor: Int64) -> Int64 {
        value - floorDivide(value, divisor) * divisor
    }

    // MARK: - Formatting

    /// `+hhmm` / `-hhmm` numeric zone, as printed by `%z`.
    var numericZone: String {
        let magnitude = abs(utcOffsetSeconds)
        return (utcOffsetSeconds < 0 ? "-" : "+")
            + Self.pad(magnitude / 3_600, 2) + Self.pad((magnitude % 3_600) / 60, 2)
    }

    /// Render with a `strftime` subset: `%Y %y %m %d %e %H %M %S %s %a %A %b %B
    /// %h %Z %z %F %T %D %R %j %u %w %n %t %%`. An unknown conversion is copied
    /// through verbatim, so a typo stays visible instead of vanishing.
    func formatted(_ pattern: String) -> String {
        var out = ""
        var iterator = pattern.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else { out.append(character); continue }
            guard let conversion = iterator.next() else { out.append("%"); break }
            switch conversion {
            case "Y": out += String(year)
            case "y": out += Self.pad(((year % 100) + 100) % 100, 2)
            case "m": out += Self.pad(month, 2)
            case "d": out += Self.pad(day, 2)
            case "e": out += Self.pad(day, 2, with: " ")
            case "H": out += Self.pad(hour, 2)
            case "M": out += Self.pad(minute, 2)
            case "S": out += Self.pad(second, 2)
            case "s": out += String(epochSeconds)
            case "a": out += Self.weekdayNames[weekday]
            case "A": out += Self.weekdayFullNames[weekday]
            case "b", "h": out += Self.monthNames[month - 1]
            case "B": out += Self.monthFullNames[month - 1]
            case "Z": out += zone
            case "z": out += numericZone
            case "F": out += "\(year)-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
            case "T": out += "\(Self.pad(hour, 2)):\(Self.pad(minute, 2)):\(Self.pad(second, 2))"
            case "D": out += "\(Self.pad(month, 2))/\(Self.pad(day, 2))/\(Self.pad(((year % 100) + 100) % 100, 2))"
            case "R": out += "\(Self.pad(hour, 2)):\(Self.pad(minute, 2))"
            case "j": out += Self.pad(dayOfYear, 3)
            case "u": out += String(weekday == 0 ? 7 : weekday)
            case "w": out += String(weekday)
            case "n": out += "\n"
            case "t": out += "\t"
            case "%": out += "%"
            default:
                out.append("%")
                out.append(conversion)
            }
        }
        return out
    }

    /// The default `date` rendering: `Wed Oct  7 12:34:56 UTC 2026`.
    var dateCommandString: String { formatted("%a %b %e %H:%M:%S %Z %Y") }

    /// The `stat`-style rendering: `2026-10-07 12:34:56 +0000`.
    var statString: String { formatted("%F %T %z") }

    /// The `ls -l` time column: `Oct  7 12:34` for an instant within roughly six
    /// months before `now` (and not in the future), otherwise `Oct  7  2025`.
    func longListingString(now: Int64) -> String {
        let sixMonths: Int64 = 15_778_800   // 365.2425 days / 2
        let recent = epochSeconds <= now && now - epochSeconds < sixMonths
        return recent ? formatted("%b %e %H:%M") : formatted("%b %e  %Y")
    }

    /// A `cal`-style month grid (Sunday first), each line unpadded on the right:
    ///
    ///         October 2026
    ///     Su Mo Tu We Th Fr Sa
    ///                  1  2  3
    ///
    /// Returns `nil` for a month outside 1...12 or a year outside 1...9999.
    static func monthCalendar(year: Int, month: Int) -> String? {
        guard (1...12).contains(month), (1...9_999).contains(year) else { return nil }
        let title = "\(monthFullNames[month - 1]) \(year)"
        let width = 20
        let leading = max(0, (width - title.count) / 2)
        var lines = [String(repeating: " ", count: leading) + title, "Su Mo Tu We Th Fr Sa"]
        var cells = Array(repeating: "  ", count: weekday(year: year, month: month, day: 1))
        for day in 1...daysInMonth(year: year, month: month) {
            cells.append(pad(day, 2, with: " "))
        }
        var index = 0
        while index < cells.count {
            let row = cells[index..<min(index + 7, cells.count)].joined(separator: " ")
            lines.append(row)
            index += 7
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func pad(_ value: Int, _ width: Int, with fill: Character = "0") -> String {
        let text = String(value)
        return text.count >= width
            ? text
            : String(repeating: fill, count: width - text.count) + text
    }
}
