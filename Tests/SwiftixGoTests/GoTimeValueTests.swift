/// `time.Time` as Go has it: Go's zero time, the calendar, `Format` and
/// `Parse` with the reference layout, fixed locations, and `==` and map keys
/// that compare the instant and the location.
///
/// A time is still one opaque value of the VM (`GoCalendar`), so an image
/// made before keeps running and a program that used a time compiles to the
/// image it did; only the zero value now means January 1 of year 1.
/// `time.Local` is UTC, as Go's is with `TZ=UTC`, which is how every
/// expected output here was taken from Go 1.24.5.

@testable import SwiftixGo
@testable import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go time values")
struct GoTimeValueTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// A variable, `time.Time{}`, and a field left out are Go's zero time;
    /// `time.Unix(0, 0)` is not it.
    @Test func theZeroTimeIsYearOne() throws {
        #expect(
            try runGoMain(
                """
                var t time.Time
                u := time.Unix(0, 0)
                fmt.Println(t.IsZero(), time.Time{}.IsZero(), u.IsZero(), entry{}.expires.IsZero())
                fmt.Println(t)
                fmt.Println(u.UTC(), t.Year(), t.Month(), t.Day(), t.Weekday(), t.Unix())
                fmt.Println(t == u, t.Equal(u), t.Before(u), u.After(t), t.Compare(u))
                fmt.Println(t.Sub(u), u.Sub(t), t.Add(time.Hour), t.Add(-time.Nanosecond).Year())
                fmt.Println(time.Time{}.In(time.FixedZone("X", 3600)).IsZero())
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type entry struct {
                        value   string
                        expires time.Time
                    }
                    """)
                == """
                true true false true
                0001-01-01 00:00:00 +0000 UTC
                1970-01-01 00:00:00 +0000 UTC 1 January 1 Monday -62135596800
                false false true true -1
                -2562047h47m16.854775808s 2562047h47m16.854775807s 0001-01-01 01:00:00 +0000 UTC 0
                true

                """)
    }

    /// The fields of a time, in its location.
    @Test func theCalendarFieldsAreGos() throws {
        #expect(
            try runGoMain(
                """
                d := time.Date(2024, time.February, 29, 13, 4, 5, 123456789, time.UTC)
                fmt.Println(d.Year(), d.Month(), d.Day(), d.Hour(), d.Minute(), d.Second(), d.Nanosecond())
                fmt.Println(d.Weekday(), d.YearDay(), int(d.Month()), int(d.Weekday()))
                y, m, dd := d.Date()
                h, mi, s := d.Clock()
                wy, w := d.ISOWeek()
                fmt.Println(y, m, dd, h, mi, s, wy, w)
                for _, day := range []int{1, 2, 3, 4, 5, 6, 7} {
                    t := time.Date(2021, 1, day, 0, 0, 0, 0, time.UTC)
                    year, week := t.ISOWeek()
                    fmt.Print(t.Weekday().String()[:3], " ", year, "-", week, " ")
                }
                fmt.Println()
                fmt.Println(time.March, time.Saturday, time.Month(13), time.Weekday(-1), time.December+1)
                fmt.Println(d.In(time.FixedZone("E", -5*3600)).Day(), time.Date(-1, 12, 31, 0, 0, 0, 0, time.UTC).YearDay())
                """,
                imports: ["fmt", "time"])
                == "2024 February 29 13 4 5 123456789\nThursday 60 2 4\n2024 February 29 13 4 5 2024 9\nFri 2020-53 Sat 2020-53 Sun 2020-53 Mon 2021-1 Tue 2021-1 Wed 2021-1 Thu 2021-1 \nMarch Saturday %!Month(13) %!Weekday(18446744073709551615) %!Month(13)\n29 365\n")
    }

    /// `time.Date` and `AddDate` carry what is out of range into the next field,
    /// in both directions.
    @Test func dateNormalizesItsFields() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(time.Date(2023, 13, 32, 25, 61, 61, -1, time.UTC))
                fmt.Println(time.Date(2023, 0, 0, -1, -1, -1, 1e9, time.UTC))
                fmt.Println(time.Date(2023, -11, 1, 0, 0, 0, 0, time.UTC))
                jan31 := time.Date(2023, time.January, 31, 9, 0, 0, 0, time.UTC)
                fmt.Println(jan31.AddDate(0, 1, 0), jan31.AddDate(1, 1, 1), jan31.AddDate(0, 0, -31))
                leap := time.Date(2024, 2, 29, 0, 0, 0, 0, time.UTC)
                fmt.Println(leap.AddDate(1, 0, 0), leap.AddDate(-4, 0, 0), leap.AddDate(-100, 0, 0))
                fmt.Println(time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC).IsZero(), time.Date(0, 12, 31, 0, 0, 0, 0, time.UTC))
                """,
                imports: ["fmt", "time"])
                == """
                2024-02-02 02:02:00.999999999 +0000 UTC
                2022-11-29 22:59:00 +0000 UTC
                2022-01-01 00:00:00 +0000 UTC
                2023-03-03 09:00:00 +0000 UTC 2024-03-03 09:00:00 +0000 UTC 2022-12-31 09:00:00 +0000 UTC
                2025-03-01 00:00:00 +0000 UTC 2020-02-29 00:00:00 +0000 UTC 1924-02-29 00:00:00 +0000 UTC
                true 0000-12-31 00:00:00 +0000 UTC

                """)
    }

    /// As Go's, both work on the time since year 1, so a day is a day of UTC.
    @Test func truncateAndRoundCountFromTheZeroTime() throws {
        #expect(
            try runGoMain(
                """
                r := time.Date(2020, 1, 1, 12, 30, 30, 500000000, time.UTC)
                fmt.Println(r.Round(time.Minute), r.Round(time.Hour), r.Round(time.Second))
                fmt.Println(r.Truncate(24*time.Hour), r.Round(7*time.Second), r.Truncate(time.Duration(1<<62)))
                fmt.Println(r.Round(0) == r, r.Truncate(-1) == r)
                var zero time.Time
                fmt.Println(zero.Round(time.Hour), time.Date(0, 1, 1, 0, 0, 0, 0, time.UTC).Truncate(5*time.Hour))
                fmt.Println(time.Date(-5, 6, 1, 1, 0, 0, 1, time.UTC).Round(time.Hour))
                """,
                imports: ["fmt", "time"])
                == """
                2020-01-01 12:31:00 +0000 UTC 2020-01-01 13:00:00 +0000 UTC 2020-01-01 12:30:31 +0000 UTC
                2020-01-01 00:00:00 +0000 UTC 2020-01-01 12:30:33 +0000 UTC 1900-10-20 22:37:19.556042752 +0000 UTC
                true true
                0001-01-01 00:00:00 +0000 UTC -0001-12-31 23:00:00 +0000 UTC
                -0005-06-01 01:00:00 +0000 UTC

                """)
    }

    /// Seconds, milliseconds, microseconds, and nanoseconds since the epoch.
    @Test func unixTimesConvertBothWays() throws {
        #expect(
            try runGoMain(
                """
                r := time.Date(2020, 1, 1, 12, 30, 30, 500000000, time.UTC)
                fmt.Println(r.Unix(), r.UnixMilli(), r.UnixMicro(), r.UnixNano())
                fmt.Println(time.UnixMilli(1700000000123).UTC(), time.UnixMicro(-1).UTC())
                fmt.Println(time.Unix(1<<40, 0).UTC(), time.Unix(-1, -1).UTC(), time.Unix(0, 1e9+5).UTC())
                early := time.Unix(-1, -1)
                fmt.Println(early.Unix(), early.UnixMilli(), early.UnixMicro(), early.UnixNano())
                var zero time.Time
                fmt.Println(zero.Unix(), zero.UnixMilli(), zero.UnixMicro())
                fmt.Println(time.Unix(5, 0).Sub(time.Unix(2, 5)), time.Unix(0, 0).Add(1<<62).Sub(time.Unix(0, 0).Add(-1<<62)))
                """,
                imports: ["fmt", "time"])
                == """
                1577881830 1577881830500 1577881830500000 1577881830500000000
                2023-11-14 22:13:20.123 +0000 UTC 1969-12-31 23:59:59.999999 +0000 UTC
                36812-02-20 00:36:16 +0000 UTC 1969-12-31 23:59:58.999999999 +0000 UTC 1970-01-01 00:00:01.000000005 +0000 UTC
                -2 -1001 -1000001 -1000000001
                -62135596800 -62135596800000 -62135596800000000
                2.999999995s 2562047h47m16.854775807s

                """)
    }

    /// Every chunk of the reference layout, in UTC and in fixed zones with and
    /// without a name, and what `Parse` makes of the text again.
    @Test func formatTakesGosLayouts() throws {
        #expect(
            try runGoMain(
                """
                layouts := []string{time.Layout, time.ANSIC, time.UnixDate, time.RubyDate, time.RFC822, time.RFC822Z,
                    time.RFC850, time.RFC1123, time.RFC1123Z, time.RFC3339, time.RFC3339Nano, time.Kitchen,
                    time.Stamp, time.StampMilli, time.StampMicro, time.StampNano, time.DateTime, time.DateOnly,
                    time.TimeOnly, "Monday January 2 __2 002 3 03 pm PM -07 -070000 Z07 Z070000 -07:00:00 Z07:00:00 .000 ,999 _2006"}
                locations := []*time.Location{time.UTC, time.Local, time.FixedZone("", 5*3600+30*60+15), time.FixedZone("ABC", -7*3600)}
                for _, loc := range locations {
                    x := time.Date(2009, 11, 10, 23, 4, 5, 6007000, loc)
                    for _, layout := range layouts {
                        out := x.Format(layout)
                        back, err := time.Parse(layout, out)
                        fmt.Println(out, "|", back, err)
                    }
                }
                fmt.Println(time.Date(2009, 1, 2, 3, 4, 5, 0, time.UTC).Format("Jan January Janx Mon Monday Monx MST 2006 06 1 01 2 02 _2 15 3 03 4 04 5 05 PM pm .0 .9 .00"))
                """,
                imports: ["fmt", "time"])
                == """
                11/10 11:04:05PM '09 +0000 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 UTC 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 +0000 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                10 Nov 09 23:04 UTC | 2009-11-10 23:04:00 +0000 UTC <nil>
                10 Nov 09 23:04 +0000 | 2009-11-10 23:04:00 +0000 UTC <nil>
                Tuesday, 10-Nov-09 23:04:05 UTC | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue, 10 Nov 2009 23:04:05 UTC | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue, 10 Nov 2009 23:04:05 +0000 | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10T23:04:05Z | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10T23:04:05.006007Z | 2009-11-10 23:04:05.006007 +0000 UTC <nil>
                11:04PM | 0000-01-01 23:04:00 +0000 UTC <nil>
                Nov 10 23:04:05 | 0000-11-10 23:04:05 +0000 UTC <nil>
                Nov 10 23:04:05.006 | 0000-11-10 23:04:05.006 +0000 UTC <nil>
                Nov 10 23:04:05.006007 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                Nov 10 23:04:05.006007000 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                2009-11-10 23:04:05 | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10 | 2009-11-10 00:00:00 +0000 UTC <nil>
                23:04:05 | 0000-01-01 23:04:05 +0000 UTC <nil>
                Tuesday November 10 314 314 11 11 pm PM +00 +000000 Z Z +00:00:00 Z .006 ,006 _2009 | 2009-11-10 23:00:00.006 +0000 UTC <nil>
                11/10 11:04:05PM '09 +0000 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 UTC 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 +0000 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                10 Nov 09 23:04 UTC | 2009-11-10 23:04:00 +0000 UTC <nil>
                10 Nov 09 23:04 +0000 | 2009-11-10 23:04:00 +0000 UTC <nil>
                Tuesday, 10-Nov-09 23:04:05 UTC | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue, 10 Nov 2009 23:04:05 UTC | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue, 10 Nov 2009 23:04:05 +0000 | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10T23:04:05Z | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10T23:04:05.006007Z | 2009-11-10 23:04:05.006007 +0000 UTC <nil>
                11:04PM | 0000-01-01 23:04:00 +0000 UTC <nil>
                Nov 10 23:04:05 | 0000-11-10 23:04:05 +0000 UTC <nil>
                Nov 10 23:04:05.006 | 0000-11-10 23:04:05.006 +0000 UTC <nil>
                Nov 10 23:04:05.006007 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                Nov 10 23:04:05.006007000 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                2009-11-10 23:04:05 | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10 | 2009-11-10 00:00:00 +0000 UTC <nil>
                23:04:05 | 0000-01-01 23:04:05 +0000 UTC <nil>
                Tuesday November 10 314 314 11 11 pm PM +00 +000000 Z Z +00:00:00 Z .006 ,006 _2009 | 2009-11-10 23:00:00.006 +0000 UTC <nil>
                11/10 11:04:05PM '09 +0530 | 2009-11-10 23:04:05 +0530 +0530 <nil>
                Tue Nov 10 23:04:05 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 +0530 2009 | 0001-01-01 00:00:00 +0000 UTC parsing time "Tue Nov 10 23:04:05 +0530 2009" as "Mon Jan _2 15:04:05 MST 2006": cannot parse "+0530 2009" as "MST"
                Tue Nov 10 23:04:05 +0530 2009 | 2009-11-10 23:04:05 +0530 +0530 <nil>
                10 Nov 09 23:04 +0530 | 0001-01-01 00:00:00 +0000 UTC parsing time "10 Nov 09 23:04 +0530" as "02 Jan 06 15:04 MST": cannot parse "+0530" as "MST"
                10 Nov 09 23:04 +0530 | 2009-11-10 23:04:00 +0530 +0530 <nil>
                Tuesday, 10-Nov-09 23:04:05 +0530 | 0001-01-01 00:00:00 +0000 UTC parsing time "Tuesday, 10-Nov-09 23:04:05 +0530" as "Monday, 02-Jan-06 15:04:05 MST": cannot parse "+0530" as "MST"
                Tue, 10 Nov 2009 23:04:05 +0530 | 0001-01-01 00:00:00 +0000 UTC parsing time "Tue, 10 Nov 2009 23:04:05 +0530" as "Mon, 02 Jan 2006 15:04:05 MST": cannot parse "+0530" as "MST"
                Tue, 10 Nov 2009 23:04:05 +0530 | 2009-11-10 23:04:05 +0530 +0530 <nil>
                2009-11-10T23:04:05+05:30 | 2009-11-10 23:04:05 +0530 +0530 <nil>
                2009-11-10T23:04:05.006007+05:30 | 2009-11-10 23:04:05.006007 +0530 +0530 <nil>
                11:04PM | 0000-01-01 23:04:00 +0000 UTC <nil>
                Nov 10 23:04:05 | 0000-11-10 23:04:05 +0000 UTC <nil>
                Nov 10 23:04:05.006 | 0000-11-10 23:04:05.006 +0000 UTC <nil>
                Nov 10 23:04:05.006007 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                Nov 10 23:04:05.006007000 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                2009-11-10 23:04:05 | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10 | 2009-11-10 00:00:00 +0000 UTC <nil>
                23:04:05 | 0000-01-01 23:04:05 +0000 UTC <nil>
                Tuesday November 10 314 314 11 11 pm PM +05 +053015 +05 +053015 +05:30:15 +05:30:15 .006 ,006 _2009 | 2009-11-10 23:00:00.006 +0530 +0530 <nil>
                11/10 11:04:05PM '09 -0700 | 2009-11-10 23:04:05 -0700 -0700 <nil>
                Tue Nov 10 23:04:05 2009 | 2009-11-10 23:04:05 +0000 UTC <nil>
                Tue Nov 10 23:04:05 ABC 2009 | 2009-11-10 23:04:05 +0000 ABC <nil>
                Tue Nov 10 23:04:05 -0700 2009 | 2009-11-10 23:04:05 -0700 -0700 <nil>
                10 Nov 09 23:04 ABC | 2009-11-10 23:04:00 +0000 ABC <nil>
                10 Nov 09 23:04 -0700 | 2009-11-10 23:04:00 -0700 -0700 <nil>
                Tuesday, 10-Nov-09 23:04:05 ABC | 2009-11-10 23:04:05 +0000 ABC <nil>
                Tue, 10 Nov 2009 23:04:05 ABC | 2009-11-10 23:04:05 +0000 ABC <nil>
                Tue, 10 Nov 2009 23:04:05 -0700 | 2009-11-10 23:04:05 -0700 -0700 <nil>
                2009-11-10T23:04:05-07:00 | 2009-11-10 23:04:05 -0700 -0700 <nil>
                2009-11-10T23:04:05.006007-07:00 | 2009-11-10 23:04:05.006007 -0700 -0700 <nil>
                11:04PM | 0000-01-01 23:04:00 +0000 UTC <nil>
                Nov 10 23:04:05 | 0000-11-10 23:04:05 +0000 UTC <nil>
                Nov 10 23:04:05.006 | 0000-11-10 23:04:05.006 +0000 UTC <nil>
                Nov 10 23:04:05.006007 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                Nov 10 23:04:05.006007000 | 0000-11-10 23:04:05.006007 +0000 UTC <nil>
                2009-11-10 23:04:05 | 2009-11-10 23:04:05 +0000 UTC <nil>
                2009-11-10 | 2009-11-10 00:00:00 +0000 UTC <nil>
                23:04:05 | 0000-01-01 23:04:05 +0000 UTC <nil>
                Tuesday November 10 314 314 11 11 pm PM -07 -070000 -07 -070000 -07:00:00 -07:00:00 .006 ,006 _2009 | 2009-11-10 23:00:00.006 -0700 -0700 <nil>
                Jan January Janx Fri Friday Monx UTC 2009 09 1 01 2 02  2 03 3 03 4 04 5 05 AM am .0  .00

                """)
    }

    /// What `Parse` refuses, and what it makes of zones and fractions.
    @Test func parseReportsGosErrors() throws {
        #expect(
            try runGoMain(
                #"""
                cases := [][2]string{{"2006-01-02", "2006-13-01"}, {"15:04:05", "25:00:00"}, {time.RFC3339, "2006-01-02T15:04:05"},
                    {time.RFC3339, "2006-01-02T15:04:05.123+25:00"}, {"Jan 2", "Foo 2"}, {"2006", "abcd"},
                    {"2006-01-02", "2006-01-02 extra"}, {"__2 2006", "366 2023"}, {"__2 2006", " 60 2024"},
                    {"MST 2006", "XYZ 2001"}, {"MST", "GMT+3"}, {"3:04PM", "12:00AM"}, {"Mon Jan 2", "Tue Feb 3"},
                    {"2006-01-02", "2021-02-30"}, {"2006-01-02 15:04", "2021-02-03 x"}, {"15:04:05", "10:11:12.123456789123"},
                    {time.RFC3339, "2021-03-04T05:06:07+02:00"}, {time.RFC3339, "2021-03-04T05:06:07+00:00"},
                    {time.RFC3339Nano, "2021-03-04T05:06:07.5Z"}, {"2006-01-02 MST", "2021-03-04 UTC"},
                    {"Jan _2", "jan  7"}, {"15:04:05.000", "01:02:03.12"}, {"2006 \x01", "2006 \x01"}}
                for _, c := range cases {
                    t, err := time.Parse(c[0], c[1])
                    fmt.Println(t, t.Location(), err)
                }
                """#,
                imports: ["fmt", "time"])
                == """
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "2006-13-01": month out of range
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "25:00:00": hour out of range
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "2006-01-02T15:04:05" as "2006-01-02T15:04:05Z07:00": cannot parse "" as "Z07:00"
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "2006-01-02T15:04:05.123+25:00": time zone offset hour out of range
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "Foo 2" as "Jan 2": cannot parse "Foo 2" as "Jan"
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "abcd" as "2006": cannot parse "abcd" as "2006"
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "2006-01-02 extra": extra text: " extra"
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "366 2023": day-of-year out of range
                2024-02-29 00:00:00 +0000 UTC UTC <nil>
                2001-01-01 00:00:00 +0000 XYZ XYZ <nil>
                0000-01-01 03:00:00 +0300 GMT+3 GMT+3 <nil>
                0000-01-01 00:00:00 +0000 UTC UTC <nil>
                0000-02-03 00:00:00 +0000 UTC UTC <nil>
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "2021-02-30": day out of range
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "2021-02-03 x" as "2006-01-02 15:04": cannot parse "x" as "15"
                0000-01-01 10:11:12.123456789 +0000 UTC UTC <nil>
                2021-03-04 05:06:07 +0200 +0200  <nil>
                2021-03-04 05:06:07 +0000 UTC UTC <nil>
                2021-03-04 05:06:07.5 +0000 UTC UTC <nil>
                2021-03-04 00:00:00 +0000 UTC UTC <nil>
                0000-01-07 00:00:00 +0000 UTC UTC <nil>
                0001-01-01 00:00:00 +0000 UTC UTC parsing time "01:02:03.12" as "15:04:05.000": cannot parse ".12" as ".000"
                2006-01-01 00:00:00 +0000 UTC UTC <nil>

                """)
    }

    /// UTC, `time.Local` (which is UTC), and fixed zones, which change how a
    /// time reads and not when it is.
    @Test func aTimeHasALocation() throws {
        #expect(
            try runGoMain(
                """
                d := time.Date(2024, 2, 29, 13, 4, 5, 0, time.UTC)
                est := time.FixedZone("EST", -5*3600)
                fmt.Println(d.In(est), d.In(est).Location(), d.Location(), time.Unix(0, 0).Location(), time.Local, time.UTC)
                name, offset := d.In(est).Zone()
                fmt.Println(name, offset, d.In(est).Equal(d), d.In(est) == d, d.Local().Equal(d), d.UTC() == d)
                fmt.Println(d.Location() == time.UTC, time.Now().Location() == time.Local, time.Unix(1, 0).UTC().Location() == time.UTC)
                loc, err := time.LoadLocation("UTC")
                fmt.Println(loc, err, loc == time.UTC)
                loc, err = time.LoadLocation("Local")
                fmt.Println(loc, err)
                in, err := time.ParseInLocation("2006-01-02 15:04 MST", "2020-05-06 07:08 EST", est)
                fmt.Println(in, err, in.UTC())
                in, err = time.ParseInLocation(time.DateTime, "2020-05-06 07:08:09", est)
                fmt.Println(in, err)
                var none *time.Location
                fmt.Println(none == nil, none, time.FixedZone("", -90*60))
                """,
                imports: ["fmt", "time"])
                == "2024-02-29 08:04:05 -0500 EST EST UTC UTC UTC UTC\nEST -18000 true false true true\ntrue true true\nUTC <nil> true\nUTC <nil>\n2020-05-06 07:08:00 -0500 EST <nil> 2020-05-06 12:08:00 +0000 UTC\n2020-05-06 07:08:09 -0500 EST <nil>\ntrue UTC \n")
    }

    /// `==` compares the instant and the location, so two readings of one
    /// instant in two locations are different keys; `Equal` compares the instant.
    @Test func timesCompareAndAreMapKeysAsInGo() throws {
        #expect(
            try runGoMain(
                """
                d := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
                fmt.Println(d == time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC), d == d.Add(1), d != d.Local())
                seen := map[time.Time]int{}
                seen[d]++
                seen[d.Add(0)]++
                seen[d.Local()]++
                seen[time.Time{}]++
                var zero time.Time
                seen[zero]++
                fmt.Println(len(seen), seen[d], seen[zero])
                type key struct {
                    at   time.Time
                    name string
                }
                keys := map[key]bool{{d, "a"}: true}
                fmt.Println(keys[key{d, "a"}], keys[key{d.Local(), "a"}], key{d, "a"} == key{d, "a"})
                var x, y any = d, d.Add(0)
                fmt.Println(x == y)
                """,
                imports: ["fmt", "time"])
                == "true false true\n3 2 2\ntrue false true\ntrue\n")
    }

    /// By `String` where `fmt` calls methods, by `GoString` under `%#v`, and as
    /// Go's struct behind an unexported field.
    @Test func aTimePrintsAsGoPrintsIt() throws {
        #expect(
            try runGoMain(
                #"""
                d := time.Date(2024, 2, 29, 13, 4, 5, 120000000, time.UTC)
                fmt.Println(d, []time.Time{d, {}}, exported{d}, hidden{d})
                fmt.Printf("%v|%s|%+v|%#v|%q\n", d, d, exported{d}, d, d)
                fmt.Printf("%+v %v %d %s %v\n", hidden{}, d.Month(), d.Month(), d.Weekday(), time.UTC)
                var s interface{ String() string } = d
                fmt.Println(s.String(), d.String() == fmt.Sprint(d))
                b, err := d.MarshalText()
                fmt.Println(string(b), err)
                b, err = time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC).MarshalText()
                fmt.Println(b == nil, err)
                fmt.Println(string(d.AppendFormat([]byte("at "), time.Kitchen)))
                fmt.Printf("%T %T %T %T\n", d, d.Month(), d.Weekday(), d.Location())
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type exported struct{ At time.Time }

                    type hidden struct{ at time.Time }
                    """)
                == """
                2024-02-29 13:04:05.12 +0000 UTC [2024-02-29 13:04:05.12 +0000 UTC 0001-01-01 00:00:00 +0000 UTC] {2024-02-29 13:04:05.12 +0000 UTC} {{120000000 63844808645 <nil>}}
                2024-02-29 13:04:05.12 +0000 UTC|2024-02-29 13:04:05.12 +0000 UTC|{At:2024-02-29 13:04:05.12 +0000 UTC}|time.Date(2024, time.February, 29, 13, 4, 5, 120000000, time.UTC)|"2024-02-29 13:04:05.12 +0000 UTC"
                {at:{wall:0 ext:0 loc:<nil>}} February 2 Thursday UTC
                2024-02-29 13:04:05.12 +0000 UTC true
                2024-02-29T13:04:05.12Z <nil>
                true Time.MarshalText: year outside of range [0,9999]
                at 1:04PM
                time.Time time.Month time.Weekday *time.Location

                """)
    }

    /// A local type, an alias, a struct that embeds a time, a closure that
    /// captures one, a method value, and an interface that holds one.
    @Test func everyPassSeesATime() throws {
        #expect(
            try runGoMain(
                """
                type local struct{ T time.Time }
                var l local
                fmt.Println(l.T.IsZero())
                var s stamp = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
                e := event{Time: s, Name: "x"}
                fmt.Println(e.Year(), e.Format(time.DateOnly), e.IsZero(), e.Add(time.Hour).Hour())
                later := func(d time.Duration) time.Time { return s.Add(d) }
                fmt.Println(later(36*time.Hour), later(-time.Nanosecond))
                format := s.Format
                fmt.Println(format(time.Kitchen))
                var x any = s
                switch v := x.(type) {
                case time.Time:
                    fmt.Println("time", v.Month())
                }
                _, ok := x.(interface{ String() string })
                fmt.Println(ok)
                switch s.Weekday() {
                case time.Saturday, time.Sunday:
                    fmt.Println("weekend")
                }
                ch := make(chan time.Time, 1)
                ch <- s
                fmt.Println((<-ch).YearDay())
                p := &s
                fmt.Println(p.Year(), (*p).Day())
                """,
                imports: ["fmt", "time"],
                declarations: """
                    type stamp = time.Time

                    type event struct {
                        time.Time
                        Name string
                    }
                    """)
                == """
                true
                2000 2000-01-01 false 1
                2000-01-02 12:00:00 +0000 UTC 1999-12-31 23:59:59.999999999 +0000 UTC
                12:00AM
                time January
                true
                weekend
                1
                2000 1

                """)
    }

    /// A package of a module declares a field of a time, a variable, and a
    /// method that takes one; `main` imports `fmt` and `time` under other names.
    /// Go 1.24.5 printed the same.
    @Test func aTimeCrossesPackagesUnderAnyName() throws {
        let cache = """
            package cache

            import "time"

            type Entry struct {
                Value   string
                Expires time.Time
            }

            func (e Entry) Live(now time.Time) bool {
                return e.Expires.IsZero() || now.Before(e.Expires)
            }

            var Epoch = time.Date(2020, time.January, 1, 0, 0, 0, 0, time.UTC)
            """
        let main = """
            package main

            import (
                f "fmt"
                clock "time"

                "example/m/cache"
            )

            func main() {
                e := cache.Entry{Value: "v"}
                f.Println(e.Live(cache.Epoch), e.Expires)
                e.Expires = cache.Epoch.Add(clock.Minute)
                f.Println(e.Live(cache.Epoch.Add(2*clock.Minute)), e.Expires.Format(clock.RFC3339))
                f.Println(e.Expires == cache.Epoch.Add(clock.Minute), cache.Epoch.Month() == clock.January)
            }
            """
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m",
                    sources: [GoSourceFile(path: "/m/main.go", text: main)]),
                GoPackageSource(
                    importPath: "example/m/cache",
                    sources: [GoSourceFile(path: "/m/cache/cache.go", text: cache)]),
            ],
            root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output == """
                true 0001-01-01 00:00:00 +0000 UTC
                false 2020-01-01T00:01:00Z
                true true

                """)
    }

    /// An image always held a time as its nanoseconds since the epoch, and
    /// still does for a local time: only `0`, the zero value, now means year 1.
    /// Every time has one value, so equal times are equal values.
    @Test func aTimeOfAnOlderImageKeepsItsMeaning() {
        #expect(GoTime(.int(0)) == GoTime.zero)
        #expect(GoTime(.int(1_700_000_000_123_456_789))?.seconds == 1_700_000_000)
        #expect(GoTime(.int(-1))?.nanoseconds == 999_999_999)
        #expect(GoTime(.int(42))?.value == .int(42))
        // The epoch itself, a time out of the integers' range, and a time
        // in UTC take the longer form.
        #expect(GoCalendar.unix(0, 0).value != .int(0))
        #expect(GoTime(GoCalendar.unix(0, 0).value) == GoCalendar.unix(0, 0))
        #expect(GoTime(GoCalendar.unix(1 << 40, 0).value)?.seconds == 1 << 40)
        let utc = GoTime(seconds: 5, nanoseconds: 0, location: .utc)
        #expect(utc.value != GoTime(seconds: 5, nanoseconds: 0, location: .local).value)
        #expect(GoTime.zero.value == .int(0))
    }

    /// The constants and the locations of `time` are Go text: a program that
    /// names none of them is made of its own functions alone, and one that names
    /// `time.UTC` gets the initializer of the package.
    @Test func aProgramPaysOnlyForWhatItNames() throws {
        func names(_ body: String) throws -> Set<String> {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go", text: goMainSource(body, imports: ["fmt", "time"]))
            ])
            return Set(executable.functions.map(\.name))
        }
        #expect(
            try names("fmt.Println(time.Now().Year(), time.Since(time.Now()), time.Time{}.IsZero())")
                == ["main"])
        #expect(
            try names("fmt.Println(time.Now().Format(time.RFC3339), time.March)")
                == ["$time.init", "main"])
        #expect(try names("fmt.Println(time.Now().In(time.UTC))") == ["$time.init", "main"])
    }

    /// Go's `time.Time` is a struct of unexported fields, and its errors say
    /// so.
    @Test func aTimeLiteralHasNoFieldsToSet() {
        #expect(
            firstError("_ = time.Time{wall: 1}", imports: ["fmt", "time"])
                == "6:15: cannot refer to unexported field wall in struct literal of type time.Time")
        #expect(
            firstError("_ = time.Time{1}", imports: ["fmt", "time"])
                == "6:15: implicit assignment to unexported field wall in struct literal of type time.Time")
        #expect(
            firstError("_ = time.Time{}.Month() + time.Now()", imports: ["fmt", "time"])
                == "6:5: invalid operation: time.Time{}.Month() + time.Now() (mismatched types time.Month and time.Time)")
        #expect(
            firstError("fmt.Println(time.Now() < time.Now())", imports: ["fmt", "time"])
                == "6:13: invalid operation: time.Now() < time.Now() (operator < not defined on struct)")
    }
}
