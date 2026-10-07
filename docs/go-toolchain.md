# Swiftix Go Toolchain Contract

> Last verified: 2026-10-07<br>
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
| Control flow | `if`, both `switch` forms, three-clause `for`, `range`, break, and continue |
| Literals | Decimal, hexadecimal (`0x1f`), octal (`0o644`, `0644`), and binary (`0b101`) integers with `_` digit separators; interpreted strings with Go escapes (`\x`, octal, `\u`, `\U`); strings must be valid UTF-8 |
| Operators | Arithmetic, comparison, logical, and bitwise `&`, `\|`, `^`, `&^`, `<<`, `>>`, and unary `^` with Go precedence; a negative shift count panics and a count of 64 or more shifts every bit out. Compound assignment `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `&^=`, `<<=`, `>>=`, and `++`/`--` |
| Types | `int`, `byte`/`uint8`, `string`, `bool`, and named types; structs, pointers, arrays/slices/strings, maps, interfaces, and channels |
| `byte` | `s[i]` is a `byte`; byte arithmetic wraps modulo 256; `byte` and `int` do not mix without a conversion; untyped integer constants adopt `byte` or a named integer type when they fit; `[]byte` is an ordinary slice |
| Conversions | `int(x)`; `byte(x)`/`uint8(x)` (truncating); `string(x)` for an integer code point; `string(b)` and `[]byte(s)`; a named type to and from its underlying non-struct type |
| Functions | Multiple and named returns, `return f()` forwarding of a multi-result call, function literals in `go` and `defer`, panic/recover, and methods |
| Concurrency | Goroutines, buffered/unbuffered channels, select, and minimal Mutex/WaitGroup |
| Runtime | Independent call stacks, managed heap, precise roots, and synchronous mark-sweep GC |
| Tools | version/env/help, mod init, fmt, run, test, build, install, and clean -cache |
| Standard library | fmt/errors/io/os, strings/bytes/strconv/sort, basic collections, testing/sync/time/context, and parts of net/net/http |
| `strings` | Native `Contains`, `Count`, `HasPrefix`, `HasSuffix`, `Index`, `Join`, `LastIndex`, `Repeat`, `Split`, and `TrimSpace` with Go semantics; each call costs a few VM instructions regardless of length |
| `sort`, `strconv` | Native `sort.Strings` and `sort.Ints` (in place, byte order for strings, one VM instruction each) and `strconv.Itoa`/`Atoi` |
| Files | `os.Stdin`, `os.Stdout`, and `os.Stderr` as `*os.File`; `fmt.Fprint`/`fmt.Fprintln` to a file (statement only); `f.Write`, `f.WriteString`, and `f.Read`; `os.ReadFile` and `os.WriteFile`. Errors are `error` values with `Error()` |
| `time` | `time.Sleep`; `time.After` and `time.Tick` return `<-chan time.Time`; durations are `int` nanoseconds |
| System | argv/env/cwd/exit, VFS, standard input/output/error with pipe backpressure, shell PATH, park/wake on logical time, and the minimal TCP path |

### Known Gaps

- `context` lacks complete Deadline/Value support; `net` lacks complete DNS, UDP, deadline, and `net/http` semantics.
- Language edges such as type switches and `fallthrough` are incomplete. Rune literals are rejected by name; floating-point literals are not accepted.
- A compound assignment evaluates its target twice (`x op= y` is compiled as `x = x op y`), so a target that contains a call or a channel receive is rejected with a diagnostic rather than evaluated twice. `++`/`--` have the same double evaluation without the check.
- Function values are limited to literals invoked by `go` and `defer`: there is no function type syntax, a function or a function-valued variable cannot be called through a variable, and a literal does not capture the locals of its enclosing function (pass them as arguments). These limits are the same inside one package and across packages.
- Call results cannot be spread into another call's arguments (`f(g())` with a multi-result `g`), variadic functions and `iota` are not implemented, the blank identifier is accepted only in `:=` and `range`, an empty struct literal (`T{}`) and the address of a composite literal (`&T{...}`) are rejected, an interface method lists parameter types without names, and imports are written one per line (no parenthesized group).
- Unexported struct fields and methods of an imported package's type are not hidden from the importing package; only package-level names are checked for export. An unused import of a runtime package (`fmt`, `strings`, ...) is not diagnosed, although an unused import of a local package is.
- Guest strings are always valid UTF-8, so `string(b)` for a `[]byte` repairs each invalid sequence to U+FFFD instead of keeping the bytes; `[]byte(s)` yields the exact UTF-8 bytes.
- Constants are integers only. An untyped constant keeps adapting to `byte` and named integer types, but a constant shift such as `1 << n` has type `int`, and a `range` over a string yields `int` code points.
- `time.Time` is opaque: it has no methods, arithmetic, or comparison, and cannot be used as an `int`. `*os.File` is likewise opaque and exists only as the three standard files.
- A value stored in an interface variable outside a call argument keeps only its representation, so a `byte` stored that way asserts as `int`.
- `gofmt -s` implements only its registered safe rules.
- `sort.Slice`, `sort.Sort`, and `sort.Stable` are not provided (a native sort cannot call back into guest code); programs encode a byte-comparable key and use `sort.Strings` or `sort.Ints`.
- A file-backed process has no CPU quota: yielding keeps the system responsive, and the host or user ends a runaway program with a signal.
- The compiler frontend still needs tighter budgets for source, AST, imports, and constants.

### Explicitly Unsupported

- Generics, reflect, cgo, assembler, plugins, the host C ABI, and native machine-code linking.
- Numeric types other than `int`, `byte`, and `uint8`: `int8`...`int64`, `uint`, `uint16`...`uint64`, `uintptr`, `rune`, floating-point, and complex types are rejected by name.
- The `(n, err)` results of `fmt.Fprint`/`fmt.Fprintln`, and opening, closing, or dereferencing an `os.File`.
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

`gofmt` supports files, directories, stdin, `-l`, `-w`, `-d`, the AST-pattern `-r` option, and limited `-s`. Output must be deterministic and idempotent; batch writes begin only after every file parses successfully.

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

- **Linking model.** Packages are linked as source, not as separately compiled objects: every package-level name `X` of the package with import path `p` becomes the program symbol `p.X` (for example `example/app/internal/text.Join`), methods follow their type (`p.T.Method`), and a qualified reference `q.X` resolves to that symbol before type checking. Names of different packages therefore never collide, even when two packages share a package name, and the main package keeps its plain names. Diagnostics print Go spelling (`lib.Point`, not the symbol).
- **What crosses a package boundary.** Functions with zero, one, or several results (`a, b := pkg.F()`, `return pkg.F()`); typed and untyped constants, which keep adapting to `byte` and named integer types in the importing package; variables, which are one shared storage location that any importer may read, assign, increment, or take the address of; named types, struct types with exported fields (`pkg.Point{X: 1}`, `p.X = 2`), their value and pointer methods, interfaces, and type assertions to an imported type. Each works to the extent the in-package form does.
- **Cost.** A cross-package call, constant, or variable access compiles to exactly the instructions of the in-package form: one `call` instruction per call, and no thunk, lookup, or indirection. The image carries no package table.
- **Initialization.** Packages initialize in dependency order, each exactly once however many packages import it: first its package-level variables (ordered by their dependencies), then its `init` functions in source order. The image's initializer list holds `$<import path>.init` for each imported package's variables, `$package.init` for the main package's, and `$init.N` for `init` functions.
- **Rules.** `cannot refer to unexported name pkg.x` and `undefined: pkg.X` for package-level names; `import cycle not allowed: a imports b imports a`; `"path" imported and not used` for a local package; `import "path" is a program, not an importable package`; `use of internal package path not allowed` when a package below an `internal` directory is imported from outside the tree rooted at that directory's parent; `found packages a and b` for mixed package clauses; and `package path is not available` for an import that is neither local nor provided by the runtime. The qualifier is the imported package's declared name; import aliases, dot imports, and blank imports are not supported.
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
    yields to the event loop and continues in a later step, so other processes
    run in between and a signal such as Ctrl-C ends a runaway program. There is
    no total instruction cap; `startProcess(instructionBudget:)` sets one for a
    host that wants it.
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

The executable-image format and ABI have exact versions (format 10, ABI 10). Incompatible, corrupt, or incorrectly targeted images are rejected before launch. Module linking, compound assignment, and the integer literal forms are compile-time features: they add no opcode and change neither version.

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
