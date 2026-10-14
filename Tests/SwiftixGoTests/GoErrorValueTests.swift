/// Go `error` values from the library: `errors.New`, and the errors that
/// `strconv`, `net`, `net/http`, and `context` calls return, which are typed
/// `error` so a program can return them, compare them, and read their text.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go error values")
struct GoErrorValueTests: GoTestHarness {

    @Test func errorsNewMakesComparableErrors() throws {
        let output = try runGoMain(
            """
            err := lookup("b")
            fmt.Println(err == errMissing, err != nil, err.Error(), err)
            fmt.Println(lookup("a") == nil, errors.New("x").Error(), wrap(nil) == nil)
            var none error
            fmt.Println(none == nil, wrap(err).Error())
            """,
            imports: ["errors", "fmt"],
            declarations: """
                var errMissing = errors.New("key not found")
                func lookup(key string) error {
                    if key == "a" {
                        return nil
                    }
                    return errMissing
                }
                func wrap(err error) error {
                    if err == nil {
                        return nil
                    }
                    return errors.New("lookup: " + err.Error())
                }
                """)

        #expect(
            output == """
                true true key not found key not found
                true x true
                true lookup: key not found

                """)
    }

    @Test func conversionErrorsAreErrorValues() throws {
        let output = try runGoMain(
            """
            value, err := parse("41")
            fmt.Println(value, err == nil)
            value, err = parse("4x")
            fmt.Println(value, err != nil, len(err.Error()) > 0)
            var failure error
            value, failure = strconv.Atoi("")
            fmt.Println(value, failure != nil)
            """,
            imports: ["fmt", "strconv"],
            declarations: """
                func parse(text string) (int, error) {
                    return strconv.Atoi(text)
                }
                """)

        #expect(output == "41 true\n0 true true\n0 true\n")
    }

    @Test func networkErrorsCanBeReturnedAndRead() throws {
        // A run without a process has no network, so every call fails.
        let output = try runGoMain(
            """
            err := connect("10.0.0.1:6379")
            fmt.Println(err.Error())
            _, listenErr := net.Listen("tcp", ":80")
            fmt.Println(listenErr.Error(), describe(listenErr))
            _, hostErr := net.LookupHost("example.test")
            fmt.Println(describe(hostErr), hostErr == nil)
            """,
            imports: ["errors", "fmt", "net"],
            declarations: """
                func connect(address string) error {
                    conn, err := net.Dial("tcp", address)
                    if err != nil {
                        return errors.New("connect " + address + ": " + err.Error())
                    }
                    return conn.Close()
                }
                func describe(err error) string {
                    if err == nil {
                        return "ok"
                    }
                    return err.Error()
                }
                """)

        #expect(
            output == """
                connect 10.0.0.1:6379: net: network not available
                net: network not available net: network not available
                net: network not available false

                """)
    }

    @Test func libraryErrorResultsHaveTheErrorType() {
        func diagnostic(_ body: String, declarations: String = "") -> String? {
            goMainDiagnostic(
                body,
                imports: ["context", "errors", "fmt", "io", "net", "net/http", "strconv", "time"],
                declarations: declarations)
        }
        #expect(
            diagnostic(
                """
                conn, err := net.Dial("tcp", "10.0.0.1:80")
                buffer := make([]byte, 16)
                n, readErr := conn.Read(buffer)
                m, writeErr := conn.Write(buffer)
                fmt.Println(n, m, readErr == io.EOF, writeErr != nil, err)
                var closeErr error = conn.Close()
                listener, listenErr := net.Listen("tcp", ":80")
                peer, acceptErr := listener.Accept()
                closeErr = listener.Close()
                fmt.Println(closeErr, listenErr, peer, acceptErr.Error())
                response, getErr := http.Get("http://10.0.0.1/")
                var serveErr error = http.ListenAndServe(":80", nil)
                fmt.Println(response.StatusCode, getErr.Error(), serveErr)
                ctx, cancel := context.WithTimeout(context.Background(), time.Second)
                cancel()
                var ctxErr error = ctx.Err()
                fmt.Println(ctxErr)
                """) == nil)
        #expect(diagnostic("var count int = errors.New(\"x\")\nfmt.Println(count)") != nil)
        #expect(
            diagnostic("fmt.Println(errors.New(1))") == "cannot use 1 (untyped int constant) as string value in argument to errors.New")
        #expect(
            diagnostic("fmt.Println(errors.New())")
                == "not enough arguments in call to errors.New\n\thave ()\n\twant (string)")
        #expect(
            diagnostic(
                """
                _, err := strconv.Atoi("1")
                var text string = err
                fmt.Println(text)
                """) != nil)
        // An error still converts to the empty interface.
        #expect(
            diagnostic(
                """
                _, err := strconv.Atoi("1")
                var boxed any = err
                fmt.Println(boxed, keep(err))
                """,
                declarations: """
                    func keep(value any) bool {
                        return value == nil
                    }
                    """) == nil)
    }
}
