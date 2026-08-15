/// Foundation-backed host implementation of the Swiftix Go tool boundary.
///
/// This integration target is the only place where compiler tooling touches the
/// macOS/Linux filesystem. Generated programs still target Swiftix/svm64 and are
/// executed inside a real `Kernel` + `ProcessContext` harness.

import Foundation
import Swiftix
import SwiftixGoRuntime
import SwiftixGoTool

public final class HostGoToolContext: GoToolContext {
    public typealias InputReader = (_ maximumBytes: Int) throws -> [UInt8]
    public typealias OutputWriter = (_ bytes: [UInt8]) -> Int

    public let currentDirectory: String
    public let hostOperatingSystem: String
    public let hostArchitecture: String
    public private(set) var exitCode: Int32 = 0

    private struct Descriptor {
        let handle: FileHandle
        let access: FileAccessMode
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let inputReader: InputReader
    private let standardOutput: OutputWriter
    private let standardError: OutputWriter
    private var descriptors: [Int: Descriptor] = [:]
    private var nextDescriptor = 3

    public init(
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inputReader: @escaping InputReader,
        standardOutput: @escaping OutputWriter,
        standardError: @escaping OutputWriter
    ) {
        self.fileManager = FileManager.default
        self.currentDirectory = URL(fileURLWithPath: currentDirectory)
            .resolvingSymlinksInPath().standardizedFileURL.path
        self.environment = environment
        self.inputReader = inputReader
        self.standardOutput = standardOutput
        self.standardError = standardError
#if os(macOS)
        self.hostOperatingSystem = "darwin"
#elseif os(Linux)
        self.hostOperatingSystem = "linux"
#else
        self.hostOperatingSystem = "unknown"
#endif
#if arch(arm64)
        self.hostArchitecture = "arm64"
#elseif arch(x86_64)
        self.hostArchitecture = "amd64"
#else
        self.hostArchitecture = "unknown"
#endif
    }

