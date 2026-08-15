/// Host-services boundary shared by the in-guest Go commands and host-side
/// development tools.
///
/// The compiler and command driver only depend on this surface. Swiftix guests
/// satisfy it with `ProcessContext`; macOS and Linux tools provide a Foundation-
/// backed implementation in the `SwiftixGoHost` integration target.

import Swiftix
import SwiftixGoRuntime

public protocol GoToolContext: AnyObject {
    var currentDirectory: String { get }
    var hostOperatingSystem: String { get }
    var hostArchitecture: String { get }

    func getenv(_ name: String) -> String?
    func stat(_ path: String) -> FileStat?
    func lstat(_ path: String) -> FileStat?
    func listDirectory(_ path: String) -> [String]?
    func mkdir(_ path: String) -> Bool
    func remove(_ path: String) -> Bool
    func chmod(_ path: String, mode: FileMode) -> Bool

    func openFile(
        _ path: String,
        flags: OpenFlags,
        access: FileAccessMode
    ) throws -> Int
    func openFile(_ path: String, access: FileAccessMode) throws -> Int
    func readFile(_ descriptor: Int, max: Int) throws -> [UInt8]
    func writeFile(_ descriptor: Int, _ bytes: [UInt8]) throws -> Int
    func closeFile(_ descriptor: Int) throws

    @discardableResult
    func write(_ descriptor: Int, _ bytes: [UInt8]) -> Int
    func print(_ string: String)
    func exit(_ code: Int32)

    func readStandardInput(upTo maximumBytes: Int) async throws -> [UInt8]
    func runGoExecutable(
        _ executable: GoExecutable,
        arguments: [String],
        write: @escaping (String) throws -> Void
    ) throws -> Int32
}

extension ProcessContext: GoToolContext {
    public var hostOperatingSystem: String { GoExecutableImage.targetOS }
    public var hostArchitecture: String { GoExecutableImage.targetArchitecture }

    public func openFile(_ path: String, access: FileAccessMode) throws -> Int {
        try openFile(path, create: false, truncate: false, access: access)
    }

    public func readStandardInput(upTo maximumBytes: Int) async throws -> [UInt8] {
        try await read(0, upTo: maximumBytes)
    }

    public func runGoExecutable(
        _ executable: GoExecutable,
        arguments: [String],
        write: @escaping (String) throws -> Void
    ) throws -> Int32 {
        try GoVirtualMachine().run(
            executable,
            eventLoop: eventLoop,
            processContext: self,
            arguments: arguments,
            write: write)
    }
}
