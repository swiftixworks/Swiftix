import Testing
@testable import Swiftix

/// The wall-clock seam: `Kernel.wallClock` maps logical time to epoch time, the
/// Foundation-free `CalendarTime` turns it into calendar fields, and `date`/`cal`
/// present it. Every instant here is injected, never read from the host.
@Suite("Wall clock, calendar, date and cal")
struct WallClockTests {

    /// 2026-10-07T12:34:56Z.
    static let reference: Int64 = 1_791_376_496

    // MARK: - Calendar arithmetic

    @Test func epochConvertsToCalendarFields() {
        let time = CalendarTime(epochSeconds: Self.reference)
        #expect(time.year == 2026)
        #expect(time.month == 10)
        #expect(time.day == 7)
        #expect(time.hour == 12)
        #expect(time.minute == 34)
        #expect(time.second == 56)
        #expect(time.weekday == 3)          // Wednesday
        #expect(time.dayOfYear == 280)
        #expect(CalendarTime(epochSeconds: 0).dateCommandString == "Thu Jan  1 00:00:00 UTC 1970")
    }

    @Test func negativeEpochAndLeapDayAreHandled() {
        let before = CalendarTime(epochSeconds: -1)
        #expect(before.formatted("%F %T %a") == "1969-12-31 23:59:59 Wed")
        let leap = CalendarTime(epochSeconds: 951_782_400)
        #expect(leap.formatted("%F %j") == "2000-02-29 060")
        #expect(CalendarTime.isLeapYear(2000))
        #expect(!CalendarTime.isLeapYear(1900))
        #expect(CalendarTime.daysInMonth(year: 2023, month: 2) == 28)
    }

    /// Property: civil -> days -> civil is the identity across a wide range, and
    /// consecutive days advance the weekday by exactly one.
    @Test func civilConversionRoundTrips() {
        var previousWeekday = -1
        for days in stride(from: Int64(-200_000), through: 200_000, by: 37) {
            let civil = CalendarTime.civil(fromDays: days)
            #expect(CalendarTime.daysFromCivil(year: civil.year, month: civil.month, day: civil.day) == days)
            #expect((1...12).contains(civil.month))
            #expect((1...CalendarTime.daysInMonth(year: civil.year, month: civil.month)).contains(civil.day))
        }
        for days in Int64(-400)...400 {
            let weekday = CalendarTime(epochSeconds: days * 86_400).weekday
            if previousWeekday >= 0 { #expect(weekday == (previousWeekday + 1) % 7) }
            previousWeekday = weekday
        }
    }

    @Test func fixedOffsetShiftsFieldsButNotTheInstant() {
        let time = CalendarTime(epochSeconds: Self.reference, utcOffsetSeconds: 9 * 3_600 + 1_800, zone: "ACST")
        #expect(time.formatted("%F %T %Z %z %s") == "2026-10-07 22:04:56 ACST +0930 1791376496")
        let west = CalendarTime(epochSeconds: Self.reference, utcOffsetSeconds: -13 * 3_600, zone: "X")
        #expect(west.formatted("%F %H %z") == "2026-10-06 23 -1300")
    }

    @Test func formatCoversTheDocumentedConversions() {
        let time = CalendarTime(epochSeconds: Self.reference)
        #expect(time.formatted("%Y|%m|%d|%H|%M|%S|%s") == "2026|10|07|12|34|56|1791376496")
        #expect(time.formatted("%a|%b|%Z|%F|%T|%j|%e|%y") == "Wed|Oct|UTC|2026-10-07|12:34:56|280| 7|26")
        #expect(time.formatted("100%% %Q %") == "100% %Q %")
        #expect(time.statString == "2026-10-07 12:34:56 +0000")
    }

    @Test func longListingSwitchesToYearForOldAndFutureFiles() {
        let now = Self.reference
        #expect(CalendarTime(epochSeconds: now - 3_600).longListingString(now: now) == "Oct  7 11:34")
        #expect(CalendarTime(epochSeconds: now - 300 * 86_400).longListingString(now: now) == "Dec 11  2025")
        #expect(CalendarTime(epochSeconds: now + 86_400).longListingString(now: now) == "Oct  8  2026")
    }

    // MARK: - Kernel seam

    @Test func defaultClockIsDeterministicLogicalTime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        #expect(kernel.wallClock == WallClock())
        loop.advance(by: 42)
        final class Box { var now = -1.0; var offset = -1 }
        let box = Box()
        kernel.spawn("p") { ctx in
            box.now = ctx.realtimeSeconds
            box.offset = ctx.utcOffsetSeconds
        }
        loop.runUntilIdle()
        #expect(box.now == 42)
        #expect(box.offset == 0)
    }

    @Test func injectedClockAnchorsAtCurrentLogicalTimeAndAdvancesWithIt() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        loop.advance(by: 100)
        kernel.setWallClock(epochSeconds: Double(Self.reference), utcOffsetSeconds: 7_200, zoneAbbreviation: "CEST")
        #expect(kernel.wallClock.epochAtLogicalZero == Double(Self.reference) - 100)
        loop.advance(by: 4)
        final class Box { var now = 0.0; var text = "" }
        let box = Box()
        kernel.spawn("p") { ctx in
            box.now = ctx.realtimeSeconds
            box.text = ctx.currentCalendarTime().dateCommandString
        }
        loop.runUntilIdle()
        #expect(box.now == Double(Self.reference) + 4)
        #expect(box.text == "Wed Oct  7 14:35:00 CEST 2026")

