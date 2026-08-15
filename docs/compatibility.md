# Compatibility and migration

> Last release baseline: Swiftix 0.9.0; current development series: 0.10.x

| Contract | Current version | Compatibility rule |
| --- | ---: | --- |
| Swiftix package | 0.10.0 | Each pre-1.0 minor may break API; patches preserve their minor series |
| Filesystem snapshot | 2 | Current writer emits v2; unsupported versions fail before restore |
| Rootfs image | 1 | Exact format; digest, target and resource limits validated |
| Swiftix Go image / ABI | 10 / 10 | Exact format and ABI required before VM allocation |
| `.pkg` archive | 2 | v1 is rejected; v2 is deterministic and bounded |
| Swiftix Minimal | 2.1.1 | Metadata declares its minimum Swiftix version |
| SwiftixDistribution manifest | 1 | Builder validates schema and deterministic output |

## Platform baseline

| Component | Supported baseline |
| --- | --- |
| Swift toolchain | Swift 6.3 |
| Swiftix core | macOS 14, iOS 17, Linux |
| Host toolchain | macOS and Linux, arm64/amd64 as produced by CI |

## Public API stability

`0.x` is the API review window. Public visibility in a pre-1.0 build does not by
itself make a symbol part of the final 1.x contract. A deliberate breaking
change advances the minor version before merge; patch releases preserve the
public API of their `0.minor` compatibility series.

The intended stable seams are:

- core lifecycle through `EventLoop` and `Kernel`;
- programs through `ProcessContext`, `CommandRegistry`, `Programs`, and
  `SyscallError`;
- terminal and topology boundaries through `PseudoTerminal`, `NetworkNode`, and
  `NetworkInterface`;
- bounded image, package, and Swiftix Go runtime contracts.

Protocol parsers, VFS nodes, process tables, socket state machines, compiler IR,
and VM storage remain implementation details. Before 1.0 they must become
internal or receive an explicit stable contract.

## Linux semantic profile

Swiftix targets Linux/POSIX-style observable behavior for its documented core
primitives; it does not target Linux ABI or subsystem completeness. In
particular, the stable direction is shared open-file descriptions, inode versus
directory-entry separation, two-phase process exit/reap, multi-waiter blocking
I/O, and last-close pipe behavior.

The compatibility boundary remains explicit:

- credentials implement inherited effective uid/gid/supplementary groups and a
  compact mode-bit DAC subset, not real/saved IDs, capabilities, ACLs, or full
  per-component search permission;
- only the cgroup-v2-style pids controller is modeled, and a refused Swift
  `spawn` returns PID `0` rather than exposing host `errno`;
- UDP has one binding owner per port. `SO_REUSEADDR` can be stored/read as an
  option but does not enable shared binding until a deterministic fanout model
  exists;
- process execution remains cooperative and logical-time-driven; Swiftix does
  not execute Linux ELF binaries or create host processes.

Consumers should rely on documented invariants and typed Swift APIs, not infer
support from a familiar Linux name alone.

## Storage and application-runtime boundary

`BlockVolume` is the public persistence seam for page-oriented applications.
Volume geometry is fixed after attachment; read, write, and flush completions
run on the same serial executor that drives the Kernel. `flush` is the only
durability barrier: a successful ordinary write means accepted, not necessarily
crash-durable. Volume implementations report `BlockVolumeError`, while guest
async syscalls translate failures to stable `SyscallError` cases.

The synchronous `BlockDevice`/RamDisk methods remain available for existing
teaching code. A durable adapter should implement `BlockVolume` directly and
must not block the Kernel executor. `pread` and `pwrite` provide regular-file
positional I/O without changing the shared open-file-description offset; they do
not make the current in-memory VFS durable.

Multi-Kernel application lifecycle is a downstream control-plane responsibility.
The stable core seam is Kernel construction, rootfs restoration, volume/network
attachment, process start/observation, and Kernel pause/resume/shutdown. Guest
processes do not receive ambient authority to create or control sibling Kernels.

