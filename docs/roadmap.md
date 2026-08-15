# Swiftix Product Roadmap

> Status: direction draft
> Updated: 2026-08-15
> Versions define capability boundaries, not release dates.

## Positioning and Version Rules

Swiftix remains an embeddable, observable lightweight operating-system and network-experiment core. New capabilities must serve a real application, network experiment, or diagnostic workflow. Linux compatibility percentage and syscall count are not goals.

- `1.x.0` adds backward-compatible capabilities; each minor version has one primary objective.
- `1.x.y` contains only compatible bug, security, performance, and documentation fixes.
- Before 1.0, one `0.minor` line is a compatibility series: breaking API
  corrections advance the minor version, while patch releases remain compatible.
- Features that do not meet their exit criteria remain experimental and do not block the stable portion of a minor release.
- Plan 2.0 only when a stable API genuinely requires a breaking adjustment; no 2.0 work is currently scheduled.

## 0.9 — Candidate Baseline (established)

Freeze the 1.0 API, formats, and support matrix without adding major features.

- Complete API reduction, documentation, and compatibility gates.
- Add long-running soak, public-input fuzzing, and resource-reclamation validation.
- Rebuild artifacts from a tag and rehearse signing, upload, installation, and promotion.
- Pin coreutils and SwiftixDistribution to the same candidate combination.
- Publish an annotated `v0.9.0` tag and replace floating `main` dependencies with a SemVer range.

**Exit criterion:** an annotated `v0.9.0` establishes the API-review baseline,
all repositories pin the same versions, and the baseline CI matrix is green.

## 0.10 — Semantic Core Corrections

Apply the bounded Linux-aligned lifecycle, descriptor, VFS, blocking-I/O, and
storage corrections discovered after the 0.9 baseline. This is an intentional
pre-1.0 API break; further breaking work requires another minor version.

**Exit criterion:** the migration notes enumerate every 0.9 API break, the API
gate accepts the 0.10 series transition and rejects unversioned breaks within
0.10.x, and full public-consumer, serial, and platform CI remains green.

## 1.0 — Stable Foundation

Deliver the current contract without adding GUI, hot snapshots, or new protocol-stack scope.

- Stabilize the core, images, Go ABI, package format, and host seams.
- Keep the declared macOS, iOS, and Linux platforms green.
- Publish versioned installation, a migration guide, a compatibility matrix, and known limitations.
- Establish a traceable and reversible production release pipeline.
- Make unconsumed public symbols internal and document each stable symbol's concurrency, failure, and resource contract.
- Run a one-hour mixed soak and record RSS, timers, processes, file descriptors, queues, drops, and post-shutdown reclamation.
- Test truncated, extreme, and randomized rootfs, package, Go-image, and network inputs.
- Reproduce the official rootfs from the tag on macOS and Linux.
- Complete an RC through signing, notarization, upload, manifest verification, installation, upgrade, and stable promotion.
- Keep package sources explicitly limited to trusted experimental networks unless signing, HTTPS, and key policy are implemented.
- Pin Swiftix, coreutils, and SwiftixDistribution to the same RC; restart the candidate cycle after an API or format break.

**Exit criterion:** the final RC and `1.0.0` APIs match; full, serial, Release,
soak, platform, and cross-repository tests pass; artifacts are traceable to the
tag; and signing, installation, upgrade, rollback, and promotion work end to
end. There must be no known data corruption, host escape, unbounded resource
growth, or migration dead end.

## 1.1 — Network Experiments and Diagnostics

Use the existing multi-node network stack and deterministic event loop to create reproducible and diagnosable experiments.

- Inject link latency, jitter, packet loss, bandwidth limits, and disconnection.
- Capture virtual-link traffic and export PCAP.
- Present processes, file descriptors, sockets, timers, queues, and packet drops in one diagnostic surface.
- Define, start, reset, and export scenarios with fixed random seeds.
- Generate failure bundles without host-private data.

**Exit criterion:** the same scenario reproduces in tests and through the documented host integration, and failures can be traced across processes, sockets, and packet paths.

## 1.2 — Native GUI MVP

Provide a Swiftix-native GUI protocol without X11, Wayland, GTK, or Qt compatibility.

- Add UI-independent, versioned surfaces, drawing commands, and input events.
- Validate the consumer seam with a SwiftUI Canvas reference adapter first, adding Metal only when performance requires it.
- Support one application surface, text, basic graphics, keyboard, pointer, touch, and resize.
- Pass only bounded `Sendable` values between a VM and `MainActor`.
- Provide a sample application and verify pause, close, and resource reclamation.

**Exit criterion:** a native Swiftix program displays and interacts reliably through the documented consumer seam on iOS and macOS, while the core imports no Apple UI framework.

Multiple windows, a desktop, a compositor, clipboard support, and accessibility do not enter 1.2. Reconsider them only after real applications validate the single-surface model.

## 1.3 — Application and Service Model

Build the minimum lifecycle needed by first-party native applications rather than duplicating complete distribution infrastructure.

- Define one manifest for CLI tools, background services, and GUI applications.
- Declare file, network, device, and GUI capabilities.
- Provide start, stop, crash restart, health state, and bounded logs.
- Enforce process, file-descriptor, queue, and storage limits.
- Stabilize the Swift and Swiftix Go SDKs with templates and external-consumer tests.
- Reuse existing package transactions for install, upgrade, and rollback.

**Exit criterion:** CLI, service, and GUI examples install, start, stop, and uninstall through the same lifecycle, leaving no resources behind after abnormal exit.

## 1.4 — Cold Snapshots and Cloning

Solve concrete downstream cold-backup needs first; do not promise restoration of active processes or TCP connections.

- Snapshot the filesystem, configuration, and topology of a powered-off VM.
- Clone, import, export, and migrate snapshot formats.
- Provide atomic writes, digest validation, quotas, and corruption recovery.
- Reset an experiment to a known initial state with one action.

**Exit criterion:** a snapshot restores across an app restart, and corrupt data never overwrites the last valid version.

## 1.5+ — Demand-Driven Only

The following capabilities do not reserve version numbers. Schedule them in a later minor only after identifying a concrete application, test plan, and maintainer:

- A multi-window desktop and more complex graphics composition.
- IPv6 support, Unix sockets, `mmap`, or new syscalls.
- Public package-source signing and key rotation.
- VLANs, routing protocols, and new network devices.
- Hot snapshots, instruction-level replay, or live-state migration between devices.

## Required in Every Version

- Fuzz public-input parsers and test boundaries and resource limits.
- Run soak tests and observe memory, timers, and queue high-water marks.
- Maintain API/format compatibility gates and migration notes.
- Optimize only hotspots demonstrated by benchmarks or real workloads.
- Add only the VFS, process, networking, and Go-subset behavior required by the current version objective.

## Explicit Non-Goals

- Executing Linux ELF or supporting Linux ABI, X11, Wayland, GTK, or Qt compatibility.
- Complete Debian userland, the complete Go language/standard library, or a syscall parity table.
- A multithreaded shared kernel pursued for throughput.
- A general cloud platform, multi-user collaboration backend, course store, or application marketplace.
- A complete desktop, dynamic routing suite, or full-state time travel without a real consumer.

If resources are constrained, protect the current stable release and 1.1 first; defer later minor versions rather than developing them in parallel. Every new proposal must identify a real user, minimum API, resource boundary, verification strategy, and the current work it replaces.