        kernel.setWallClock(epochSeconds: .nan)             // rejected, unchanged
        #expect(kernel.wallClock.zoneAbbreviation == "CEST")
    }

    /// File timestamps are stamped with the wall clock, so they are meaningful
    /// epoch times once a host injects one — and survive a snapshot unchanged.
    @Test func fileTimestampsUseTheWallClockAndRoundTripThroughSnapshots() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.setWallClock(epochSeconds: Double(Self.reference))
        final class Box { var stat: FileStat?; var listing = ""; var text = "" }
        let box = Box()
        kernel.spawn("p") { ctx in
            let fd = ctx.open("/note", create: true)!
            ctx.write(fd, [1])
            ctx.close(fd)
            box.stat = ctx.stat("/note")
            box.listing = ctx.longListingTime(box.stat?.mtime ?? 0)
            box.text = ctx.statTime(box.stat?.mtime ?? 0)
        }
        loop.runUntilIdle()
        #expect(box.stat?.mtime == Double(Self.reference))
        #expect(box.stat?.ctime == Double(Self.reference))
        #expect(box.listing == "Oct  7 12:34")
        #expect(box.text == "2026-10-07 12:34:56 +0000")

        let snapshot = kernel.snapshotFileSystem()
        let restoredLoop = EventLoop()
        let restored = Kernel(loop: restoredLoop)
        #expect(restored.restoreFileSystem(snapshot))
        let again = Box()
        restored.spawn("p") { ctx in again.stat = ctx.stat("/note") }
        restoredLoop.runUntilIdle()
        #expect(again.stat?.mtime == Double(Self.reference))
    }

    // MARK: - date

    @Test func dateDefaultFormatUsesInjectedEpochAndZone() {
        let session = SystemSession(configure: { $0.setWallClock(epochSeconds: Double(Self.reference)) })
        #expect(session.lines("date") == ["Wed Oct  7 12:34:56 UTC 2026"])
        #expect(session.lines("date +%Y-%m-%dT%H:%M:%S") == ["2026-10-07T12:34:56"])
        #expect(session.lines("date +%s") == ["1791376496"])
    }

    @Test func dateHonorsLocalZoneAndUTCFlag() {
        let session = SystemSession(configure: {
            $0.setWallClock(epochSeconds: Double(Self.reference), utcOffsetSeconds: -4 * 3_600, zoneAbbreviation: "EDT")
        })
        #expect(session.lines("date") == ["Wed Oct  7 08:34:56 EDT 2026"])
        #expect(session.lines("date -u") == ["Wed Oct  7 12:34:56 UTC 2026"])
        #expect(session.lines("date -u +%H%Z") == ["12UTC"])
    }

    @Test func dateWithoutInjectedClockIsTheEpochPlusLogicalTime() {
        let session = SystemSession()
        session.loop.advance(by: 90)
        #expect(session.lines("date") == ["Thu Jan  1 00:01:30 UTC 1970"])
    }

    @Test func dateParsesExplicitInstants() {
        let session = SystemSession()
        #expect(session.lines("date -u -d @1791376496") == ["Wed Oct  7 12:34:56 UTC 2026"])
        #expect(session.lines("date -d 2000-02-29 +%s") == ["951782400"])
        #expect(session.lines("date -d 2026-10-07T12:34 +%s") == ["1791376440"])
        #expect(session.run("date -d 2026-02-30").contains("date: invalid date"))
        #expect(session.run("date --bogus").contains("date: invalid argument"))
        #expect(session.lines("date -d @0 +%F; echo rc=$?").last == "rc=0")
        #expect(session.lines("date -d nope; echo rc=$?").last == "rc=1")
    }

    @Test func dateOperandParserRespectsZoneOffset() {
        #expect(BuiltinCommands.parseDateOperand("@-5", utcOffsetSeconds: 0) == -5)
        #expect(BuiltinCommands.parseDateOperand("1970-01-01 01:00:00", utcOffsetSeconds: 3_600) == 0)
        #expect(BuiltinCommands.parseDateOperand("1970-01-01 24:00", utcOffsetSeconds: 0) == nil)
        #expect(BuiltinCommands.parseDateOperand("1970-1", utcOffsetSeconds: 0) == nil)
    }

    // MARK: - cal

    @Test func calPrintsRequestedAndCurrentMonth() {
        let october = [
            "    October 2026",
            "Su Mo Tu We Th Fr Sa",
            "             1  2  3",
            " 4  5  6  7  8  9 10",
            "11 12 13 14 15 16 17",
            "18 19 20 21 22 23 24",
            "25 26 27 28 29 30 31",
        ]
        let session = SystemSession(configure: { $0.setWallClock(epochSeconds: Double(Self.reference)) })
        #expect(session.lines("cal") == october)
        #expect(session.lines("cal 10 2026") == october)
        #expect(session.lines("cal 2 2024").last == "25 26 27 28 29")
        #expect(session.lines("cal 2 2024").first == "   February 2024")
        #expect(session.run("cal 13 2024").contains("cal: invalid month"))
        let year = session.lines("cal 2025")
        #expect(year.first == "    January 2025")
        #expect(year.contains("   December 2025"))
    }
}
