/// The errors of the library as Go has them: the sentinels of `os`, `io/fs`,
/// and `io`; `*fs.PathError` and `*os.LinkError` around a `syscall.Errno`,
/// which `errors.Is` and `os.IsNotExist` see through; and `runtime.Error`,
/// which a recovered run-time error asserts to.
///
/// `io/fs`, `syscall`, `runtime`, and the error part of `os` are Go text of
/// the library (`Sources/SwiftixGoLibrary`). These programs need no file
/// system; `GoPathErrorTests` has the failures of real calls. Every
/// expected output was printed by Go 1.24.5.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go library errors")
struct GoLibraryErrorTests: GoTestHarness {

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

    /// Each sentinel is one value with Go's text, and `os` shares those of
    /// `io/fs`.
    @Test func theSentinelsAreGos() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(os.ErrNotExist, "|", os.ErrExist, "|", os.ErrPermission, "|", os.ErrClosed, "|", os.ErrInvalid)
                fmt.Println(fs.ErrNotExist == os.ErrNotExist, fs.ErrExist == os.ErrExist, fs.ErrClosed == os.ErrClosed)
                fmt.Println(os.ErrNotExist == os.ErrExist, errors.Is(os.ErrNotExist, fs.ErrNotExist))
                fmt.Printf("%T %#v\n", os.ErrNotExist, fs.ErrPermission)
                fmt.Println(io.ErrUnexpectedEOF, "|", io.ErrShortWrite, "|", io.ErrClosedPipe, "|", io.ErrNoProgress, "|", io.EOF)
                fmt.Println(io.ErrUnexpectedEOF == io.ErrShortWrite, errors.Is(fmt.Errorf("x: %w", io.ErrClosedPipe), io.ErrClosedPipe))
                """#,
                imports: ["errors", "fmt", "io", "io/fs", "os"])
                == """
                file does not exist | file already exists | permission denied | file already closed | invalid argument
                true true true
                false true
                *errors.errorString &errors.errorString{s:"permission denied"}
                unexpected EOF | short write | io: read/write on closed pipe | multiple Read calls return no data or error | EOF
                false true

                """)
    }

    /// A `*fs.PathError` prints as Go's, unwraps to its `syscall.Errno`, and
    /// `errors.Is` asks the `Errno` which kind of failure it is.
    @Test func aPathErrorHoldsAnErrno() throws {
        #expect(
            try runGoMain(
                #"""
                var err error = &fs.PathError{Op: "open", Path: "/a/b", Err: syscall.ENOENT}
                fmt.Println(err)
                fmt.Printf("%v|%+v|%T|%#v\n", err, err, err, err)
                fmt.Println(errors.Unwrap(err) == error(syscall.ENOENT), errors.Is(err, os.ErrNotExist), errors.Is(err, fs.ErrExist))
                fmt.Println(os.IsNotExist(err), os.IsExist(err), os.IsPermission(err), os.IsTimeout(err))
                var pe *os.PathError
                fmt.Println(errors.As(fmt.Errorf("load: %w", err), &pe), pe.Op, pe.Path, pe.Err)
                var en syscall.Errno
                fmt.Println(errors.As(err, &en), en, uint64(en))
                wrapped := fmt.Errorf("config: %w", err)
                fmt.Println(errors.Is(wrapped, os.ErrNotExist), os.IsNotExist(wrapped))
                """#,
                imports: ["errors", "fmt", "io/fs", "os", "syscall"])
                == """
                open /a/b: no such file or directory
                open /a/b: no such file or directory|open /a/b: no such file or directory|*fs.PathError|&fs.PathError{Op:"open", Path:"/a/b", Err:0x2}
                true true false
                true false false false
                true open /a/b no such file or directory
                true no such file or directory 2
                true false

                """)
        #expect(
            try runGoMain(
                """
                for _, e := range []syscall.Errno{syscall.EEXIST, syscall.ENOTEMPTY, syscall.EACCES, syscall.EPERM, syscall.EISDIR, syscall.ENOENT} {
                    err := &os.PathError{Op: "mkdir", Path: "d", Err: e}
                    fmt.Println(err, os.IsExist(err), os.IsPermission(err), errors.Is(err, fs.ErrExist), errors.Is(err, fs.ErrPermission))
                }
                """,
                imports: ["errors", "fmt", "io/fs", "os", "syscall"])
                == """
                mkdir d: file exists true false true false
                mkdir d: directory not empty true false true false
                mkdir d: permission denied false true false true
                mkdir d: operation not permitted false true false true
                mkdir d: is a directory false false false false
                mkdir d: no such file or directory false false false false

                """)
    }

    /// `*os.LinkError` is the error of an operation on two paths.
    @Test func aLinkErrorNamesBothPaths() throws {
        #expect(
            try runGoMain(
                #"""
                var err error = &os.LinkError{Op: "rename", Old: "a", New: "b", Err: syscall.ENOENT}
                fmt.Printf("%v|%T|%#v\n", err, err, err)
                fmt.Println(os.IsNotExist(err), errors.Is(err, fs.ErrNotExist), errors.Unwrap(err))
                """#,
                imports: ["errors", "fmt", "io/fs", "os", "syscall"])
                == """
                rename a b: no such file or directory|*os.LinkError|&os.LinkError{Op:"rename", Old:"a", New:"b", Err:0x2}
                true true no such file or directory

