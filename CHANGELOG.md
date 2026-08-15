# Changelog

Swiftix follows [Semantic Versioning](https://semver.org/). User-visible API,
format, behavior and platform changes are recorded here.

## Unreleased

- No changes yet.

## 0.9.0 — planned

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
