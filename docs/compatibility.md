# Compatibility and migration

> Baseline: Swiftix 0.9.0

| Contract | Current version | Compatibility rule |
| --- | ---: | --- |
| Swiftix package | 0.9.0 | Pre-1.0 API may still be reduced; 1.x will follow SemVer |
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

`0.9.x` is the API review window. Public visibility in a pre-1.0 build does not
by itself make a symbol part of the final 1.x contract.

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

CI compiles `Example/PublicAPISmoke` without `@testable import` and uses
`Scripts/check-api-breakage.sh` against the latest version tag.

## Change policy

- Stable 1.x source API changes follow SemVer; removals require a new major.
- Encoded formats carry their own version. Readers reject unknown versions
  before mutating guest state.
- A minimum Swiftix version uses SemVer precedence, including prereleases.
- Go image ABI is exact: rebuilding distribution commands is required after an
  ABI bump.
- SwiftixDistribution publishes a rootfs digest; consumers pin that digest, and an
  existing VM snapshot takes precedence over a new bundled image.
- A format bump must update this table, tests, migration notes and all
  consuming repositories in the same release train.

## Migrating from 0.9 to 1.0

This section will be finalized against the last 1.0 release candidate. After
`v0.9.0` exists, replace a floating `main` dependency with a SemVer range:

```swift
.package(
    url: "https://github.com/swiftixworks/Swiftix.git",
    .upToNextMajor(from: "0.9.0")
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

Unknown snapshot, rootfs, Go image, and package formats fail before mutating
guest state. Preserve the old artifact and report every relevant version from
the matrix above. Breaking changes made during `0.9.x` will be recorded here
before the first 1.0 release candidate.
