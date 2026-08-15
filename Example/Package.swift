// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftixDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "SwiftixDemo",
            dependencies: [
                .product(name: "Swiftix", package: "Swiftix"),
                .product(name: "SwiftixGo", package: "Swiftix"),
            ],
            path: "SwiftixDemo",
            sources: ["main.swift"]
        )
    ],
    swiftLanguageModes: [.v6]
)
