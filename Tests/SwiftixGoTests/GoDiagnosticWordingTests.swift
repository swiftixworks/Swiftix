/// Diagnostics worded and placed as Go words and places them.
///
/// Each case below is a program real Go 1.24.5 refuses, followed by the first
/// error `go build` prints for it, after the name of the file: the line and
/// the column, the message, and the lines that continue it, which begin with
/// a tab. This compiler reports the same error, character for character.
/// The programs were written to cover what a program can get wrong, and the
/// expected text was taken from Go, not from this compiler.

@testable import SwiftixGo
import Testing

@Suite("Go diagnostic wording")
struct GoDiagnosticWordingTests {
    /// The programs of `cases` and the error Go reports first for each. A
    /// case is a program, a line `>>> ` with the error, where `\\n` and
    /// `\\t` stand for a new line and a tab, and a line `----`.
    private static func parsed(_ cases: String) -> [(program: String, error: String)] {
        var result: [(program: String, error: String)] = []
        var program: [Substring] = []
        for line in cases.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "----" {
                program = []
            } else if line.hasPrefix(">>> ") {
                var error = ""
                var escaped = false
                for character in line.dropFirst(4) {
                    if escaped {
                        error.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else {
                        error.append(character)
                    }
                }
                result.append((program.joined(separator: "\n") + "\n", error))
            } else {
                program.append(line)
            }
        }
        return result
    }

    /// The first error of compiling `program`, as `line:column: message`.
    private static func firstError(_ program: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: program)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    private static func expectGoErrors(_ cases: String) {
        let parsed = parsed(cases)
        #expect(!parsed.isEmpty)
        for (program, error) in parsed {
            let found = firstError(program)
            #expect(found == error, "\(program)")
        }
    }

    /// A value that is none of the type it is used as: Go describes the operand,
    /// names where it was to be used, and says why a type is no implementation
    /// of an interface.
    @Test func valuesThatDoNotFit() {
        Self.expectGoErrors(Self.valuesThatDoNotFitCases)
    }

    /// An operator, an index, a builtin, or a call applied to an operand it is not
    /// defined on: Go writes the operation out and reports it where it begins,
    /// or at the operand that is at fault.
    @Test func operationsThatAreInvalid() {
        Self.expectGoErrors(Self.operationsThatAreInvalidCases)
    }

    /// A field or a method a type does not have.
    @Test func selectionsOfWhatIsNotThere() {
        Self.expectGoErrors(Self.selectionsOfWhatIsNotThereCases)
    }

    /// A call with too few or too many arguments, with what it has and what it
    /// wants, and an argument of the wrong type, for functions, methods, function
    /// values, conversions, and the functions of the library.
    @Test func callsWithTheWrongArguments() {
        Self.expectGoErrors(Self.callsWithTheWrongArgumentsCases)
    }

    /// Assignments and declarations whose two sides do not match in number,
    /// returns with the wrong number of values, names declared twice, and
    /// constants their type cannot hold.
    @Test func assignmentsAndDeclarations() {
        Self.expectGoErrors(Self.assignmentsAndDeclarationsCases)
    }

    /// Undefined names, conditions, `switch`, `range`, `select`, `defer` and `go`,
    /// expressions that are no statement, composite literals, and declarations.
    @Test func everythingElse() {
        Self.expectGoErrors(Self.everythingElseCases)
    }

    private static let valuesThatDoNotFitCases = #"""
        package main
        import _ "fmt"

