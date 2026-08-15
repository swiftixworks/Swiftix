// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftixPublicAPISmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "SwiftixPublicAPISmoke",
            dependencies: [
                .product(name: "Swiftix", package: "Swiftix"),
                .product(name: "SwiftixBridge", package: "Swiftix"),
                .product(name: "SwiftixGo", package: "Swiftix"),
                .product(name: "SwiftixImage", package: "Swiftix"),
                .product(name: "SwiftixPackages", package: "Swiftix"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
