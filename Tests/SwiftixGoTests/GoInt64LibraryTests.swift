/// The members of the library that Go types as `int64`: `time.Duration`
/// is defined over it, and the seconds, milliseconds, and nanoseconds of a
/// `time.Time` and of a duration, the arguments of `time.Unix`, and the
/// `ContentLength` of an HTTP request and response have it.
///
/// What each program prints is what Go 1.24.5 prints for it. An error is
/// pinned by its message, which is worded as this dialect words such
/// messages and was compared with Go's when the test was written.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go library members that are int64")
struct GoInt64LibraryTests: GoTestHarness {

    /// `t.Unix()`, `d.Milliseconds()` and the like give an `int64`, `time.Unix`
    /// takes two, and a duration converts to and from one.
    @Test func timesAndDurationsCountInInt64() throws {
        #expect(
            try runGoMain(
                #"""
                t := time.Unix(1700000000, 500)
                var s int64 = t.Unix()
                var ms int64 = t.UnixMilli()
                ns := t.UnixNano()
                d := 1500 * time.Millisecond
                fmt.Printf("%T %T %T %T %T %T %T\n", s, ms, ns, d.Milliseconds(), d.Microseconds(), d.Nanoseconds(), d)
                fmt.Println(s, ms, ns, d.Milliseconds(), d.Microseconds(), d.Nanoseconds(), int64(d), time.Duration(int64(250)), d.Milliseconds()/1000)
                var n int64 = 3
                fmt.Println(time.Duration(n)*time.Second, time.Unix(n, n).UnixNano(), time.Unix(s, 0).Unix() == s, int(d), time.Duration(7))
                """#,
                imports: ["fmt", "time"])
                == """
                int64 int64 int64 int64 int64 int64 time.Duration
                1700000000 1700000000000 1700000000000000500 1500 1500000 1500000000 1500000000 250ns 1
                3s 3000000003 true 1500000000 7ns

                """)
        #expect(
            goMainDiagnostic(
                """
                t := time.Unix(1700000000, 0)
                var s int = t.Unix()
                fmt.Println(s)
                """,
                imports: ["fmt", "time"])
                == "cannot use int64 as int value")
        #expect(
            goMainDiagnostic(
                """
                d := time.Second
                var n int = d.Milliseconds()
                fmt.Println(n)
                """,
                imports: ["fmt", "time"])
                == "cannot use int64 as int value")
        #expect(
            goMainDiagnostic(
                """
                var sec int = 5
                fmt.Println(time.Unix(sec, 0).Unix())
                """,
                imports: ["fmt", "time"])
                == "cannot use int as int64 value")
        #expect(
            goMainDiagnostic(
                """
                var d time.Duration = 5
                var i int64 = d
                fmt.Println(i)
                """,
                imports: ["fmt", "time"])
                == "cannot use time.Duration as int64 value")
    }

    /// `ContentLength` of a request and of a response.
    @Test func theContentLengthOfHTTPIsInt64() throws {
        #expect(
            try runGoMain(
                #"""
                req, err := http.NewRequest("POST", "http://example.test/", strings.NewReader("hello"))
                var resp http.Response
                resp.ContentLength = -1
                fmt.Printf("%T %v %T %v %v %v\n", req.ContentLength, req.ContentLength, resp.ContentLength, resp.ContentLength, length(req), err)
                """#,
                imports: ["fmt", "net/http", "strings"],
                declarations: """
                    func length(r *http.Request) int64 { return r.ContentLength * 2 }
                    """)
                == "int64 5 int64 -1 10 <nil>\n")
    }
}
