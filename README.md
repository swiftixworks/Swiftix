# Swiftix

Swiftix is a **single-node operating system and TCP/IP stack** implemented in pure Swift and running entirely in user space. Each instance models a lightweight Linux-like node with processes, a VFS, file descriptors, signals, PTYs, a shell, and Ethernet/ARP/IPv4/ICMP/UDP/TCP/DNS.

Swiftix targets iOS and also supports macOS and Linux. It does not execute ELF binaries or call host `fork`/`exec`; programs receive POSIX-style semantics through Swift APIs or first-party Swiftix Go bytecode.

> Swiftix is currently in its pre-1.0 stabilization phase. See the [product roadmap](docs/roadmap.md) for release gates.

## Positioning

| Swiftix owns | The consumer owns |
| --- | --- |
| Single-node kernel, processes, VFS, file descriptors, signals, and PTYs | UI, machine inventory, and persistence policy |
| Single-node interfaces, routing, sockets, and TCP/IP | Links, switches, routers, and multi-node topology |
| Logical time, event loop, and serial executor | Real-time driving, platform callbacks, and cross-node scheduling |
| Built-in commands, Swiftix Go, image, and package-management APIs | Distribution content, courses, and application experience |

The core has no Foundation, UI, or third-party dependencies. See [Core Architecture](docs/architecture.md) for the complete boundary.

## Installation

- Swift 6.3+
- macOS 14 or iOS 17

There is no stable tag before 1.0, so development consumers temporarily depend on `main`:

```swift
dependencies: [
    .package(url: "https://github.com/swiftixworks/Swiftix.git", branch: "main"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "Swiftix", package: "Swiftix")]
    ),
]
```

Remote consumers should move to a SemVer range after the 0.9/1.0 release.

## Minimal Example

An `EventLoop` drives each instance. Processes and network timers run only when the loop advances:

```swift
import Swiftix

let loop = EventLoop()
let kernel = Kernel(loop: loop)

kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
    address: IPv4Address(10, 0, 0, 1),
    mac: MACAddress("02:00:00:00:00:01")!
)))

kernel.spawn("hello") { context in
    context.print("hello from Swiftix\n")
    context.exit(0)
}

loop.runUntilIdle()
```

Terminals connect through `PseudoTerminal`. The consumer writes keystrokes, reads output, and renders it:

```swift
let pty = PseudoTerminal()
kernel.spawn("sh", Programs.shell(tty: pty.slave))
loop.runUntilIdle()

pty.writeFromApp(Array("echo hello\n".utf8))
loop.runUntilIdle()
let output = pty.readForApp(max: 65_535)
```

For multiple nodes, the consumer passes frames from one `NetworkInterface.onEgress` callback to another node's `NetworkNode.receive(_:on:)`. The same seam can implement point-to-point links, switches, latency, and packet loss. `Example` provides a standalone macOS SwiftPM consumer example.

## Optional Products

| Product | Purpose |
| --- | --- |
| `SwiftixBridge` | Apple `Network.framework` uplink transport |
| `SwiftixGo` | Go-compatible compiler, bytecode VM, and runtime |
| `SwiftixImage` | Bounded, verifiable rootfs image and restore API |
| `SwiftixPackages` | Native `pkg` command, dependency resolution, and transactional installation |
| `swiftix-go` | macOS/Linux build, test, and image-execution tool |

See the [Go Toolchain Contract](docs/go-toolchain.md) for the supported language and standard-library scope, and the [Package Management Contract](docs/package-manager.md) for package formats, commands, and trust boundaries. The sibling `coreutils` repository owns the basic-command `.pkg`, while `SwiftixDistribution` assembles official rootfs content; the core package does not install distribution files.

## Concurrency Contract

The Swiftix core object graph has no internal locking. It must be constructed and driven by **one serial executor**:

- Create the `Kernel` and `EventLoop` on the same executor.
- Keep spawn, network configuration, ingress frame delivery, PTY interaction, and time advancement on that executor.
- Async syscalls and process bodies resume on `SwiftixExecutor`.
- `EventLoop`, `Kernel`, `NetworkStack`, `ProcessContext`, and `PseudoTerminal` deliberately remain non-Sendable.
- Platform and actor callbacks must first switch back to the executor that owns the object graph.

## Build and Verification

```bash
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift test --no-parallel
swift build -c release -Xswiftc -warnings-as-errors
swift build --package-path Example -Xswiftc -warnings-as-errors
git diff --check
```

Package host tools with `Packaging/build-toolchain.sh`. CI builds and smoke-tests host packages, signs and notarizes tagged macOS artifacts, and retains the results as workflow artifacts; see the [product roadmap](docs/roadmap.md) for the complete release criteria.

## Documentation

| Document | Scope |
| --- | --- |
| [Core Architecture](docs/architecture.md) | Object relationships, boundaries, subsystem status, and non-goals |
| [Go Toolchain](docs/go-toolchain.md) | Language, tools, runtime, and compatibility subset |
| [Package Management](docs/package-manager.md) | Repositories, formats, resolution, transactions, and trust boundary |
| [Performance](docs/performance.md) | Current baseline, unresolved risks, and regression dimensions |
| [Product Roadmap](docs/roadmap.md) | Release gates, version priorities, tradeoffs, and non-goals |
| [Compatibility and Migration](docs/compatibility.md) | API stability, formats, platforms, and the 0.9-to-1.0 upgrade checklist |
| [AGENTS.md](AGENTS.md) | Engineering rules for maintainers and automation agents |

See the [changelog](CHANGELOG.md) for version history and [security policy](SECURITY.md) for vulnerability reporting. Swiftix is released under the [MIT License](LICENSE).
