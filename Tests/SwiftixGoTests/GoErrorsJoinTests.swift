/// `errors.Join`, and `Unwrap() []error` of the errors that wrap several.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go errors.Join")
struct GoErrorsJoinTests: GoTestHarness {

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

    /// The text is the texts on a line each, `errors.Is` and `errors.As` look
    /// through every one, nil arguments are dropped, and nothing but nils is nil.
    @Test func joinedErrorsReadALineEachAndAreFoundByIsAndAs() throws {
        #expect(
            try runGoMain(
                #"""
                j := errors.Join(errA, errB)
                fmt.Println(j)
                fmt.Printf("%v|%s|%q|%T\n", j, j, j, j)
                fmt.Println(j.Error() == "a\nb", errors.Is(j, errA), errors.Is(j, errB), errors.Is(j, io.EOF))
                fmt.Println(errors.Unwrap(j) == nil)
                fmt.Println(errors.Join() == nil, errors.Join(nil) == nil, errors.Join(nil, nil) == nil)
                one := errors.Join(nil, errA, nil)
                fmt.Printf("%v %v %v %T\n", one, one == errA, errors.Is(one, errA), one)
                c := &codeErr{code: 7}
                mixed := errors.Join(c, valueErr("v"), fmt.Errorf("wrapped: %w", io.EOF))
                fmt.Println(mixed)
                var target *codeErr
                fmt.Println(errors.As(mixed, &target), target == c)
                var ve valueErr
                fmt.Println(errors.As(mixed, &ve), ve)
                fmt.Println(errors.Is(mixed, io.EOF), errors.Is(mixed, errA))
                nested := errors.Join(j, mixed)
                fmt.Println(errors.Is(nested, errB), errors.Is(nested, io.EOF), errors.As(nested, &target))
                fmt.Println(errors.Join(errA, errA) == errors.Join(errA, errA))
                wrapped := fmt.Errorf("ctx: %w", j)
                fmt.Println(wrapped, errors.Is(wrapped, errB))
                """#,
                imports: ["errors", "fmt", "io"],
                declarations: #"""
                    type codeErr struct{ code int }

                    func (e *codeErr) Error() string { return fmt.Sprintf("code %d", e.code) }

                    type valueErr string

                    func (e valueErr) Error() string { return "value " + string(e) }

                    var errA = errors.New("a")
                    var errB = errors.New("b")

                    func walk(err error, depth int) {
                        fmt.Printf("%*s%T %q\n", depth*2, "", err, err.Error())
                        switch x := err.(type) {
                        case interface{ Unwrap() error }:
                            if inner := x.Unwrap(); inner != nil {
                                walk(inner, depth+1)
                            }
                        case interface{ Unwrap() []error }:
                            for _, inner := range x.Unwrap() {
                                walk(inner, depth+1)
                            }
                        }
                    }
                    """#)
                == #"""
                a
                b
                a
                b|a
                b|"a\nb"|*errors.joinError
                true true true false
                true
                true true true
                a false true *errors.joinError
                code 7
                value v
                wrapped: EOF
                true true
                true value v
                true false
                true true true
                false
                ctx: a
                b true

                """#)
        #expect(
            try runGoMain(
                #"""
                list := []error{errA, nil, errB}
                spread := errors.Join(list...)
                fmt.Println(spread.Error() == "a\nb")
                var none []error
                fmt.Println(errors.Join(none...) == nil)
                join := errors.Join
                fmt.Printf("%T\n", join)
                fmt.Println(join(errA, errB).Error() == "a\nb", join() == nil)
                errors.Join(nil)
                defer fmt.Println(errors.Join(errB, errA))
                func() {
                    defer func() { fmt.Println("recovered:", recover()) }()
                    panic(errors.Join(errA, errB))
                }()
                """#,
                imports: ["errors", "fmt", "io"],
                declarations: #"""
                    type codeErr struct{ code int }

                    func (e *codeErr) Error() string { return fmt.Sprintf("code %d", e.code) }

                    type valueErr string

                    func (e valueErr) Error() string { return "value " + string(e) }

                    var errA = errors.New("a")
                    var errB = errors.New("b")

                    func walk(err error, depth int) {
                        fmt.Printf("%*s%T %q\n", depth*2, "", err, err.Error())
                        switch x := err.(type) {
                        case interface{ Unwrap() error }:
                            if inner := x.Unwrap(); inner != nil {
                                walk(inner, depth+1)
                            }
                        case interface{ Unwrap() []error }:
                            for _, inner := range x.Unwrap() {
                                walk(inner, depth+1)
                            }
                        }
                    }
                    """#)
                == "true\ntrue\nfunc(...error) error\ntrue true\nrecovered: a\nb\nb\na\n")
    }

    /// What `errors.Join` gives and what `fmt.Errorf` gives for several `%w`
    /// have `Unwrap() []error`, and what one `%w` gives has `Unwrap() error`: an
    /// assertion and a type switch tell them apart, as the walk of a tree of errors
    /// needs.
    @Test func anErrorThatWrapsSeveralUnwrapsToASlice() throws {
        #expect(
            try runGoMain(
                #"""
                j := errors.Join(errA, errB)
                u, ok := j.(interface{ Unwrap() []error })
                fmt.Println(ok, len(u.Unwrap()), u.Unwrap()[0] == errA, u.Unwrap()[1] == errB)
                _, single := j.(interface{ Unwrap() error })
                fmt.Println(single)
                c := &codeErr{code: 7}
                multi := fmt.Errorf("both: %w and %w", errA, c)
                fmt.Printf("%T %v\n", multi, multi)
                mu, ok := multi.(interface{ Unwrap() []error })
                fmt.Println(ok, len(mu.Unwrap()), mu.Unwrap()[0] == errA, mu.Unwrap()[1] == error(c))
                _, single = multi.(interface{ Unwrap() error })
                fmt.Println(single, errors.Unwrap(multi) == nil)
                w := fmt.Errorf("one: %w", errA)
                wu, ok := w.(interface{ Unwrap() error })
                fmt.Println(ok, wu.Unwrap() == errA)
                _, several := w.(interface{ Unwrap() []error })
                fmt.Println(several)
                walk(fmt.Errorf("outer: %w", errors.Join(multi, w, valueErr("leaf"))), 0)
                """#,
                imports: ["errors", "fmt", "io"],
                declarations: #"""
                    type codeErr struct{ code int }

                    func (e *codeErr) Error() string { return fmt.Sprintf("code %d", e.code) }

                    type valueErr string

                    func (e valueErr) Error() string { return "value " + string(e) }

                    var errA = errors.New("a")
                    var errB = errors.New("b")

                    func walk(err error, depth int) {
                        fmt.Printf("%*s%T %q\n", depth*2, "", err, err.Error())
                        switch x := err.(type) {
                        case interface{ Unwrap() error }:
                            if inner := x.Unwrap(); inner != nil {
                                walk(inner, depth+1)
                            }
                        case interface{ Unwrap() []error }:
                            for _, inner := range x.Unwrap() {
                                walk(inner, depth+1)
                            }
                        }
                    }
                    """#)
                == #"""
                true 2 true true
                false
                *fmt.wrapErrors both: a and code 7
                true 2 true true
                false true
                true true
                false
                *fmt.wrapError "outer: both: a and code 7\none: a\nvalue leaf"
                  *errors.joinError "both: a and code 7\none: a\nvalue leaf"
                    *fmt.wrapErrors "both: a and code 7"
                      *errors.errorString "a"
                      *main.codeErr "code 7"
                    *fmt.wrapError "one: a"
                      *errors.errorString "a"
                    main.valueErr "value leaf"

                """#)
    }

    /// The first error of Go's compiler for each.
    @Test func wrongCallsAreReportedAsGoReportsThem() {
        #expect(
            firstError(
                """
                x := errors.Join(1)
                _ = x
                """,
                imports: ["errors", "fmt", "io"])
                == "7:18: cannot use 1 (constant of type int) as error value in argument to errors.Join: int does not implement error (missing method Error)")
        #expect(
            firstError(
                """
                x := errors.Join(errors.New("a"), "b")
                _ = x
                """,
                imports: ["errors", "fmt", "io"])
                == "7:35: cannot use \"b\" (constant of type string) as error value in argument to errors.Join: string does not implement error (missing method Error)")
        #expect(
            firstError(
                """
                var e []string
                x := errors.Join(e...)
                _ = x
                """,
                imports: ["errors", "fmt", "io"])
                == "8:18: cannot use e (variable of type []string) as []error value in argument to errors.Join")
        #expect(
            firstError(
                """
                var e []error
                x := errors.Join(nil, e...)
                _ = x
                """,
                imports: ["errors", "fmt", "io"])
                == "8:23: too many arguments in call to errors.Join\n\thave (nil, []error...)\n\twant (...error)")
        #expect(
            firstError(
                """
                var s string = errors.Join()
                _ = s
                """,
                imports: ["errors", "fmt", "io"])
                == "7:16: cannot use errors.Join() (value of interface type error) as string value in variable declaration")
        #expect(
            firstError(
                """
                x, y := errors.Join(nil)
                _, _ = x, y
                """,
                imports: ["errors", "fmt", "io"])
                == "7:9: assignment mismatch: 2 variables but errors.Join returns 1 value")
        #expect(
            firstError(
                """
                type E struct{}
                x := errors.Join(E{})
                _ = x
                """,
                imports: ["errors", "fmt", "io"])
                == "8:18: cannot use E{} (value of struct type E) as error value in argument to errors.Join: E does not implement error (missing method Error)")
    }
}
