# Swiftix Go Toolchain Contract

> Last verified: 2026-08-13<br>
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
| Packages | Import graph, global/init order, and local cross-package calls |
| Control flow | `if`, both `switch` forms, three-clause `for`, `range`, break, and continue |
| Types | Primitive and named types, structs, pointers, arrays/slices/strings, maps, interfaces, and channels |
| Functions | Multiple and named returns, closures, defer, panic/recover, and methods |
| Concurrency | Goroutines, buffered/unbuffered channels, select, and minimal Mutex/WaitGroup |
| Runtime | Independent call stacks, managed heap, precise roots, and synchronous mark-sweep GC |
| Tools | version/env/help, mod init, fmt, run, test, build, install, and clean -cache |
| Standard library | fmt/errors/io/os, strings/bytes/strconv, basic collections, testing/sync/time/context, and parts of net/net/http |
| System | argv/env/cwd/exit, VFS, file descriptors/pipes, shell PATH, logical time, and the minimal TCP path |

### Known Gaps

- `context` lacks complete Deadline/Value support; `net` lacks complete DNS, UDP, deadline, and `net/http` semantics.
- Language edges such as type switches and `fallthrough` are incomplete.
- `gofmt -s` implements only its registered safe rules.
- The compiler frontend still needs tighter budgets for source, AST, imports, and constants.

### Explicitly Unsupported

- Generics, reflect, cgo, assembler, plugins, the host C ABI, and native machine-code linking.
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

Default guest paths:

```text
GOPATH=/home/<user>/go
GOBIN=/home/<user>/go/bin
GOCACHE=/home/<user>/.cache/go-build
GOMODCACHE=/home/<user>/go/pkg/mod
```

Module support includes one module, multiple local packages, `replace` within the same VFS, and external dependencies already present in `GOMODCACHE`. The toolchain does not download modules from the network; `pkg` installs dependencies. The build cache uses a SHA-256 content key that covers the tool version, ABI, target, `go.mod`, and source. Corrupt entries are treated as misses.

## Runtime and System Integration

```text
SwiftixGo          parser → type checker → IR → bytecode
SwiftixGoRuntime   image → VM → heap/GC → goroutine/channel
SwiftixGoTool      go/gofmt, module graph, cache
SwiftixGoHost      host-file adapter and CLI
```

- `GOMAXPROCS=1`; runnable work uses deterministic FIFO ordering, and select uses fair choice.
- Channels, pipes, networking, sleep, and wait all integrate with Swiftix park/wake.
- Each executable corresponds to one Swiftix process and shares its argv/env/cwd/file descriptors/signals.
- The standard library reaches the guest VFS and network only through the `ProcessContext` syscall bridge.
- `GoRuntimeResourceLimits` bounds images, heap, collections, goroutines, timers, handles, and I/O.
- Exceeding a boundary must return a stable error rather than causing a host trap, infinite recursion, or unbounded allocation.

The executable-image format and ABI have exact versions. Incompatible, corrupt, or incorrectly targeted images are rejected before launch.

## Distribution and Host Tools

The sibling `coreutils` repository builds official base commands from Go source into a native `.pkg`; `SwiftixDistribution` verifies and installs that package into the rootfs. Running those commands requires only `SwiftixGoRuntime`; distribution content does not enter the core target.

macOS and Linux provide:

```text
swiftix-go build -o hello .
swiftix-go run . arg
swiftix-go test ./...
swiftix-go exec --root . hello -- arg
```

The host adapter copies an explicit workspace into guest `/workspace`, rejects symlinks, and limits file count, individual file size, and total bytes. Guest writes do not modify the host directory. The executable ships under the shared `swiftix-toolchain` version.

See the [product roadmap](roadmap.md) for shared versioning, signing, notarization, and release gates. Every newly supported semantic requires positive, error, and resource-boundary coverage; unsupported behavior must retain stable diagnostics.
