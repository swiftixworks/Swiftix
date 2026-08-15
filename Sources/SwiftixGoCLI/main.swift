/// macOS/Linux command-line entry point for the Swiftix Go toolchain.

import Foundation
import Swiftix
import SwiftixGoHost
import SwiftixGoTool

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@main
struct SwiftixGoCLI {
    static func main() async {
        let context = HostGoToolContext.live()
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--version" {
            print("swiftix-toolchain \(Swiftix.version)")
        } else if arguments.dropFirst().first == "gofmt" {
            await GoToolchain.runGofmt(
                context,
                arguments: Array(arguments.dropFirst(2)))
        } else if arguments.dropFirst().first == "exec" {
            runImage(arguments: Array(arguments.dropFirst(2)))
        } else {
            GoToolchain.run(
                context,
                arguments: ["go"] + Array(arguments.dropFirst()))
        }
        exit(context.exitCode)
    }

    private static func runImage(arguments: [String]) {
        var root: String?
        var index = 0
        if arguments.first == "--root" {
            guard arguments.count >= 3 else {
                imageUsage()
                exit(2)
            }
            root = arguments[1]
            index = 2
        }
        guard index < arguments.count else {
            imageUsage()
            exit(2)
        }

        let image = arguments[index]
        index += 1
        let guestArguments: [String]
        if index < arguments.count, arguments[index] == "--" {
            guestArguments = Array(arguments.dropFirst(index + 1))
        } else {
            guestArguments = Array(arguments.dropFirst(index))
        }

        let currentDirectory = root ?? FileManager.default.currentDirectoryPath
        let context = HostGoToolContext.live(currentDirectory: currentDirectory)
        do {
            exit(try context.runImage(at: image, arguments: guestArguments))
        } catch {
            FileHandle.standardError.write(
                Data("swiftix-go exec: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func imageUsage() {
        FileHandle.standardError.write(
            Data("usage: swiftix-go exec [--root DIRECTORY] IMAGE [--] [arguments...]\n".utf8))
    }
}