                """)
    }

    /// `syscall.Errno` has Linux's texts and numbers where they agree with the
    /// system Go ran on, and its own `Is`, `Timeout`, and `Temporary`.
    @Test func anErrnoIsGos() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Printf("%T %v %d %#v %x\n", syscall.ENOENT, syscall.ENOENT, syscall.ENOENT, syscall.ENOENT, syscall.EISDIR)
                fmt.Println(syscall.EACCES, "|", syscall.EEXIST, "|", syscall.ENOTDIR, "|", syscall.EINVAL, "|", syscall.EBADF, "|", syscall.EPIPE)
                fmt.Println(syscall.Errno(0x2) == syscall.ENOENT, syscall.ENOENT.Is(os.ErrNotExist), syscall.EINTR.Temporary(), syscall.ENOENT.Timeout())
                var err error = syscall.EEXIST
                fmt.Println(errors.Is(err, os.ErrExist), os.IsExist(err), err == error(syscall.EEXIST))
                """#,
                imports: ["errors", "fmt", "io/fs", "os", "syscall"])
                == """
                syscall.Errno no such file or directory 2 0x2 69732061206469726563746f7279
                permission denied | file exists | not a directory | invalid argument | bad file descriptor | broken pipe
                true true true false
                true true true

                """)
    }

    /// What a run-time error panics with asserts to `runtime.Error`, and its
    /// `RuntimeError` method exists; a panic with a string or an error of the
    /// program is not one.
    @Test func aRunTimeErrorIsARuntimeError() throws {
        #expect(
            try runGoMain(
                """
                var a []int
                i := 3
                try(func() { _ = a[i] })
                try(func() { var p *struct{ x int }; _ = p.x })
                try(func() { z := 0; _ = 1 / z })
                try(func() { var m map[int]int; m[1] = 2 })
                try(func() { var x any = "s"; _ = x.(int) })
                try(func() { _ = a[1:i] })
                try(func() { panic("text") })
                try(func() { panic(errors.New("e")) })
                """,
                imports: ["errors", "fmt", "runtime"],
                declarations: #"""
                    func try(f func()) {
                        defer func() {
                            r := recover()
                            re, ok := r.(runtime.Error)
                            if ok {
                                re.RuntimeError()
                                var target runtime.Error
                                fmt.Printf("%v %T %v\n", re.Error(), re, errors.As(fmt.Errorf("w: %w", re), &target))
                                return
                            }
                            err, isError := r.(error)
                            fmt.Println("not a runtime.Error:", r, isError, err)
                        }()
                        f()
                    }
                    """#)
                == """
                runtime error: index out of range [3] with length 0 runtime.boundsError true
                runtime error: invalid memory address or nil pointer dereference runtime.errorString true
                runtime error: integer divide by zero runtime.errorString true
                assignment to entry in nil map runtime.plainError true
                interface conversion: interface {} is string, not int *runtime.TypeAssertionError true
                runtime error: slice bounds out of range [:3] with capacity 0 runtime.boundsError true
                not a runtime.Error: text false <nil>
                not a runtime.Error: e true e

                """)
        #expect(
            try runGoMain(
                """
                runtime.GC()
                fmt.Println(kind(mine{}), kind(errors.New("x")), kind(3))
                defer func() {
                    fmt.Println(kind(recover()))
                }()
                var m map[string]int
                m["a"] = 1
                """,
                imports: ["errors", "fmt", "runtime"],
                declarations: """
                    type mine struct{}

                    func (mine) Error() string { return "mine" }
                    func (mine) RuntimeError() {}

                    func kind(r any) string {
                        switch e := r.(type) {
                        case runtime.Error:
                            return "runtime " + e.Error()
                        case error:
                            return "error " + e.Error()
                        }
                        return "other"
                    }
                    """)
                == "runtime mine error x other\nruntime assignment to entry in nil map\n")
    }

    /// Go's first error for a value that is not one of these types.
    @Test func theTypesAreCheckedAsGos() {
        #expect(
            firstError(
                """
                var e runtime.Error = errors.New("x")
                fmt.Println(e)
                """,
                imports: ["errors", "fmt", "runtime"])
                == "7:23: cannot use errors.New(\"x\") (value of interface type error) as runtime.Error value in variable declaration: error does not implement runtime.Error (missing method RuntimeError)")
        #expect(
            firstError(
                """
                var p *fs.PathError = os.ErrNotExist
                fmt.Println(p)
                """,
                imports: ["errors", "fmt", "io/fs", "os", "syscall"])
                == "9:23: cannot use os.ErrNotExist (variable of interface type error) as *fs.PathError value in variable declaration: need type assertion")
        #expect(
            firstError("fmt.Println(syscall.ENOENT + \"x\")", imports: ["errors", "fmt", "io/fs", "os", "syscall"])
                == "9:13: invalid operation: syscall.ENOENT + \"x\" (mismatched types syscall.Errno and untyped string)")
    }
}
