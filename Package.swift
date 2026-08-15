// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Swiftix",
    // Custom `SerialExecutor` / `ExecutorJob` APIs (R16.4) require these OS
    // floors on Apple platforms; Linux has no availability gating, so the
    // concurrency contract stays identical across platforms (R16.5).
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Swiftix",
            targets: ["Swiftix"]
        ),
        // Optional platform bridge for SLIRP-style real-network access. The
        // core exposes only transport protocols; this target supplies the
        // Network.framework-backed implementation on Apple platforms.
        .library(
            name: "SwiftixBridge",
            targets: ["SwiftixBridge"]
        ),
        // Distribution package management (`pkg`): repository
        // protocol, package format, dependency resolution and a transactional
        // installer. Depends only on the core's public syscall surface.
        .library(
            name: "SwiftixPackages",
            targets: ["SwiftixPackages"]
        ),
        // Versioned distribution root-filesystem image format. Images contain
        // policy/content, while the core only supplies bounded decoding and
        // atomic VFS restoration.
        .library(
            name: "SwiftixImage",
            targets: ["SwiftixImage"]
        ),
        // First-party Go-compatible language and toolchain for Swiftix nodes.
        // The compiler/runtime stay outside the core and use only public syscalls.
        .library(
            name: "SwiftixGo",
            targets: [
                "SwiftixGo",
                "SwiftixGoRuntime",
                "SwiftixGoTool",
            ]
        ),
        // Host-side macOS/Linux development tool. It always emits Swiftix
        // svm64 images; the host platform is never confused with the target.
        .executable(
            name: "swiftix-go",
            targets: ["SwiftixGoCLI"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Swiftix",
            linkerSettings: [
                .linkedLibrary("m", .when(platforms: [.linux]))
            ]
        ),
        .target(
            name: "SwiftixBridge",
            dependencies: ["Swiftix"],
            linkerSettings: [
                .linkedFramework(
                    "Network",
                    .when(platforms: [.macOS, .iOS])
                )
            ]
        ),
        .target(
            name: "SwiftixGo",
            dependencies: ["SwiftixGoRuntime"]
        ),
        .target(
            name: "SwiftixGoRuntime",
            dependencies: ["Swiftix"]
        ),
        .target(
            name: "SwiftixGoTool",
            dependencies: [
                "Swiftix",
                "SwiftixGo",
                "SwiftixGoRuntime",
            ]
        ),
        .target(
            name: "SwiftixGoHost",
            dependencies: [
                "Swiftix",
                "SwiftixGoRuntime",
                "SwiftixGoTool",
            ]
        ),
        // Foundation-free SHA-256 shared by independently layered artifact
        // formats. It is intentionally not a public product.
        .target(
            name: "SwiftixDigest"
        ),
        .executableTarget(
            name: "SwiftixGoCLI",
            dependencies: ["Swiftix", "SwiftixGoHost"]
        ),
        // Package manager; pure Swift and core-only (no Foundation, no TLS).
        .target(
            name: "SwiftixPackages",
            dependencies: ["Swiftix", "SwiftixDigest"]
        ),
        .target(
            name: "SwiftixImage",
            dependencies: ["Swiftix", "SwiftixDigest"]
        ),
        .testTarget(
            name: "SwiftixTests",
            dependencies: ["Swiftix"]
        ),
        .testTarget(
            name: "SwiftixPackagesTests",
            dependencies: [
                "Swiftix",
                "SwiftixPackages",
            ]
        ),
        .testTarget(
            name: "SwiftixImageTests",
            dependencies: ["Swiftix", "SwiftixImage"]
        ),
        .testTarget(
            name: "SwiftixGoTests",
            dependencies: [
                "Swiftix",
                "SwiftixGo",
                "SwiftixGoRuntime",
                "SwiftixGoTool",
            ]
        ),
        .testTarget(
            name: "SwiftixGoHostTests",
            dependencies: [
                "SwiftixGo",
                "SwiftixGoHost",
                "SwiftixGoRuntime",
                "SwiftixGoTool",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