CI compiles `Example/PublicAPISmoke` without `@testable import` and uses
`Scripts/check-api-breakage.sh` against the latest version tag in the same
SemVer compatibility series. For `0.x`, the series is `0.minor`; for 1.0 and
later, it is the major version. Before a new series has a release tag, its first
committed version-bump revision becomes the development baseline. Crossing a
series accepts breaking changes only when the package version was advanced.

## Change policy

- Stable 1.x source API changes follow SemVer; removals require a new major.
- Pre-1.0 source compatibility is scoped to one `0.minor` series. Breaking API
  changes require the next minor version; patch releases remain compatible.
- Encoded formats carry their own version. Readers reject unknown versions
  before mutating guest state.
- A minimum Swiftix version uses SemVer precedence, including prereleases.
- Go image ABI is exact: rebuilding distribution commands is required after an
  ABI bump.
- SwiftixDistribution publishes a rootfs digest; consumers pin that digest, and an
  existing VM snapshot takes precedence over a new bundled image.
- A format bump must update this table, tests, migration notes and all
  consuming repositories in the same release train.

## Migrating from 0.9 to 0.10 and 1.0

This section will be finalized against the last 1.0 release candidate. Use an
exact pre-1.0 minor range rather than allowing every `0.x` API revision:

```swift
.package(
    url: "https://github.com/swiftixworks/Swiftix.git",
    .upToNextMinor(from: "0.10.0")
)
```

For `1.0.0`, advance the lower bound to `1.0.0` after completing these checks:

1. Build the consumer without `@testable import Swiftix`.
2. Keep each core object graph on one owning serial executor.
3. Connect topology through `NetworkNode` and `NetworkInterface`.
4. Restore the official rootfs only when no existing snapshot is present.
5. Rebuild Swiftix Go executables after an image ABI change.
6. Accept `.pkg` repositories only from the documented trust domain.

The 0.9 API review has already made these user-visible reductions:

- use `swiftix-go exec` instead of the removed `swiftix-run` executable;
- do not depend on `IPv6Address`, ICMPv6 echo, or
  `NetworkInterface.ipv6Address`; IPv6 is outside the current contract;
- install `awk` or an editor as distribution software when needed; they are no
  longer native built-ins.

The 0.10 process lifecycle contract intentionally changes the `v0.9.0` API:

- `ProcessWaitStatus` now represents child state changes and includes
  `.continued`; exhaustive switches must handle the new case.
- terminal results are represented separately by `ProcessExitStatus`.
- an exited child with a live parent remains visible as `Z` until a matching
  wait consumes its terminal event, so `Kernel.processCount` includes zombies.
- use `Kernel.snapshotProcesses()` and the live/zombie fields in
  `snapshotResources()` when a consumer needs lifecycle diagnostics rather than
  assuming every retained PID is executable.

Other intentional 0.10 API and semantic corrections:

- `dup`, `dup2`, and spawn inheritance now share one open-file description,
  including file-status flags and last-close behavior;
- `ProcessContext.setuid`/`setgid` now return success and do not let an
  unprivileged process regain another identity; set gid/groups before dropping
  a root uid;
- cgroup `pids.max` refusal returns PID `0` without creating a waitable phantom
  child, while moving an existing process into a full group succeeds;
- readerless pipe/FIFO writes deliver `SIGPIPE`; throwing writes report
  `SyscallError.brokenPipe` (`EPIPE`);
- a second UDP bind never displaces a live incumbent, including when only the
  newcomer enables `SO_REUSEADDR`.

Unknown snapshot, rootfs, Go image, and package formats fail before mutating
guest state. Preserve the old artifact and report every relevant version from
the matrix above. Later pre-1.0 breaking changes require another minor bump and
corresponding migration notes before the first 1.0 release candidate.
