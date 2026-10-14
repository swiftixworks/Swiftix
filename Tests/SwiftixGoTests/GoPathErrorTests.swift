/// The errors of failed calls of `os` on a real file system: a fresh
/// `*fs.PathError` (or `*os.LinkError` for a rename) around Go's
/// `syscall.Errno`, which `errors.Is`, `errors.As`, and `os.IsNotExist` see,
/// from a program that names `os` and `fmt` by other names, declares a type
/// alias and a type inside a function, calls from a function literal and
/// through `os.Open` as a value, and reaches `os` from a second package of
/// its module. The expected output was printed by Go 1.24.5 for the same
/// module in an empty directory.

import Testing

@testable import Swiftix

@Suite("Go path errors")
struct GoPathErrorTests: GoTestHarness {
    private static let library = """
        package lib

        import (
            "errors"
            "io/fs"
            "os"
        )

        // Missing opens name and says whether it is missing.
        func Missing(name string) (bool, error) {
            _, err := os.Open(name)
            return errors.Is(err, fs.ErrNotExist), err
        }
        """

    private static let program = """
        package main

        import (
            "errors"
            "example/m/lib"
            f "fmt"
            "io/fs"
            o "os"
            "syscall"
        )

        type pathError = fs.PathError

        func main() {
            type holder struct{ err error }
            var h holder
            _, h.err = o.Open("missing.txt")
            f.Println(lib.Missing("missing.txt"))
            f.Printf("%v|%T|%#v\\n", h.err, h.err, h.err)
            var pe *pathError
            f.Println(errors.As(h.err, &pe), pe.Op, pe.Path, pe.Err == error(syscall.ENOENT))
            _, again := o.Open("missing.txt")
            f.Println(again == h.err, again.Error() == h.err.Error())
            mkdir := func() {
                err := o.Mkdir("d", 0o755)
                f.Println(err, o.IsExist(err), errors.Is(err, fs.ErrExist))
            }
            mkdir()
            mkdir()
            o.WriteFile("d/x", []byte("hi"), 0o644)
            err := o.Remove("d")
            f.Printf("%v %T %v\\n", err, errors.Unwrap(err), errors.Is(err, o.ErrExist))
            err = o.Rename("nope", "nope2")
            f.Printf("%v|%T|%#v|%v\\n", err, err, err, o.IsNotExist(err))
            _, err = o.ReadFile("d")
            f.Printf("%v|%#v\\n", err, err)
            _, err = o.Create("nodir/x")
            f.Println(err)
            _, err = o.OpenFile("d/x", o.O_CREATE|o.O_EXCL|o.O_WRONLY, 0o644)
            f.Println(err, o.IsExist(err))
            err = o.WriteFile("nodir/y", nil, 0o644)
            f.Println(err, o.IsNotExist(err))
            f.Println(o.Remove("d/x"), o.Remove("d"), o.Remove("d"))
            open := o.Open
            _, err = open("missing2")
            f.Println(err)
        }
        """

    private func write(_ context: ProcessContext, _ path: String, _ text: String) {
        let descriptor = context.open(path, create: true, truncate: true)!
        context.write(descriptor, Array(text.utf8))
        context.close(descriptor)
    }

    @Test func failedCallsGiveGosErrors() {
        let output = runShell(["cd /m", "go run ."]) { context in
            _ = context.mkdir("/m")
            _ = context.mkdir("/m/lib")
            write(context, "/m/go.mod", "module example/m\n\ngo 1.24\n")
            write(context, "/m/lib/lib.go", Self.library)
            write(context, "/m/main.go", Self.program)
        }
        #expect(
            shellResultLines(output).joined(separator: "\n") == """
                true open missing.txt: no such file or directory
                open missing.txt: no such file or directory|*fs.PathError|&fs.PathError{Op:"open", Path:"missing.txt", Err:0x2}
                true open missing.txt true
                false true
                <nil> false false
                mkdir d: file exists true true
                remove d: directory not empty syscall.Errno true
                rename nope nope2: no such file or directory|*os.LinkError|&os.LinkError{Op:"rename", Old:"nope", New:"nope2", Err:0x2}|true
                read d: is a directory|&fs.PathError{Op:"read", Path:"d", Err:0x15}
                open nodir/x: no such file or directory
                open d/x: file exists true
                open nodir/y: no such file or directory true
                <nil> <nil> remove d: no such file or directory
                open missing2: no such file or directory
                """)
    }
}