    public static func live(
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> HostGoToolContext {
        HostGoToolContext(
            currentDirectory: currentDirectory,
            inputReader: { maximumBytes in
                let data = try FileHandle.standardInput.read(upToCount: maximumBytes) ?? Data()
                return Array(data)
            },
            standardOutput: { bytes in
                do {
                    try FileHandle.standardOutput.write(contentsOf: Data(bytes))
                    return bytes.count
                } catch {
                    return 0
                }
            },
            standardError: { bytes in
                do {
                    try FileHandle.standardError.write(contentsOf: Data(bytes))
                    return bytes.count
                } catch {
                    return 0
                }
            })
    }

    public func getenv(_ name: String) -> String? {
        environment[name]
    }

    public func stat(_ path: String) -> FileStat? {
        fileStat(at: resolved(path), followFinalSymlink: true)
    }

    public func lstat(_ path: String) -> FileStat? {
        fileStat(at: resolved(path), followFinalSymlink: false)
    }

    public func listDirectory(_ path: String) -> [String]? {
        let directory = resolved(path)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        return names.sorted().map { name in
            let child = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            return fileStat(at: child, followFinalSymlink: false)?.isDirectory == true
                ? name + "/"
                : name
        }
    }

    @discardableResult
    public func mkdir(_ path: String) -> Bool {
        let path = resolved(path)
        if let existing = fileStat(at: path, followFinalSymlink: true) {
            return existing.isDirectory
        }
        do {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func remove(_ path: String) -> Bool {
        let path = resolved(path)
        guard let status = fileStat(at: path, followFinalSymlink: false) else {
            return false
        }
        if status.isDirectory,
            let entries = try? fileManager.contentsOfDirectory(atPath: path),
            !entries.isEmpty
        {
            return false
        }
        do {
            try fileManager.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func chmod(_ path: String, mode: FileMode) -> Bool {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: mode.rawValue)],
                ofItemAtPath: resolved(path))
            return true
        } catch {
            return false
        }
    }

    public func openFile(
        _ path: String,
        flags: OpenFlags,
        access: FileAccessMode
    ) throws -> Int {
        let path = resolved(path)
        let exists = fileManager.fileExists(atPath: path)
        if flags.contains(.exclusive), flags.contains(.create), exists {
            throw HostGoToolError.fileExists(path)
        }
        if !exists {
            guard flags.contains(.create),
                fileManager.createFile(atPath: path, contents: Data())
            else {
                throw HostGoToolError.noSuchFile(path)
            }
        }

        let handle: FileHandle
        switch access {
        case .readOnly:
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        case .writeOnly:
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        case .readWrite:
            handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        case .none:
            throw HostGoToolError.invalidAccess(path)
        }
        if flags.contains(.truncate) {
            try handle.truncate(atOffset: 0)
        }
        if flags.contains(.append) {
            _ = try handle.seekToEnd()
        }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        descriptors[descriptor] = Descriptor(handle: handle, access: access)
        return descriptor
    }

    public func openFile(_ path: String, access: FileAccessMode) throws -> Int {
        try openFile(path, flags: [], access: access)
    }

    public func readFile(_ descriptor: Int, max: Int) throws -> [UInt8] {
        guard let entry = descriptors[descriptor], entry.access.canRead else {
            throw HostGoToolError.badDescriptor(descriptor)
        }
        return Array(try entry.handle.read(upToCount: max) ?? Data())
    }

    @discardableResult
    public func writeFile(_ descriptor: Int, _ bytes: [UInt8]) throws -> Int {
        guard let entry = descriptors[descriptor], entry.access.canWrite else {
            throw HostGoToolError.badDescriptor(descriptor)
        }
        try entry.handle.write(contentsOf: Data(bytes))
        return bytes.count
    }

    public func closeFile(_ descriptor: Int) throws {
        guard let entry = descriptors.removeValue(forKey: descriptor) else {
            throw HostGoToolError.badDescriptor(descriptor)
        }
        try entry.handle.close()
    }

    @discardableResult
    public func write(_ descriptor: Int, _ bytes: [UInt8]) -> Int {
        switch descriptor {
        case 1:
            return standardOutput(bytes)
        case 2:
            return standardError(bytes)
        default:
            return (try? writeFile(descriptor, bytes)) ?? 0
        }
    }

    public func print(_ string: String) {
        _ = standardOutput(Array(string.utf8))
    }

    public func exit(_ code: Int32) {
        exitCode = code
    }

    public func readStandardInput(upTo maximumBytes: Int) async throws -> [UInt8] {
        try inputReader(maximumBytes)
    }

    public func runGoExecutable(
        _ executable: GoExecutable,
        arguments: [String],
        write: @escaping (String) throws -> Void
    ) throws -> Int32 {
        let workspace = try snapshotWorkspace()
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var result: Result<Int32, Error>?
        kernel.spawn(arguments.first ?? "swiftix-go", args: arguments) { context in
            self.installRuntimeStandardIO(on: context)
            context.mkdir("/workspace")
            do {
                try self.install(workspace, on: context)
            } catch {
                result = .failure(error)
                context.exit(1)
                return
            }
            _ = context.chdir("/workspace")
            for (name, value) in self.environment {
                context.setenv(name, value)
            }
            do {
                let code = try GoVirtualMachine().run(
                    executable,
                    eventLoop: loop,
                    processContext: context,
                    arguments: arguments,
                    write: write)
                result = .success(code)
                context.exit(code)
            } catch {
                result = .failure(error)
                context.exit(1)
            }
        }
        loop.runUntilIdle()
        guard let result else { throw HostGoToolError.runtimeDidNotStart }
        return try result.get()
    }

    public func runImage(
        at path: String,
        arguments: [String] = []
    ) throws -> Int32 {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: resolved(path)))
        let executable = try GoExecutableImage.decode(Array(bytes))
        let programName = URL(fileURLWithPath: path).lastPathComponent
        return try runGoExecutable(
            executable,
            arguments: [programName] + arguments
        ) { text in
            _ = self.write(1, Array(text.utf8))
        }
    }

