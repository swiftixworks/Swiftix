# Changelog

Swiftix follows [Semantic Versioning](https://semver.org/). User-visible API,
format, behavior and platform changes are recorded here.

## Unreleased

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
