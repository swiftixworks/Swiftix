/// Content-addressed build cache for Swiftix Go executable images.

import Swiftix
import SwiftixGo
import SwiftixGoRuntime

enum GoBuildCache {
    static let namespace = "swiftix-v1"

    static func key(
        toolVersion: String,
        languageVersion: String,
        sources: [GoSourceFile],
        moduleFile: [UInt8]?
    ) -> String {
        var digest = StableSHA256()
        digest.updateField(Array("swiftix-go-build-cache-v1".utf8))
        digest.updateField(Array(toolVersion.utf8))
        digest.updateField(Array(languageVersion.utf8))
        digest.updateField(Array(GoExecutableImage.targetOS.utf8))
        digest.updateField(Array(GoExecutableImage.targetArchitecture.utf8))
        digest.updateInteger(UInt64(GoExecutableImage.formatVersion))
        digest.updateInteger(UInt64(GoExecutableImage.abiVersion))
        if let moduleFile {
            digest.updateInteger(1)
            digest.updateField(moduleFile)
        } else {
            digest.updateInteger(0)
        }
        digest.updateInteger(UInt64(sources.count))
        for source in sources {
            digest.updateField(Array(source.path.utf8))
            digest.updateField(Array(source.text.utf8))
        }
        return digest.finalizeHex()
    }

    static func entryPath(root: String, key: String) -> String {
        let namespacePath = childPath(root, namespace)
        let shard = String(key.prefix(2))
        return childPath(childPath(namespacePath, shard), key + ".sxi")
    }

    static func load(
        _ context: any GoToolContext,
        root: String,
        key: String
    ) -> GoExecutable? {
        let path = entryPath(root: root, key: key)
        guard let status = context.lstat(path) else { return nil }
        guard status.type == .regular, status.size <= GoExecutableImage.maximumImageSize else {
            _ = context.remove(path)
            return nil
        }
        do {
            let descriptor = try context.openFile(path, access: .readOnly)
            defer { try? context.closeFile(descriptor) }
            let bytes = try context.readFile(
                descriptor,
                max: GoExecutableImage.maximumImageSize + 1)
            guard bytes.count <= GoExecutableImage.maximumImageSize else {
                _ = context.remove(path)
                return nil
            }
            return try GoExecutableImage.decode(bytes)
        } catch {
            _ = context.remove(path)
            return nil
        }
    }

    static func store(
        _ context: any GoToolContext,
        root: String,
        key: String,
        executable: GoExecutable
    ) throws {
        let path = entryPath(root: root, key: key)
        let namespacePath = childPath(root, namespace)
        let directory = parentPath(path)
        if let status = context.lstat(namespacePath), !status.isDirectory {
            throw GoBuildCacheError.invalidEntry(namespacePath)
        }
        guard context.mkdir(directory) else {
            throw GoBuildCacheError.cannotCreateDirectory(directory)
        }
        guard context.lstat(namespacePath)?.isDirectory == true,
            context.lstat(directory)?.isDirectory == true
        else {
            throw GoBuildCacheError.cannotCreateDirectory(directory)
        }
        if let status = context.lstat(path), status.type != .regular {
            throw GoBuildCacheError.invalidEntry(path)
        }

        let bytes = try GoExecutableImage.encode(executable)
        do {
            let descriptor = try context.openFile(
                path,
                flags: [.create, .truncate],
                access: .writeOnly)
            defer { try? context.closeFile(descriptor) }
            guard try context.writeFile(descriptor, bytes) == bytes.count else {
                throw GoBuildCacheError.shortWrite(path)
            }
        } catch let error as GoBuildCacheError {
            throw error
        } catch {
            throw GoBuildCacheError.cannotWrite(path, String(describing: error))
        }
    }

    static func clear(_ context: any GoToolContext, root: String) throws {
        try removeTree(context, path: childPath(root, namespace))
    }

    private static func removeTree(_ context: any GoToolContext, path: String) throws {
        guard let status = context.lstat(path) else { return }
        if status.isDirectory {
            guard let entries = context.listDirectory(path) else {
                throw GoBuildCacheError.cannotRemove(path)
            }
            for entry in entries {
                let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                try removeTree(context, path: childPath(path, name))
            }
        }
        guard context.remove(path) else {
            throw GoBuildCacheError.cannotRemove(path)
        }
    }

    private static func childPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    private static func parentPath(_ path: String) -> String {
        guard path != "/" else { return "/" }
        var components = path.split(separator: "/")
        if !components.isEmpty { components.removeLast() }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}

enum GoBuildCacheError: Error, CustomStringConvertible {
    case cannotCreateDirectory(String)
    case invalidEntry(String)
    case shortWrite(String)
    case cannotWrite(String, String)
    case cannotRemove(String)

    var description: String {
        switch self {
        case .cannotCreateDirectory(let path):
            return "go: failed to initialize build cache at \(path)"
        case .invalidEntry(let path):
            return "go: build cache path \(path) has an invalid file type"
        case .shortWrite(let path):
            return "go: writing build cache entry \(path): short write"
        case .cannotWrite(let path, let reason):
            return "go: writing build cache entry \(path): \(reason)"
        case .cannotRemove(let path):
            return "go: removing build cache entry \(path) failed"
        }
    }
}

struct StableSHA256 {
    private var state: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    mutating func updateField(_ bytes: [UInt8]) {
        updateInteger(UInt64(bytes.count))
        update(bytes)
    }

    mutating func updateInteger(_ value: UInt64) {
        update((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) })
    }

    mutating func update(_ bytes: [UInt8]) {
        byteCount &+= UInt64(bytes.count)
        var index = 0
        if !buffer.isEmpty {
            let count = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes.prefix(count))
            index += count
            if buffer.count == 64 {
                process(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while index + 64 <= bytes.count {
            process(bytes, offset: index)
            index += 64
        }
        if index < bytes.count {
            buffer.append(contentsOf: bytes[index...])
        }
    }

    mutating func finalizeHex() -> String {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        var index = 0
        while index < buffer.count {
            process(buffer, offset: index)
            index += 64
        }
        buffer.removeAll(keepingCapacity: true)
        let bytes = state.flatMap { word in
            stride(from: 24, through: 0, by: -8).map {
                UInt8(truncatingIfNeeded: word >> UInt32($0))
            }
        }
        let alphabet = Array("0123456789abcdef".utf8)
        return String(
            decoding: bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 0x0F)]] },
            as: UTF8.self)
    }

    private mutating func process(_ block: [UInt8], offset blockOffset: Int = 0) {
        var words = Array(repeating: UInt32(0), count: 64)
        for index in 0..<16 {
            let offset = blockOffset + index * 4
            words[index] =
                UInt32(block[offset]) << 24
                | UInt32(block[offset + 1]) << 16
                | UInt32(block[offset + 2]) << 8
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let s0 =
                rotateRight(words[index - 15], by: 7)
                ^ rotateRight(words[index - 15], by: 18)
                ^ (words[index - 15] >> 3)
            let s1 =
                rotateRight(words[index - 2], by: 17)
                ^ rotateRight(words[index - 2], by: 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for index in 0..<64 {
            let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let choose = (e & f) ^ ((~e) & g)
            let temporary1 = h &+ sum1 &+ choose &+ Self.constants[index] &+ words[index]
            let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let constants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
        0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
        0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
        0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
        0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
        0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]
}
