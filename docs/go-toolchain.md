# Swiftix Go Toolchain Contract

> Last verified: 2026-10-13<br>
> Scope: `SwiftixGo`, `SwiftixGoRuntime`, `SwiftixGoTool`, and `SwiftixGoHost`

Swiftix Go accepts Go source, compiles it to `swiftix/svm64` bytecode with a pure Swift compiler, and executes it in its own VM as a real Swiftix process. It neither embeds the host Go runtime nor presents itself as an official Go distribution.

The implementation uses Go 1.24 as a specification reference but promises only the subset recorded here. Unsupported behavior must return an explicit error instead of silently approximating the semantics.

## User Contract

| Item | Behavior |
| --- | --- |
| Source | `*.go` and `*_test.go`; one module with multiple local packages |
| Tools | `go`, `gofmt`, and `go fmt` |
| Entry point | `package main` with `func main()` |
| Target | `GOOS=swiftix` and `GOARCH=svm64` |
| Artifact | Versioned Swiftix executable image, not ELF or Mach-O |
| Determinism | Identical source, tool version, and target metadata produce identical bytes |

Typical workflow:

```text
go mod init example/hello
go fmt ./...
go test ./...
go build -o hello .
./hello
```

## Compatibility Scope

| Area | Supported |
| --- | --- |
| Packages | One module of local packages linked into one program: cross-package functions with any number of results, exported constants, variables, types, struct fields, and methods; dependency-first initialization; `internal/` visibility. See [Packages and Linking](#packages-and-linking) |
| Control flow | `if`, both `switch` forms, three-clause `for`, `range`, break, and continue. `if` and `switch` take an initializer statement (`if err := f(); err != nil { }`, `switch n := len(s); { }`), whose variables last for that statement and its `else` branches. Each iteration of a loop has its own variables, as in Go 1.22: a variable declared in the body, and the variables of a `for` or `range` clause, so a pointer taken in one iteration keeps that iteration's value. A block is a statement of its own (`{ ... }`) with its own scope; a `break` or `continue` inside it belongs to the statement around it, and it ends a function when its last statement does |
| Panics | `panic`, `recover`, and `defer`. A run-time error is a panic with Go's message that `recover` returns as an `error`: a nil pointer dereference, an index or slice bound out of range, an integer division by zero, an assignment to a nil map, a failed type assertion, a negative shift count, and a misuse of a closed or nil channel. See [Panics](#panics) |
| Literals | Decimal, hexadecimal (`0x1f`), octal (`0o644`, `0644`), and binary (`0b101`) integers with `_` digit separators; interpreted strings with Go escapes (`\x`, octal, `\u`, `\U`); strings must be valid UTF-8 |
| Operators | Arithmetic, comparison, logical, and bitwise `&`, `\|`, `^`, `&^`, `<<`, `>>`, and unary `^` with Go precedence; a negative shift count panics and a count of 64 or more shifts every bit out. Compound assignment `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `&^=`, `<<=`, `>>=`, and `++`/`--` |
| Types | `int`, `byte`/`uint8`, `string`, `bool`, and named types; structs, pointers, arrays/slices/strings, maps, interfaces, and channels. Fields of one type may share it (`X, Y int`). An alias declaration (`type Name = T`, at package level, in a function, and across packages) is another name for `T` and no new type: both have one method set, assert as each other, and print as `T` |
| `byte` | `s[i]` is a `byte`; byte arithmetic wraps modulo 256; `byte` and `int` do not mix without a conversion; untyped integer constants adopt `byte` or a named integer type when they fit; `[]byte` is an ordinary slice |
| Conversions | `int(x)`; `byte(x)`/`uint8(x)` (truncating); `string(x)` for an integer code point; `string(b)` and `[]byte(s)`; a named type to and from its underlying non-struct type |
| Functions | Multiple and named returns, including results that share a type (`(q, r int)`), `return f()` forwarding of a multi-result call, variadic functions and methods (`func f(prefix string, values ...int)`, called with any number of arguments or one `slice...`), function literals in `go` and `defer`, panic/recover, and methods. A function with results may end in a call to `panic` |
| Interfaces | A value converted to an interface keeps its dynamic type wherever the conversion happens (assignment, argument, return, composite literal, `append`, channel send), so `%T`, `==`, type assertions, and method calls see the type Go sees. An assertion takes a concrete type or an interface type (`v.(sizer)`, with or without `, ok`); interface methods may have several results and a variadic parameter, and may name their parameters and results (`Get(key string) (value string, ok bool)`). See [Interface Values](#interface-values) |
| Declarations and assignments | `x := v`, `var x T = v`, and their forms with several names: `a, b := x, y`, `a, b = b, a`, `var a, b T`, `var a, b = x, y`, `var n, err = f()`, and `const a, b = 1, 2`. Go's order holds: the index and pointer operands on the left and every value on the right are read first, then the assignments happen left to right, so `a, b = b, a` swaps and `i, list[i] = 2, 9` stores in the element the old `i` names. A multi-value `:=` may reuse variables the same block already declares when at least one name is new (`n, err := f()` after an earlier `err`): the old variable is assigned, not shadowed. The blank identifier takes a value and keeps none in `:=`, `=`, `var`, and `range`. Declarations may be grouped in parentheses, at package level and in functions: `import ( ... )`, `var ( ... )`, `const ( ... )`, and `type ( ... )`. In a `const` group `iota` is the index of the specification, and one without a value repeats the type and the expression of the one before it, so `const ( KB = 1 << (10 * (iota + 1)); MB; GB )` and typed enumerations work as in Go. An import may name its package: `import f "fmt"`, `import _ "pkg"` for its initialization alone, and `import . "pkg"` to use its exported names unqualified. A function may declare types, alone or in a `type ( ... )` group: each reaches from its declaration to the end of its block, hides what the name meant outside, and is a type of its own that prints by the name the source gives it (`main.pair`). A variable a function declares must be read: `declared and not used: x`, as in Go, where being the target of `x = v` is no read and `x++`, `x += v`, `x.f = v`, `x[i] = v`, and `&x` are. See "Names" below |
| Composite literals | Structs, arrays, slices, and maps. A struct literal names its fields or gives them all in order; fields it does not name, all of them in `T{}`, have their zero values. `&T{...}` is a pointer to a new variable each time it is evaluated, so a constructor returns `&Server{...}` and a loop that appends `&node{...}` appends distinct nodes |
| Builtins | `len`, `cap`, `append`, `make`, `delete`, `close`, `panic`, `recover`, and `copy`. `copy(dst, src)` and `append(dst, src...)` take a slice or, for a `[]byte` destination, a string; they handle overlapping ranges and cost one VM instruction whatever the length |
| Concurrency | Goroutines, buffered/unbuffered channels, select, and minimal Mutex/WaitGroup |
| Runtime | Independent call stacks, managed heap, precise roots, and synchronous mark-sweep GC |
| Maps | Hash-indexed: lookup, insertion, and `delete` are O(1) amortized. `range` visits entries in insertion order, so output never depends on a hash seed; a key that is deleted and set again moves to the end. `fmt` prints a map sorted by key, as Go does |
| Tools | version/env/help, mod init, fmt, run, test, build, install, and clean -cache |
| Standard library | fmt/errors/io/os, strings/strconv/sort, basic collections, testing/sync/time/context, and parts of net/net/http |
| Formatting | `fmt.Print`, `Println`, `Printf`, `Fprint`, `Fprintln`, `Fprintf` (each also as an expression returning `(n, err)`), `Sprint`, `Sprintln`, `Sprintf`, and `Errorf`, with Go's verbs including `%T`, `%#v`, `%p`, and argument indexes, and with a value's `Error()` or `String()` method. See [Formatting](#formatting) |
| Errors | `errors.New`, `errors.Unwrap`, `errors.Is`, and `errors.As`; `fmt.Errorf` with one or several `%w`; a program type with an `Error() string` method is an `error`, and its `Unwrap` and `Is` methods are honored. Errors compare by identity as in Go: two `errors.New("x")` differ. `io.EOF`; every library call that can fail returns an `error`, which a program can return, compare with `nil` or `io.EOF`, and read with `Error()`. A failed system call reads like Go's `*PathError`: `open /data/kv.aof: no such file or directory` |
| `strings` | Native `Contains`, `Count`, `Fields`, `HasPrefix`, `HasSuffix`, `Index`, `Join`, `LastIndex`, `Repeat`, `Split`, `ToLower`, `ToUpper`, `TrimPrefix`, `TrimSpace`, and `TrimSuffix` with Go semantics; each call costs a few VM instructions regardless of length. Case mapping and `%q`'s printable test use the Unicode tables of the reference Go release (Unicode 15.0.0), not the host's |
| `sort`, `strconv` | Native `sort.Strings` and `sort.Ints` (in place, byte order for strings, one VM instruction each) and `strconv.Itoa`/`Atoi` |
| Files | `os.Stdin`, `os.Stdout`, and `os.Stderr` as `*os.File`; `os.Open`, `os.Create`, and `os.OpenFile` with `os.O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_CREATE`, `O_EXCL`, `O_TRUNC`, and `O_APPEND`; `fmt.Fprint`/`fmt.Fprintln`/`fmt.Fprintf` to a file; `f.Write`, `f.WriteString`, `f.Read`, `f.ReadAt`, `f.WriteAt`, `f.Seek` with `io.SeekStart`/`SeekCurrent`/`SeekEnd`, `f.Sync`, and `f.Close`; `os.ReadFile` and `os.WriteFile`; `os.Remove`, `os.Rename`, and `os.Mkdir`. See [Files](#files) |
| `time` | `time.Sleep`; `time.After` and `time.Tick` return `<-chan time.Time`; `time.Now`, `time.Since`, and `time.Unix`; `t.Unix`, `t.UnixMilli`, `t.UnixNano`, `t.Sub`, `t.Add`, `t.Before`, `t.After`, and `t.Equal`; durations are `int` nanoseconds. See [Wall-Clock Time](#wall-clock-time) |
| System | argv/env/cwd/exit, VFS, standard input/output/error with pipe backpressure, shell PATH, park/wake on logical time, and the minimal TCP path |

### Known Gaps

- `context` lacks complete Deadline/Value support; `net` lacks complete DNS, UDP, deadline, and `net/http` semantics. `net.Dial` reports a refused connection and an abandoned handshake as errors; a write to a connection the peer reset still succeeds.
- Language edges such as type switches and `fallthrough` are incomplete. Rune literals are rejected by name; floating-point literals are not accepted.
- A compound assignment evaluates its target twice (`x op= y` is compiled as `x = x op y`), so a target that contains a call or a channel receive is rejected with a diagnostic rather than evaluated twice. `++`/`--` have the same double evaluation without the check.
- A single-value `x := v` that names a variable of the same block is reported as `x redeclared in this block`, where Go says `no new variables on left side of :=` (the multi-value form says that).
- The error of a failed library call (`strconv.Atoi`, `os.Open`, `conn.Read`, ...) is its message only. Two of them with the same text compare equal, where Go makes a new value each time; `%T` reports `*errors.errorString` where Go has `*strconv.NumError`, `*fs.PathError`, or `*net.OpError`; and `io.EOF` is the only sentinel (`os.ErrNotExist` and the like are not provided). Errors a program makes with `errors.New`, `fmt.Errorf`, or its own types do not have this limit.
- An unrecovered panic prints Go's first line without the goroutine trace that follows it in Go: `panic: runtime error: index out of range [3] with length 1`, and for a value of the program's what Go prints for it (see "Panics"). A panic raised again after `recover` prints its own line alone, where Go prints the recovered one before it, marked `[recovered]`. `sync: unlock of unlocked mutex` is a panic that `recover` can catch, where Go ends the program. The `runtime` package and its `runtime.Error` interface are not provided; a recovered run-time error asserts to `error`.
- An interface value cannot be compared with a value of a concrete type (`var a any = 5; a == 5`); two interface values, and an interface with `nil`, can.
- Function values are limited to literals invoked by `go` and `defer`: there is no function type syntax, a function or a function-valued variable cannot be called through a variable, and a literal does not capture the locals of its enclosing function (pass them as arguments). These limits are the same inside one package and across packages.
- Call results cannot be spread into another call's arguments (`f(g())` with a multi-result `g`), `new(T)` is not implemented (write `&T{}`), the inner type of a nested literal cannot be left out (`[]point{{1, 2}}`), and a pointer to an array is not indexed implicitly (write `(*p)[i]`). A local variable named `iota` does not hide the constant generator inside a `const` declaration.
- A file can dot-import one package of the run-time library (`import . "fmt"`); a second one is refused, because nothing lists what such a package declares. Local packages have no such limit.
- A diagnostic about a selection `x.f` is reported at the `.`, one column before the name where Go reports it, and one about a function at its `func` keyword.
- Go lists every error of a package; Swiftix Go reports one, the first in the order of the source. It finds the first that Go finds for an unused variable beside another error; elsewhere the choice among several errors may differ.
- Unexported struct fields and methods of an imported package's type are not hidden from the importing package; only package-level names are checked for export.
- Guest strings are always valid UTF-8, so `string(b)` for a `[]byte` repairs each invalid sequence to U+FFFD instead of keeping the bytes; `[]byte(s)` yields the exact UTF-8 bytes.
- Constants are integers only. An untyped constant keeps adapting to `byte` and named integer types, but a constant shift such as `1 << n` has type `int`, and a `range` over a string yields `int` code points.
- `time.Time` is opaque apart from the methods listed above: it has no operators, no calendar fields, no `Format`, and no location, and cannot be used as an `int`. `*os.File` is likewise opaque: it cannot be dereferenced, and it has no `Stat`, `Truncate`, `Chmod`, or directory reads. `os.Open` refuses a directory.
- `gofmt -s` implements only its registered safe rules.
- `sort.Slice`, `sort.Sort`, and `sort.Stable` are not provided (a native sort cannot call back into guest code); programs encode a byte-comparable key and use `sort.Strings` or `sort.Ints`.
- A file-backed process has no CPU quota: yielding keeps the system responsive, and the host or user ends a runaway program with a signal.
- The compiler frontend still needs tighter budgets for source, AST, imports, and constants.

### Explicitly Unsupported

- Generics, reflect, cgo, assembler, plugins, the host C ABI, and native machine-code linking.
- Numeric types other than `int`, `byte`, and `uint8`: `int8`...`int64`, `uint`, `uint16`...`uint64`, `uintptr`, `rune`, floating-point, and complex types are rejected by name.
- Dereferencing an `os.File`.
- `fmt.Sscanf` and the other scanning functions, `fmt.Append*`, and the `fmt.Stringer`, `fmt.Formatter`, and `fmt.GoStringer` interface names. A `String()` method is honored without the name; `Format` and `GoString` methods are not called.
- Benchmarking, coverage, profiling, `go vet`, `go work`, `go.sum`, and direct `GOPROXY` access.
- `crypto/*`, `compress/*`, `archive/*`, and `math/big`.
- Go binaries for other platforms or any path that bypasses Swiftix to access host files, processes, or networking.

The presence of a package name does not imply compatibility with the full official API.

## Tools and Modules

```text
go version
go env [NAME ...]
go mod init MODULE
go fmt [FILE | . | ./...]
go run PACKAGE [args ...]
go test [PACKAGE | ./...]
go build [-o FILE] [PACKAGE | ./...]
go install [PACKAGE]
go clean -cache
```

`gofmt` supports files, directories, stdin, `-l`, `-w`, `-d`, the AST-pattern `-r` option, and limited `-s`. A rule is `pattern -> replacement`, two expressions. As in Go, an identifier of the pattern that is one lower-case letter stands for any expression and every other identifier matches itself; the operands of an expression are rewritten before the expression is matched, so a rule applies at every depth (`f(f(1))` under `f(1) -> 1` is `1`); an operand in parentheses is matched with them; and a rule from one identifier to another renames it wherever the file has it, the name of a declaration, a field, or a type included. A rule cannot name parentheses (`(a) -> a`), and a single letter alone (`x -> y`) rewrites expressions, where Go's also meets the names of declarations. Output must be deterministic and idempotent; batch writes begin only after every file parses successfully.

The blanks around binary operators follow Go's printer rule for rule, so source that Go's `gofmt` formatted comes back unchanged: precedence shows at the top of an expression (`x*2 + y`), and an operator inside the arguments of a call that has several, inside an index, among several values of an assignment, or under an operator of another precedence is joined to its operands (`f(a+1, b)`, `s[i+1]`, `a, b = b+1, a*2`, `n-1 < len(s)`). Parentheses take one level back (`(a + b) * c`), an operator stays clear of a unary one after it (`a - -b`), and the `:` of a slice has blanks beside a binary bound (`s[lo : hi+1]`). Parentheses that say nothing are dropped: the second pair of `((x))` and the pair around a whole `if`, `for`, `switch`, or `range` expression. An empty line separates top-level declarations of different kinds; between two of one kind the source decides.

Beyond the spacing of tokens `gofmt` does what Go's printer does with lines and columns:

- **Columns.** The printer of Go writes through a tabwriter, and so does this one: the name of a struct field, a comment at the end of a line, the body of a one-line function declaration, and the key of a composite literal element that begins a line each end a cell, and the cells of consecutive lines of one indentation are padded to one width. A line without the cell, an empty line, a `case`, and a function that spans several lines start the columns over, and so does a literal element whose size is far from that of the ones before it (Go's rule: both over 40 columns and off the geometric mean by a factor of 2.5).
- **One line.** A function stays on the line of its signature when the source has it there, it has at most five statements, none of which needs a line of its own, and signature and statements take no more than 100 columns: `func (s *stack) empty() bool { return len(s.items) == 0 }`. A `struct` or `interface` stays on one line when it has one field or method whose type takes no more than 30 columns: `interface{ Area() int }`. The blocks of `if`, `for`, and `switch` always open a line.
- **Line breaks.** A line break of the source is kept after a binary operator, between the arguments of a call, the parameters of a function, the elements of a composite literal, and the values of an assignment, `return`, or `case`, after `=`, and after the `.` of a selector. What follows is indented one level until the construct ends; constructs inside one another add up. A closing `)` or `}` on a line of its own, after the final comma, returns to the indentation of the line that opened the list; where the whole list is on the line of its opening delimiter, a final comma is dropped.

- **Groups.** A declaration group has each specification on a line of its own, indented, between `(` and `)`; a group without any is `()`. The imports of a group are sorted by path within each run of successive lines, each with the comment at the end of its line, and one that is there twice is kept once; an empty line or a comment on a line of its own ends a run. In a `var` or `const` group of several specifications the names, the types, the values, and the comments are columns. The column of types is kept, empty, for a value without a type when a value beside it has one (`x          = 7` under `foobar int = 42`), and otherwise values stand in it. The names of the types of a `type` group are a column too.

Every Go source file of the coreutils, sysutils, and editors packages, which Go's `gofmt` formatted, comes back from this `gofmt` unchanged.

`go build`, `go run`, and `go install` take one package directory below the current one (`.`, `./cmd/tool`; `go run` needs the `./` form) or a list of `.go` files; a file list is compiled as a single package without local imports. `go test` takes `.` or `./...`, and a package's test files may import local packages that its other files do not.

Default guest paths:

```text
GOPATH=/home/<user>/go
GOBIN=/home/<user>/go/bin
GOCACHE=/home/<user>/.cache/go-build
GOMODCACHE=/home/<user>/go/pkg/mod
```

Module support includes one module, multiple local packages, `replace` within the same VFS, and external dependencies already present in `GOMODCACHE`. The toolchain does not download modules from the network; `pkg` installs dependencies. The build cache uses a SHA-256 content key that covers the tool version, ABI, target, `go.mod`, the root package's import path, and the path and text of every source file of every package in the build, so a change to an imported package is a miss. Corrupt entries are treated as misses.

### Packages and Linking

A build is one `package main` plus every local package it reaches through imports. `GoCompiler.compile(packages:root:)` takes the packages by import path, and `GoCompiler.compile(root:sources:)` asks a callback for each one on demand; the `go` tool and the `coreutils` package builder both use this path. An import path that names a runtime package (`fmt`, `os`, `strings`, `swiftix/userland`, ...) is never looked up as a local package.

- **Linking model.** Packages are linked as source, not as separately compiled objects: every package-level name `X` of the package with import path `p` becomes the program symbol `p.X` (for example `example/app/internal/text.Join`), methods follow their type (`p.T.Method`), and a qualified reference `q.X` resolves to that symbol before type checking. Names of different packages therefore never collide, even when two packages share a package name, and the main package keeps its plain names. A package whose name is not the last element of its import path has the name in its symbols, after the path (`example/app/v2@api.Request`), because Go prints a type by its package's name (`api.Request`) and the symbol is all the VM has of it. Diagnostics print Go spelling (`lib.Point`, not the symbol), and name a package as the file that is reported names it.
- **What crosses a package boundary.** Functions with zero, one, or several results (`a, b := pkg.F()`, `return pkg.F()`); typed and untyped constants, which keep adapting to `byte` and named integer types in the importing package; variables, which are one shared storage location that any importer may read, assign, increment, or take the address of; named types, struct types with exported fields (`pkg.Point{X: 1}`, `p.X = 2`), their value and pointer methods, interfaces, and type assertions to an imported type. Each works to the extent the in-package form does.
- **Cost.** A cross-package call, constant, or variable access compiles to exactly the instructions of the in-package form: one `call` instruction per call, and no thunk, lookup, or indirection. The image carries no package table.
- **Initialization.** Packages initialize in dependency order, each exactly once however many packages import it: first its package-level variables (ordered by their dependencies), then its `init` functions in source order. The image's initializer list holds `$<import path>.init` for each imported package's variables, `$package.init` for the main package's, and `$init.N` for `init` functions.
- **Rules.** `cannot refer to unexported name pkg.x` and `undefined: pkg.X` for package-level names; `import cycle not allowed: a imports b imports a`; `"path" imported and not used` for a package the file never names, local or of the run-time library, or `"path" imported as name and not used` when its name in the file is not the last element of its path; `name redeclared in this block` for two imports of one name; `use of package name not in selector`; `import "path" is a program, not an importable package`; `use of internal package path not allowed` when a package below an `internal` directory is imported from outside the tree rooted at that directory's parent; `found packages a and b` for mixed package clauses; and `package path is not available` for an import that is neither local nor provided by the runtime. The qualifier is the name the import gives, or else the imported package's declared name. A package imported as `_` is linked and initialized and needs no use; one imported as `.` lends the file its exported package-level names, which a declaration of the file's own package or of an enclosing block hides. Diagnostics are reported at the import's name, or at its path when it has none.
- **Limits.** One build holds at most 1,024 packages, and the `go` tool follows import chains at most 128 packages deep; larger builds are refused with a diagnostic.
- `GoCompiler.compilePackage` and `compile(sources:importedPackages:)` remain as the older separate-compilation interface, which resolves only single-result functions of an imported package. New code should use the module build.

## Runtime and System Integration

```text
SwiftixGo          parser → type checker → IR → bytecode
SwiftixGoRuntime   image → VM → heap/GC → goroutine/channel
SwiftixGoTool      go/gofmt, module graph, cache
SwiftixGoHost      host-file adapter and CLI
```

- `GOMAXPROCS=1`; runnable work uses deterministic FIFO ordering, and select uses fair choice.
- Each executable corresponds to one Swiftix process and shares its argv/env/cwd/file descriptors/signals.
- The standard library reaches the guest VFS and network only through the `ProcessContext` syscall bridge.
- `GoRuntimeResourceLimits` bounds images, heap, collections, goroutines, timers, handles, and I/O.
- `swiftix/userland` provides the terminal ABI for full-screen programs:
  `ReadStdin() (string, int)` returns the next fd 0 chunk (at most 4096 bytes,
  never splitting a UTF-8 sequence) with status 0, or status 1 at end of input;
  `WriteFile(path, data string) int` creates or truncates a VFS file and returns
  0 or 1; `SetRawMode(enabled bool) bool` switches the fd 0 terminal and reports
  `false` when fd 0 is not a terminal; `WindowSize() (int, int)` returns rows
  and columns of the fd 1 (or fd 0) terminal, or `(0, 0)`. There is no
  `SIGWINCH`; programs re-read `WindowSize` after input.
- File-backed executables (`GoExecutableLoader`, built on
  `GoVirtualMachine.startProcess`) run cooperatively as the body of their
  process and never drive the event loop themselves:
  - **CPU.** After each instruction quantum (4,096 instructions) the process
    yields to the event loop (`ProcessContext.yield`) and continues in a later
    step, so other processes run in between and a signal such as Ctrl-C ends a
    runaway program. `ps` shows it running (`R`). There is no total
    instruction cap; `startProcess(instructionBudget:)` sets one for a host
    that wants it.
  - **Time.** A program that never blocks does not stop logical time. Under
    `EventLoop.advance(by:stepBudget:)`, a timer due inside the interval (a
    `sleep` in another process, a TCP retransmission, an ARP timeout) runs at
    its deadline after at most 8 quanta, and the clock reaches the end of the
    interval even though the program is still runnable. The host's step
    budget is the number of quanta one interval holds; the call returns
    `.budgetExceeded` while the program runs, which a host should read as
    "more work is ready", not as "time did not pass". See
    [Real-Time Driving](architecture.md#real-time-driving). Under
    `runUntilIdle()` the program still runs to completion at one instant.
  - **Waiting.** `time.Sleep`, `time.After`/`time.Tick`, context timeouts,
    `ReadStdin`, `ReadInput` on standard input, `f.Read`, and network waits park
    the process in the kernel (`ps` shows it sleeping) until logical time
    advances or the descriptor is ready. Nothing fast-forwards the clock, so a
    polling loop costs one wake-up per interval.
  - **Output.** `fmt.Print*`, `fmt.Fprint*`, `f.Write`, and `f.WriteString`
    write to the process's descriptors. When a pipe accepts only part of a
    write, the writing goroutine parks until the reader makes room; writes to
    one descriptor complete in order and are never interleaved or dropped. A
    reader that went away delivers `SIGPIPE`.
  - **Limits.** Strings may reach 16 MiB, slices 4,194,304 elements, and the
    heap 256 MiB. `maximumOutputBytes` does not apply because backpressure
    bounds output. A `[]byte` costs one heap value per byte, so byte-level
    tools should stream through a fixed buffer (`f.Read` into `make([]byte, n)`)
    rather than hold a large file in a slice.
  - A program whose goroutines all wait on each other with no host wait
    outstanding still fails with the deadlock error and status 1.
- `runProgram`, `run`, `go run`, and `go test` complete synchronously inside one
  step: they drive the event loop while goroutines wait (so `time.Sleep`
  advances logical time), keep the 1,000,000-instruction and output budgets,
  send `fmt.Print*` to their output sink, send other descriptors to the
  process when there is one (otherwise to the same sink), and report a wait on
  input the host has not delivered as a deadlock. `startProgram` is the older
  resumable form of that run, which suspends only for `ReadStdin`/`f.Read`.
- A goroutine that parks on the instruction a quantum ends on is recorded as
  parked before the event loop gets its turn, in every run mode.
- Heap statistics are maintained incrementally, and a slice element store or
  in-capacity `append` updates the backing array in place.
- A run that fails while its program left the terminal raw restores cooked
  mode; a program that exits normally keeps the mode it chose, and the shell
  restores cooked mode before its next prompt.
- Exceeding a boundary must return a stable error rather than causing a host trap, infinite recursion, or unbounded allocation.

The executable-image format and ABI have exact versions (format 10, ABI 10). Incompatible, corrupt, or incorrectly targeted images are rejected before launch. Module linking, compound assignment, short-declaration reuse, the `append` spread, variadic functions, and the integer literal forms are compile-time features: they add no opcode and change neither version. The file, wall-clock, `errors`, formatting, `copy`, `append`-spread, `&T{...}`, and new-variable natives are reserved call names, and the dynamic type of an interface value travels in the type name an interface value already had, so they change neither version as well; an image that uses one needs a runtime that provides it. An image built by an earlier compiler keeps running: the type names it boxed call arguments with (`int`, `point`, `*point`) are still understood.

### Names

Two things a name means depend on its scope alone, and both are settled on the syntax tree, a package at a time, before anything is checked. The checker and the compiler then see what they saw before: packages of the run-time library under their own names, and types that belong to a package.

- **Import names.** In a file that says `import f "fmt"`, `f.Println` is rewritten to `fmt.Println` wherever no parameter, variable, or type of an enclosing block is called `f`, and the type `f.Stringer` likewise. The package's own name is then free: the file may have a variable `time` beside `import stdtime "time"`, or import a local package `errors` beside `stderrors "errors"`. Because `time` would now read as the package, every other use of that name in the package is respelled with a middle dot, `time·`, which no source can write; diagnostics print it as the source has it. A local package's name is resolved by the linker, to the same symbol the unnamed import gives.
- **Alias declarations.** `type Name = T` declares no type, so every use of `Name` is replaced by `T` on the syntax tree, across the whole program, and the declaration is dropped; what is left is checked and compiled as if the program had said `T`. An alias that stands for itself is `invalid recursive type`, and one nothing uses must still name a type.
- **Types declared in functions.** A local type becomes a type of the package under a name of its own, `pair·1`, numbered through the package, and the uses its scope gives it are renamed with it. Two functions that each declare `pair` therefore have two types, an assertion from one to the other fails, and the image names them apart. `%T`, `%v`, and panics print `main.pair` for both, as Go does, and a failed assertion between them ends in Go's `(types from different scopes)`; between types of one name in two packages it ends in `(types from different packages)`. A local type has no methods, as in Go, and costs what a package-level type costs.

### Loop Variables

A VM local is one storage cell, and a declaration that a loop reaches again writes that cell again. That is Go's behavior for every program that takes no pointer to the variable, which is why it costs nothing. Where a pointer can reach a variable that is declared in a loop body or in a `for` or `range` clause, the compiler emits one more instruction, the reserved call `$fresh.<local>`, which unbinds the local from its cell so that the store that follows allocates a new one; pointers to the old cell keep the old variable, which the collector frees when none is left. For the variables of a three-clause `for` the new variable is a copy made before the post statement, as Go specifies.

A pointer can reach a variable when the function takes its address (`&x`, `&x.f`, `&x[i]`), calls a method with a pointer receiver on it, or slices it when it is an array. The test is by name within one function, so it may renew a variable that did not need it, never the reverse.

### Interface Values

A value converted to an interface is boxed with a descriptor of its static type: the type itself and the underlying type of every named type it reaches. Only an `int`, a `string`, and a `bool` travel bare, because the value shows the type. The descriptor is what `fmt` formats by, what `==` and a type assertion compare, and where a method call through the interface finds the method.

- **Assertions to a concrete type** compare type identity, so a `byte` is not an `int`, a named type is not its underlying type, and `[]byte`, `map[string]int`, and struct types assert as themselves.
- **Assertions to an interface type** succeed for the types that implement it. The compiler, which sees every package of the program, lists them from exact method signatures (name, parameter types, result types, and whether the receiver is a pointer), and the VM looks the dynamic type up in that list. A failed assertion without `, ok` panics with Go's message: `interface conversion: main.file is not main.sizer: missing method size`.
- **Method calls** through an interface dispatch on the dynamic type, dereference a pointer for a value receiver, take several results (`value, ok := store.Get(key)`), and pack a variadic parameter.
- **Native calls into guest code.** `fmt` and `errors` run a program's `Error`, `String`, `Unwrap`, and `Is` methods. A native cannot run guest code, so the instruction that needs a method calls it like any function and then executes again with the result; a native that needs several methods repeats this once per method. A formatting call therefore costs one VM instruction plus the instructions of the methods it runs.

### Panics

A run-time error of the program does not end it at once. The instruction that meets the error raises a panic in the function that was executing, that function's deferred calls run, and so do its callers' while the panic travels up the goroutine's stack. A deferred function that calls `recover` stops it, and the function that panicked returns the zero values of its results (or what its named results hold).

| Error | `recover()` prints | `%T` |
| --- | --- | --- |
| `p.field`, `*p`, or a method call with a nil `p` or a nil interface | `runtime error: invalid memory address or nil pointer dereference` | `runtime.errorString` |
| `x[i]` out of range | `runtime error: index out of range [5] with length 3`, or `[-1]` for a negative index | `runtime.boundsError` |
| `x[a:b]` out of range | `runtime error: slice bounds out of range [:5] with capacity 3` (`with length` for a string or an array), `[2:1]`, `[-1:]` | `runtime.boundsError` |
| `a / b`, `a % b` with `b == 0` | `runtime error: integer divide by zero` | `runtime.errorString` |
| `1 << n` with `n < 0`; `make([]T, n)` with `n < 0` | `runtime error: negative shift amount`; `runtime error: makeslice: len out of range` | `runtime.errorString` |
| An assignment to an entry of a nil map; a send on or a second `close` of a closed channel; `close` of a nil channel | `assignment to entry in nil map`, `send on closed channel`, `close of closed channel`, `close of nil channel` | `runtime.plainError` |
| `v.(T)` without `, ok` when `v` is not a `T` | `interface conversion: interface {} is string, not int` | `*runtime.TypeAssertionError` |

- The recovered value is an `error`: `err, ok := r.(error)` succeeds and `err.Error()` is the text above. Two such values are equal when they say the same, as Go's are; no heap cell is allocated to report one.
- A panic nothing recovers ends the run with `GoRuntimeError.panicError(message)`, printed as `panic: <message>`, after every deferred call of the goroutine has run. A file-backed program exits with status 2, as a Go program does.
- The message of a value the program panicked with is Go's: an `int`, a `string`, or a `bool` as it is; one of a named type with the type around it (`main.code(4)`, `main.name("x")`); an error by its `Error` method and a value with a `String` method by that, which run as the goroutine's last frame; and anything else by its type and where it lies (`(main.failure) 0xc000012000`, `([]int) 0xc000013000`).
- The argument of `panic` is converted to `interface{}` like any other, so `recover` returns it with its type: `%T` of a recovered `code(4)` is `main.code`.
- A goroutine recovers only its own panics; an unrecovered panic in any goroutine ends the program.
- `fmt` recovers a panic of an `Error` or `String` method it calls and prints `%!v(PANIC=String method: runtime error: ...)`.
- A fault of the machine itself is not a panic and cannot be recovered: a malformed image, a dangling heap cell, an exceeded resource limit, or a deadlock ends the run with its own `GoRuntimeError`.

### Formatting

`fmt.Print`, `Println`, `Printf`, `Fprint`, `Fprintln`, `Fprintf`, `Sprint`, `Sprintln`, `Sprintf`, and `Errorf` follow Go's `fmt`. The programs in `GoConformanceTests` were run through Go 1.24.5 and Swiftix Go must print the same bytes (addresses aside, which differ between two runs of Go as well); `GoFormatVerbTests` pins further cases that were checked the same way.

| Part | Supported |
| --- | --- |
| Verbs | `%v` `%+v` `%#v` `%T` `%p` `%d` `%b` `%o` `%O` `%x` `%X` `%c` `%q` `%U` `%s` `%t` `%%`, and `%w` in `fmt.Errorf` |
| Flags | `-`, `+`, `#`, space, and `0` |
| Width, precision | Decimal or `*` from an operand, capped at 1,000,000 as in Go; width counts code points |
| Argument indexes | `%[2]d`, `%[1]*d`, `%[3]*.[2]*[1]d`, with Go's `%!d(BADINDEX)` |
| Operands | Every type of the dialect, formatted by its static type: a `byte` is a `uint8`, a nil slice is `[]` and a nil map `map[]`, a map prints sorted by key, a pointer to a struct, slice, array, or map prints `&{...}` as an operand and its address inside another value, `[]byte` is text for `%s`, `%x`, and `%q` |
| Methods | `Error()` and then `String()` under `%v`, `%s`, `%q`, `%x`, and `%X`, for an operand and for any value inside it that is not behind an unexported field. A method is called on a nil pointer too; one that panics prints `%!v(PANIC=String method: ...)`, or `<nil>` when its receiver is a nil pointer |
| Results | `Sprint` and `Print` put a space between operands when neither is a string; the output functions return the byte count and the error of the write, if any |
| Mistakes | Go's markers: `%!d(string=hi)`, `%!d(MISSING)`, `%!(EXTRA int=1)`, `%!(NOVERB)`, `%!(BADWIDTH)`, `%!(BADPREC)`, `%!d(BADINDEX)` |

What differs from Go:

- `Format` (`fmt.Formatter`) and `GoString` (`fmt.GoStringer`) methods are not called; `%#v` always prints Go syntax from the type.
- A library-call error has no concrete type of its own (see Known Gaps): `%T` prints `*errors.errorString`, and `%+v`, `%#v`, and `%d` print that shape.
- A `time.Time` prints as its nanosecond count and a duration as an `int`, because that is what they are here.
- A pointer prints an address of the VM's heap (`0xc000012000`), which identifies the value but is not a machine address.
- A type of the program's root package is named `main.T`; this is wrong only under `go test` of a package that is not `main`.

A result is bounded by the string limit, and printed text by the run's output budget.

### Files

A `*os.File` the program opens is a handle, not a descriptor number, and a handle is never reused. A file used after `Close` therefore fails with `file already closed` even when a later `os.Open` was given the same descriptor, and it never reaches the other file.

- `os.OpenFile(name, flag, perm)` accepts the flags listed above with Go's Linux values; any other bit is `invalid argument`. A new file gets `perm` under the process umask, and a missing parent directory is an error rather than being created.
- `f.ReadAt` and `f.WriteAt` use the kernel's `pread`/`pwrite`: they leave the file offset alone, `ReadAt` returns `io.EOF` with a short count at the end of the file, a write past the end leaves a zero-filled gap, and `WriteAt` on a file opened with `O_APPEND` is refused as in Go. `ReadAt` fills its slice in one accounting pass, which is what a page-sized read needs.
- `f.Sync` succeeds for any open file: a VFS write is complete when it returns. The VFS itself is in memory; durability across a restart belongs to the host's snapshot of it.
- `os.Rename` keeps the node, so a file that is open across the rename keeps writing to it; this is the write-temporary-then-rename pattern. `os.Remove` removes a file or an empty directory.
- Files still open when a synchronous run (`go run`, `go test`, `runProgram`) ends are closed, in the order they were opened. A file-backed process leaves that to its exit.
- A run without a process has no file system: every call returns an error ending in `no file system`.

### Wall-Clock Time

A `time.Time` is an instant on the hosting kernel's wall clock, which is the Unix epoch at logical time zero unless the host anchored it with `Kernel.setWallClock`. It follows logical time, so it advances only as the host advances the event loop, and a run without a process counts from zero. `time.After` and `time.Tick` deliver the same instants. The zero `time.Time` is the epoch, not year 1, and there is no monotonic reading: an interval measured across a host re-anchoring of the clock includes the jump.

## Distribution and Host Tools

The sibling `coreutils` repository builds official base commands from Go source into a native `.pkg`, compiling each command as a module build that imports a shared local package; `SwiftixDistribution` verifies and installs that package into the rootfs. Running those commands requires only `SwiftixGoRuntime`; distribution content does not enter the core target.

macOS and Linux provide:

```text
swiftix-go build -o hello .
swiftix-go run . arg
swiftix-go test ./...
swiftix-go exec --root . hello -- arg
```

The host adapter copies an explicit workspace into guest `/workspace`, rejects symlinks, and limits file count, individual file size, and total bytes. Guest writes do not modify the host directory. The executable ships under the shared `swiftix-toolchain` version.

See the [product roadmap](roadmap.md) for shared versioning, signing, notarization, and release gates. Every newly supported semantic requires positive, error, and resource-boundary coverage; unsupported behavior must retain stable diagnostics.