        func main() {
        var s string = 1
        _ = s
        }
        >>> 5:16: cannot use 1 (untyped int constant) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var n int = "s"
        _ = n
        }
        >>> 5:13: cannot use "s" (untyped string constant) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var s string
        s = 1
        _ = s
        }
        >>> 6:5: cannot use 1 (untyped int constant) as string value in assignment
        ----
        package main
        import _ "fmt"

        func main() {
        var n int
        n = "x"
        _ = n
        }
        >>> 6:5: cannot use "x" (untyped string constant) as int value in assignment
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var s string = x
        _ = s
        }
        >>> 6:16: cannot use x (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := "a"
        var n int
        n = x
        _ = n
        }
        >>> 7:5: cannot use x (variable of type string) as int value in assignment
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        var s string = f()
        _ = s
        }
        >>> 5:16: cannot use f() (value of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{ x int }
        func main() {
        var t T
        var s string = t.x
        _ = s
        }
        >>> 6:16: cannot use t.x (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{ x int }
        func main() {
        p := &T{}
        var s string = p.x
        _ = s
        }
        >>> 6:16: cannot use p.x (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        type T int
        const c T = 5
        func main() {
        var s string = c
        _ = s
        }
        >>> 6:16: cannot use c (constant 5 of int type T) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        const c = 5
        func main() {
        var s string = c
        _ = s
        }
        >>> 5:16: cannot use c (untyped int constant 5) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int = 1
        _ = p
        }
        >>> 5:14: cannot use 1 (untyped int constant) as *int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var n int = nil
        _ = n
        }
        >>> 5:13: cannot use nil as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var s string = nil
        _ = s
        }
        >>> 5:16: cannot use nil as string value in variable declaration
        ----
        package main
        import _ "fmt"
        func f(s string) {}
        func main() {
        f(1)
        }
        >>> 5:3: cannot use 1 (untyped int constant) as string value in argument to f
        ----
        package main
        import _ "fmt"
        func f(s string) {}
        func main() {
        x := 1
        f(x)
        }
        >>> 6:3: cannot use x (variable of type int) as string value in argument to f
        ----
        package main
        import _ "fmt"
        func f(a int, s string) {}
        func main() {
        f("a", "b")
        }
        >>> 5:3: cannot use "a" (untyped string constant) as int value in argument to f
        ----
        package main
        import _ "fmt"
        func f(a int, s string) {}
        func main() {
        f(1, 2)
        }
        >>> 5:6: cannot use 2 (untyped int constant) as string value in argument to f
        ----
        package main
        import _ "fmt"
        func f() string { return 1 }
        func main() {
        _ = f()
        }
        >>> 3:26: cannot use 1 (untyped int constant) as string value in return statement
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return "a", 1 }
        func main() {
        _, _ = f()
        }
        >>> 3:33: cannot use "a" (untyped string constant) as int value in return statement
        ----
        package main
        import _ "fmt"
        func f() int { x := "s"; return x }
        func main() {
        _ = f()
        }
        >>> 3:33: cannot use x (variable of type string) as int value in return statement
        ----
        package main
        import _ "fmt"
        func f() error { return 1 }
        func main() {
        _ = f()
        }
        >>> 3:25: cannot use 1 (constant of type int) as error value in return statement: int does not implement error (missing method Error)
        ----
        package main
        import _ "fmt"
        func f() error { return "boom" }
        func main() {
        _ = f()
        }
        >>> 3:25: cannot use "boom" (constant of type string) as error value in return statement: string does not implement error (missing method Error)
        ----
        package main
        import _ "fmt"
        type T struct{ a int; b string }
        func main() {
        _ = T{a: "x"}
        }
        >>> 5:10: cannot use "x" (untyped string constant) as int value in struct literal
        ----
        package main
        import _ "fmt"
        type T struct{ a int; b string }
        func main() {
        _ = T{1, 2}
        }
        >>> 5:10: cannot use 2 (untyped int constant) as string value in struct literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []int{"a"}
        }
        >>> 5:11: cannot use "a" (untyped string constant) as int value in array or slice literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []string{1, 2}
        }
        >>> 5:14: cannot use 1 (untyped int constant) as string value in array or slice literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = [2]int{"a", 1}
        }
        >>> 5:12: cannot use "a" (untyped string constant) as int value in array or slice literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[string]int{"a": "b"}
        }
        >>> 5:25: cannot use "b" (untyped string constant) as int value in map literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[string]int{1: 2}
        }
        >>> 5:20: cannot use 1 (untyped int constant) as string value in map literal
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        ch <- "s"
        }
        >>> 6:7: cannot use "s" (untyped string constant) as int value in send
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan string, 1)
        x := 1
        ch <- x
        }
        >>> 7:7: cannot use x (variable of type int) as string value in send
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type T struct{}
        func main() {
        var i I = T{}
        _ = i
        }
        >>> 6:11: cannot use T{} (value of struct type T) as I value in variable declaration: T does not implement I (missing method M)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type T struct{}
        func (t *T) M() {}
        func main() {
        var i I = T{}
        _ = i
        }
        >>> 7:11: cannot use T{} (value of struct type T) as I value in variable declaration: T does not implement I (method M has pointer receiver)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type T struct{}
        func (t T) M(x int) {}
        func main() {
        var i I = T{}
        _ = i
        }
        >>> 7:11: cannot use T{} (value of struct type T) as I value in variable declaration: T does not implement I (wrong type for method M)\n\t\thave M(int)\n\t\twant M()
        ----
        package main
        import _ "fmt"
        type I interface{ M() int }
        type T struct{}
        func (t T) M() string { return "" }
        func main() {
        var i I = T{}
        _ = i
        }
        >>> 7:11: cannot use T{} (value of struct type T) as I value in variable declaration: T does not implement I (wrong type for method M)\n\t\thave M() string\n\t\twant M() int
        ----
        package main
        import _ "fmt"
        type I interface{ M(); N() }
        type T struct{}
        func (t T) M() {}
        func main() {
        var i I = &T{}
        _ = i
        }
        >>> 7:11: cannot use &T{} (value of type *T) as I value in variable declaration: *T does not implement I (missing method N)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type T struct{}
        func f(i I) {}
        func main() {
        f(T{})
        }
        >>> 7:3: cannot use T{} (value of struct type T) as I value in argument to f: T does not implement I (missing method M)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type T struct{}
        func f() I { return T{} }
        func main() {
        _ = f()
        }
        >>> 5:21: cannot use T{} (value of struct type T) as I value in return statement: T does not implement I (missing method M)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func main() {
        var i I = 1
        _ = i
        }
        >>> 5:11: cannot use 1 (constant of type int) as I value in variable declaration: int does not implement I (missing method M)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func main() {
        var i I = "s"
        _ = i
        }
        >>> 5:11: cannot use "s" (constant of type string) as I value in variable declaration: string does not implement I (missing method M)
        ----
        package main
        import _ "fmt"

        func main() {
        var e error = "s"
        _ = e
        }
        >>> 5:15: cannot use "s" (constant of type string) as error value in variable declaration: string does not implement error (missing method Error)
        ----
        package main
        import _ "fmt"

        func main() {
        var e error = 1
        _ = e
        }
        >>> 5:15: cannot use 1 (constant of type int) as error value in variable declaration: int does not implement error (missing method Error)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func main() {
        var e error = T{}
        _ = e
        }
        >>> 5:15: cannot use T{} (value of struct type T) as error value in variable declaration: T does not implement error (missing method Error)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) Error() string { return "" }
        func main() {
        var e error = T{}
        _ = e
        }
        >>> 6:15: cannot use T{} (value of struct type T) as error value in variable declaration: T does not implement error (method Error has pointer receiver)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any = 1
        var s string = a
        _ = s
        }
        >>> 6:16: cannot use a (variable of interface type any) as string value in variable declaration: need type assertion
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        var s string = e
        _ = s
        }
        >>> 6:16: cannot use e (variable of interface type error) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type J interface{ M(); N() }
        func main() {
        var i I
        var j J = i
        _ = j
        }
        >>> 7:11: cannot use i (variable of interface type I) as J value in variable declaration: I does not implement J (missing method N)
        ----
        package main
        import _ "fmt"

        func main() {
        var a []int
        var b []string = a
        _ = b
        }
        >>> 6:18: cannot use a (variable of type []int) as []string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var m map[string]int
        var n map[string]string = m
        _ = n
        }
        >>> 6:27: cannot use m (variable of type map[string]int) as map[string]string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var f func(int) = func(s string) {}
        _ = f
        }
        >>> 5:19: cannot use func(s string) {} (value of type func(s string)) as func(int) value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var f func() int = func() {}
        _ = f
        }
        >>> 5:20: cannot use func() {} (value of type func()) as func() int value in variable declaration
        ----
        package main
        import _ "fmt"
        type A int
        type B int
        func main() {
        var a A = 1
        var b B = a
        _ = b
        }
        >>> 7:11: cannot use a (variable of int type A) as B value in variable declaration
        ----
        package main
        import _ "fmt"
        type A int
        func main() {
        var a A = 1
        var n int = a
        _ = n
        }
        >>> 6:13: cannot use a (variable of int type A) as int value in variable declaration
        ----
        package main
        import _ "fmt"
        type A int
        func main() {
        n := 1
        var a A = n
        _ = a
        }
        >>> 6:11: cannot use n (variable of type int) as A value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := 5
        var b bool = x
        _ = b
        }
        >>> 6:14: cannot use x (variable of type int) as bool value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var b bool = "true"
        _ = b
        }
        >>> 5:14: cannot use "true" (untyped string constant) as bool value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var n int = true
        _ = n
        }
        >>> 5:13: cannot use true (untyped bool constant) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := true
        var n int = x
        _ = n
        }
        >>> 6:13: cannot use x (variable of type bool) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var b byte = "a"
        _ = b
        }
        >>> 5:14: cannot use "a" (untyped string constant) as byte value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var s string = 'a'
        _ = s
        }
        >>> 5:16: cannot use 'a' (untyped rune constant 97) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        var n int = s[0]
        _ = n
        }
        >>> 6:13: cannot use s[0] (value of type byte) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{1}
        var str string = s[0]
        _ = str
        }
        >>> 6:18: cannot use s[0] (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        var str string = m["a"]
        _ = str
        }
        >>> 6:18: cannot use m["a"] (map index expression of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        a := [3]int{}
        var str string = a[1]
        _ = str
        }
        >>> 6:18: cannot use a[1] (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        p := new(int)
        var str string = *p
        _ = str
        }
        >>> 6:18: cannot use *p (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var str string = &x
        _ = str
        }
        >>> 6:18: cannot use &x (value of type *int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var str string = []int{1}
        _ = str
        }
        >>> 5:18: cannot use []int{…} (value of type []int) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var str string = T{1}
        _ = str
        }
        >>> 5:18: cannot use T{…} (value of struct type T) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var str string = func() {}
        _ = str
        }
        >>> 5:18: cannot use func() {} (value of type func()) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        var str string = a.(int)
        _ = str
        }
        >>> 6:18: cannot use a.(int) (comma, ok expression of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        var str string = <-ch
        _ = str
        }
        >>> 6:18: cannot use <-ch (comma, ok expression of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x, y := 1, 2
        var str string = x + y
        _ = str
        }
        >>> 6:18: cannot use x + y (value of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var str string = 1 + 2
        _ = str
        }
        >>> 5:18: cannot use 1 + 2 (untyped int constant 3) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var str string = -x
        _ = str
        }
        >>> 6:18: cannot use -x (value of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var str string = x == 1
        _ = str
        }
        >>> 6:18: cannot use x == 1 (untyped bool value) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var str string = len("abc")
        _ = str
        }
        >>> 5:18: cannot use len("abc") (constant 3 of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        var n int = s[1:]
        _ = n
        }
        >>> 6:14: cannot use s[1:] (value of type string) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var n int = string("abc")
        _ = n
        }
        >>> 5:13: cannot use string("abc") (constant "abc" of type string) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var str string = int64(x)
        _ = str
        }
        >>> 6:18: cannot use int64(x) (value of type int64) as string value in variable declaration
        ----
        package main
        import "fmt"

        func main() {
        var str string = fmt.Sprint(1) + 1
        _ = str
        }
        >>> 5:18: invalid operation: fmt.Sprint(1) + 1 (mismatched types string and untyped int)
        ----
        package main
        import "fmt"

        func main() {
        var n int = fmt.Sprint(1)
        _ = n
        }
        >>> 5:13: cannot use fmt.Sprint(1) (value of type string) as int value in variable declaration
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        var str string = f
        _ = str
        }
        >>> 5:18: cannot use f (value of type func()) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M() {}
        func main() {
        var t T
        var str string = t.M
        _ = str
        }
        >>> 7:18: cannot use t.M (value of type func()) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var x int8 = 300
        _ = x
        }
        >>> 5:14: cannot use 300 (untyped int constant) as int8 value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var x uint = -1
        _ = x
        }
        >>> 5:14: cannot use -1 (untyped int constant) as uint value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var x int32 = 1 << 40
        _ = x
        }
        >>> 5:15: cannot use 1 << 40 (untyped int constant 1099511627776) as int32 value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var x int8
        x = 200
        _ = x
        }
        >>> 6:5: cannot use 200 (untyped int constant) as int8 value in assignment (overflows)
        ----
        package main
        import _ "fmt"
        func f(b byte) {}
        func main() {
        f(256)
        }
        >>> 5:3: cannot use 256 (untyped int constant) as byte value in argument to f (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        x := []byte{1, 300}
        _ = x
        }
        >>> 5:16: cannot use 300 (untyped int constant) as byte value in array or slice literal (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var a [2]int = [3]int{}
        _ = a
        }
        >>> 5:16: cannot use [3]int{} (value of type [3]int) as [2]int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        var q *string = p
        _ = q
        }
        >>> 6:17: cannot use p (variable of type *int) as *string value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var p *T = T{}
        _ = p
        }
        >>> 5:12: cannot use T{} (value of struct type T) as *T value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T = &T{}
        _ = t
        }
        >>> 5:11: cannot use &T{} (value of type *T) as T value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var ch chan int
        var r <-chan string = ch
        _ = r
        }
        >>> 6:23: cannot use ch (variable of type chan int) as <-chan string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var r <-chan int
        var ch chan int = r
        _ = ch
        }
        >>> 6:19: cannot use r (variable of type <-chan int) as chan int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var s []int = x
        _ = s
        }
        >>> 6:15: cannot use x (variable of type int) as []int value in variable declaration
        ----
        package main
        import _ "fmt"
        type T struct{ f func() }
        func main() {
        _ = T{f: 1}
        }
        >>> 5:10: cannot use 1 (untyped int constant) as func() value in struct literal
        ----
        package main
        import _ "fmt"
        type T struct{ s []string }
        func main() {
        _ = T{s: []int{1}}
        }
        >>> 5:10: cannot use []int{…} (value of type []int) as []string value in struct literal
        ----
        package main
        import _ "fmt"

        func main() {
        var s []string
        s = append(s, 1)
        }
        >>> 6:15: cannot use 1 (untyped int constant) as string value in argument to append
        ----
        package main
        import _ "fmt"

        func main() {
        var s []int
        s = append(s, "a")
        }
        >>> 6:15: cannot use "a" (untyped string constant) as int value in argument to append
        ----
        package main
        import _ "fmt"

        func main() {
        var s []int
        x := "a"
        s = append(s, 1, x)
        }
        >>> 7:18: cannot use x (variable of type string) as int value in argument to append
        ----
        package main
        import _ "fmt"

        func main() {
        var s []int
        var t []string
        s = append(s, t...)
        }
        >>> 7:15: cannot use t (variable of type []string) as []int value in argument to append
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        m[1] = 2
        }
        >>> 6:3: cannot use 1 (untyped int constant) as string value in map index
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        m["a"] = "b"
        }
        >>> 6:10: cannot use "b" (untyped string constant) as int value in assignment
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        _ = m[1]
        }
        >>> 6:7: cannot use 1 (untyped int constant) as string value in map index
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        x := 1
        delete(m, x)
        }
        >>> 7:11: cannot use x (variable of type int) as string value in argument to delete
        ----
        package main
        import _ "fmt"

        func main() {
        var n int
        var s string
        n, s = "a", 1
        _, _ = n, s
        }
        >>> 7:8: cannot use "a" (untyped string constant) as int value in assignment
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a string
        var b int
        a, b = f()
        _, _ = a, b
        }
        >>> 7:8: cannot use f() (value of type int) as string value in assignment
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a, b string = f()
        _, _ = a, b
        }
        >>> 5:19: cannot use f() (value of type int) as string value in assignment
        ----
        package main
        import _ "fmt"

        func main() {
        var a, b int = 1, "x"
        _, _ = a, b
        }
        >>> 5:19: cannot use "x" (untyped string constant) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        for i := 0; i < 3; i++ {
            var s string = i
            _ = s
        }
        }
        >>> 6:20: cannot use i (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        if x := 1; x > 0 {
            var s string = x
            _ = s
        }
        }
        >>> 6:20: cannot use x (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"
        func f(args ...int) {}
        func main() {
        f(1, "a")
        }
        >>> 5:6: cannot use "a" (untyped string constant) as int value in argument to f
        ----
        package main
        import _ "fmt"
        func f(args ...int) {}
        func main() {
        s := []string{}
        f(s...)
        }
        >>> 6:3: cannot use s (variable of type []string) as []int value in argument to f
        ----
        package main
        import _ "fmt"
        func f(args ...string) {}
        func main() {
        f("a", 2, "c")
        }
        >>> 5:8: cannot use 2 (untyped int constant) as string value in argument to f
        ----
        package main
        import _ "fmt"
        type S struct{ n int }
        func (s S) Set(v string) {}
        func main() {
        var s S
        s.Set(1)
        }
        >>> 7:7: cannot use 1 (untyped int constant) as string value in argument to s.Set
        ----
        package main
        import _ "fmt"
        type I interface{ Set(v string) }
        func main() {
        var i I
        i.Set(1)
        }
        >>> 6:7: cannot use 1 (untyped int constant) as string value in argument to i.Set
        ----
        package main
        import _ "fmt"

        func main() {
        f := func(a int) {}
        f("x")
        }
        >>> 6:3: cannot use "x" (untyped string constant) as int value in argument to f
        ----
        package main
        import _ "fmt"

        func main() {
        func(a int) {}("x")
        }
        >>> 5:16: cannot use "x" (untyped string constant) as int value in argument to func(a int) {}
        ----
        package main
        import _ "fmt"

        func main() {
        var fn func(string) int
        _ = fn(1)
        }
        >>> 6:8: cannot use 1 (untyped int constant) as string value in argument to fn
        ----
        package main
        import "fmt"

        func main() {
        defer fmt.Println()
        var e error = fmt.Errorf("x")
        var s string = e.Error
        _ = s
        }
        >>> 7:16: cannot use e.Error (value of type func() string) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        const big = 1 << 40
        var x int32 = big
        _ = x
        }
        >>> 6:15: cannot use big (untyped int constant 1099511627776) as int32 value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"
        type Color int
        const Red Color = 1
        func main() {
        var n int = Red
        _ = n
        }
        >>> 6:13: cannot use Red (constant 1 of int type Color) as int value in variable declaration
        ----
        package main
        import _ "fmt"
        type Color int
        const Red Color = 1
        func paint(n int) {}
        func main() {
        paint(Red)
        }
        >>> 7:7: cannot use Red (constant 1 of int type Color) as int value in argument to paint
        ----
        package main
        import _ "fmt"
        type Celsius int
        type Fahrenheit int
        func show(c Celsius) {}
        func main() {
        var f Fahrenheit = 10
        show(f)
        }
        >>> 8:6: cannot use f (variable of int type Fahrenheit) as Celsius value in argument to show
        ----
        package main
        import _ "fmt"

        func main() {
        var x int = 1
        var y int64 = x
        _ = y
        }
        >>> 6:15: cannot use x (variable of type int) as int64 value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var x int64 = 1
        var y int = x
        _ = y
        }
        >>> 6:13: cannot use x (variable of type int64) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        var x uint = 1
        x = -x + "a"
        }
        >>> 6:5: invalid operation: -x + "a" (mismatched types uint and untyped string)
        ----
        """#

    private static let operationsThatAreInvalidCases = #"""
        package main
        import _ "fmt"

        func main() {
        a, b := 1, "s"
        _ = a + b
        }
        >>> 6:5: invalid operation: a + b (mismatched types int and string)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := "s", 1
        _ = a + b
        }
        >>> 6:5: invalid operation: a + b (mismatched types string and int)
        ----
        package main
        import _ "fmt"

        func main() {
        a := 1
        _ = a + "s"
        }
        >>> 6:5: invalid operation: a + "s" (mismatched types int and untyped string)
        ----
        package main
        import _ "fmt"

        func main() {
        a := "s"
        _ = a + 1
        }
        >>> 6:5: invalid operation: a + 1 (mismatched types string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        a := "s"
        _ = 1 + a
        }
        >>> 6:5: invalid operation: 1 + a (mismatched types untyped int and string)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := 1, true
        _ = a + b
        }
        >>> 6:5: invalid operation: a + b (mismatched types int and bool)
        ----
        package main
        import _ "fmt"

        func main() {
        var a int8 = 1
        var b int16 = 2
        _ = a + b
        }
        >>> 7:5: invalid operation: a + b (mismatched types int8 and int16)
        ----
        package main
        import _ "fmt"

        func main() {
        var a int = 1
        var b int64 = 2
        _ = a * b
        }
        >>> 7:5: invalid operation: a * b (mismatched types int and int64)
        ----
        package main
        import _ "fmt"
        type A int
        type B int
        func main() {
        var a A
        var b B
        _ = a + b
        }
        >>> 8:5: invalid operation: a + b (mismatched types A and B)
        ----
        package main
        import _ "fmt"
        type A int
        func main() {
        var a A
        n := 1
        _ = a - n
        }
        >>> 7:5: invalid operation: a - n (mismatched types A and int)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := 1, "s"
        _ = a == b
        }
        >>> 6:10: invalid operation: a == b (mismatched types int and string)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := 1, "s"
        if a != b {
        }
        }
        >>> 6:9: invalid operation: a != b (mismatched types int and string)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := 1, "s"
        _ = a < b
        }
        >>> 6:9: invalid operation: a < b (mismatched types int and string)
        ----
        package main
        import _ "fmt"

        func main() {
        a := []int{}
        b := []int{}
        _ = a == b
        }
        >>> 7:5: invalid operation: a == b (slice can only be compared to nil)
        ----
        package main
        import _ "fmt"

        func main() {
        a := map[string]int{}
        b := map[string]int{}
        _ = a == b
        }
        >>> 7:5: invalid operation: a == b (map can only be compared to nil)
        ----
        package main
        import _ "fmt"

        func main() {
        f := func() {}
        g := func() {}
        _ = f == g
        }
        >>> 7:5: invalid operation: f == g (func can only be compared to nil)
        ----
        package main
        import _ "fmt"

        func main() {
        a := []int{}
        _ = a == 1
        }
        >>> 6:10: cannot convert 1 (untyped int constant) to type []int
        ----
        package main
        import _ "fmt"
        type T struct{ s []int }
        func main() {
        a, b := T{}, T{}
        _ = a == b
        }
        >>> 6:5: invalid operation: a == b (struct containing []int cannot be compared)
        ----
        package main
        import _ "fmt"
        type T struct{ m map[string]int }
        func main() {
        a, b := T{}, T{}
        _ = a != b
        }
        >>> 6:5: invalid operation: a != b (struct containing map[string]int cannot be compared)
        ----
        package main
        import _ "fmt"
        type T struct{ f func() }
        func main() {
        a, b := T{}, T{}
        _ = a == b
        }
        >>> 6:5: invalid operation: a == b (struct containing func() cannot be compared)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := [2][]int{}, [2][]int{}
        _ = a == b
        }
        >>> 6:5: invalid operation: a == b ([2][]int cannot be compared)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        a, b := T{}, T{}
        _ = a < b
        }
        >>> 6:5: invalid operation: a < b (operator < not defined on struct)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := true, false
        _ = a < b
        }
        >>> 6:5: invalid operation: a < b (operator < not defined on bool)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := true, false
        _ = a + b
        }
        >>> 6:5: invalid operation: operator + not defined on a (variable of type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        var p, q *int
        _ = p < q
        }
        >>> 6:5: invalid operation: p < q (operator < not defined on pointer)
        ----
        package main
        import _ "fmt"

        func main() {
        var p, q *int
        _ = p + q
        }
        >>> 6:5: invalid operation: operator + not defined on p (variable of type *int)
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := []int{}, []int{}
        _ = a + b
        }
        >>> 6:5: invalid operation: operator + not defined on a (variable of type []int)
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        _ = m + m
        }
        >>> 6:5: invalid operation: operator + not defined on m (variable of type map[string]int)
        ----
        package main
        import _ "fmt"

        func main() {
        var e1, e2 error
        _ = e1 < e2
        }
        >>> 6:5: invalid operation: e1 < e2 (operator < not defined on interface)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = !x
        }
        >>> 6:6: invalid operation: operator ! not defined on x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = !s
        }
        >>> 6:6: invalid operation: operator ! not defined on s (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = -s
        }
        >>> 6:6: invalid operation: operator - not defined on s (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        _ = -b
        }
        >>> 6:6: invalid operation: operator - not defined on b (variable of type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        _ = +b
        }
        >>> 6:6: invalid operation: operator + not defined on b (variable of type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        _ = -s
        }
        >>> 6:6: invalid operation: operator - not defined on s (variable of type []int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x && true
        }
        >>> 6:5: invalid operation: x && true (mismatched types int and untyped bool)
        ----
        package main
        import _ "fmt"

        func main() {
        x, y := 1, 2
        _ = x && y
        }
        >>> 6:5: invalid operation: operator && not defined on x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x, y := 1, 2
        _ = x || y
        }
        >>> 6:5: invalid operation: operator || not defined on x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = s || true
        }
        >>> 6:5: invalid operation: s || true (mismatched types string and untyped bool)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        _ = b & true
        }
        >>> 6:5: invalid operation: operator & not defined on b (variable of type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "a"
        _ = x & 1
        }
        >>> 6:5: invalid operation: x & 1 (mismatched types string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "a"
        _ = x | "b"
        }
        >>> 6:5: invalid operation: operator | not defined on x (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        _ = ^b
        }
        >>> 6:6: invalid operation: operator ^ not defined on b (variable of type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "a"
        _ = x << 1
        }
        >>> 6:5: invalid operation: shifted operand x (variable of type string) must be integer
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x << "a"
        }
        >>> 6:10: cannot convert "a" (untyped string constant) to type uint
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        s := "a"
        _ = x << s
        }
        >>> 7:10: invalid operation: shift count s (variable of type string) must be integer
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x << -1
        }
        >>> 6:10: invalid operation: negative shift count -1 (untyped int constant)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x / 0
        }
        >>> 6:9: invalid operation: division by zero
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x % 0
        }
        >>> 6:9: invalid operation: division by zero
        ----
        package main
        import _ "fmt"

        func main() {
        _ = 1 / 0
        }
        >>> 5:9: invalid operation: division by zero
        ----
        package main
        import _ "fmt"
        const z = 0
        func main() {
        x := 5
        _ = x / z
        }
        >>> 6:9: invalid operation: division by zero
        ----
        package main
        import _ "fmt"

        func main() {
        x := "s"
        _ = x / 2
        }
        >>> 6:5: invalid operation: x / 2 (mismatched types string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "s"
        _ = x * 2
        }
        >>> 6:5: invalid operation: x * 2 (mismatched types string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "s"
        _ = x - "a"
        }
        >>> 6:5: invalid operation: operator - not defined on x (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "s"
        _ = x % "a"
        }
        >>> 6:5: invalid operation: operator % not defined on x (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x()
        }
        >>> 6:1: invalid operation: cannot call non-function x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        s()
        }
        >>> 6:1: invalid operation: cannot call non-function s (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x(1, 2)
        }
        >>> 6:5: invalid operation: cannot call non-function x (variable of type int)
        ----
        package main
        import _ "fmt"
        const c = 5
        func main() {
        c()
        }
        >>> 5:1: invalid operation: cannot call non-function c (untyped int constant 5)
        ----
        package main
        import _ "fmt"
        type T struct{ f int }
        func main() {
        var t T
        t.f()
        }
        >>> 6:1: invalid operation: cannot call non-function t.f (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        p()
        }
        >>> 6:1: invalid operation: cannot call non-function p (variable of type *int)
        ----
        package main
        import _ "fmt"

        func main() {
        nil()
        }
        >>> 5:1: invalid operation: cannot call non-function nil
        ----
        package main
        import _ "fmt"

        func main() {
        _ = 1()
        }
        >>> 5:5: invalid operation: cannot call non-function 1 (untyped int constant)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = "a"()
        }
        >>> 5:5: invalid operation: cannot call non-function "a" (untyped string constant)
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        m["a"]()
        }
        >>> 6:1: invalid operation: cannot call non-function m["a"] (map index expression of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x[0]
        }
        >>> 6:6: invalid operation: cannot index x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x[1:]
        }
        >>> 6:5: invalid operation: cannot slice x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        _ = b[0]
        }
        >>> 6:6: invalid operation: cannot index b (variable of type bool)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func main() {
        var t T
        _ = t[0]
        }
        >>> 6:6: invalid operation: cannot index t (variable of struct type T)
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        _ = p[0]
        }
        >>> 6:6: invalid operation: cannot index p (variable of type *int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{1}
        _ = s["a"]
        }
        >>> 6:7: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{1}
        i := "a"
        _ = s[i]
        }
        >>> 7:7: invalid argument: index i (variable of type string) must be integer
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        _ = s[true]
        }
        >>> 6:7: cannot convert true (untyped bool constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{1,2,3}
        _ = s["a":]
        }
        >>> 6:7: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{1,2,3}
        _ = s[:"b"]
        }
        >>> 6:8: cannot convert "b" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        _ = m[1:]
        }
        >>> 6:5: invalid operation: cannot slice m (variable of type map[string]int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = *x
        }
        >>> 6:6: invalid operation: cannot indirect x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = *s
        }
        >>> 6:6: invalid operation: cannot indirect s (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = *nil
        }
        >>> 5:6: invalid operation: cannot indirect nil
        ----
        package main
        import _ "fmt"

        func main() {
        _ = &1
        }
        >>> 5:6: invalid operation: cannot take address of 1 (untyped int constant)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = &"a"
        }
        >>> 5:6: invalid operation: cannot take address of "a" (untyped string constant)
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        _ = &f()
        }
        >>> 5:6: invalid operation: cannot take address of f() (value of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = <-x
        }
        >>> 6:7: invalid operation: cannot receive from non-channel x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan<- int)
        _ = <-ch
        }
        >>> 6:7: invalid operation: cannot receive from send-only channel ch (variable of type chan<- int)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(<-chan int)
        ch <- 1
        }
        >>> 6:1: invalid operation: cannot send to receive-only channel ch (variable of type <-chan int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x <- 1
        }
        >>> 6:1: invalid operation: cannot send to non-channel x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x.(int)
        }
        >>> 6:5: invalid operation: x (variable of type int) is not an interface
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = s.(string)
        }
        >>> 6:5: invalid operation: s (variable of type string) is not an interface
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        _ = a.(undefinedType)
        }
        >>> 6:8: undefined: undefinedType
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x++
        x.y++
        }
        >>> 7:3: x.y undefined (type int has no field or method y)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        s++
        }
        >>> 6:1: invalid operation: s++ (non-numeric type string)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        b--
        }
        >>> 6:1: invalid operation: b-- (non-numeric type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        s++
        }
        >>> 6:1: invalid operation: s++ (non-numeric type []int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := "a"
        x += 1
        }
        >>> 6:1: invalid operation: x += 1 (mismatched types string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x += "a"
        }
        >>> 6:1: invalid operation: x += "a" (mismatched types int and untyped string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := true
        x += true
        }
        >>> 6:1: invalid operation: operator + not defined on x (variable of type bool)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x -= "s"
        }
        >>> 6:1: invalid operation: x -= "s" (mismatched types int and untyped string)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        b &= 1
        }
        >>> 6:1: invalid operation: b &= 1 (mismatched types bool and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        s *= 2
        }
        >>> 6:1: invalid operation: s *= 2 (mismatched types string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x <<= "a"
        }
        >>> 6:7: cannot convert "a" (untyped string constant) to type uint
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        s -= "b"
        }
        >>> 6:1: invalid operation: operator - not defined on s (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var y int8 = 2
        x += y
        }
        >>> 7:1: invalid operation: x += y (mismatched types int and int8)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = len(1)
        }
        >>> 5:9: invalid argument: 1 (untyped int constant) for built-in len
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = len(x)
        }
        >>> 6:9: invalid argument: x (variable of type int) for built-in len
        ----
        package main
        import _ "fmt"

        func main() {
        _ = len(true)
        }
        >>> 5:9: invalid argument: true (untyped bool constant) for built-in len
        ----
        package main
        import _ "fmt"

        func main() {
        _ = cap("abc")
        }
        >>> 5:9: invalid argument: "abc" (untyped string constant) for built-in cap
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        _ = cap(m)
        }
        >>> 6:9: invalid argument: m (variable of type map[string]int) for built-in cap
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = cap(x)
        }
        >>> 6:9: invalid argument: x (variable of type int) for built-in cap
        ----
        package main
        import _ "fmt"

        func main() {
        _ = len()
        }
        >>> 5:5: invalid operation: not enough arguments for len() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = len("a", "b")
        }
        >>> 5:5: invalid operation: too many arguments for len("a", "b") (expected 1, found 2)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = cap()
        }
        >>> 5:5: invalid operation: not enough arguments for cap() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = append(x, 1)
        }
        >>> 6:12: first argument to append must be a slice; have x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = append()
        }
        >>> 5:5: invalid operation: not enough arguments for append() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = append(s, "b")
        }
        >>> 6:12: first argument to append must be a slice; have s (variable of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        close(x)
        }
        >>> 6:7: invalid operation: cannot close non-channel x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(<-chan int)
        close(ch)
        }
        >>> 6:7: invalid operation: cannot close receive-only channel ch (variable of type <-chan int)
        ----
        package main
        import _ "fmt"

        func main() {
        close()
        }
        >>> 5:1: invalid operation: not enough arguments for close() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        close(ch, ch)
        }
        >>> 6:1: invalid operation: too many arguments for close(ch, ch) (expected 1, found 2)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        delete(x, 1)
        }
        >>> 6:8: invalid argument: x (variable of type int) is not a map
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        delete(m)
        }
        >>> 6:1: invalid operation: not enough arguments for delete(m) (expected 2, found 1)
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        delete(m, "a", "b")
        }
        >>> 6:1: invalid operation: too many arguments for delete(m, "a", "b") (expected 2, found 3)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        copy(x, x)
        }
        >>> 6:6: invalid argument: copy expects slice arguments; found x (variable of type int) and x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        copy(s)
        }
        >>> 6:1: invalid operation: not enough arguments for copy(s) (expected 2, found 1)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        t := []string{}
        copy(s, t)
        }
        >>> 7:6: invalid argument: arguments to copy s (variable of type []int) and t (variable of type []string) have different element types int and string
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        copy(s, 1)
        }
        >>> 6:6: invalid argument: copy expects slice arguments; found s (variable of type []int) and 1 (untyped int constant)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make(int)
        }
        >>> 5:10: invalid argument: cannot make int; type must be slice, map, or channel
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make([]int)
        }
        >>> 5:5: invalid operation: make([]int) expects 2 or 3 arguments; found 1
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make([]int, "a")
        }
        >>> 5:17: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make([]int, 1, 2, 3)
        }
        >>> 5:5: invalid operation: make([]int, 1, 2, 3) expects 2 or 3 arguments; found 4
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make(map[string]int, "a")
        }
        >>> 5:26: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make(chan int, "a")
        }
        >>> 5:20: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = make()
        }
        >>> 5:5: invalid operation: not enough arguments for make() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = new()
        }
        >>> 5:5: invalid operation: not enough arguments for new() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = new(int, int)
        }
        >>> 5:5: invalid operation: too many arguments for new(int, int) (expected 1, found 2)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = new(1)
        }
        >>> 5:9: 1 is not a type
        ----
        package main
        import _ "fmt"

        func main() {
        panic()
        }
        >>> 5:1: invalid operation: not enough arguments for panic() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        panic(1, 2)
        }
        >>> 5:1: invalid operation: too many arguments for panic(1, 2) (expected 1, found 2)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = recover(1)
        }
        >>> 5:5: invalid operation: too many arguments for recover(1) (expected 0, found 1)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        for range x.y {
        }
        }
        >>> 6:13: x.y undefined (type int has no field or method y)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        _ = T{} + T{}
        }
        >>> 5:5: invalid operation: operator + not defined on T{} (value of struct type T)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = "a" - "b"
        }
        >>> 5:5: invalid operation: operator - not defined on "a" (untyped string constant)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = "a" * 2
        }
        >>> 5:5: invalid operation: "a" * 2 (mismatched types untyped string and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = true + 1
        }
        >>> 5:5: invalid operation: true + 1 (mismatched types untyped bool and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = nil + 1
        }
        >>> 5:5: invalid operation: nil + 1 (mismatched types untyped nil and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x == nil
        }
        >>> 6:10: invalid operation: x == nil (mismatched types int and untyped nil)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        _ = s != nil
        }
        >>> 6:10: invalid operation: s != nil (mismatched types string and untyped nil)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func main() {
        var t T
        _ = t == nil
        }
        >>> 6:10: invalid operation: t == nil (mismatched types T and untyped nil)
        ----
        package main
        import _ "fmt"

        func main() {
        b := true
        _ = b == nil
        }
        >>> 6:10: invalid operation: b == nil (mismatched types bool and untyped nil)
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        _ = p == 1
        }
        >>> 6:10: invalid operation: p == 1 (mismatched types *int and untyped int)
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        var q *string
        _ = p == q
        }
        >>> 7:10: invalid operation: p == q (mismatched types *int and *string)
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        _ = e == 1
        }
        >>> 6:10: cannot convert 1 (untyped int constant) to type interface{Error() string}
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        _ = e == "x"
        }
        >>> 6:10: cannot convert "x" (untyped string constant) to type interface{Error() string}
        ----
        package main
        import _ "fmt"
        type T struct{}
        func main() {
        var e error
        _ = e == T{}
        }
        >>> 6:10: invalid operation: e == T{} (mismatched types error and T)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        s := []int{}
        _ = a == s
        }
        >>> 7:10: invalid operation: a == s (slice can only be compared to nil)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type J interface{ N() }
        func main() {
        var i I
        var j J
        _ = i == j
        }
        >>> 8:10: invalid operation: i == j (mismatched types I and J)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        var c2 chan string
        _ = ch == c2
        }
        >>> 7:11: invalid operation: ch == c2 (mismatched types chan int and chan string)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x + nil
        }
        >>> 6:5: invalid operation: x + nil (mismatched types int and untyped nil)
        ----
        package main
        import _ "fmt"

        func main() {
        var u uint = 1
        _ = -u + -1
        }
        >>> 6:10: -1 (untyped int constant) overflows uint
        ----
        """#

    private static let selectionsOfWhatIsNotThereCases = #"""
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        _ = t.b
        }
        >>> 6:7: t.b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        t.b = 1
        }
        >>> 6:3: t.b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        p := &T{}
        _ = p.b
        }
        >>> 6:7: p.b undefined (type *T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        t.m()
        }
        >>> 6:3: t.m undefined (type T has no field or method m)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        p := &T{}
        p.m()
        }
        >>> 6:3: p.m undefined (type *T has no field or method m)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        _ = t.A
        }
        >>> 6:7: t.A undefined (type T has no field or method A, but does have field a)
        ----
        package main
        import _ "fmt"
        type T struct{ Name string }
        func main() {
        var t T
        _ = t.name
        }
        >>> 6:7: t.name undefined (type T has no field or method name, but does have field Name)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) Run() {}
        func main() {
        var t T
        t.run()
        }
        >>> 7:3: t.run undefined (type T has no field or method run, but does have method Run)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) run() {}
        func main() {
        var t T
        t.Run()
        }
        >>> 7:3: t.Run undefined (type T has no field or method Run, but does have method run)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x.f
        }
        >>> 6:7: x.f undefined (type int has no field or method f)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x.m()
        }
        >>> 6:3: x.m undefined (type int has no field or method m)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        _ = s.len
        }
        >>> 6:7: s.len undefined (type string has no field or method len)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        _ = s.Len()
        }
        >>> 6:7: s.Len undefined (type string has no field or method Len)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        _ = s.len
        }
        >>> 6:7: s.len undefined (type []int has no field or method len)
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        s.append(1)
        }
        >>> 6:3: s.append undefined (type []int has no field or method append)
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        _ = m.a
        }
        >>> 6:7: m.a undefined (type map[string]int has no field or method a)
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        _ = p.x
        }
        >>> 6:7: p.x undefined (type *int has no field or method x)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var pp **T
        _ = pp.a
        }
        >>> 6:8: pp.a undefined (type **T has no field or method a)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func (T) M() {}
        func main() {
        var pp **T
        pp.M()
        }
        >>> 7:4: pp.M undefined (type **T has no field or method M)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func main() {
        var i I
        i.N()
        }
        >>> 6:3: i.N undefined (type I has no field or method N)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func main() {
        var i I
        _ = i.x
        }
        >>> 6:7: i.x undefined (type I has no field or method x)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func main() {
        var p *I
        p.M()
        }
        >>> 6:3: p.M undefined (type *I is pointer to interface, not interface)
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        _ = e.Message
        }
        >>> 6:7: e.Message undefined (type error has no field or method Message)
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        _ = e.Msg()
        }
        >>> 6:7: e.Msg undefined (type error has no field or method Msg)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        a.Foo()
        }
        >>> 6:3: a.Foo undefined (type any has no field or method Foo)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        _ = a.x
        }
        >>> 6:7: a.x undefined (type any has no field or method x)
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        _ = f.x
        }
        >>> 5:7: f.x undefined (type func() has no field or method x)
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        _ = f().x
        }
        >>> 5:9: f().x undefined (type int has no field or method x)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func g() T { return T{} }
        func main() {
        _ = g().b
        }
        >>> 6:9: g().b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type A struct{ x int }
        type B struct{ x int }
        type C struct{ A; B }
        func main() {
        var c C
        _ = c.x
        }
        >>> 8:7: ambiguous selector c.x
        ----
        package main
        import _ "fmt"
        type A struct{}
        func (A) M() {}
        type B struct{}
        func (B) M() {}
        type C struct{ A; B }
        func main() {
        var c C
        c.M()
        }
        >>> 10:3: ambiguous selector c.M
        ----
        package main
        import _ "fmt"
        type A struct{ x int }
        type C struct{ A }
        func main() {
        var c C
        _ = c.y
        }
        >>> 7:7: c.y undefined (type C has no field or method y)
        ----
        package main
        import _ "fmt"
        type A struct{ x int }
        type C struct{ *A }
        func main() {
        var c C
        _ = c.A.y
        }
        >>> 7:9: c.A.y undefined (type *A has no field or method y)
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Foo
        }
        >>> 5:9: undefined: fmt.Foo
        ----
        package main
        import "fmt"

        func main() {
        fmt.Foo()
        }
        >>> 5:5: undefined: fmt.Foo
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.println
        }
        >>> 5:9: undefined: fmt.println
        ----
        package main
        import "fmt"

        func main() {
        fmt.println("x")
        }
        >>> 5:5: undefined: fmt.println
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Foo("a")
        }
        >>> 6:13: undefined: strings.Foo
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        _ = os.Foo
        }
        >>> 6:8: undefined: os.Foo
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        _ = time.Foo
        }
        >>> 6:10: undefined: time.Foo
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        x := time.Now()
        _ = x.Foo()
        }
        >>> 7:7: x.Foo undefined (type time.Time has no field or method Foo)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        x := time.Now()
        _ = x.foo
        }
        >>> 7:7: x.foo undefined (type time.Time has no field or method foo)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        var d time.Duration
        _ = d.Foo()
        }
        >>> 7:7: d.Foo undefined (type time.Duration has no field or method Foo)
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var wg sync.WaitGroup
        wg.Foo()
        }
        >>> 7:4: wg.Foo undefined (type "sync".WaitGroup has no field or method Foo)
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var mu sync.Mutex
        mu.lock()
        }
        >>> 7:4: mu.lock undefined (type "sync".Mutex has no field or method lock, but does have method Lock)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        _ = T.a
        }
        >>> 5:7: T.a undefined (type T has no method a)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        _ = T.M
        }
        >>> 5:7: T.M undefined (type T has no field or method M)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) M() {}
        func main() {
        _ = T.M
        }
        >>> 6:7: invalid method expression T.M (needs pointer receiver (*T).M)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t T) m() {}
        func main() {
        f := T.m
        f(T{})
        _ = (*T).x
        }
        >>> 8:10: (*T).x undefined (type *T has no field or method x)
        ----
        package main
        import _ "fmt"
        type T int
        func main() {
        var t T
        _ = t.x
        }
        >>> 6:7: t.x undefined (type T has no field or method x)
        ----
        package main
        import _ "fmt"
        type T int
        func main() {
        var t T
        t.x = 1
        }
        >>> 6:3: t.x undefined (type T has no field or method x)
        ----
        package main
        import _ "fmt"
        type T []int
        func main() {
        var t T
        _ = t.Len()
        }
        >>> 6:7: t.Len undefined (type T has no field or method Len)
        ----
        package main
        import _ "fmt"
        type T func()
        func main() {
        var t T
        t.x()
        }
        >>> 6:3: t.x undefined (type T has no field or method x)
        ----
        package main
        import _ "fmt"
        type P *int
        func main() {
        var p P
        _ = p.x
        }
        >>> 6:7: p.x undefined (type P has no field or method x)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        type P *T
        func main() {
        var p P
        _ = p.b
        }
        >>> 7:7: p.b undefined (type P has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a struct{ b int } }
        func main() {
        var t T
        _ = t.a.c
        }
        >>> 6:9: t.a.c undefined (type struct{b int} has no field or method c)
        ----
        package main
        import _ "fmt"
        type T struct{ a struct{ b int } }
        func main() {
        var t T
        _ = t.a.b.c
        }
        >>> 6:11: t.a.b.c undefined (type int has no field or method c)
        ----
        package main
        import _ "fmt"
        type T struct{ a []int }
        func main() {
        var t T
        _ = t.a[0].x
        }
        >>> 6:12: t.a[0].x undefined (type int has no field or method x)
        ----
        package main
        import _ "fmt"
        type T struct{ next *T; v int }
        func main() {
        var t T
        _ = t.next.next.w
        }
        >>> 6:17: t.next.next.w undefined (type *T has no field or method w)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        ts := []T{}
        _ = ts[0].b
        }
        >>> 6:11: ts[0].b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        m := map[string]T{}
        _ = m["k"].b
        }
        >>> 6:12: m["k"].b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        m := map[string]*T{}
        m["k"].b = 1
        }
        >>> 6:8: m["k"].b undefined (type *T has no field or method b)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x.y = 2
        }
        >>> 6:3: x.y undefined (type int has no field or method y)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = nil.x
        }
        >>> 5:9: nil.x undefined (type untyped nil has no field or method x)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = "abc".x
        }
        >>> 5:11: "abc".x undefined (type untyped string has no field or method x)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        _ = T{}.b
        }
        >>> 5:9: T{}.b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        _ = (&T{}).b
        }
        >>> 5:12: (&T{}).b undefined (type *T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        f := func() T { return T{} }
        _ = f().b
        }
        >>> 6:9: f().b undefined (type T has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        _ = t.a.b
        }
        >>> 6:9: t.a.b undefined (type int has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ f func() }
        func main() {
        var t T
        t.g()
        }
        >>> 6:3: t.g undefined (type T has no field or method g)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        ch.Close()
        }
        >>> 6:4: ch.Close undefined (type chan int has no field or method Close)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func (t T) String() string { return "" }
        func main() {
        var t T
        _ = t.string()
        }
        >>> 7:7: t.string undefined (type T has no field or method string, but does have method String)
        ----
        package main
        import _ "fmt"

        func main() {
        var x struct{ a int }
        _ = x.b
        }
        >>> 6:7: x.b undefined (type struct{a int} has no field or method b)
        ----
        package main
        import _ "fmt"

        func main() {
        x := struct{ a int }{1}
        _ = x.b
        }
        >>> 6:7: x.b undefined (type struct{a int} has no field or method b)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        _ = t.a.(int)
        }
        >>> 6:5: invalid operation: t.a (variable of type int) is not an interface
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = T{c: 1}
        }
        >>> 5:7: unknown field c in struct literal of type T
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = T{a: 1, a: 2}
        }
        >>> 5:13: duplicate field name a in struct literal
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = T{1}
        }
        >>> 5:8: too few values in struct literal of type T
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = T{1, 2, 3}
        }
        >>> 5:13: too many values in struct literal of type T
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = T{a: 1, 2}
        }
        >>> 5:13: mixture of field:value and value elements in struct literal
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = &T{c: 1}
        }
        >>> 5:8: unknown field c in struct literal of type T
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = []T{{c: 1}}
        }
        >>> 5:10: unknown field c in struct literal of type T
        ----
        package main
        import _ "fmt"
        type T struct{ a, b int }
        func main() {
        _ = map[string]T{"k": {1}}
        }
        >>> 5:25: too few values in struct literal of type T
        ----
        """#

    private static let callsWithTheWrongArgumentsCases = #"""
        package main
        import _ "fmt"
        func f(a int, b string) {}
        func main() {
        f(1)
        }
        >>> 5:3: not enough arguments in call to f\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        func f(a int, b string) {}
        func main() {
        f()
        }
        >>> 5:1: not enough arguments in call to f\n\thave ()\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        func f(a int, b string) {}
        func main() {
        f(1, "a", 2)
        }
        >>> 5:11: too many arguments in call to f\n\thave (number, string, number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        f(1)
        }
        >>> 5:3: too many arguments in call to f\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        f(1, "a")
        }
        >>> 5:3: too many arguments in call to f\n\thave (number, string)\n\twant ()
        ----
        package main
        import _ "fmt"
        func f(a int) int { return a }
        func main() {
        x := f()
        _ = x
        }
        >>> 5:6: not enough arguments in call to f\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f(a int) int { return a }
        func main() {
        x := f(1, 2)
        _ = x
        }
        >>> 5:11: too many arguments in call to f\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f(a int, b ...string) {}
        func main() {
        f()
        }
        >>> 5:1: not enough arguments in call to f\n\thave ()\n\twant (int, ...string)
        ----
        package main
        import _ "fmt"
        func f(a int, b ...string) {}
        func main() {
        s := []string{}
        f(1, "a", s...)
        }
        >>> 6:11: too many arguments in call to f\n\thave (number, string, []string...)\n\twant (int, ...string)
        ----
        package main
        import _ "fmt"
        func f(a int, b ...string) {}
        func main() {
        s := []string{}
        f(s...)
        }
        >>> 6:3: not enough arguments in call to f\n\thave ([]string...)\n\twant (int, ...string)
        ----
        package main
        import _ "fmt"
        func f(a, b int) {}
        func main() {
        x := 1
        f(x)
        }
        >>> 6:3: not enough arguments in call to f\n\thave (int)\n\twant (int, int)
        ----
        package main
        import _ "fmt"
        func f(a, b int) {}
        func main() {
        x := "s"
        f(x, x, x)
        }
        >>> 6:9: too many arguments in call to f\n\thave (string, string, string)\n\twant (int, int)
        ----
        package main
        import _ "fmt"
        func f(a int, b string, c bool) {}
        func main() {
        var e error
        f(1, e)
        }
        >>> 6:6: not enough arguments in call to f\n\thave (number, error)\n\twant (int, string, bool)
        ----
        package main
        import _ "fmt"
        func f(a []int, m map[string]int) {}
        func main() {
        f(nil)
        }
        >>> 5:3: not enough arguments in call to f\n\thave (nil)\n\twant ([]int, map[string]int)
        ----
        package main
        import _ "fmt"
        func f(a int) {}
        func main() {
        f(1, nil)
        }
        >>> 5:6: too many arguments in call to f\n\thave (number, nil)\n\twant (int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M(a int, b string) {}
        func main() {
        var t T
        t.M(1)
        }
        >>> 7:5: not enough arguments in call to t.M\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M(a int, b string) {}
        func main() {
        var t T
        t.M(1, "a", 3)
        }
        >>> 7:13: too many arguments in call to t.M\n\thave (number, string, number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (*T) M() {}
        func main() {
        t := &T{}
        t.M(1)
        }
        >>> 7:5: too many arguments in call to t.M\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M() int { return 0 }
        func main() {
        var t T
        _ = t.M("a", 1)
        }
        >>> 7:9: too many arguments in call to t.M\n\thave (string, number)\n\twant ()
        ----
        package main
        import _ "fmt"
        type I interface{ M(a int, b string) }
        func main() {
        var i I
        i.M(1)
        }
        >>> 6:5: not enough arguments in call to i.M\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        type I interface{ M(a int) }
        func main() {
        var i I
        i.M(1, 2)
        }
        >>> 6:8: too many arguments in call to i.M\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func main() {
        var i I
        i.M(1)
        }
        >>> 6:5: too many arguments in call to i.M\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"

        func main() {
        f := func(a int, b string) {}
        f(1)
        }
        >>> 6:3: not enough arguments in call to f\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"

        func main() {
        f := func(a int) {}
        f(1, 2)
        }
        >>> 6:6: too many arguments in call to f\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"

        func main() {
        f := func() {}
        f(1)
        }
        >>> 6:3: too many arguments in call to f\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"

        func main() {
        var f func(int, string) bool
        _ = f(1)
        }
        >>> 6:7: not enough arguments in call to f\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"

        func main() {
        var f func(int, string) bool
        _ = f(1, "a", true)
        }
        >>> 6:15: too many arguments in call to f\n\thave (number, string, bool)\n\twant (int, string)
        ----
        package main
        import _ "fmt"

        func main() {
        func(a int) {}()
        }
        >>> 5:1: not enough arguments in call to func(a int) {}\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"

        func main() {
        func(a int) {}(1, 2)
        }
        >>> 5:19: too many arguments in call to func(a int) {}\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"

        func main() {
        func() {}(1)
        }
        >>> 5:11: too many arguments in call to func() {}\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        type T struct{ f func(int) }
        func main() {
        var t T
        t.f()
        }
        >>> 6:1: not enough arguments in call to t.f\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        type T struct{ f func(int) }
        func main() {
        var t T
        t.f(1, 2)
        }
        >>> 6:8: too many arguments in call to t.f\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M(a int) {}
        func main() {
        T.M(T{})
        }
        >>> 6:5: not enough arguments in call to T.M\n\thave (T)\n\twant (T, int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M(a int) {}
        func main() {
        T.M(T{}, 1, 2)
        }
        >>> 6:13: too many arguments in call to T.M\n\thave (T, number, number)\n\twant (T, int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M(a int) {}
        func main() {
        T.M()
        }
        >>> 6:1: not enough arguments in call to T.M\n\thave ()\n\twant (T, int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M(a int) {}
        func main() {
        var t T
        g := t.M
        g()
        }
        >>> 8:1: not enough arguments in call to g\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        func g() (int, string) { return 1, "" }
        func f(a int, b string, c bool) {}
        func main() {
        f(g())
        }
        >>> 6:3: not enough arguments in call to f\n\thave (int, string)\n\twant (int, string, bool)
        ----
        package main
        import _ "fmt"
        func g() (int, string) { return 1, "" }
        func f(a int) {}
        func main() {
        f(g())
        }
        >>> 6:3: too many arguments in call to f\n\thave (int, string)\n\twant (int)
        ----
        package main
        import _ "fmt"
        func g() (int, string) { return 1, "" }
        func f(a string, b int) {}
        func main() {
        f(g())
        }
        >>> 6:3: cannot use g() (value of type int) as string value in argument to f
        ----
        package main
        import _ "fmt"
        func g() (int, string) { return 1, "" }
        func f() {}
        func main() {
        f(g())
        }
        >>> 6:3: too many arguments in call to f\n\thave (int, string)\n\twant ()
        ----
        package main
        import _ "fmt"
        func g() {}
        func f(a int) {}
        func main() {
        f(g())
        }
        >>> 6:3: g() (no value) used as value
        ----
        package main
        import _ "fmt"
        func g() (int, string) { return 1, "" }
        func f(a int, b string, c int) {}
        func main() {
        f(g(), 1)
        }
        >>> 6:3: multiple-value g() (value of type (int, string)) in single-value context
        ----
        package main
        import "fmt"
        func g() (int, string) { return 1, "" }
        func main() {
        fmt.Println(g(), 1)
        }
        >>> 5:13: multiple-value g() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"

        func main() {
        _ = int()
        }
        >>> 5:5: missing argument in conversion to int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = int(1, 2)
        }
        >>> 5:12: too many arguments in conversion to int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = string()
        }
        >>> 5:5: missing argument in conversion to string
        ----
        package main
        import _ "fmt"

        func main() {
        _ = string(1, 2)
        }
        >>> 5:15: too many arguments in conversion to string
        ----
        package main
        import _ "fmt"
        type T int
        func main() {
        _ = T()
        }
        >>> 5:5: missing argument in conversion to T
        ----
        package main
        import _ "fmt"
        type T int
        func main() {
        _ = T(1, 2)
        }
        >>> 5:10: too many arguments in conversion to T
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []byte()
        }
        >>> 5:5: missing argument in conversion to []byte
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []byte("a", "b")
        }
        >>> 5:17: too many arguments in conversion to []byte
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        os.Exit()
        }
        >>> 6:1: not enough arguments in call to os.Exit\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        os.Exit(1, 2)
        }
        >>> 6:12: too many arguments in call to os.Exit\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        os.Exit("a")
        }
        >>> 6:9: cannot use "a" (untyped string constant) as int value in argument to os.Exit
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.ToUpper()
        }
        >>> 6:5: not enough arguments in call to strings.ToUpper\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.ToUpper("a", "b")
        }
        >>> 6:26: too many arguments in call to strings.ToUpper\n\thave (string, string)\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.ToUpper(1)
        }
        >>> 6:21: cannot use 1 (untyped int constant) as string value in argument to strings.ToUpper
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Contains("a")
        }
        >>> 6:22: not enough arguments in call to strings.Contains\n\thave (string)\n\twant (string, string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Contains("a", "b", "c")
        }
        >>> 6:32: too many arguments in call to strings.Contains\n\thave (string, string, string)\n\twant (string, string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Split("a")
        }
        >>> 6:19: not enough arguments in call to strings.Split\n\thave (string)\n\twant (string, string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Repeat("a", "b")
        }
        >>> 6:25: cannot use "b" (untyped string constant) as int value in argument to strings.Repeat
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Join([]string{"a"})
        }
        >>> 6:18: not enough arguments in call to strings.Join\n\thave ([]string)\n\twant ([]string, string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Join("a", "b")
        }
        >>> 6:18: cannot use "a" (untyped string constant) as []string value in argument to strings.Join
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Index("a", 1)
        }
        >>> 6:24: cannot use 1 (untyped int constant) as string value in argument to strings.Index
        ----
        package main
        import _ "fmt"
        import "strconv"

        func main() {
        _, _ = strconv.Atoi()
        }
        >>> 6:8: not enough arguments in call to strconv.Atoi\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "strconv"

        func main() {
        _, _ = strconv.Atoi("1", 2)
        }
        >>> 6:26: too many arguments in call to strconv.Atoi\n\thave (string, number)\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "strconv"

        func main() {
        _, _ = strconv.Atoi(1)
        }
        >>> 6:21: cannot use 1 (untyped int constant) as string value in argument to strconv.Atoi
        ----
        package main
        import _ "fmt"
        import "strconv"

        func main() {
        _ = strconv.Itoa()
        }
        >>> 6:5: not enough arguments in call to strconv.Itoa\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        import "strconv"

        func main() {
        _ = strconv.Itoa("1")
        }
        >>> 6:18: cannot use "1" (untyped string constant) as int value in argument to strconv.Itoa
        ----
        package main
        import _ "fmt"
        import "strconv"

        func main() {
        _ = strconv.Itoa(1, 2)
        }
        >>> 6:21: too many arguments in call to strconv.Itoa\n\thave (number, number)\n\twant (int)
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Sprintf()
        }
        >>> 5:5: not enough arguments in call to fmt.Sprintf\n\thave ()\n\twant (string, ...any)
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Sprintf(1)
        }
        >>> 5:17: cannot use 1 (untyped int constant) as string value in argument to fmt.Sprintf
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Sprintf(1, 2)
        }
        >>> 5:17: cannot use 1 (untyped int constant) as string value in argument to fmt.Sprintf
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Errorf()
        }
        >>> 5:5: not enough arguments in call to fmt.Errorf\n\thave ()\n\twant (string, ...any)
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Errorf(1)
        }
        >>> 5:16: cannot use 1 (untyped int constant) as string value in argument to fmt.Errorf
        ----
        package main
        import "fmt"

        func main() {
        fmt.Fprintf()
        }
        >>> 5:1: not enough arguments in call to fmt.Fprintf\n\thave ()\n\twant (io.Writer, string, ...any)
        ----
        package main
        import "fmt"

        func main() {
        fmt.Fprintf(1, "x")
        }
        >>> 5:13: cannot use 1 (constant of type int) as io.Writer value in argument to fmt.Fprintf: int does not implement io.Writer (missing method Write)
        ----
        package main
        import "fmt"

        func main() {
        fmt.Fprintln("x", "y")
        }
        >>> 5:14: cannot use "x" (constant of type string) as io.Writer value in argument to fmt.Fprintln: string does not implement io.Writer (missing method Write)
        ----
        package main
        import "fmt"
        import "os"

        func main() {
        fmt.Fprint(os.Stdout)
        fmt.Fprintf(os.Stdout)
        }
        >>> 7:13: not enough arguments in call to fmt.Fprintf\n\thave (*os.File)\n\twant (io.Writer, string, ...any)
        ----
        package main
        import _ "fmt"
        import "errors"

        func main() {
        _ = errors.New()
        }
        >>> 6:5: not enough arguments in call to errors.New\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "errors"

        func main() {
        _ = errors.New(1)
        }
        >>> 6:16: cannot use 1 (untyped int constant) as string value in argument to errors.New
        ----
        package main
        import _ "fmt"
        import "errors"

        func main() {
        _ = errors.New("a", "b")
        }
        >>> 6:21: too many arguments in call to errors.New\n\thave (string, string)\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "errors"

        func main() {
        _ = errors.Is(nil)
        }
        >>> 6:15: not enough arguments in call to errors.Is\n\thave (nil)\n\twant (error, error)
        ----
        package main
        import _ "fmt"
        import "errors"

        func main() {
        _ = errors.Unwrap()
        }
        >>> 6:5: not enough arguments in call to errors.Unwrap\n\thave ()\n\twant (error)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        time.Sleep()
        }
        >>> 6:1: not enough arguments in call to time.Sleep\n\thave ()\n\twant (time.Duration)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        time.Sleep(1, 2)
        }
        >>> 6:15: too many arguments in call to time.Sleep\n\thave (number, number)\n\twant (time.Duration)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        time.Sleep("a")
        }
        >>> 6:12: cannot use "a" (untyped string constant) as time.Duration value in argument to time.Sleep
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        _ = time.Now(1)
        }
        >>> 6:14: too many arguments in call to time.Now\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        _ = time.Since()
        }
        >>> 6:5: not enough arguments in call to time.Since\n\thave ()\n\twant (time.Time)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        _ = time.Since(1)
        }
        >>> 6:16: cannot use 1 (untyped int constant) as time.Time value in argument to time.Since
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        _ = time.After()
        }
        >>> 6:5: not enough arguments in call to time.After\n\thave ()\n\twant (time.Duration)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        _ = time.Duration()
        }
        >>> 6:5: missing argument in conversion to time.Duration
        ----
        package main
        import _ "fmt"
        import "sort"

        func main() {
        sort.Ints()
        }
        >>> 6:1: not enough arguments in call to sort.Ints\n\thave ()\n\twant ([]int)
        ----
        package main
        import _ "fmt"
        import "sort"

        func main() {
        sort.Ints(1)
        }
        >>> 6:11: cannot use 1 (untyped int constant) as []int value in argument to sort.Ints
        ----
        package main
        import _ "fmt"
        import "sort"

        func main() {
        sort.Ints([]string{})
        }
        >>> 6:11: cannot use []string{} (value of type []string) as []int value in argument to sort.Ints
        ----
        package main
        import _ "fmt"
        import "sort"

        func main() {
        sort.Strings([]int{})
        }
        >>> 6:14: cannot use []int{} (value of type []int) as []string value in argument to sort.Strings
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var wg sync.WaitGroup
        wg.Add()
        }
        >>> 7:1: not enough arguments in call to wg.Add\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var wg sync.WaitGroup
        wg.Add(1, 2)
        }
        >>> 7:11: too many arguments in call to wg.Add\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var wg sync.WaitGroup
        wg.Add("a")
        }
        >>> 7:8: cannot use "a" (untyped string constant) as int value in argument to wg.Add
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var wg sync.WaitGroup
        wg.Done(1)
        }
        >>> 7:9: too many arguments in call to wg.Done\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var wg sync.WaitGroup
        wg.Wait(1)
        }
        >>> 7:9: too many arguments in call to wg.Wait\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var mu sync.Mutex
        mu.Lock(1)
        }
        >>> 7:9: too many arguments in call to mu.Lock\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "sync"

        func main() {
        var mu sync.Mutex
        mu.Unlock(1)
        }
        >>> 7:11: too many arguments in call to mu.Unlock\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        _ = e.Error(1)
        }
        >>> 6:13: too many arguments in call to e.Error\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        t := time.Now()
        _ = t.Unix(1)
        }
        >>> 7:12: too many arguments in call to t.Unix\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        t := time.Now()
        _ = t.Sub()
        }
        >>> 7:5: not enough arguments in call to t.Sub\n\thave ()\n\twant (time.Time)
        ----
        package main
        import _ "fmt"
        import "time"

        func main() {
        t := time.Now()
        _ = t.Add("a")
        }
        >>> 7:11: cannot use "a" (untyped string constant) as time.Duration value in argument to t.Add
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        _, _ = os.ReadFile()
        }
        >>> 6:8: not enough arguments in call to os.ReadFile\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        _, _ = os.ReadFile(1)
        }
        >>> 6:20: cannot use 1 (untyped int constant) as string value in argument to os.ReadFile
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        _, _ = os.ReadFile("a", "b")
        }
        >>> 6:25: too many arguments in call to os.ReadFile\n\thave (string, string)\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        _, _ = os.Open()
        }
        >>> 6:8: not enough arguments in call to os.Open\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        f, _ := os.Open("x")
        f.Close(1)
        }
        >>> 7:9: too many arguments in call to f.Close\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        f, _ := os.Open("x")
        _, _ = f.Write()
        }
        >>> 7:8: not enough arguments in call to f.Write\n\thave ()\n\twant ([]byte)
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        f, _ := os.Open("x")
        _, _ = f.Write("a")
        }
        >>> 7:16: cannot use "a" (untyped string constant) as []byte value in argument to f.Write
        ----
        package main
        import _ "fmt"
        import "os"

        func main() {
        f, _ := os.Open("x")
        _, _ = f.WriteString(1)
        }
        >>> 7:22: cannot use 1 (untyped int constant) as string value in argument to f.WriteString
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.NewReader()
        }
        >>> 6:5: not enough arguments in call to strings.NewReader\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.Fields()
        }
        >>> 6:5: not enough arguments in call to strings.Fields\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.TrimSpace(1)
        }
        >>> 6:23: cannot use 1 (untyped int constant) as string value in argument to strings.TrimSpace
        ----
        package main
        import _ "fmt"
        import "strings"

        func main() {
        _ = strings.HasPrefix("a")
        }
        >>> 6:23: not enough arguments in call to strings.HasPrefix\n\thave (string)\n\twant (string, string)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = min()
        }
        >>> 5:5: invalid operation: not enough arguments for min() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = max()
        }
        >>> 5:5: invalid operation: not enough arguments for max() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = min(1, "a")
        }
        >>> 5:12: invalid argument: mismatched types untyped int (previous argument) and untyped string (type of "a")
        ----
        package main
        import _ "fmt"

        func main() {
        x := []int{}
        clear()
        _ = x
        }
        >>> 6:1: invalid operation: not enough arguments for clear() (expected 1, found 0)
        ----
        package main
        import _ "fmt"

        func main() {
        x := []int{}
        clear(x, x)
        }
        >>> 6:1: invalid operation: too many arguments for clear(x, x) (expected 1, found 2)
        ----
        package main
        import _ "fmt"
        func f() int { return 0 }
        func main() {
        go f(1)
        }
        >>> 5:6: too many arguments in call to f\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        func f(a int) {}
        func main() {
        defer f()
        }
        >>> 5:7: not enough arguments in call to f\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f(a int) {}
        func main() {
        go f("a")
        }
        >>> 5:6: cannot use "a" (untyped string constant) as int value in argument to f
        ----
        package main
        import _ "fmt"
        func f(a int) {}
        func main() {
        defer f("a")
        }
        >>> 5:9: cannot use "a" (untyped string constant) as int value in argument to f
        ----
        package main
        import _ "fmt"
        func f() (int, error) { return 0, nil }
        func main() {
        x := f(1)
        _ = x
        }
        >>> 5:6: assignment mismatch: 1 variable but f returns 2 values
        ----
        package main
        import _ "fmt"
        func f() (int, error) { return 0, nil }
        func main() {
        x, err := f(1)
        _, _ = x, err
        }
        >>> 5:13: too many arguments in call to f\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        func f(a int) (int, error) { return 0, nil }
        func main() {
        x, err := f()
        _, _ = x, err
        }
        >>> 5:11: not enough arguments in call to f\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f(a int) (int, error) { return 0, nil }
        func main() {
        x, err := f("a")
        _, _ = x, err
        }
        >>> 5:13: cannot use "a" (untyped string constant) as int value in argument to f
        ----
        package main
        import _ "fmt"
        func f(a int) (int, error) { return 0, nil }
        func main() {
        return f()
        }
        >>> 5:8: not enough arguments in call to f\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func New(a int, b string) *T { return nil }
        func main() {
        t := New(1)
        _ = t
        }
        >>> 6:10: not enough arguments in call to New\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) Get(k string) (int, bool) { return 0, false }
        func main() {
        t := &T{}
        v, ok := t.Get()
        _, _ = v, ok
        }
        >>> 7:10: not enough arguments in call to t.Get\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) Get(k string) (int, bool) { return 0, false }
        func main() {
        t := &T{}
        v, ok := t.Get("a", "b")
        _, _ = v, ok
        }
        >>> 7:21: too many arguments in call to t.Get\n\thave (string, string)\n\twant (string)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) Get(k string) (int, bool) { return 0, false }
        func main() {
        t := &T{}
        v, ok := t.Get(1)
        _, _ = v, ok
        }
        >>> 7:16: cannot use 1 (untyped int constant) as string value in argument to t.Get
        ----
        package main
        import _ "fmt"
        type I interface{ Get(k string) (int, bool) }
        func main() {
        var i I
        v, ok := i.Get()
        _, _ = v, ok
        }
        >>> 6:10: not enough arguments in call to i.Get\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"
        type I interface{ Get(k string) (int, bool) }
        func main() {
        var i I
        v, ok := i.Get(1)
        _, _ = v, ok
        }
        >>> 6:16: cannot use 1 (untyped int constant) as string value in argument to i.Get
        ----
        package main
        import _ "fmt"

        func main() {
        var f func(string) (int, bool)
        v, ok := f()
        _, _ = v, ok
        }
        >>> 6:10: not enough arguments in call to f\n\thave ()\n\twant (string)
        ----
        package main
        import _ "fmt"

        func main() {
        var f func(string) (int, bool)
        v, ok := f(1)
        _, _ = v, ok
        }
        >>> 6:12: cannot use 1 (untyped int constant) as string value in argument to f
        ----
        """#

    private static let assignmentsAndDeclarationsCases = #"""
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        a, b := f()
        _, _ = a, b
        }
        >>> 5:9: assignment mismatch: 2 variables but f returns 1 value
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        a := f()
        _ = a
        }
        >>> 5:6: assignment mismatch: 1 variable but f returns 2 values
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        a, b, c := f()
        _, _, _ = a, b, c
        }
        >>> 5:12: assignment mismatch: 3 variables but f returns 2 values
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a int
        a = f()
        _ = a
        }
        >>> 6:5: assignment mismatch: 1 variable but f returns 2 values
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a, b, c int
        a, b, c = f()
        _, _, _ = a, b, c
        }
        >>> 6:11: assignment mismatch: 3 variables but f returns 2 values
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        var a, b int
        a, b = f()
        _, _ = a, b
        }
        >>> 6:8: assignment mismatch: 2 variables but f returns 1 value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        a := f()
        _ = a
        }
        >>> 5:6: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        var a int
        a = f()
        _ = a
        }
        >>> 6:5: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        a, b := f()
        _, _ = a, b
        }
        >>> 5:9: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a = f()
        _ = a
        }
        >>> 5:9: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a int = f()
        _ = a
        }
        >>> 5:13: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        var a, b, c = f()
        _, _, _ = a, b, c
        }
        >>> 5:15: assignment mismatch: 3 variables but f returns 2 values
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        var a, b = f()
        _, _ = a, b
        }
        >>> 5:12: assignment mismatch: 2 variables but f returns 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := 1
        _, _ = a, b
        }
        >>> 5:9: assignment mismatch: 2 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        a, b := 1, 2, 3
        _, _ = a, b
        }
        >>> 5:9: assignment mismatch: 2 variables but 3 values
        ----
        package main
        import _ "fmt"

        func main() {
        a := 1, 2
        _ = a
        }
        >>> 5:6: assignment mismatch: 1 variable but 2 values
        ----
        package main
        import _ "fmt"

        func main() {
        var a, b int
        a, b = 1
        _, _ = a, b
        }
        >>> 6:8: assignment mismatch: 2 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        var a, b int
        a, b = 1, 2, 3
        _, _ = a, b
        }
        >>> 6:8: assignment mismatch: 2 variables but 3 values
        ----
        package main
        import _ "fmt"

        func main() {
        var a int
        a = 1, 2
        _ = a
        }
        >>> 6:5: assignment mismatch: 1 variable but 2 values
        ----
        package main
        import _ "fmt"

        func main() {
        var a, b = 1
        _, _ = a, b
        }
        >>> 5:12: assignment mismatch: 2 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        var a, b = 1, 2, 3
        _, _ = a, b
        }
        >>> 5:18: extra init expr 3
        ----
        package main
        import _ "fmt"

        func main() {
        var a, b int = 1
        _, _ = a, b
        }
        >>> 5:16: assignment mismatch: 2 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        var a = 1, 2
        _ = a
        }
        >>> 5:12: extra init expr 2
        ----
        package main
        import _ "fmt"

        func main() {
        const a, b = 1
        }
        >>> 5:10: missing init expr for b
        ----
        package main
        import _ "fmt"

        func main() {
        const a = 1, 2
        }
        >>> 5:14: extra init expr 2
        ----
        package main
        import _ "fmt"

        func main() {
        m := map[string]int{}
        a, b, c := m["x"]
        _, _, _ = a, b, c
        }
        >>> 6:12: assignment mismatch: 3 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        var x any
        a, b, c := x.(int)
        _, _, _ = a, b, c
        }
        >>> 6:12: assignment mismatch: 3 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        a, b, c := <-ch
        _, _, _ = a, b, c
        }
        >>> 6:12: assignment mismatch: 3 variables but 1 value
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        x := f() + 1
        _ = x
        }
        >>> 5:6: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        fmt.Println(f() + 1)
        }
        >>> 5:13: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        x := []int{f()}
        _ = x
        }
        >>> 5:12: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        if f() {
        }
        }
        >>> 5:4: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        x := -f()
        _ = x
        }
        >>> 5:7: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        s := []int{1}
        _ = s[f()]
        }
        >>> 6:7: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func g() int { return f() }
        func main() {
        _ = g()
        }
        >>> 4:23: too many return values\n\thave (int, string)\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func g() (int, string, bool) { return f() }
        func main() {
        _, _, _ = g()
        }
        >>> 4:39: not enough return values\n\thave (int, string)\n\twant (int, string, bool)
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func g() (string, int) { return f() }
        func main() {
        _, _ = g()
        }
        >>> 4:33: cannot use f() (value of type int) as string value in return statement
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        ch := make(chan int)
        ch <- f()
        }
        >>> 6:7: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        a, b := f(), 1
        _, _ = a, b
        }
        >>> 5:9: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        switch f() {
        }
        }
        >>> 5:8: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        for range f() {
        }
        }
        >>> 5:11: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        func main() {
        defer f()
        x := map[string]int{"a": f()}
        _ = x
        }
        >>> 6:26: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() (int, string) { return 1, "" }
        type T struct{ a int }
        func main() {
        _ = T{a: f()}
        }
        >>> 6:10: multiple-value f() (value of type (int, string)) in single-value context
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        x := 1 + f()
        _ = x
        }
        >>> 5:10: f() (no value) used as value
        ----
        package main
        import "fmt"
        func f() {}
        func main() {
        fmt.Println(f())
        }
        >>> 5:13: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        if f() {
        }
        }
        >>> 5:4: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        return f()
        }
        >>> 5:8: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        var x int = f()
        _ = x
        }
        >>> 5:13: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        _ = f()
        }
        >>> 5:5: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        x := []int{f()}
        _ = x
        }
        >>> 5:12: f() (no value) used as value
        ----
        package main
        import _ "fmt"
        func f() {}
        func g(a int) {}
        func main() {
        g(f())
        }
        >>> 6:3: f() (no value) used as value
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x := 2
        _ = x
        }
        >>> 6:3: no new variables on left side of :=
        ----
        package main
        import _ "fmt"

        func main() {
        x, y := 1, 2
        x, y := 3, 4
        _, _ = x, y
        }
        >>> 6:6: no new variables on left side of :=
        ----
        package main
        import _ "fmt"

        func main() {
        var x int
        var x string
        _ = x
        }
        >>> 6:5: x redeclared in this block\n\tmain.go:5:5: other declaration of x
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        var x int
        _ = x
        }
        >>> 6:5: x redeclared in this block\n\tmain.go:5:1: other declaration of x
        ----
        package main
        import _ "fmt"

        func main() {
        var x int
        x := 2
        _ = x
        }
        >>> 6:3: no new variables on left side of :=
        ----
        package main
        import _ "fmt"

        func main() {
        const c = 1
        const c = 2
        }
        >>> 6:7: c redeclared in this block\n\tmain.go:5:7: other declaration of c
        ----
        package main
        import _ "fmt"
        func f(a int) {
            a := 1
            _ = a
        }
        func main() {
        f(1)
        }
        >>> 4:7: no new variables on left side of :=
        ----
        package main
        import _ "fmt"
        func f(a int) {
            var a string
            _ = a
        }
        func main() {
        f(1)
        }
        >>> 4:9: a redeclared in this block\n\tmain.go:3:8: other declaration of a
        ----
        package main
        import _ "fmt"
        func f(a int, a string) {}
        func main() {
        f(1, "")
        }
        >>> 3:15: a redeclared in this block\n\tmain.go:3:8: other declaration of a
        ----
        package main
        import _ "fmt"
        func f(a int) (a string) { return }
        func main() {
        f(1)
        }
        >>> 3:16: a redeclared in this block\n\tmain.go:3:8: other declaration of a
        ----
        package main
        import _ "fmt"
        func f() (a int, a string) { return }
        func main() {
        f()
        }
        >>> 3:18: a redeclared in this block\n\tmain.go:3:11: other declaration of a
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t T) m(t int) {}
        func main() {

        }
        >>> 4:14: t redeclared in this block\n\tmain.go:4:7: other declaration of t
        ----
        package main
        import _ "fmt"
        var g int
        var g string
        func main() {

        }
        >>> 4:5: g redeclared in this block\n\tmain.go:3:5: other declaration of g
        ----
        package main
        import _ "fmt"
        func h() {}
        func h() {}
        func main() {

        }
        >>> 4:6: h redeclared in this block\n\tmain.go:3:6: other declaration of h
        ----
        package main
        import _ "fmt"
        type T struct{}
        type T struct{}
        func main() {

        }
        >>> 4:6: T redeclared in this block\n\tmain.go:3:6: other declaration of T
        ----
        package main
        import _ "fmt"
        var v int
        func v() {}
        func main() {

        }
        >>> 4:6: v redeclared in this block\n\tmain.go:3:5: other declaration of v
        ----
        package main
        import _ "fmt"
        type U int
        var U int
        func main() {

        }
        >>> 4:5: U redeclared in this block\n\tmain.go:3:6: other declaration of U
        ----
        package main
        import _ "fmt"
        type T struct{ a int; a string }
        func main() {

        }
        >>> 3:23: a redeclared\n\tmain.go:3:16: other declaration of a
        ----
        package main
        import _ "fmt"
        type I interface{ M(); M() }
        func main() {

        }
        >>> 3:24: duplicate method M\n\tmain.go:3:19: other declaration of method M
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M() {}
        func (T) M() {}
        func main() {

        }
        >>> 5:10: method T.M already declared at main.go:4:10
        ----
        package main
        import _ "fmt"
        type T struct{ M int }
        func (T) M() {}
        func main() {

        }
        >>> 4:10: field and method with the same name M\n\tmain.go:3:16: other declaration of M
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        }
        >>> 5:1: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        x, y := 1, 2
        _ = x
        }
        >>> 5:4: declared and not used: y
        ----
        package main
        import _ "fmt"

        func main() {
        var x int
        }
        >>> 5:5: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        var x, y int
        _ = y
        }
        >>> 5:5: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x = 2
        }
        >>> 5:1: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        for i := 0; ; {
            break
        }
        }
        >>> 5:5: declared and not used: i
        ----
        package main
        import _ "fmt"

        func main() {
        for i, v := range []int{} {
        }
        }
        >>> 5:5: declared and not used: i
        ----
        package main
        import _ "fmt"

        func main() {
        for _, v := range []int{} {
        }
        }
        >>> 5:8: declared and not used: v
        ----
        package main
        import _ "fmt"

        func main() {
        if x := 1; true {
        }
        }
        >>> 5:4: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        switch x := 1; {
        }
        }
        >>> 5:8: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch v := a.(type) {
        }
        }
        >>> 6:8: v declared and not used
        ----
        package main
        import _ "fmt"
        func f() (int, error) { return 0, nil }
        func main() {
        v, err := f()
        _ = v
        }
        >>> 5:4: declared and not used: err
        ----
        package main
        import _ "fmt"

        func main() {
        f := func() {
            x := 1
        }
        f()
        }
        >>> 6:5: declared and not used: x
        ----
        package main
        import _ "fmt"
        func f() int {
        }
        func main() {
        _ = f()
        }
        >>> 4:1: missing return
        ----
        package main
        import _ "fmt"
        func f() int {
            if true {
                return 1
            }
        }
        func main() {
        _ = f()
        }
        >>> 7:1: missing return
        ----
        package main
        import _ "fmt"
        func f() int {
            for {
                break
            }
        }
        func main() {
        _ = f()
        }
        >>> 7:1: missing return
        ----
        package main
        import _ "fmt"
        func f(x int) int {
            switch x {
            case 1:
                return 1
            }
        }
        func main() {
        _ = f(1)
        }
        >>> 8:1: missing return
        ----
        package main
        import _ "fmt"
        func f() (n int) {
        }
        func main() {
        _ = f()
        }
        >>> 4:1: missing return
        ----
        package main
        import _ "fmt"

        func main() {
        f := func() int {
        }
        _ = f
        }
        >>> 6:1: missing return
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M() int {
        }
        func main() {

        }
        >>> 5:1: missing return
        ----
        package main
        import _ "fmt"
        func f() int {
            return
        }
        func main() {
        _ = f()
        }
        >>> 4:5: not enough return values\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f() (int, string) {
            return 1
        }
        func main() {
        _, _ = f()
        }
        >>> 4:12: not enough return values\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        func f() int {
            return 1, 2
        }
        func main() {
        _ = f()
        }
        >>> 4:15: too many return values\n\thave (number, number)\n\twant (int)
        ----
        package main
        import _ "fmt"
        func f() {
            return 1
        }
        func main() {
        f()
        }
        >>> 4:12: too many return values\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"
        func f() (int, string) {
            return
        }
        func main() {
        _, _ = f()
        }
        >>> 4:5: not enough return values\n\thave ()\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        func f() (a int, b string) {
            return 1
        }
        func main() {
        _, _ = f()
        }
        >>> 4:12: not enough return values\n\thave (number)\n\twant (int, string)
        ----
        package main
        import _ "fmt"
        func f() (int, string, bool) {
            return 1, "a"
        }
        func main() {
        _, _, _ = f()
        }
        >>> 4:15: not enough return values\n\thave (number, string)\n\twant (int, string, bool)
        ----
        package main
        import _ "fmt"

        func main() {
        return 1
        }
        >>> 5:8: too many return values\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"

        func main() {
        f := func() int { return }
        _ = f
        }
        >>> 5:19: not enough return values\n\thave ()\n\twant (int)
        ----
        package main
        import _ "fmt"

        func main() {
        f := func() { return 1 }
        _ = f
        }
        >>> 5:22: too many return values\n\thave (number)\n\twant ()
        ----
        package main
        import _ "fmt"

        func main() {
        var x int8 = 127 + 1
        _ = x
        }
        >>> 5:14: cannot use 127 + 1 (untyped int constant 128) as int8 value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        const c int8 = 300
        }
        >>> 5:16: cannot use 300 (untyped int constant) as int8 value in constant declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        const c uint = -1
        }
        >>> 5:16: cannot use -1 (untyped int constant) as uint value in constant declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        x := int8(300)
        _ = x
        }
        >>> 5:11: constant 300 overflows int8
        ----
        package main
        import _ "fmt"

        func main() {
        x := byte(256)
        _ = x
        }
        >>> 5:11: constant 256 overflows byte
        ----
        package main
        import _ "fmt"

        func main() {
        var a int8 = 1
        x := a + 200
        _ = x
        }
        >>> 6:10: 200 (untyped int constant) overflows int8
        ----
        package main
        import _ "fmt"

        func main() {
        var a int8 = 1
        _ = a == 300
        }
        >>> 6:10: 300 (untyped int constant) overflows int8
        ----
        package main
        import _ "fmt"

        func main() {
        var a uint = 1
        _ = a < -1
        }
        >>> 6:9: -1 (untyped int constant) overflows uint
        ----
        package main
        import _ "fmt"

        func main() {
        var a int8
        a += 300
        }
        >>> 6:6: 300 (untyped int constant) overflows int8
        ----
        package main
        import _ "fmt"

        func main() {
        var a byte
        a = 255 + 1
        }
        >>> 5:5: declared and not used: a
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1 << 64
        _ = x
        }
        >>> 5:6: cannot use 1 << 64 (untyped int constant 18446744073709551616) as int value in assignment (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 9223372036854775808
        _ = x
        }
        >>> 5:6: cannot use 9223372036854775808 (untyped int constant) as int value in assignment (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var x int = 1 << 63
        _ = x
        }
        >>> 5:13: cannot use 1 << 63 (untyped int constant 9223372036854775808) as int value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"
        const big = 1 << 100
        func main() {
        x := big
        _ = x
        }
        >>> 5:6: cannot use big (untyped int constant 1267650600228229401496703205376) as int value in assignment (overflows)
        ----
        package main
        import "fmt"
        const big = 1 << 100
        func main() {
        fmt.Println(big)
        }
        >>> 5:13: cannot use big (untyped int constant 1267650600228229401496703205376) as int value in argument to fmt.Println (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var u uint32 = 1 << 32
        _ = u
        }
        >>> 5:16: cannot use 1 << 32 (untyped int constant 4294967296) as uint32 value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"

        func main() {
        var i int16 = -32769
        _ = i
        }
        >>> 5:15: cannot use -32769 (untyped int constant) as int16 value in variable declaration (overflows)
        ----
        package main
        import _ "fmt"
        const c = "a"
        func main() {
        c = "b"
        }
        >>> 5:1: cannot assign to c (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        const c = 1
        func main() {
        c++
        }
        >>> 5:1: cannot assign to c (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        const c = 1
        func main() {
        c += 1
        }
        >>> 5:1: cannot assign to c (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        const c = 1
        func main() {
        _ = &c
        }
        >>> 5:6: invalid operation: cannot take address of c (untyped int constant 1)
        ----
        package main
        import _ "fmt"

        func main() {
        1 = 2
        }
        >>> 5:1: cannot assign to 1 (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        "a" = "b"
        }
        >>> 5:1: cannot assign to "a" (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        func main() {
        f() = 2
        }
        >>> 5:1: cannot assign to f() (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x + 1 = 2
        }
        >>> 6:1: cannot assign to x + 1 (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        s := "abc"
        s[0] = 'x'
        }
        >>> 6:1: cannot assign to s[0] (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        nil = 1
        }
        >>> 5:1: cannot assign to nil (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        true = false
        }
        >>> 5:1: cannot assign to true (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        func f() {}
        func main() {
        f = nil
        }
        >>> 5:1: cannot assign to f (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (T) M() {}
        func main() {
        var t T
        t.M = nil
        }
        >>> 7:1: cannot assign to t.M (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        len = 1
        }
        >>> 5:1: len (built-in) must be called
        ----
        package main
        import _ "fmt"

        func main() {
        x, 1 := 1, 2
        _ = x
        }
        >>> 5:4: non-name 1 on left side of :=
        ----
        package main
        import _ "fmt"

        func main() {
        x := nil
        _ = x
        }
        >>> 5:6: use of untyped nil in assignment
        ----
        package main
        import _ "fmt"

        func main() {
        var x = nil
        _ = x
        }
        >>> 5:9: use of untyped nil in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        x, y := nil, 1
        _, _ = x, y
        }
        >>> 5:9: use of untyped nil in assignment
        ----
        package main
        import _ "fmt"

        func main() {
        _ = nil
        }
        >>> 5:5: use of untyped nil in assignment to _ identifier
        ----
        package main
        import _ "fmt"

        func main() {
        const c = nil
        }
        >>> 5:11: nil is not constant
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x, x = 2, 3
        }
        >>> 5:1: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        a, a := 1, 2
        }
        >>> 5:1: declared and not used: a
        ----
        package main
        import _ "fmt"

        func main() {
        _ := 1
        }
        >>> 5:3: no new variables on left side of :=
        ----
        package main
        import _ "fmt"

        func main() {
        _, _ := 1, 2
        }
        >>> 5:6: no new variables on left side of :=
        ----
        package main
        import _ "fmt"

        func main() {
        var _ = 1
        x := _
        }
        >>> 6:1: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        _ = _
        }
        >>> 5:5: cannot use _ as value or type
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x + _
        }
        >>> 6:9: cannot use _ as value or type
        ----
        package main
        import _ "fmt"

        func main() {
        _()
        }
        >>> 5:1: cannot use _ as value or type
        ----
        package main
        import _ "fmt"

        func main() {
        var x _
        }
        >>> 5:5: declared and not used: x
        ----
        package main
        import _ "fmt"

        func main() {
        const c = len([]int{1})
        }
        >>> 5:11: len([]int{…}) (value of type int) is not constant
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        const c = x
        }
        >>> 6:11: x (variable of type int) is not constant
        ----
        package main
        import "fmt"

        func main() {
        const c = fmt.Sprint(1)
        }
        >>> 5:11: fmt.Sprint(1) (value of type string) is not constant
        ----
        package main
        import _ "fmt"
        func f() int { return 1 }
        const c = f()
        func main() {

        }
        >>> 4:11: f() (value of type int) is not constant
        ----
        package main
        import _ "fmt"

        func main() {
        const c int = "a"
        }
        >>> 5:15: cannot use "a" (untyped string constant) as int value in constant declaration
        ----
        package main
        import _ "fmt"

        func main() {
        const c string = 1
        }
        >>> 5:18: cannot use 1 (untyped int constant) as string value in constant declaration
        ----
        package main
        import _ "fmt"

        func main() {
        const c bool = 1
        }
        >>> 5:16: cannot use 1 (untyped int constant) as bool value in constant declaration
        ----
        package main
        import _ "fmt"

        func main() {
        const c = 1 + "a"
        }
        >>> 5:11: invalid operation: 1 + "a" (mismatched types untyped int and untyped string)
        ----
        package main
        import _ "fmt"
        type T struct{}
        const c = T{}
        func main() {

        }
        >>> 4:11: T{} (value of struct type T) is not constant
        ----
        """#

    private static let everythingElseCases = #"""
        package main
        import _ "fmt"

        func main() {
        _ = x
        }
        >>> 5:5: undefined: x
        ----
        package main
        import _ "fmt"

        func main() {
        x = 1
        }
        >>> 5:1: undefined: x
        ----
        package main
        import _ "fmt"

        func main() {
        f()
        }
        >>> 5:1: undefined: f
        ----
        package main
        import _ "fmt"

        func main() {
        _ = f(1)
        }
        >>> 5:5: undefined: f
        ----
        package main
        import _ "fmt"

        func main() {
        var a T
        _ = a
        }
        >>> 5:7: undefined: T
        ----
        package main
        import _ "fmt"

        func main() {
        _ = T{}
        }
        >>> 5:5: undefined: T
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []T{}
        }
        >>> 5:7: undefined: T
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[string]T{}
        }
        >>> 5:16: undefined: T
        ----
        package main
        import _ "fmt"

        func main() {
        var p *T
        _ = p
        }
        >>> 5:8: undefined: T
        ----
        package main
        import _ "fmt"
        func f(a T) {}
        func main() {

        }
        >>> 3:10: undefined: T
        ----
        package main
        import _ "fmt"
        func f() T { return nil }
        func main() {

        }
        >>> 3:10: undefined: T
        ----
        package main
        import _ "fmt"
        type S struct{ a T }
        func main() {

        }
        >>> 3:18: undefined: T
        ----
        package main
        import _ "fmt"
        type I interface{ M(a T) }
        func main() {

        }
        >>> 3:23: undefined: T
        ----
        package main
        import _ "fmt"

        func main() {
        _ = foo.Bar
        }
        >>> 5:5: undefined: foo
        ----
        package main
        import _ "fmt"

        func main() {
        foo.Bar()
        }
        >>> 5:1: undefined: foo
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Bar
        }
        >>> 5:9: undefined: fmt.Bar
        ----
        package main
        import "fmt"

        func main() {
        var x fmt.Bar
        _ = x
        }
        >>> 5:11: undefined: fmt.Bar
        ----
        package main
        import _ "fmt"

        func main() {
        var x foo.Bar
        _ = x
        }
        >>> 5:7: undefined: foo
        ----
        package main
        import _ "fmt"

        func main() {
        _ = fmt
        }
        >>> 5:5: undefined: fmt
        ----
        package main
        import _ "fmt"

        func main() {
        fmt = 1
        }
        >>> 5:1: undefined: fmt
        ----
        package main
        import _ "fmt"

        func main() {
        x := fmt
        _ = x
        }
        >>> 5:6: undefined: fmt
        ----
        package main
        import _ "fmt"

        func main() {
        fmt()
        }
        >>> 5:1: undefined: fmt
        ----
        package main
        import "fmt"

        func main() {
        _ = fmt.Println()
        }
        >>> 5:5: assignment mismatch: 1 variable but fmt.Println returns 2 values
        ----
        package main
        import _ "fmt"

        func main() {
        var x int = y
        _ = x
        }
        >>> 5:13: undefined: y
        ----
        package main
        import _ "fmt"

        func main() {
        x := y + 1
        _ = x
        }
        >>> 5:6: undefined: y
        ----
        package main
        import _ "fmt"

        func main() {
        _ = undefinedFunc(1) + 2
        }
        >>> 5:5: undefined: undefinedFunc
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = x.y.z
        }
        >>> 6:7: x.y undefined (type int has no field or method y)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = a.b
        }
        >>> 5:5: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        _ = a.b.c
        }
        >>> 5:5: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        a.b()
        }
        >>> 5:1: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        a.b = 1
        }
        >>> 5:1: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        a[0] = 1
        }
        >>> 5:1: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        a++
        }
        >>> 5:1: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        _ = len(a)
        }
        >>> 5:9: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        _ = &a
        }
        >>> 5:6: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        _ = *a
        }
        >>> 5:6: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        for i := range a {
            _ = i
        }
        }
        >>> 5:16: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        for _, v := range undefinedSlice {
            _ = v
        }
        }
        >>> 5:19: undefined: undefinedSlice
        ----
        package main
        import _ "fmt"

        func main() {
        if a {
        }
        }
        >>> 5:4: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        switch a {
        }
        }
        >>> 5:8: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        go a()
        }
        >>> 5:4: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        defer a()
        }
        >>> 5:7: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        a <- 1
        }
        >>> 5:1: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        _ = <-a
        }
        >>> 5:7: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        return a
        }
        >>> 5:8: undefined: a
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        if x {
        }
        }
        >>> 6:4: non-boolean condition in if statement
        ----
        package main
        import _ "fmt"

        func main() {
        if 1 {
        }
        }
        >>> 5:4: non-boolean condition in if statement
        ----
        package main
        import _ "fmt"

        func main() {
        if "a" {
        }
        }
        >>> 5:4: non-boolean condition in if statement
        ----
        package main
        import _ "fmt"

        func main() {
        s := "a"
        if s {
        }
        }
        >>> 6:4: non-boolean condition in if statement
        ----
        package main
        import _ "fmt"

        func main() {
        for 1 {
        }
        }
        >>> 5:5: non-boolean condition in for statement
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        for x {
        }
        }
        >>> 6:5: non-boolean condition in for statement
        ----
        package main
        import _ "fmt"

        func main() {
        if nil {
        }
        }
        >>> 5:4: non-boolean condition in if statement
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        if p {
        }
        }
        >>> 6:4: non-boolean condition in if statement
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        for ; x; {
        }
        }
        >>> 6:7: non-boolean condition in for statement
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        if !x {
        }
        }
        >>> 6:5: invalid operation: operator ! not defined on x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch x {
        case "a":
        }
        }
        >>> 7:6: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        x := "s"
        switch x {
        case 1:
        }
        }
        >>> 7:6: cannot convert 1 (untyped int constant) to type string
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch x {
        case 1:
        case 1:
        }
        }
        >>> 8:6: duplicate case 1 (constant of type int) in expression switch\n\tmain.go:7:6: previous case
        ----
        package main
        import _ "fmt"

        func main() {
        x := "s"
        switch x {
        case "a", "a":
        }
        }
        >>> 7:11: duplicate case "a" (constant of type string) in expression switch\n\tmain.go:7:6: previous case
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch x {
        case true:
        }
        }
        >>> 7:6: cannot convert true (untyped bool constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch {
        case x:
        }
        }
        >>> 7:6: invalid case x in switch on true (mismatched types int and bool)
        ----
        package main
        import _ "fmt"

        func main() {
        switch {
        case 1:
        }
        }
        >>> 6:6: cannot convert 1 (untyped int constant) to type bool
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch x {
        case nil:
        }
        }
        >>> 7:6: cannot convert nil to type int
        ----
        package main
        import _ "fmt"

        func main() {
        x := []int{}
        switch x {
        case x:
        }
        }
        >>> 7:6: invalid case x in switch on x (slice can only be compared to nil)
        ----
        package main
        import _ "fmt"
        type T struct{ s []int }
        func main() {
        var t T
        switch t {
        }
        }
        >>> 6:8: cannot switch on t (variable of struct type T) (T is not comparable)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch x {
        default:
        default:
        }
        }
        >>> 8:1: multiple defaults (first at main.go:7:1)
        ----
        package main
        import _ "fmt"

        func main() {
        var y int8
        x := 1
        switch x {
        case y:
        }
        }
        >>> 8:6: invalid case y in switch on x (mismatched types int8 and int)
        ----
        package main
        import _ "fmt"

        func main() {
        var e error
        switch e {
        case 1:
        }
        }
        >>> 7:6: cannot convert 1 (untyped int constant) to type interface{Error() string}
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch a {
        case []int{}:
        }
        }
        >>> 7:6: invalid case []int{} in switch on a (slice can only be compared to nil)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        switch x.(type) {
        }
        }
        >>> 6:8: x (variable of type int) is not an interface
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch a.(type) {
        case int:
        case int:
        }
        }
        >>> 8:6: duplicate case int in type switch\n\tmain.go:7:6: previous case
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch a.(type) {
        case foo:
        }
        }
        >>> 7:6: undefined: foo
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        type T struct{}
        func main() {
        var i I
        switch i.(type) {
        case T:
        }
        }
        >>> 8:6: impossible type switch case: T\n\ti (variable of interface type I) cannot have dynamic type T (missing method M)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch v := a.(type) {
        case int:
            _ = v + "a"
        }
        }
        >>> 8:9: invalid operation: v + "a" (mismatched types int and untyped string)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch a.(type) {
        case nil:
        case nil:
        }
        }
        >>> 8:6: duplicate case nil in type switch\n\tmain.go:7:6: previous case
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        switch a.(type) {
        default:
        default:
        }
        }
        >>> 8:1: multiple defaults (first at main.go:7:1)
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        _ = a.(type)
        }
        >>> 6:5: invalid syntax tree: use of .(type) outside type switch
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        for range x {
            break
        }
        for i, v := range x {
            _, _ = i, v
        }
        }
        >>> 9:8: range over x (variable of type int) permits only one iteration variable
        ----
        package main
        import _ "fmt"

        func main() {
        for i := range true {
            _ = i
        }
        }
        >>> 5:16: cannot range over true (untyped bool constant)
        ----
        package main
        import _ "fmt"

        func main() {
        var p *int
        for range p {
        }
        }
        >>> 6:11: cannot range over p (variable of type *int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func main() {
        var t T
        for range t {
        }
        }
        >>> 6:11: cannot range over t (variable of struct type T)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        for i, v := range ch {
            _, _ = i, v
        }
        }
        >>> 6:8: range over ch (variable of type chan int) permits only one iteration variable
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan<- int)
        for v := range ch {
            _ = v
        }
        }
        >>> 6:16: cannot range over ch (variable of type chan<- int): receive from send-only channel
        ----
        package main
        import _ "fmt"

        func main() {
        for i := range 10 {
            var s string = i
            _ = s
        }
        }
        >>> 6:20: cannot use i (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        for k, v := range map[string]bool{} {
            var n int = k
            _, _ = n, v
        }
        }
        >>> 6:17: cannot use k (variable of type string) as int value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        select {
        case x := 1:
            _ = x
        }
        }
        >>> 5:1: declared and not used: ch
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        select {
        case ch <- "a":
        }
        }
        >>> 7:12: cannot use "a" (untyped string constant) as int value in send
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        select {
        case v := <-ch:
            var s string = v
            _ = s
        }
        }
        >>> 8:20: cannot use v (variable of type int) as string value in variable declaration
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        select {
        default:
        default:
        }
        _ = ch
        }
        >>> 8:1: multiple defaults (first at main.go:7:1)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        select {
        case <-x:
        }
        }
        >>> 7:8: invalid operation: cannot receive from non-channel x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        select {
        case x <- 1:
        }
        }
        >>> 7:6: invalid operation: cannot send to non-channel x (variable of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        select {
        case a, b, c := <-ch:
            _, _, _ = a, b, c
        }
        }
        >>> 7:17: assignment mismatch: 3 variables but 1 value
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        defer x
        }
        >>> 6:7: expression in defer must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        defer 1
        }
        >>> 5:7: expression in defer must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        go x
        }
        >>> 6:4: expression in go must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        defer func() {}
        }
        >>> 5:7: expression in defer must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        go func() {}
        }
        >>> 5:4: expression in go must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        defer len("a")
        }
        >>> 5:7: defer discards result of len("a") (constant 1 of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        go len("a")
        }
        >>> 5:4: go discards result of len("a") (constant 1 of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        defer int(1)
        }
        >>> 5:7: defer requires function call, not conversion int(1) (constant 1 of type int)
        ----
        package main
        import _ "fmt"

        func main() {
        go string("a")
        }
        >>> 5:4: go requires function call, not conversion string("a") (constant "a" of type string)
        ----
        package main
        import _ "fmt"

        func main() {
        defer recover
        }
        >>> 5:7: expression in defer must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        defer panic
        }
        >>> 5:7: expression in defer must be function call
        ----
        package main
        import _ "fmt"

        func main() {
        s := []int{}
        defer append(s, 1)
        }
        >>> 6:7: defer discards result of append(s, 1) (value of type []int)
        ----
        package main
        import _ "fmt"

        func main() {
        defer new(int)
        }
        >>> 5:7: defer discards result of new(int) (value of type *int)
        ----
        package main
        import _ "fmt"

        func main() {
        defer make([]int, 1)
        }
        >>> 5:7: defer discards result of make([]int, 1) (value of type []int)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x
        }
        >>> 6:1: x (variable of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        1
        }
        >>> 5:1: 1 (untyped int constant) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        "a"
        }
        >>> 5:1: "a" (untyped string constant) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x + 1
        }
        >>> 6:1: x + 1 (value of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        x == 1
        }
        >>> 6:1: x == 1 (untyped bool value) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        -x
        }
        >>> 6:1: -x (value of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        x := []int{1}
        x[0]
        }
        >>> 6:1: x[0] (variable of type int) is not used
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        var t T
        t.a
        }
        >>> 6:1: t.a (variable of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        len("a")
        }
        >>> 5:1: len("a") (constant 1 of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        cap([]int{})
        }
        >>> 5:1: cap([]int{}) (value of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        x := []int{}
        append(x, 1)
        }
        >>> 6:1: append(x, 1) (value of type []int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        make([]int, 1)
        }
        >>> 5:1: make([]int, 1) (value of type []int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        new(int)
        }
        >>> 5:1: new(int) (value of type *int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        int(1)
        }
        >>> 5:1: int(1) (constant 1 of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        string("a")
        }
        >>> 5:1: string("a") (constant "a" of type string) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        []int{1}
        }
        >>> 5:1: []int{…} (value of type []int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        func() {}
        }
        >>> 5:1: func() {} (value of type func()) is not used
        ----
        package main
        import _ "fmt"
        type T struct{}
        func main() {
        T{}
        }
        >>> 5:1: T{} (value of struct type T) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        nil
        }
        >>> 5:1: nil is not used
        ----
        package main
        import _ "fmt"

        func main() {
        true
        }
        >>> 5:1: true (untyped bool constant) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        &x
        }
        >>> 6:1: &x (value of type *int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        p := new(int)
        *p
        }
        >>> 6:1: *p (variable of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        var a any
        a.(int)
        }
        >>> 6:1: a.(int) (comma, ok expression of type int) is not used
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []int{1: 1, 1: 2}
        }
        >>> 5:17: duplicate index 1 in array or slice literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = [2]int{1, 2, 3}
        }
        >>> 5:18: index 2 is out of bounds (>= 2)
        ----
        package main
        import _ "fmt"

        func main() {
        _ = [2]int{5: 1}
        }
        >>> 5:12: invalid argument: index 5 out of bounds [0:2]
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []int{-1: 1}
        }
        >>> 5:11: invalid argument: index -1 (constant of type int) must not be negative
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []int{"a": 1}
        }
        >>> 5:11: cannot convert "a" (untyped string constant) to type int
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        _ = []int{x: 1}
        }
        >>> 6:11: index x must be integer constant
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[string]int{"a": 1, "a": 2}
        }
        >>> 5:28: duplicate key "a" in map literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[int]string{1: "a", 1: "b"}
        }
        >>> 5:28: duplicate key 1 in map literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[string]int{"a"}
        }
        >>> 5:20: missing key in map literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[[]int]string{}
        }
        >>> 5:9: invalid map key type []int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[func()]int{}
        }
        >>> 5:13: invalid map key type func()
        ----
        package main
        import _ "fmt"
        type T struct{ s []int }
        func main() {
        _ = map[T]int{}
        }
        >>> 5:9: invalid map key type T
        ----
        package main
        import _ "fmt"

        func main() {
        var m map[map[string]int]int
        _ = m
        }
        >>> 5:11: invalid map key type map[string]int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = int{1}
        }
        >>> 5:5: invalid composite literal type int
        ----
        package main
        import _ "fmt"

        func main() {
        _ = string{}
        }
        >>> 5:5: invalid composite literal type string
        ----
        package main
        import _ "fmt"
        type T int
        func main() {
        _ = T{}
        }
        >>> 5:5: invalid composite literal type T
        ----
        package main
        import _ "fmt"
        type P *int
        func main() {
        _ = P{}
        }
        >>> 5:5: invalid composite literal type P
        ----
        package main
        import _ "fmt"

        func main() {
        _ = struct{ a int }{b: 1}
        }
        >>> 5:21: unknown field b in struct literal of type struct{a int}
        ----
        package main
        import _ "fmt"

        func main() {
        _ = struct{ a int }{1, 2}
        }
        >>> 5:24: too many values in struct literal of type struct{a int}
        ----
        package main
        import _ "fmt"

        func main() {
        _ = &[]int{"a"}
        }
        >>> 5:12: cannot use "a" (untyped string constant) as int value in array or slice literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = [][]int{{1, "a"}}
        }
        >>> 5:17: cannot use "a" (untyped string constant) as int value in array or slice literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = []map[string]int{{"a": "b"}}
        }
        >>> 5:28: cannot use "b" (untyped string constant) as int value in map literal
        ----
        package main
        import _ "fmt"

        func main() {
        _ = map[string][]int{"a": {1, "b"}}
        }
        >>> 5:31: cannot use "b" (untyped string constant) as int value in array or slice literal
        ----
        package main
        import _ "fmt"
        type T T
        func main() {

        }
        >>> 3:6: invalid recursive type: T refers to itself
        ----
        package main
        import _ "fmt"
        type T struct{ t T }
        func main() {

        }
        >>> 3:6: invalid recursive type: T refers to itself
        ----
        package main
        import _ "fmt"
        type T [2]T
        func main() {

        }
        >>> 3:6: invalid recursive type: T refers to itself
        ----
        package main
        import _ "fmt"
        type A B
        type B A
        func main() {

        }
        >>> 3:6: invalid recursive type A\n\tmain.go:3:6: A refers to B\n\tmain.go:4:6: B refers to A
        ----
        package main
        import _ "fmt"
        type A struct{ b B }
        type B struct{ a A }
        func main() {

        }
        >>> 3:6: invalid recursive type A\n\tmain.go:3:6: A refers to B\n\tmain.go:4:6: B refers to A
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func (t T) M() {}
        func (t *T) M() {}
        func main() {

        }
        >>> 5:13: method T.M already declared at main.go:4:12
        ----
        package main
        import _ "fmt"
        func (x int) M() {}
        func main() {

        }
        >>> 3:9: cannot define new methods on non-local type int
        ----
        package main
        import _ "fmt"
        func (x *int) M() {}
        func main() {

        }
        >>> 3:10: cannot define new methods on non-local type int
        ----
        package main
        import _ "fmt"
        func (s []int) M() {}
        func main() {

        }
        >>> 3:9: invalid receiver type []int
        ----
        package main
        import _ "fmt"
        type P *int
        func (p P) M() {}
        func main() {

        }
        >>> 4:9: invalid receiver type P (pointer or interface type)
        ----
        package main
        import _ "fmt"
        type I interface{ M() }
        func (i I) N() {}
        func main() {

        }
        >>> 4:9: invalid receiver type I (pointer or interface type)
        ----
        package main
        import _ "fmt"
        func (t Undefined) M() {}
        func main() {

        }
        >>> 3:9: undefined: Undefined
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t **T) M() {}
        func main() {

        }
        >>> 4:10: invalid receiver type **T
        ----
        package main
        import _ "fmt"
        func init() int { return 1 }
        func main() {

        }
        >>> 3:6: func init must have no arguments and no return values
        ----
        package main
        import _ "fmt"
        func init(a int) {}
        func main() {

        }
        >>> 3:6: func init must have no arguments and no return values
        ----
        package main
        import _ "fmt"
        var init = 1
        func main() {

        }
        >>> 3:5: cannot declare init - must be func
        ----
        package main
        import _ "fmt"
        func main() {}
        func main() {

        }
        >>> 4:6: main redeclared in this block\n\tmain.go:3:6: other declaration of main
        ----
        package main
        import _ "fmt"
        var main = 1
        func main() {

        }
        >>> 3:5: cannot declare main - must be func
        ----
        package main

        func main(a int) {
        }
        >>> 3:6: func main must have no arguments and no return values
        ----
        package main

        func main() int {
            return 1
        }
        >>> 3:6: func main must have no arguments and no return values
        ----
        package main

        import "fmt"

        func main() {
        }
        >>> 3:8: "fmt" imported and not used
        ----
        package main

        import (
            "fmt"
            "os"
        )

        func main() {
            fmt.Println()
        }
        >>> 5:5: "os" imported and not used
        ----
        package main

        import "fmt"
        import "fmt"

        func main() {
            fmt.Println()
        }
        >>> 4:8: fmt redeclared in this block\n\tmain.go:3:8: other declaration of fmt
        ----
        package main

        import f "fmt"

        func main() {
            fmt.Println()
        }
        >>> 3:8: "fmt" imported as f and not used
        ----
        package main

        import f "fmt"

        func main() {
        }
        >>> 3:8: "fmt" imported as f and not used
        ----
        package main

        import "fmt"

        func main() {
            fmt := 1
            fmt.Println()
        }
        >>> 3:8: "fmt" imported and not used
        ----
        package main

        import "fmt"

        var fmt = 1

        func main() {
        }
        >>> 3:8: "fmt" imported and not used
        ----
        package main

        import "fmt"

        func fmt() {}

        func main() {
        }
        >>> 3:8: "fmt" imported and not used
        ----
        package main

        func main() {
            x := 1
            {
                y := x
            }
        }
        >>> 6:9: declared and not used: y
        ----
        package main

        func f() {
            a := 1
        }

        func g() {
            b := "s" + 1
        }

        func main() {}
        >>> 4:5: declared and not used: a
        ----
        package main

        func f() {
            b := "s" + 1
            a := 1
        }

        func main() {}
        >>> 4:5: declared and not used: b
        ----
        package main

        var x int = "a"
        var y string = 1

        func main() {}
        >>> 3:13: cannot use "a" (untyped string constant) as int value in variable declaration
        ----
        package main

        var x = undefined1

        func main() {
            _ = undefined2
        }
        >>> 3:9: undefined: undefined1
        ----
        package main

        func f(a undefinedT) {}

        func main() {
            var s string = 1
            _ = s
        }
        >>> 3:10: undefined: undefinedT
        ----
        package main

        type T struct {
            a undefinedT
        }

        func main() {
            var s string = 1
            _ = s
        }
        >>> 4:7: undefined: undefinedT
        ----
        package main

        func main() {
            x := 1
            var s string = 1
            _ = s
        }
        >>> 4:5: declared and not used: x
        ----
        package main

        func main() {
            var s string = 1
            _ = s
            x := 1
        }
        >>> 4:20: cannot use 1 (untyped int constant) as string value in variable declaration
        ----
        package main

        func main() {
            var s string = 1
            var t int = "x"
            _, _ = s, t
        }
        >>> 4:20: cannot use 1 (untyped int constant) as string value in variable declaration
        ----
        package main

        func main() {
            if true {
                var t int = "x"
                _ = t
            }
            var s string = 1
            _ = s
        }
        >>> 5:21: cannot use "x" (untyped string constant) as int value in variable declaration
        ----
        package main

        func a() {
            var t int = "x"
            _ = t
        }

        func main() {
            var s string = 1
            _ = s
        }
        >>> 4:17: cannot use "x" (untyped string constant) as int value in variable declaration
        ----
        package main

        func main() {
            f := func() {
                var t int = "x"
                _ = t
            }
            f()
        }
        >>> 5:21: cannot use "x" (untyped string constant) as int value in variable declaration
        ----
        package main

        func main() {
            L:
            for {
            }
        }
        >>> 4:5: label L defined and not used
        ----
        package main

        func main() {
            goto L
        }
        >>> 4:10: label L not defined
        ----
        package main

        func main() {
            for {
                break L
            }
        }
        >>> 5:15: break label not defined: L
        ----
        package main

        func main() {
            break
        }
        >>> 4:5: break is not in a loop, switch, or select
        ----
        package main

        func main() {
            continue
        }
        >>> 4:5: continue is not in a loop
        ----
        package main

        func main() {
            if true {
                continue
            }
        }
        >>> 5:9: continue is not in a loop
        ----
        package main

        func main() {
            switch {
            case true:
                continue
            }
        }
        >>> 6:9: continue is not in a loop
        ----
        package main

        func main() {
            fallthrough
        }
        >>> 4:5: fallthrough statement out of place
        ----
        package main

        func main() {
            switch {
            case true:
                fallthrough
            }
        }
        >>> 6:9: cannot fallthrough final case in switch
        ----
        package main

        func main() {
            var a any
            switch a.(type) {
            case int:
                fallthrough
            default:
            }
        }
        >>> 7:9: cannot fallthrough in type switch
        ----
        package main
        import _ "fmt"

        func main() {
        var a any = 1
        a.(int) = 2
        }
        >>> 6:1: cannot assign to a.(int) (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        ch := make(chan int)
        <-ch = 1
        }
        >>> 6:1: cannot assign to <-ch (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"

        func main() {
        x := 1
        (x) = 2
        (x + 1) = 3
        }
        >>> 7:1: cannot assign to (x + 1) (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func f() T { return T{} }
        func main() {
        f().a = 1
        }
        >>> 6:1: cannot assign to f().a (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        type T struct{ a int }
        func main() {
        T{}.a = 1
        }
        >>> 5:1: cannot assign to T{}.a (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        type T struct{ a [2]int }
        func f() T { return T{} }
        func main() {
        f().a[0] = 1
        }
        >>> 6:1: cannot assign to f().a[0] (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        func f() [2]int { return [2]int{} }
        func main() {
        f()[0] = 1
        }
        >>> 5:1: cannot assign to f()[0] (neither addressable nor a map index expression)
        ----
        package main
        import _ "fmt"
        func f() []int { return nil }
        func main() {
        f()[0] = 1
        _ = &f()[0]
        _ = &f
        }
        >>> 7:6: invalid operation: cannot take address of f (value of type func() []int)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) M() {}
        func f() T { return T{} }
        func main() {
        f().M()
        }
        >>> 7:5: cannot call pointer method M on T
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) M() {}
        func main() {
        T{}.M()
        }
        >>> 6:5: cannot call pointer method M on T
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) M() {}
        func main() {
        _ = T.M
        }
        >>> 6:7: invalid method expression T.M (needs pointer receiver (*T).M)
        ----
        package main
        import _ "fmt"
        type T struct{}
        func (t *T) M() {}
        type I interface{ M() }
        func main() {
        var t T
        var i I = t
        _ = i
        }
        >>> 8:11: cannot use t (variable of struct type T) as I value in variable declaration: T does not implement I (method M has pointer receiver)
        ----
        """#
}
