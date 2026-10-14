extension GoStandardLibrary {
    /// The natives of the file system, as the Go text of `os` calls them:
    /// `native.Open(name)` is `$os.Open`. They fail with the text of Go's
    /// error, which the text makes Go's `*fs.PathError` or `*os.LinkError`;
    /// a program's `os.Open` is the text's.
    static func fileSystemNative(_ name: String) -> GoNativeFunction? {
        if let metadata = fileMetadataNative(name) { return metadata }
        guard
            ["Open", "Create", "OpenFile", "ReadFile", "WriteFile", "Remove", "Rename", "Mkdir"]
                .contains(name)
        else { return nil }
        return nativeFunction(package: "os", member: name)
    }
}

extension GoStandardLibrary {
    /// The natives `os`'s text reads and changes the metadata of the file
    /// system with (`$os.stat` and the rest): a node's size, Go's file mode,
    /// and modification time in nanoseconds; the names and modes of a
    /// directory's entries; and the changes Go makes with `Chmod`, `Chdir`,
    /// and `Symlink`. They fail as the other natives of the file system do.
    static func fileMetadataNative(_ name: String) -> GoNativeFunction? {
        let failure = GoPredeclared.errorType
        let signature: (parameters: [GoType], results: [GoType])
        switch name {
        case "stat": signature = ([.string, .bool], [.int, .int, .int, failure])
        case "readdir": signature = ([.string], [.slice(.string), .slice(.int), failure])
        case "chmod": signature = ([.string, .int], [failure])
        case "chdir": signature = ([.string], [failure])
        case "symlink": signature = ([.string, .string], [failure])
        case "readlink": signature = ([.string], [.string, failure])
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$os." + name, goName: "os." + name, parameters: signature.parameters,
            results: signature.results)
    }

    static let fileMetadataCallNames = [
        "$os.stat", "$os.readdir", "$os.chmod", "$os.chdir", "$os.symlink", "$os.readlink",
        "$os.File.name",
    ]
}
