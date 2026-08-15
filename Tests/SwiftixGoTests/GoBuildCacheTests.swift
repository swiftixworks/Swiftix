/// Go build cache tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go build cache")
struct GoBuildCacheTests: GoTestHarness {

    @Test func buildCacheDigestUsesStableSHA256() {
        var empty = StableSHA256()
        #expect(
            empty.finalizeHex()
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        var abc = StableSHA256()
        abc.update(Array("abc".utf8))
        #expect(
            abc.finalizeHex()
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        var twoBlocks = StableSHA256()
        twoBlocks.update(
            Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
        #expect(
            twoBlocks.finalizeHex()
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func buildCacheRoundTripsAndRejectsCorruptEntries() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc main() {}\n")
        let executable = try GoCompiler.compile(sources: [source])
        let key = GoBuildCache.key(
            toolVersion: GoToolchain.toolVersion,
            languageVersion: GoToolchain.languageVersion,
            sources: [source],
            moduleFile: nil)
        let root = "/cache"
        let path = GoBuildCache.entryPath(root: root, key: key)
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var loaded: GoExecutable?
        var rejectedCorruption = false
        var errorDescription: String?

        kernel.spawn("cache-test") { context in
            do {
                try GoBuildCache.store(
                    context,
                    root: root,
                    key: key,
                    executable: executable)
                loaded = GoBuildCache.load(context, root: root, key: key)
                Self.writeBytes(context, path: path, contents: Array("corrupt".utf8))
                rejectedCorruption =
                    GoBuildCache.load(context, root: root, key: key) == nil
                    && context.stat(path) == nil
            } catch {
                errorDescription = String(describing: error)
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        #expect(errorDescription == nil)
        #expect(loaded == executable)
        #expect(rejectedCorruption)
    }

    @Test func buildCacheCleanDoesNotFollowNamespaceSymlinks() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var preservedVictim = false
        var removedNamespaceLink = false
        var errorDescription: String?

        kernel.spawn("cache-clean-symlink-test") { context in
            _ = context.mkdir("/cache-root")
            _ = context.mkdir("/victim")
            Self.write(context, path: "/victim/keep.txt", contents: "keep\n")
            _ = context.symlink("/victim", at: "/cache-root/swiftix-v1")
            do {
                try GoBuildCache.clear(context, root: "/cache-root")
                preservedVictim = context.stat("/victim/keep.txt") != nil
                removedNamespaceLink = context.lstat("/cache-root/swiftix-v1") == nil
            } catch {
                errorDescription = String(describing: error)
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        #expect(errorDescription == nil)
        #expect(preservedVictim)
        #expect(removedNamespaceLink)
    }

    @Test func goBuildCacheInvalidatesWithSourceAndCleanPreservesForeignFiles() {
        let output = runShell(
            [
                "cd /cache-demo",
                "go build -o first .",
                "./first",
                "find /root/.cache/go-build/swiftix-v1",
                "cp /second-source main.go",
                "go build -o second .",
                "./second",
                "find /root/.cache/go-build/swiftix-v1",
                "go clean -cache",
                "echo clean=$?",
                "cat /root/.cache/go-build/keep.txt",
                "stat /root/.cache/go-build/swiftix-v1",
                "echo cache=$?",
            ],
            seed: { context in
                _ = context.mkdir("/cache-demo")
                _ = context.mkdir("/root/.cache/go-build")
                Self.write(
                    context,
                    path: "/cache-demo/go.mod",
                    contents: "module example/cache-demo\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/cache-demo/main.go",
                    contents: """
                        package main
                        import "fmt"
                        func main() { fmt.Println("cache first") }
                        """)
                Self.write(
                    context,
                    path: "/second-source",
                    contents: """
                        package main
                        import "fmt"
                        func main() { fmt.Println("cache second") }
                        """)
                Self.write(
                    context,
                    path: "/root/.cache/go-build/keep.txt",
                    contents: "foreign cache data\n")
            })

        let resultLines = shellResultLines(output)
        let cacheEntries = resultLines.filter { $0.hasSuffix(".sxi") }
        #expect(output.contains("cache first"))
        #expect(output.contains("cache second"))
        #expect(cacheEntries.count == 3)
        #expect(Set(cacheEntries).count == 2)
        #expect(resultLines.contains("clean=0"))
        #expect(resultLines.contains("foreign cache data"))
        #expect(resultLines.contains("cache=1"))
    }

    @Test func goBuildRecoversFromCorruptCacheAndCanDisableCaching() {
        let module = "module example/cache-recovery\n\ngo 1.24\n"
        let source = """
            package main
            import "fmt"
            func main() { fmt.Println("cache recovered") }
            """
        let key = GoBuildCache.key(
            toolVersion: GoToolchain.toolVersion,
            languageVersion: GoToolchain.languageVersion,
            sources: [GoSourceFile(path: "main.go", text: source)],
            moduleFile: Array(module.utf8))
        let cachePath = GoBuildCache.entryPath(
            root: "/root/.cache/go-build",
            key: key)
        let output = runShell(
            [
                "cd /cache-recovery",
                "go build -o initial .",
                "echo corrupt > \(cachePath)",
                "go build -o recovered .",
                "./recovered",
                "GOCACHE=off go build -o uncached .",
                "./uncached",
                "GOCACHE=relative go build -o invalid .",
                "echo relative=$?",
            ],
            seed: { context in
                _ = context.mkdir("/cache-recovery")
                Self.write(context, path: "/cache-recovery/go.mod", contents: module)
                Self.write(context, path: "/cache-recovery/main.go", contents: source)
            })

        #expect(output.split(separator: "\n").filter { $0 == "cache recovered" }.count == 2)
        #expect(output.contains("GOCACHE must be an absolute path or 'off'"))
        #expect(output.contains("relative=1"))
    }
}
