# Changelog

Swiftix follows [Semantic Versioning](https://semver.org/). User-visible API,
format, behavior and platform changes are recorded here.

## Unreleased

### Added

- `ProcessContext.yield(resume:)`: a CPU-bound process gives up the processor
  and continues in a later step without holding logical time, unlike
  `sleep(0)`.
- `ProcessContext.yield()`: the `async` form, for process bodies that loop
  through `await`. It throws `.interrupted` if the process is terminated while
  it is waiting for its turn.

### Changed

- `EventLoop.advance(by:stepBudget:)` no longer lets yielded CPU-bound work
  freeze the clock. A timer due inside the interval runs at its deadline after
  at most 8 consecutive yields, and when the budget runs out with only yields
  left, `now` still reaches the target (the result stays `.budgetExceeded`).
  Timers, executor jobs, and ordinary zero-delay work hold the clock as
  before, and `runUntilIdle()`/`runNext()` are unchanged. Hosts should keep
  advancing toward their own frame target when a call stops short of it; see
  "Real-Time Driving" in `docs/architecture.md`.
- `EventLoop.advance(by:stepBudget:)` treats the executor jobs that resume an
  `async` task after `yield()` as yields: they keep their FIFO place, and the
  clock reaches the target when the budget runs out with only such jobs and
  yields left. Every other job holds the clock as before.
- `awk` and `bc` yield instead of taking a zero-length sleep, and `bc` also
  yields on the first iteration of a loop instead of only every 256th.
- A read from `/dev/zero`, `/dev/full`, `/dev/random`, or `/dev/urandom`
  through the blocking or async frontend resumes as a yield.
- A shell `while`/`until` loop yields on its first iteration and then every
  256 iterations.
- `ps`, `top`, and `/proc/<pid>/stat` report an `async` process that is
  yielding (`awk`, `bc`, `cat /dev/zero`, a custom body calling `yield()`) as
  running (`R`) until it next waits. It was shown as sleeping (`S`) for most
  of each turn.
- A yielding process that is stopped and continued is yielded work again at
  once: a step held back while it was stopped is replayed as a yield if it
  was one, so the process is reported as running (`R`) and does not hold
  logical time for the first turn after `SIGCONT`.
- A process step queued by yielded work (a wake-up through a pipe, a child
  being started, an exit being reported) is queued as a yield, and `yes`
  yields each time a full pipe makes it wait.
- A file-backed Go program yields at each instruction quantum instead of taking
  a zero-length sleep, and `ps` reports a spinning program as running (`R`).

### Fixed

- A CPU-bound Go program no longer stops logical time for its kernel: a
  `sleep` in another process, TCP retransmission, ARP, and `ping` timeouts now
  fire while it runs. Previously each quantum re-queued itself at the current
  instant, `advance(by:)` never reached its target, and it returned
  `.budgetExceeded` with the clock unmoved for as long as the program ran.
- An `async` process body no longer takes a loop step for every `async` call
  and return. Its jobs were run as jobs of the loop's serial executor although
  the task only has a task-executor preference, so the Swift runtime re-posted
  the task at each call boundary. A 5,000-iteration `bc` loop took about
  155,000 steps, more than the default step budget of one `runUntilIdle()`,
  and now takes about 50; the loop now has a separate task executor and runs
  those jobs on it. Fewer steps per process means a given step budget does
  more work, and async processes interleave at their suspensions only.
- `awk`, `bc`, and commands that copy from an endless device (`cat /dev/zero`,
  `dd if=/dev/urandom`) no longer stop logical time for their kernel while
  they run under a real-time host; a `sleep` in another process now wakes on
  time. The same holds for endless pipelines such as `yes | cat > /dev/null`.
- A shell loop made only of builtins (`while :; do :; done`, also in the
  background) no longer runs as a single step that never ends. The call that
  drove it (`advance(by:)`, `runUntilIdle()`) never returned, so the host
  hung and Ctrl-C could not be delivered.
- `mkdir`, `mv`, `rm`, `rmdir`, and every other command that goes through the
  capability-scoped file calls now stamp what they change. A new directory or
  file created that way was left at the epoch (1970 with an injected clock), a
  directory's mtime/ctime did not follow entries added, removed, or renamed
  through those calls, and a renamed node kept its old ctime.
- `rm` of one of several hard links now gives the link count back and updates
  the inode's ctime.
- `symlink` no longer restamps the existing directories that lead to the link.
- A tmpfs mount root, `/dev` and `/proc` files, and computed nodes such as
  `/proc/<pid>` and `/dev/pts/<n>` no longer show the epoch: kernel-provided
  nodes are dated at boot on the injected clock and computed ones at lookup.
  Restored snapshots and images keep their stored times.

## 0.13.0 — 2026-10-07

A userland baseline: the shell is a POSIX-style interpreter, the built-in
command set covers everyday coreutils use, and time, identity, devices, and
signals behave the way a Linux user expects. Public API changes are additive.

### Added

- Shell language: `if`/`for`/`while`/`until`/`case`, functions with `local`
  and `return`, here-documents and here-strings, `$(...)`, `$((...))`,
  `${v:-d}`-style parameter expansion, brace and tilde expansion, subshells
  and groups, `trap`, `set -eux`, aliases, and job control. `sh` runs a script
  file, `sh -c STRING`, or a nested interactive shell, and an executable
  script (`./x.sh a b`, or by name through `$PATH`) runs as a program.
- Shell builtins `umask [-S] [MODE]` (octal and symbolic) and `$RANDOM`, plus
  `BUILTIN --help` for every builtin.
- Commands: `awk` (patterns, arrays, user functions, `printf`, `getline`,
  `system()`, and `|` pipes through `sh -c`), `tar`, `bc`, `dd`, `od`,
  `hexdump`, `xxd`, `base64`, `tr`, `comm`, `join`, `paste`, `column`,
  `expand`, `fold`, `split`, `tac`, `cmp`, `strings`, `file`, `tree`,
  `realpath`, `mktemp`, `truncate`, `rmdir`, `sync`, `yes`, `less`, `time`,
  `watch`, `nproc`, `printenv`, `pgrep`, `pkill`, `pidof`, `killall`, `date`,
  `cal`, `id`, `groups`, `who`, `w`, `logname`, `tty`, `stty`, `shutdown`,
  `reboot`, `poweroff`, `halt`, `dig`, `ss`, and `telnet`.
- Every registered command answers `--help` with `Usage: …` and exits 0, and
  `man COMMAND` renders the same text. `Command` gains an optional `usage`
  string for consumer-registered commands.
- Wall clock: `Kernel.setWallClock` injects the epoch and zone; `date`,
  `ls -l`, `stat`, `tar tv`, `touch -d`/`-t`, and `find -newer`/`-mmin`/
  `-mtime` use it. Without an injected clock, logical zero is the Unix epoch.
- Identity: users and groups come from `/etc/passwd` and `/etc/group` (with a
  synthetic `root`/`userN` fallback) in `ls -l`, `stat`, `chown`,
  `find -user`, `ps`, `id`, `whoami`, the prompt, and `su`. `su` accepts a
  name or uid and the forms `su`, `su -`, `su - USER`, `su USER -c COMMAND`,
  and `su USER COMMAND ARG...`.
- Devices and procfs: `/dev/zero`, `/dev/full`, `/dev/random`, `/dev/urandom`,
  `/dev/tty`, `/dev/pts/N`, `/dev/stdin|stdout|stderr`, `/dev/fd`;
  `/proc/self`, `/proc/<pid>/{stat,comm,environ,fd,cwd}`, and system files
  such as `/proc/uptime`, `/proc/loadavg`, `/proc/meminfo`, and
  `/proc/version`.
- Per-process `umask` (`ProcessContext.umask(_:)`, `fileCreationMask`), and
  `Kernel.onPowerRequest` for `shutdown`/`reboot`.
- Network commands: `ip addr|link|route|neigh`, `ss`, `dig`, `telnet`,
  `hostname -I|-i|-s|-f`, a fuller `curl`/`wget`/`nc`/`ping`/`traceroute`
  option set, and uniform option parsing — an unknown option is a usage error
  (exit 2), never taken for a host name.
- Ctrl-C at the shell: at an idle prompt it discards the input line and
  prompts again; at a continuation prompt (`> `) it abandons the pending
  command; it stops a running shell loop; and a nested interactive shell
  survives it. `$?` is 130 afterwards.
- Swiftix Go: `os.Stdin`/`os.Stdout`/`os.Stderr`, `fmt.Fprint`/`fmt.Fprintln`,
  `(*os.File).Read`/`Write`/`WriteString`, `os.ReadFile`/`os.WriteFile`,
  `sort.Strings`/`sort.Ints`, `strconv.Itoa`, the bitwise operators, the
  `byte`/`uint8` type, and conversions among `int`, `byte`, `string`, and
  `[]byte`. `GoVirtualMachine.startProcess` runs an executable cooperatively
  as the body of a process.
- Swiftix Go links the local packages of a module into one program:
  `GoCompiler.compile(packages:root:)` and
  `GoCompiler.compile(root:sources:)` (with `GoPackageSource`) compile a
  `package main` together with every package it imports, directly or
  transitively. Across packages a program may call functions with any number
  of results, use exported constants, read and assign exported variables, and
  use exported types, struct fields, and methods; packages initialize
  dependencies first, each exactly once. A cross-package reference compiles to
  the same instructions as the in-package form. Unexported and undefined
  names, import cycles, unused local imports, imports of a `package main`, and
  `internal/` packages imported from outside their tree are diagnosed.
  `go build`, `go run`, and `go install` accept a package directory such as
  `./cmd/tool`.
- Swiftix Go language: compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`,
  `&=`, `|=`, `^=`, `&^=`, `<<=`, `>>=`); hexadecimal, octal (`0o644` and
  `0644`), and binary integer literals with `_` separators; `return f()`
  forwarding every result of a multi-result call; qualified composite
  literals (`pkg.Type{...}`); and package-level initializers that call
  imported packages.

### Changed

- Swiftix Go: the `go` tool builds multi-package modules through the module
  linker, so a main package is no longer limited to single-result functions
  of the packages it imports. The build cache key now also names the root
  package (entries written by earlier builds are simply not reused), and an
  import chain deeper than 128 packages is refused. A leading zero now selects
  octal (`010` is 8), `12ab` is an invalid literal instead of two tokens, and
  `gofmt` writes a space before a parenthesized result list
  (`func f() (int, error)`).
- Unquoted expansions are split into fields on `$IFS` and then globbed;
  quote an expansion (`"$v"`) to keep it as one word.
- Shell variables are no longer exported by default: `v=1` is visible to
  child processes only after `export v` (or as a `v=1 command` prefix).
- Command substitution, pipeline stages that run shell code, and `( ... )`
  run in a child shell, so their assignments and `cd` do not affect the
  parent.
- New files, directories, and FIFOs honor the process `umask` (022 by
  default): `mkdir` creates mode 0755 and `mkfifo` 0644.
- `grep` and `sed` use POSIX basic regular expressions by default; pass `-E`
  for extended syntax (`+`, `?`, `|`, unescaped groups).
- `mkdir` without `-p` no longer creates missing parent directories, and
  reports an existing directory as an error.
- `head` and `tail` print `==> NAME <==` headers when given several files.
- `find`, `du`, `tree`, `ls -R`, `grep -r`, `rm -r`, and `cp -r` no longer
  follow symbolic links met during a walk (`grep -R` follows them, visiting
  each directory once); `chmod -R`, `chown -R`, and `tar` walk the same way.
  `grep -r`, `cp -r`, and `tar` skip device nodes met during a walk.
- `ls -l` and `stat` print calendar times and user/group names (`ls -n` for
  numeric ids). In `stat -c`, `%X`/`%Y`/`%Z` are integer epoch seconds and
  `%x`/`%y`/`%z` the readable forms.
- Reading an endless device with `cat` (`cat /dev/zero`) streams until
  interrupted, as on Linux. A failed write is reported and fails the command:
  `echo x > /dev/full` prints `echo: write error: No space left on device`
  and exits 1.
- PID 1 of a PID namespace ignores guest signals it has no handler for, so
  `kill -9 1` no longer ends the session it is typed into. Signals sent
  through the host `Kernel` API are unaffected.
- A foreground job killed by Ctrl-C ends the rest of its command line
  (`sleep 100; echo done` prints nothing).
- `hostname -I` and other options are parsed as options; they previously set
  the host name to the option text.
- `whoami` and the shell's default `USER`/`HOME` come from the user database.
- Directory search (execute) permission is enforced on every component of a
  path, not only the last: as uid 1000, `cat /root/x` now fails with
  `Permission denied` when `/root` is mode 0700, whatever the mode of `x`.
  This applies to every path syscall, to symbolic-link targets, to mount
  namespaces, and to `FileSystemScope` operations; uid 0 is unaffected. A path
  at or below the working directory still resolves from the working
  directory. `link` fails when the caller cannot reach the target, and tab
  completion lists only what the shell's user may list.
- `mount` and `umount` (and `mountTmpfs`/`mountBind`/`unmount`) require
  uid 0; other users get `must be superuser to use mount.` Previously any user
  could change the mount table, including bind-mounting a directory it could
  not otherwise enter.
- A connected TCP socket is closed by its last descriptor: `tcpClose` on one
  of several descriptors sharing a connection (a `dup`, or a socket inherited
  by a child) no longer sends a FIN; the last close does.
- Swiftix Go conformance: `s[i]` on a string is a `byte` and `time.After`/
  `time.Tick` return `<-chan time.Time`, as in Go. Source that used a string
  byte as an `int` needs `int(s[i])`.
- File-backed Swiftix Go programs are scheduled cooperatively. They yield to
  the event loop every instruction quantum instead of stopping at 1,000,000
  instructions, `time.Sleep` and timers park the process until logical time
  advances instead of fast-forwarding the clock, and reads of standard input
  no longer run the upstream pipeline stage nested inside the reader. A host
  that runs such a program must advance logical time for its timers to fire.

### Fixed

- A directory tree nested thousands of levels deep (reachable from a guest
  with `mkdir -p`) no longer overflows the host stack. Releasing the tree,
  `/proc/meminfo` and resource accounting, rename's subtree check, filesystem
  snapshot capture/validation/restore, and `rm -r`, `chmod -R`, `chown -R`,
  `du`, `tree`, `grep -r`, `df`, and `free` now walk with explicit worklists.
  A snapshot's legacy `root` projection is written to at most
  `FilesystemSnapshot.legacyProjectionDepthLimit` (256) directory levels;
  the inode table still holds every level, and images whose `root` carries
  the full tree remain valid.
- Swiftix Go programs no longer lose output beyond a pipe's 64 KiB: a write
  parks until the reader makes room.
- A goroutine that sleeps or reads standard input exactly on an instruction
  quantum boundary no longer aborts the run with `bytecode operand type
  mismatch`.
- The Go heap no longer scans every cell after each instruction, and a slice
  element store or `append` no longer copies the whole backing array.

- A process that exits or is killed with a connected TCP socket open now
  closes the connection: Ctrl-C on `nc` or `curl` no longer leaves the server
  side established forever. The peer sees a FIN, or a reset if the process
  left received data unread (as on Linux). Connections nobody accepted are
  reset when their listener closes, data sent to a closed peer draws a reset,
  an ownerless connection whose peer never closes is released after 60
  seconds, and one whose last data is stuck behind a zero window resets the
  peer after 8 unanswered probes.
- A TCP close with data still waiting for the send window sends the FIN after
  that data instead of ahead of it.
- Data can be sent on a connection after the peer has closed its half
  (CLOSE_WAIT).
- A receive on a connection that was already reset returns immediately
  instead of parking forever, and bytes that arrived before a reset are
  delivered before the reset is reported.
- `mv`, `chmod`, `chown`, and `du` report `Permission denied` rather than
  `No such file or directory` for a path behind an unsearchable directory.
- Output larger than a pipe buffer (64 KiB) is no longer truncated in
  pipelines or command substitution (`x=$(seq 1 20000)`,
  `seq 1 50000 | sort -rn | head -1`): producers wait for the reader.

## 0.12.0 — 2026-09-30

This release lets independently packaged Swiftix Go programs run full-screen
in a terminal, such as the nano-style editor from the `editors` repository.
It is an intentional pre-1.0 API break: see the 0.12 notes in
[compatibility](docs/compatibility.md).

### Changed

- The GitHub Actions workflow is removed. Verification runs locally with the
  commands in the README, and host toolchain packages are built, signed, and
  notarized as manual release steps; this release publishes no packaged
  toolchain.
- The package version advances to 0.12.0: the public `GoInstruction` and
  `GoIROperation` enums gain cases for the terminal ABI and `strings`, which
  breaks exhaustive switches. See the 0.12 notes in
  [compatibility](docs/compatibility.md).

### Added

- `swiftix/userland` terminal calls for full-screen Go programs:
  `ReadStdin`, `WriteFile`, `SetRawMode`, and `WindowSize`. Images that use
  them encode four new bytecode opcodes (97–100); the image format and ABI
  versions are unchanged, and older runtimes reject such images at decode.
- `GoVirtualMachine.startProgram`, a resumable run that suspends while its
  goroutines wait on terminal input. `GoExecutableLoader` uses it, so
  file-backed interactive programs wait for keystrokes instead of reporting a
  deadlock. Its instruction and output budgets apply per uninterrupted slice.
- Go interpreted string literals accept `\a`, `\b`, `\f`, `\v`, `\xHH`,
  three-digit octal, `\uHHHH`, and `\UHHHHHHHH` escapes, so programs can
  emit terminal control sequences such as `"\x1b[2J"`. Escapes must still
  form valid UTF-8, and `gofmt -r` re-quotes control characters as `\x`
  escapes.
- A native `strings` package: `Contains`, `Count`, `HasPrefix`, `HasSuffix`,
  `Index`, `Join`, `LastIndex`, `Repeat`, `Split`, and `TrimSpace`, with Go
  semantics and string and collection limits. Calls encode as opcode 101
  followed by a function byte, so later functions need no new opcode; older
  runtimes reject them at decode.

### Fixed

- A process step that completes nested inside another step of the same
  process (for example a read resumed while the Go VM drives the event loop)
  no longer reaps the process with status 0 while the enclosing step is still
  running.
- A Swiftix Go run that fails with the terminal in raw mode restores cooked
  mode.
- A `for` header no longer parses an identifier before `{` as a composite
  literal, so `for i < limit {` and `for …; …; i = i + step {` compile.
- Indexing, slicing, and ranging over a Go string no longer copy the whole
  string on every operation, which made byte loops quadratic.

## 0.11.2 — 2026-09-29

This release republishes the host toolchain packages so that every
platform's downloads are complete. The toolchain is unchanged from 0.11.0.

### Fixed

- The Linux `arm64` `.tar.gz` package, which was missing from the 0.11.1
  downloads, is published again alongside the other seven packages.

## 0.11.1 — 2026-09-29

This release adds host toolchain packages for two more host platforms. The
toolchain itself is unchanged from 0.11.0.

### Added

- `swiftix-toolchain` packages for macOS on Intel (`amd64`: `.pkg` and
  `.tar.gz`) and Linux on `arm64` (`.deb` and `.tar.gz`). CI builds and
  install-smoke-tests them next to the existing macOS `arm64` and Linux
  `amd64` packages, and signs and notarizes both macOS packages for tagged
  releases.

## 0.11.0 — 2026-08-16

This release establishes the versioned teaching-observability surface used by
independently packaged system diagnostic commands.

### Added

- Kernel-wide managed-runtime memory admission with configurable limits, exact
  Swiftix Go heap reporting, per-process heap/GC diagnostics, and separate VFS
  byte accounting.
- `/proc/<pid>/fdinfo` descriptor diagnostics for files, pipes, FIFOs, PTYs,
  UDP sockets, TCP sockets, and devices.
- A versioned teaching-observability contract in `/proc/swiftix`, plus the last
  128 completed Swift-native calls per process in `/proc/<pid>/syscalls`.

### Changed

- `/proc/meminfo` and `free` now report actual managed-runtime heap usage instead
  of treating VFS file bytes as synthetic physical memory. Output explicitly
  distinguishes the managed-runtime model from host memory and VFS storage.
- `/proc/processes` adds a `MEM` field containing exact runtime-reported bytes;
  `top` displays the same value without labeling it RSS.

### Fixed

- Release validation now rejects a tag that disagrees with `Swiftix.version` or
  lacks a matching changelog entry. The historical `v0.10.1` tag contained the
  `0.10.0` runtime version string; 0.11 establishes the corrected baseline.

## 0.10.0 — 2026-08-15

This pre-1.0 minor intentionally changes the public kernel API described in the
0.9-to-0.10 migration notes.

### Added

- Public process diagnostics through `Kernel.snapshotProcesses()`, including
  lifecycle, Linux-style state, exit status, wait reasons, queued work, signals,
  descriptors, and scheduler ticks.
- `ProcessExitStatus`, `SIGSTOP`, continued child notifications, and the
  `ProcessWaitOptions.continued` (`WCONTINUED`) option.
- Separate live and zombie counts in kernel resource snapshots and `/proc/resources`.
- `SIGPIPE` plus typed `SyscallError.brokenPipe` (`EPIPE`) for readerless
  pipe/FIFO writes.
- Supplementary process groups and a compact inherited mode-bit DAC model.
- Injectable asynchronous `BlockVolume` storage with typed failures and an
  explicit flush/durability barrier, while retaining RamDisk compatibility.
- Pager-friendly `pread`/`pwrite` regular-file operations that preserve the
  shared open-file-description offset.
- Typed device/storage syscall failures for missing devices, I/O failure,
  exhausted space, and read-only storage.

### Changed

- Process execution state and terminal lifecycle are independent. Exited
  children now remain observable as zombies until a parent wait reaps them.
- Process-owned timers, resumptions, and parked operations are cancelled at
  logical exit; orphaned children are adopted by a namespace reaper or the host.
- Blocking operations use a structured wait registry instead of an opaque count.
- Descriptors created by `dup` or spawn inheritance now share one open-file
  description, including status flags, locks, offsets, and last-close lifetime.
- VFS names now belong to directory entries, so hard links and rename preserve
  independent names for one inode-like node.
- Pipe, PTY, and TCP blocking reads retain FIFO queues of waiters rather than one
  overwriteable callback.
- `pids.max` rejects child creation before PID allocation (`spawn` returns `0`),
  while migration into an over-limit cgroup remains allowed.
- UDP binding is single-owner and non-replacing; port `0` allocates an ephemeral
  port and `SO_REUSEADDR` no longer silently steals an existing binding.
- Credential changes now inherit across spawn and enforce root/owner boundaries
  for identity, ownership, mode, and parent-directory mutation.

## 0.9.0 — 2026-08-15

### Added

- Single-node kernel, VFS, process/fd/signal/pty model and IPv4 TCP/IP stack.
- Swiftix Go compiler, bytecode runtime and macOS/Linux host tools.
- Deterministic root filesystem images and Debian-style package management.
- Public topology, terminal, uplink and observability seams.

### Changed

- Distribution content moved to SwiftixDistribution.
- Core version advanced from `0.0.1` to `0.9.0` for the 1.0 stabilization cycle.
- Root filesystem minimum-version checks now implement SemVer prerelease precedence.
- Host image execution moved from `swiftix-run` to `swiftix-go exec`.
- Removed the unconsumed built-in `awk` and `nano` programs and the partial
  IPv6 address/ICMPv6 surface.

### Known limits

- IPv6 is not supported; Swiftix Go and Linux compatibility are documented subsets.
- `pkg` uses HTTP + SHA-256 in trusted experiment networks; it does not
  authenticate arbitrary public repositories.
- Public API remains subject to review until 1.0.
