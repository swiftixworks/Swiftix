import Swiftix
import SwiftixImage
import Testing

@Suite("Swiftix distribution root filesystem images")
struct RootFilesystemImageTests {
    @Test("encoding is deterministic and restores the exact filesystem")
    func deterministicRoundTripAndRestore() throws {
        let snapshot = makeFilesystem()
        let image = SwiftixRootFilesystemImage(
            distribution: metadata,
            filesystem: snapshot)

        let first = try SwiftixRootFilesystemImageCodec.encode(image)
        let second = try SwiftixRootFilesystemImageCodec.encode(image)
        #expect(first == second)
        #expect(SwiftixRootFilesystemImageCodec.recognizes(first))

        let decoded = try SwiftixRootFilesystemImageCodec.decode(first)
        #expect(decoded == image)
        #expect(decoded.distribution.isCompatible(withSwiftixVersion: Swiftix.version))
        #expect(!decoded.distribution.isCompatible(withSwiftixVersion: "0.0.0"))
        #expect(try SwiftixRootFilesystemImageCodec.digest(of: first).count == 64)

        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        #expect(kernel.restoreRootFilesystemImage(decoded))
        #expect(kernel.snapshotFileSystem() == snapshot)
    }

    @Test("tampering and truncation are rejected before restore")
    func integrityChecks() throws {
        let bytes = try SwiftixRootFilesystemImageCodec.encode(
            .init(
                distribution: metadata,
                filesystem: makeFilesystem()))

        var tampered = bytes
        tampered[tampered.count / 2] ^= 0x01
        #expect(throws: SwiftixRootFilesystemImageError.invalidDigest) {
            try SwiftixRootFilesystemImageCodec.decode(tampered)
        }
        #expect(throws: SwiftixRootFilesystemImageError.truncated) {
            try SwiftixRootFilesystemImageCodec.decode(Array(bytes.prefix(8)))
        }
    }

    @Test("metadata target and filesystem graph are validated")
    func targetAndFilesystemValidation() throws {
        let wrongTarget = SwiftixDistributionMetadata(
            identifier: "org.swiftix.minimal",
            name: "Swiftix Minimal",
            version: "1.0.0",
            minimumSwiftixVersion: "0.0.1",
            operatingSystem: "linux",
            architecture: "amd64")
        #expect(
            throws: SwiftixRootFilesystemImageError.unsupportedTarget(
                operatingSystem: "linux", architecture: "amd64")
        ) {
            try SwiftixRootFilesystemImageCodec.encode(
                .init(
                    distribution: wrongTarget,
                    filesystem: makeFilesystem()))
        }

        let legacy = FilesystemSnapshot(root: .directory(children: [:]))
        #expect(throws: SwiftixRootFilesystemImageError.invalidFilesystem) {
            try SwiftixRootFilesystemImageCodec.encode(
                .init(
                    distribution: metadata,
                    filesystem: legacy))
        }

        let future = SwiftixDistributionMetadata(
            identifier: "org.swiftix.future",
            name: "Swiftix Future",
            version: "1.0.0",
            minimumSwiftixVersion: "999.0.0")
        let kernel = Kernel(loop: EventLoop())
        #expect(
            !kernel.restoreRootFilesystemImage(
                .init(
                    distribution: future,
                    filesystem: makeFilesystem())))
    }

    @Test("minimum core versions follow Semantic Versioning precedence")
    func semanticVersionCompatibility() {
        func requires(_ version: String) -> SwiftixDistributionMetadata {
            SwiftixDistributionMetadata(
                identifier: "org.swiftix.test",
                name: "Swiftix Test",
                version: "1.0.0",
                minimumSwiftixVersion: version)
        }

        let candidate = requires("1.0.0-rc.1")
        #expect(candidate.isCompatible(withSwiftixVersion: "1.0.0-rc.1"))
        #expect(candidate.isCompatible(withSwiftixVersion: "1.0.0-rc.2"))
        #expect(candidate.isCompatible(withSwiftixVersion: "1.0.0"))
        #expect(candidate.isCompatible(withSwiftixVersion: "1.0.0+build.7"))
        #expect(!candidate.isCompatible(withSwiftixVersion: "1.0.0-beta.9"))
        #expect(!requires("1.0.0").isCompatible(withSwiftixVersion: "1.0.0-rc.9"))
        #expect(
            requires("1.0.0-999999999999999999999999")
                .isCompatible(withSwiftixVersion: "1.0.0-1000000000000000000000000"))
        #expect(
            requires("184467440737095516160.0.0")
                .isCompatible(withSwiftixVersion: "184467440737095516160.0.0"))

        for invalid in ["1.0", "01.0.0", "1.0.0-rc.01", "1.0.0+", "1.0.0-"] {
            #expect(!requires(invalid).isCompatible(withSwiftixVersion: "1.0.0"))
        }
    }

    private var metadata: SwiftixDistributionMetadata {
        SwiftixDistributionMetadata(
            identifier: "org.swiftix.minimal",
            name: "Swiftix Minimal",
            version: "1.0.0",
            minimumSwiftixVersion: Swiftix.version)
    }

    private func makeFilesystem() -> FilesystemSnapshot {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed-image") { context in
            _ = context.mkdir("/usr/bin")
            let descriptor = context.open("/usr/bin/hello", create: true)!
            context.write(descriptor, Array("hello\n".utf8))
            context.close(descriptor)
            _ = context.chmod(
                "/usr/bin/hello",
                mode: [
                    .ownerRead, .ownerWrite, .ownerExecute,
                    .groupRead, .groupExecute,
                    .otherRead, .otherExecute,
                ])
            _ = context.symlink("/usr/bin", at: "/bin")
            context.exit(0)
        }
        loop.runUntilIdle()
        return kernel.snapshotFileSystem()
    }
}
