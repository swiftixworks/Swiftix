import Swiftix
import SwiftixBridge
import SwiftixGo
import SwiftixGoRuntime
import SwiftixGoTool
import SwiftixImage
import SwiftixPackages

let loop = EventLoop()
let kernel = Kernel(loop: loop, runtimeMemoryLimitBytes: 1_048_576)
let terminal = PseudoTerminal()
let commands = CommandRegistry.builtins

SwiftixPackages.register(in: commands)
GoToolchain.register(in: commands)
kernel.spawn("sh", Programs.shell(tty: terminal.slave, commands: commands))
loop.runUntilIdle()

let versionCore = Swiftix.version.split(separator: "-", maxSplits: 1)[0]
precondition(versionCore.split(separator: ".").count == 3)
let resources = kernel.snapshotResources()
precondition(resources.runtimeMemoryLimitBytes == 1_048_576)
precondition(resources.runtimeMemoryBytes == 0)
precondition(resources.vfsFileBytes >= 0)
precondition(Swiftix.teachingProcfsSchemaVersion == 1)
precondition(SwiftixRootFilesystemImageCodec.formatVersion == 1)
precondition(SwiftixPackages.formatVersion == 2)
precondition(GoExecutableImage.formatVersion == 10)
precondition(GoExecutableImage.abiVersion == 10)

// Resolve one public type from every library product. This package deliberately
// compiles without @testable imports so CI catches accidental product-boundary
// regressions.
_ = NetworkUplinkTransport.self
_ = GoCompiler.self
