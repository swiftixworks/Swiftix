# Security policy

## Supported versions

`0.9.x` is the active pre-1.0 stabilization line and receives correctness and
security fixes. After 1.0, the latest `1.x` release will be supported; older
pre-1.0 versions are best effort.

## Reporting

Do not file a public issue for a suspected vulnerability. Use GitHub private
vulnerability reporting or a private security advisory for this repository. If
that UI is unavailable, contact the repository owner privately before
publishing details.

Include:

- Swiftix version/commit, Swift version, platform and architecture;
- the affected public API, parser, artifact or network path;
- a minimal reproducer or malformed input;
- observed impact and whether guest input can cross into host state;
- any known workaround.

We will acknowledge receipt, reproduce the issue, agree on disclosure timing
and publish a fix with release notes. No response-time SLA is promised before
1.0.

## Trust boundary

Swiftix runs guest-like programs inside the host process; it is not a hardware
virtualization or process security boundary. Core state is isolated by a serial
executor, not by OS-level sandboxing.

The current package manager accepts HTTP repositories and verifies size,
SHA-256 and archive contents. This detects corruption but does not authenticate
the repository. Treat package sources as trusted unless a future signed
repository contract says otherwise.