    private func resolved(_ path: String) -> String {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: currentDirectory).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }

    private func fileStat(at path: String, followFinalSymlink: Bool) -> FileStat? {
        if !followFinalSymlink,
            let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.isSymbolicLinkKey]),
            values.isSymbolicLink == true
        {
            return FileStat(type: .symlink, size: 0, mode: .symlinkDefault)
        }
        let inspectedPath = followFinalSymlink
            ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            : path
        guard let attributes = try? fileManager.attributesOfItem(atPath: inspectedPath),
            let attributeType = attributes[.type] as? FileAttributeType
        else {
            return nil
        }
        let type: FileType
        switch attributeType {
        case .typeDirectory: type = .directory
        case .typeRegular: type = .regular
        case .typeSymbolicLink: type = .symlink
        default: type = .fifo
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let rawMode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            ?? FileMode.regularDefault.rawValue
        return FileStat(type: type, size: size, mode: FileMode(rawValue: rawMode))
    }

    private struct WorkspaceSnapshot {
        let directories: [String]
        let files: [(path: String, bytes: [UInt8])]
    }

    private func snapshotWorkspace() throws -> WorkspaceSnapshot {
        let root = URL(fileURLWithPath: currentDirectory).resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [])
        else {
            throw HostGoToolError.cannotReadWorkspace(currentDirectory)
        }

        let ignoredDirectories: Set<String> = [".git", ".build", ".swiftpm"]
        var directories: [String] = []
        var files: [(path: String, bytes: [UInt8])] = []
        var totalBytes = 0
        while let url = enumerator.nextObject() as? URL {
            let lexicalValues = try url.resourceValues(forKeys: Set(keys))
            if lexicalValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let canonicalURL = url.resolvingSymlinksInPath()
            let components = canonicalURL.pathComponents
            guard components.starts(with: rootComponents) else {
                continue
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            if lexicalValues.isDirectory == true {
                if ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                } else {
                    directories.append(relative)
                }
                continue
            }
            guard lexicalValues.isRegularFile == true else {
                continue
            }
            let fileSize = lexicalValues.fileSize ?? 0
            guard fileSize <= 16 * 1_024 * 1_024,
                totalBytes <= 64 * 1_024 * 1_024 - fileSize,
                files.count < 10_000
            else {
                throw HostGoToolError.workspaceLimitExceeded(relative)
            }
            let bytes = Array(try Data(contentsOf: url))
            totalBytes += bytes.count
            files.append((relative, bytes))
        }
        directories.sort {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0 < $1 : leftDepth < rightDepth
        }
        files.sort { $0.path < $1.path }
        return WorkspaceSnapshot(directories: directories, files: files)
    }

    private func install(
        _ workspace: WorkspaceSnapshot,
        on context: ProcessContext
    ) throws {
        for directory in workspace.directories {
            guard context.mkdir("/workspace/" + directory) else {
                throw HostGoToolError.cannotStageWorkspace(directory)
            }
        }
        for file in workspace.files {
            let path = "/workspace/" + file.path
            let descriptor = try context.openFile(
                path,
                flags: [.create, .truncate],
                access: .writeOnly)
            defer { try? context.closeFile(descriptor) }
            guard try context.writeFile(descriptor, file.bytes) == file.bytes.count else {
                throw HostGoToolError.cannotStageWorkspace(file.path)
            }
        }
    }

    private func installRuntimeStandardIO(on context: ProcessContext) {
        install(HostRuntimeInput(inputReader: inputReader), as: 0, on: context)
        install(HostRuntimeOutput(outputWriter: standardOutput), as: 1, on: context)
        install(HostRuntimeOutput(outputWriter: standardError), as: 2, on: context)
    }

    private func install(_ object: FileObject, as target: Int, on context: ProcessContext) {
        let descriptor = context.install(object)
        guard descriptor != target else { return }
        _ = context.dup2(descriptor, onto: target)
        try? context.closeFile(descriptor)
    }
}

private final class HostRuntimeInput: FileObject {
    private let inputReader: HostGoToolContext.InputReader

    init(inputReader: @escaping HostGoToolContext.InputReader) {
        self.inputReader = inputReader
    }

    var readiness: IOReadiness { [.readable] }

    func read(max: Int) -> [UInt8] {
        (try? inputReader(max)) ?? []
    }

    func write(_ bytes: [UInt8]) -> Int { 0 }
}

private final class HostRuntimeOutput: FileObject {
    private let outputWriter: HostGoToolContext.OutputWriter

    init(outputWriter: @escaping HostGoToolContext.OutputWriter) {
        self.outputWriter = outputWriter
    }

    var readiness: IOReadiness { [.writable] }

    func read(max: Int) -> [UInt8] { [] }

    func write(_ bytes: [UInt8]) -> Int {
        outputWriter(bytes)
    }
}

public enum HostGoToolError: Error, CustomStringConvertible {
    case noSuchFile(String)
    case fileExists(String)
    case invalidAccess(String)
    case badDescriptor(Int)
    case runtimeDidNotStart
    case cannotReadWorkspace(String)
    case cannotStageWorkspace(String)
    case workspaceLimitExceeded(String)

    public var description: String {
        switch self {
        case .noSuchFile(let path): return "no such file or directory: \(path)"
        case .fileExists(let path): return "file exists: \(path)"
        case .invalidAccess(let path): return "invalid file access: \(path)"
        case .badDescriptor(let descriptor): return "bad file descriptor: \(descriptor)"
        case .runtimeDidNotStart: return "Swiftix Go runtime did not start"
        case .cannotReadWorkspace(let path): return "cannot read workspace: \(path)"
        case .cannotStageWorkspace(let path): return "cannot stage workspace path: \(path)"
        case .workspaceLimitExceeded(let path):
            return "workspace staging limit exceeded at: \(path)"
        }
    }
}
