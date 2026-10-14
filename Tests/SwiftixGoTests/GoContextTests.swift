/// The package `context`: deadlines, cancellation, and values, as Go has
/// them.
///
/// The package is Go text (`GoEmbeddedSources.context`), linked with a
/// program that imports it the way `net/http` is. So `context.Context` is an
/// interface like any other: a program implements it, embeds it, keeps it
/// in fields and maps, and switches on it; a `CancelFunc` is a `func()`;
/// `ctx.Done()` is a channel a `select` waits on; and the errors are values
/// `errors.Is` finds.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// is the first one its compiler reports, copied without change. No program
/// prints anything that depends on how long it ran.

@testable import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go context")
struct GoContextTests: GoTestHarness {

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

    /// Compiles `text`, one whole file, and returns what the program prints.
    private func runGoProgram(_ text: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// The message of the diagnostic that compiling `text` produces, or nil.
    private func goProgramDiagnostic(_ text: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    /// What did not compile before: a receive from `ctx.Done()` in a `select`
    /// and as a statement, and `defer cancel()`.
    @Test func aTimeoutCancelsAndDoneIsAChannel() throws {
        #expect(
            try runGoProgram(
                """
                package main

                import (
                    "context"
                    "errors"
                    "fmt"
                    "time"
                )

                func main() {
                    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
                    defer cancel()
                    select {
                    case <-ctx.Done():
                        fmt.Println(ctx.Err(), errors.Is(ctx.Err(), context.DeadlineExceeded))
                    }
                    parent, stop := context.WithCancel(context.Background())
                    child, stopChild := context.WithCancel(parent)
                    fmt.Println(parent.Err(), child.Err())
                    stopChild()
                    fmt.Println(parent.Err(), child.Err())
                    stop()
                    stop()
                    <-parent.Done()
                    fmt.Println(parent.Err(), child.Err(), parent.Err() == context.Canceled)
                    fmt.Println(context.Background(), context.TODO(), parent, child)
                }
                """)
                == """
                context deadline exceeded true
                <nil> <nil>
                <nil> context canceled
                context canceled context canceled true
                context.Background context.TODO context.Background.WithCancel context.Background.WithCancel.WithCancel

                """)
    }

    /// Cancellation reaches the contexts derived from one and not the one it
    /// derives from; a `CancelFunc` is a `func()`; deadlines, values, a context of
    /// the program's own as a parent, one that embeds a `Context`, and contexts in
    /// fields, maps, slices, `any`, and goroutines.
    @Test func contextsAreValuesAndCancellationReachesChildren() throws {
        #expect(
            try runGoProgram(
                #"""
                package main

                import (
                    "context"
                    "errors"
                    "fmt"
                    "sync"
                    "time"
                )

                type key string

                type requestID int

                func (r requestID) String() string { return fmt.Sprint("request-", int(r)) }

                // fixed is a context of the program's own: cancelled when its channel closes.
                type fixed struct {
                    done chan struct{}
                    name string
                }

                func (f *fixed) Deadline() (deadline time.Time, ok bool) { return }
                func (f *fixed) Done() <-chan struct{}       { return f.done }
                func (f *fixed) Err() error {
                    select {
                    case <-f.done:
                        return errors.New("fixed is over")
                    default:
                        return nil
                    }
                }
                func (f *fixed) Value(k any) any {
                    var name any = key("name")
                    if k == name {
                        return f.name
                    }
                    return nil
                }

                // traced embeds a Context and adds to it.
                type traced struct {
                    context.Context
                    trace []string
                }

                func (t *traced) Value(k any) any {
                    t.trace = append(t.trace, fmt.Sprint(k))
                    return t.Context.Value(k)
                }

                type server struct {
                    ctx    context.Context
                    cancel context.CancelFunc
                    byName map[string]context.Context
                }

                func wait(ctx context.Context, name string) string {
                    select {
                    case <-ctx.Done():
                        return name + ": " + ctx.Err().Error()
                    case <-time.After(50 * time.Millisecond):
                        return name + ": still running"
                    }
                }

                func describe(v any) string {
                    switch c := v.(type) {
                    case nil:
                        return "nil"
                    case context.Context:
                        return fmt.Sprintf("context %v err=%v", c, c.Err())
                    case context.CancelFunc:
                        return "cancel func"
                    case error:
                        return "error " + c.Error()
                    }
                    return fmt.Sprintf("other %T", v)
                }

                func run(stop func()) { stop() }

                func main() {
                    root := context.Background()
                    fmt.Println(root, context.TODO(), root.Err(), root.Done() == nil, root.Value("k"))
                    deadline, ok := root.Deadline()
                    _ = deadline
                    fmt.Println(ok)
                    fmt.Printf("%T %T %v %v\n", context.Canceled, context.DeadlineExceeded, context.Canceled, context.DeadlineExceeded)

                    // Cancellation reaches children and not parents.
                    parent, cancelParent := context.WithCancel(root)
                    child, cancelChild := context.WithCancel(parent)
                    grandchild, cancelGrandchild := context.WithCancel(child)
                    sibling, cancelSibling := context.WithCancel(parent)
                    defer cancelGrandchild()
                    defer cancelSibling()
                    cancelChild()
                    fmt.Println(parent.Err(), child.Err(), grandchild.Err(), sibling.Err())
                    cancelParent()
                    cancelParent()
                    fmt.Println(parent.Err(), child.Err(), grandchild.Err(), sibling.Err())
                    <-sibling.Done()
                    _, open := <-grandchild.Done()
                    fmt.Println(open, errors.Is(sibling.Err(), context.Canceled), sibling.Err() == context.Canceled, errors.Is(sibling.Err(), context.DeadlineExceeded))
                    late, cancelLate := context.WithCancel(parent)
                    fmt.Println(late.Err(), wait(late, "late"))
                    cancelLate()

                    // A CancelFunc is a func().
                    ctx, cancel := context.WithCancel(root)
                    var stop func() = cancel
                    var again context.CancelFunc = stop
                    run(cancel)
                    again()
                    stops := []func(){cancel, stop, again}
                    for _, s := range stops {
                        s()
                    }
                    fmt.Println(ctx.Err(), cancel != nil, describe(cancel), describe(ctx), describe(ctx.Err()), describe(nil), describe(5))

                    // Timeouts and deadlines.
                    timed, cancelTimed := context.WithTimeout(root, 20*time.Millisecond)
                    defer cancelTimed()
                    due, has := timed.Deadline()
                    fmt.Println(has, time.Until(due) > 0, time.Until(due) <= 20*time.Millisecond, timed.Err())
                    inner, cancelInner := context.WithTimeout(timed, time.Hour)
                    innerDue, _ := inner.Deadline()
                    fmt.Println(innerDue.Equal(due), wait(inner, "inner"), wait(timed, "timed"))
                    cancelInner()
                    fmt.Println(timed.Err() == context.DeadlineExceeded, errors.Is(inner.Err(), context.DeadlineExceeded), inner.Err())
                    past, cancelPast := context.WithDeadline(root, time.Now().Add(-time.Second))
                    fmt.Println(past.Err(), wait(past, "past"))
                    cancelPast()
                    quick, cancelQuick := context.WithTimeout(root, time.Hour)
                    cancelQuick()
                    fmt.Println(quick.Err(), wait(quick, "quick"))
                    var timeout interface{ Timeout() bool }
                    timeout, isTimeout := context.DeadlineExceeded.(interface{ Timeout() bool })
                    fmt.Println(isTimeout, timeout.Timeout())

                    // Values.
                    withUser := context.WithValue(root, key("user"), "ada")
                    withID := context.WithValue(withUser, requestID(7), 42)
                    shadow := context.WithValue(withID, key("user"), "grace")
                    valued, cancelValued := context.WithCancel(shadow)
                    defer cancelValued()
                    fmt.Println(withUser.Value(key("user")), withID.Value(key("user")), shadow.Value(key("user")), valued.Value(key("user")))
                    fmt.Println(withUser.Value("user"), withUser.Value(key("none")), valued.Value(requestID(7)), valued.Value(requestID(8)), withID.Value(7))
                    name, isString := valued.Value(key("user")).(string)
                    fmt.Println(name, isString, withUser, withID, shadow)
                    fmt.Println(valued)

                    // A context of the program's own, a parent like any other.
                    own := &fixed{done: make(chan struct{}), name: "own"}
                    derived, cancelDerived := context.WithCancel(own)
                    defer cancelDerived()
                    tagged := context.WithValue(derived, key("tag"), 1)
                    fmt.Println(derived.Err(), tagged.Value(key("name")), tagged.Value(key("tag")), wait(tagged, "tagged"))
                    close(own.done)
                    <-derived.Done()
                    fmt.Println(derived.Err(), tagged.Err(), wait(tagged, "tagged"))
                    t := &traced{Context: withID}
                    var asContext context.Context = t
                    fmt.Println(asContext.Value(key("user")), asContext.Value(requestID(7)), t.trace, asContext.Err(), asContext.Done() == nil)
                    wrapped, cancelWrapped := context.WithTimeout(t, time.Millisecond)
                    defer cancelWrapped()
                    <-wrapped.Done()
                    fmt.Println(wrapped.Err(), wrapped.Value(key("user")), len(t.trace) > 2)

                    // Contexts are values: fields, maps, zero values, nil.
                    var none context.Context
                    var noCancel context.CancelFunc
                    s := server{byName: map[string]context.Context{}}
                    fmt.Println(none == nil, noCancel == nil, s.ctx == nil, s.cancel == nil, s.byName["x"] == nil, describe(none))
                    s.ctx, s.cancel = context.WithCancel(root)
                    s.byName["root"] = root
                    s.byName["s"] = s.ctx
                    all := []context.Context{root, s.ctx, timed}
                    fmt.Println(len(all), s.byName["s"] == s.ctx, s.byName["root"] == root, s.ctx != root, all[1].Err())
                    var wg sync.WaitGroup
                    results := make(chan string, 3)
                    for i := 0; i < 3; i++ {
                        wg.Add(1)
                        go func(n int) {
                            defer wg.Done()
                            <-s.ctx.Done()
                            results <- fmt.Sprint("worker ", n, " ", s.ctx.Err())
                        }(i)
                    }
                    s.cancel()
                    wg.Wait()
                    close(results)
                    count := 0
                    for r := range results {
                        if r != "" {
                            count++
                        }
                    }
                    fmt.Println(count, all[1].Err())
                }
                """#)
                == """
                context.Background context.TODO <nil> true <nil>
                false
                *errors.errorString context.deadlineExceededError context canceled context deadline exceeded
                <nil> context canceled context canceled <nil>
                context canceled context canceled context canceled context canceled
                false true true false
                context canceled late: context canceled
                context canceled true cancel func context context.Background.WithCancel err=context canceled error context canceled nil other int
                true true true <nil>
                true inner: context deadline exceeded timed: context deadline exceeded
                true true context deadline exceeded
                context deadline exceeded past: context deadline exceeded
                context canceled quick: context canceled
                true true
                ada ada grace grace
                <nil> <nil> 42 <nil> <nil>
                grace true context.Background.WithValue(main.key, ada) context.Background.WithValue(main.key, ada).WithValue(request-7, int) context.Background.WithValue(main.key, ada).WithValue(request-7, int).WithValue(main.key, grace)
                context.Background.WithValue(main.key, ada).WithValue(request-7, int).WithValue(main.key, grace).WithCancel
                <nil> own 1 tagged: still running
                fixed is over fixed is over tagged: fixed is over
                ada 42 [user request-7] <nil> true
                context deadline exceeded ada true
                true true true true true nil
                3 true true true <nil>
                3 context canceled

                """)
    }

    /// `WithCancelCause`, `Cause`, the `...Cause` forms of a deadline,
    /// `AfterFunc`, `WithoutCancel`, and the panics Go has for a nil parent, a nil
    /// key, and a nil `CancelFunc`.
    @Test func causesAfterFuncAndWithoutCancel() throws {
        #expect(
            try runGoProgram(
                #"""
                package main

                import (
                    "context"
                    "errors"
                    "fmt"
                    "time"
                )

                type key struct{}

                func try(name string, f func()) {
                    defer func() {
                        if r := recover(); r != nil {
                            fmt.Println(name, "panic:", r)
                        }
                    }()
                    f()
                }

                func main() {
                    root := context.Background()
                    boom := errors.New("boom")

                    ctx, cancel := context.WithCancelCause(root)
                    child, stop := context.WithCancel(ctx)
                    defer stop()
                    fmt.Println(context.Cause(ctx), context.Cause(child), context.Cause(root))
                    cancel(boom)
                    cancel(errors.New("later"))
                    fmt.Println(ctx.Err(), context.Cause(ctx), context.Cause(child), child.Err(), errors.Is(context.Cause(child), boom))
                    plain, cancelPlain := context.WithCancelCause(root)
                    cancelPlain(nil)
                    fmt.Println(plain.Err(), context.Cause(plain))
                    timed, cancelTimed := context.WithTimeoutCause(root, time.Millisecond, boom)
                    defer cancelTimed()
                    <-timed.Done()
                    fmt.Println(timed.Err(), context.Cause(timed))
                    due, cancelDue := context.WithDeadlineCause(root, time.Now().Add(time.Millisecond), nil)
                    defer cancelDue()
                    <-due.Done()
                    fmt.Println(due.Err(), context.Cause(due))

                    // AfterFunc.
                    ran := make(chan string, 4)
                    a, cancelA := context.WithCancel(root)
                    stopA := context.AfterFunc(a, func() { ran <- "a" })
                    cancelA()
                    fmt.Println(<-ran, stopA())
                    b, cancelB := context.WithCancel(root)
                    stopB := context.AfterFunc(b, func() { ran <- "b" })
                    fmt.Println(stopB(), stopB())
                    cancelB()
                    context.AfterFunc(b, func() { ran <- "already" })
                    fmt.Println(<-ran, len(ran))

                    // WithoutCancel keeps the values and drops the cancellation.
                    valued := context.WithValue(root, key{}, "v")
                    c, cancelC := context.WithCancel(valued)
                    free := context.WithoutCancel(c)
                    cancelC()
                    _, has := free.Deadline()
                    fmt.Println(c.Err(), free.Err(), free.Done() == nil, free.Value(key{}), has, free, context.Cause(free))
                    under, cancelUnder := context.WithCancel(free)
                    fmt.Println(under.Err(), under)
                    cancelUnder()

                    // Go's panics.
                    var none context.Context
                    try("WithCancel", func() { context.WithCancel(none) })
                    try("WithValue", func() { context.WithValue(none, key{}, 1) })
                    try("WithValue key", func() { context.WithValue(root, nil, 1) })
                    try("WithTimeout", func() { context.WithTimeout(none, time.Second) })
                    try("WithoutCancel", func() { context.WithoutCancel(none) })
                    try("nil method", func() { fmt.Println(none.Err()) })
                    var noCancel context.CancelFunc
                    try("nil cancel", func() { noCancel() })
                    fmt.Printf("%T %T %T %T\n", root, c, valued, free)
                    fmt.Printf("%v|%s|%+v\n", c, valued, context.TODO())
                }
                """#)
                == """
                <nil> <nil> <nil>
                context canceled boom boom context canceled true
                context canceled context canceled
                context deadline exceeded boom
                context deadline exceeded context deadline exceeded
                a false
                true false
                already 0
                context canceled <nil> true v false context.Background.WithValue(main.key, v).WithCancel.WithoutCancel <nil>
                <nil> context.Background.WithValue(main.key, v).WithCancel.WithoutCancel.WithCancel
                WithCancel panic: cannot create context from nil parent
                WithValue panic: cannot create context from nil parent
                WithValue key panic: nil key
                WithTimeout panic: cannot create context from nil parent
                WithoutCancel panic: cannot create context from nil parent
                nil method panic: runtime error: invalid memory address or nil pointer dereference
                nil cancel panic: runtime error: invalid memory address or nil pointer dereference
                context.backgroundCtx *context.cancelCtx *context.valueCtx context.withoutCancelCtx
                context.Background.WithValue(main.key, v).WithCancel|context.Background.WithValue(main.key, v)|context.TODO

                """)
    }

    /// The errors are those of an interface and of functions of a package,
    /// because that is what these are.
    @Test func whatIsNoContextIsRefusedAsGoRefusesIt() {
        #expect(
            firstError(
                """
                var ctx context.Context = 5
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt"])
                == "6:27: cannot use 5 (constant of type int) as context.Context value in variable declaration: int does not implement context.Context (missing method Deadline)")
        #expect(
            firstError(
                """
                var ctx context.Context = half{}
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt"],
                declarations: """
                    type half struct{}

                    func (half) Done() <-chan struct{} { return nil }
                    func (half) Err() error            { return nil }
                    """)
                == "9:27: cannot use half{} (value of struct type half) as context.Context value in variable declaration: half does not implement context.Context (missing method Deadline)")
        #expect(
            firstError(
                """
                ctx := context.Background()
                fmt.Println(ctx.Foo())
                """,
                imports: ["context", "fmt"])
                == "7:17: ctx.Foo undefined (type context.Context has no field or method Foo)")
        #expect(
            firstError(
                """
                ctx, cancel := context.WithCancel()
                fmt.Println(ctx, cancel)
                """,
                imports: ["context", "fmt"])
                == "6:16: not enough arguments in call to context.WithCancel\n\thave ()\n\twant (context.Context)")
        #expect(
            firstError(
                """
                ctx := context.WithCancel(context.Background())
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt"])
                == "6:8: assignment mismatch: 1 variable but context.WithCancel returns 2 values")
        #expect(
            firstError(
                """
                ctx, cancel := context.WithTimeout(context.Background(), 5)
                cancel(1)
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt"])
                == "7:8: too many arguments in call to cancel\n\thave (number)\n\twant ()")
        #expect(
            firstError(
                """
                n := 3
                ctx, cancel := context.WithTimeout(context.Background(), n)
                cancel()
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt"])
                == "7:58: cannot use n (variable of type int) as time.Duration value in argument to context.WithTimeout")
        #expect(
            firstError(
                """
                var cancel context.CancelFunc = func(int) {}
                cancel()
                """,
                imports: ["context", "fmt"])
                == "6:33: cannot use func(int) {} (value of type func(int)) as context.CancelFunc value in variable declaration")
        #expect(
            firstError(
                """
                ctx := context.WithValue(context.Background(), "k")
                fmt.Println(ctx)
                """,
                imports: ["context", "fmt"])
                == "6:48: not enough arguments in call to context.WithValue\n\thave (context.Context, string)\n\twant (context.Context, any, any)")
        #expect(
            firstError("fmt.Println(context.Nope)", imports: ["context", "fmt"])
                == "6:21: undefined: context.Nope")
        #expect(
            firstError(
                """
                var done chan struct{} = context.Background().Done()
                fmt.Println(done)
                """,
                imports: ["context", "fmt"])
                == "6:26: cannot use context.Background().Done() (value of type <-chan struct{}) as chan struct{} value in variable declaration")
    }

    /// A program that imports `context` is linked with its source: the image
    /// has its functions under the names Go gives them, and none of the
    /// instructions the VM keeps for images built when contexts were native.
    @Test func thePackageIsGoTextLinkedWithTheProgram() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    ctx, cancel := context.WithCancel(context.Background())
                    cancel()
                    fmt.Println(ctx.Err())
                    """, imports: ["context", "fmt"]))
        ])
        let names = Set(executable.functions.map(\.name))

        #expect(names.contains("context.WithCancel"))
        #expect(names.contains("*context.cancelCtx.Done"))
        let native: [GoInstruction] = [
            .contextBackground, .contextWithCancel, .contextWithTimeout, .contextDone, .contextErr,
            .cancelContext,
        ]
        #expect(!executable.functions.flatMap(\.instructions).contains(where: native.contains))
        #expect(GoSourceLibraryText.paths.contains("context"))
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "context canceled\n")
    }
}
