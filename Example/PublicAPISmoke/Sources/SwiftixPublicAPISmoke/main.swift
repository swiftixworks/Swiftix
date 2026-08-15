import Swiftix
import SwiftixBridge
import SwiftixGo
import SwiftixGoRuntime
import SwiftixGoTool
import SwiftixImage
import SwiftixPackages

let loop = EventLoop()
let kernel = Kernel(loop: loop)
let terminal = PseudoTerminal()
let commands = CommandRegistry.builtins

SwiftixPackages.register(in: commands)
GoToolchain.register(in: commands)
kernel.spawn("sh", Programs.shell(tty: terminal.slave, commands: commands))
loop.runUntilIdle()

precondition(Swiftix.version == "0.10.0")
precondition(SwiftixRootFilesystemImageCodec.formatVersion == 1)
precondition(SwiftixPackages.formatVersion == 2)
precondition(GoExecutableImage.formatVersion == 10)
precondition(GoExecutableImage.abiVersion == 10)

// Resolve one public type from every library product. This package deliberately
// compiles without @testable imports so CI catches accidental product-boundary
// regressions.
_ = NetworkUplinkTransport.self
_ = GoCompiler.self
