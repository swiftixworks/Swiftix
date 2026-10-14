extension GoStandardLibrary {
    /// The natives of the file system, as the Go text of `os` calls them:
    /// `native.Open(name)` is `$os.Open`. They fail with the text of Go's
    /// error, which the text makes Go's `*fs.PathError` or `*os.LinkError`;
    /// a program's `os.Open` is the text's.
    static func fileSystemNative(_ name: String) -> GoNativeFunction? {
        guard
            ["Open", "Create", "OpenFile", "ReadFile", "WriteFile", "Remove", "Rename", "Mkdir"]
                .contains(name)
        else { return nil }
        return nativeFunction(package: "os", member: name)
    }
}
