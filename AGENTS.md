# AGENTS.md — Swiftix Development Rules

This file contains only the operational and engineering rules that AI and automation agents must follow when working in the `Swiftix/` repository. Product positioning, current capabilities, and future direction are maintained in [`README.md`](README.md) and [`docs/architecture.md`](docs/architecture.md), not here.

## Scope

- These rules apply to the current `Swiftix/` Git repository. Do not treat sibling app repositories as part of the same worktree.
- Preserve the user's existing uncommitted changes. Do not overwrite or format unrelated files.
- Inspect the relevant source, tests, and documentation before making changes. Do not infer current product capabilities from this file.

## Core Boundaries

These constraints define code ownership; they are not a feature inventory:

- `Sources/Swiftix/` implements the single-node core only. Do not add UI, multi-host topology, link models, or device orchestration.
- The core target must not add third-party dependencies or import Foundation, UIKit, Network.framework, or other platform frameworks. Put platform implementations in separate integration targets.
- The topology layer composes nodes through the `NetworkNode`/`NetworkInterface` frame seam and must not depend on the concrete `NetworkStack.Interface` type.
- Console integrations use the input, output, and control-signal seams exposed by `PseudoTerminal`.
- New implementation remains `internal` by default. Make only stable consumer boundaries public; do not expose VFS, process, socket, or protocol-parsing internals as public API.

If a requirement introduces UI, platform objects, links, or multi-node state, first confirm that it belongs in the core repository. Do not break target boundaries for convenience.

## Concurrency Constraints

A single serial executor drives the Swiftix core object graph. Safety comes from executor isolation, not internal locking:

- Do not add `NSLock`, `DispatchQueue`, or another internal synchronization layer.
- Do not use `@unchecked Sendable` to bypass concurrency checking.
- Reference objects such as `EventLoop`, `Kernel`, `NetworkStack`, `ProcessContext`, and `PseudoTerminal` remain non-Sendable.
- Construction, `spawn`, network configuration, ingress frame delivery, PTY interaction, and event-loop advancement must all occur on the same executor.
- Async syscalls and async process bodies must resume on the event loop's bound `SwiftixExecutor`.

Core builds must not introduce new data-race diagnostics.

## Implementation Conventions

- Follow the existing file-header style in new source files and state each file's responsibility and concurrency context.
- Preserve `R*` traceability markers in the code. Remove them only after confirming that the corresponding specification has been retired.
- Syscalls that can fail use `throws` with `SyscallError`. Blocking operations integrate with park/wake and `IOReadiness`, with an async frontend where appropriate.
- Separate state decisions from side effects. In particular, keep pure TCP decisions in planners or state machines, and centralize I/O and state application in the execution layer.
- Do not opportunistically reorder, rename, or format code unrelated to the task.

## Testing Conventions

- Use swift-testing (`import Testing`, `@Test`, and `#expect`) rather than adding XCTest-style tests.
- Every new behavior requires tests. Prefer invariants or property-style tests for correctness properties.
- Tests must not depend on wall-clock time. Advance logical time with `EventLoop.advance(by:)` or `runUntilIdle()`.
- Cross-node tests use fixtures such as `TestWire` in test code; do not add topology types to the core for testing.
- Keep one feature area per test file. Name property-test files `*PropertyTests.swift`.

## Verification Commands

Run from `Swiftix/`:

```bash
swift build
swift test
git diff --check
```

At minimum, run `swift build` and the full `swift test` suite for every change. For concurrency, scheduling, or order-sensitive behavior, also run:

```bash
swift test --no-parallel
```

Distribution commands, default configuration, and the built rootfs artifact belong in the `SwiftixDistribution` repository. Do not reintroduce distribution policy or content into this repository.

## Documentation Ownership

- `README.md`: user-facing positioning, installation, examples, and release entry points.
- `docs/architecture.md`: current architecture, scope boundaries, non-goals, and active direction.
- `docs/go-toolchain.md` and `docs/package-manager.md`: technical contracts for the corresponding optional products.
- `AGENTS.md`: agent operating rules and non-negotiable engineering constraints only.

Do not duplicate command inventories, subsystem completion tables, roadmaps, milestones, or product copy in this file.
