/// Filesystem built-ins (category .fileSystem): ls/stat/cat/mkdir/rmdir/rm/cp/
/// mv/ln/readlink/realpath/chmod/chown/touch/mktemp/truncate/basename/dirname/
/// df/free/mkfifo/flock. Tree-walking tools (find/du/tree/file/diff) live in
/// `FileTreeCommands.swift`; the shared path helpers and formatting hooks are in
/// `CommandFileSupport.swift`.
///
/// Every command reports the real reason an operation failed (`cmd: path:
/// <errno text>`), accepts the conventional option letters, and rejects unknown
/// ones through `ProcessContext.options`.
///
/// Concurrency: plain programs over `ProcessContext`, run on the single
/// loop-bound executor. Bodies are `async` wherever output can exceed a pipe's
/// capacity, so writes park on backpressure instead of being truncated.
/// One step of `rm -r`'s explicit-stack removal. File scope: a type declared
/// inside a command closure makes the module-interface pass misjudge the
/// closure's nested functions.
private enum RemovalStep {
    case visit(String)
    case removeDirectory(String)
}

extension BuiltinCommands {

    // MARK: - Extended filesystem (category: .fileSystem)

    static func extendedFileSystem() -> [Command] {
        [
            Command(name: "ls", summary: "list directory contents", category: .fileSystem,
                    usage: """
                    ls [-alhRd1trSFiAnp] [FILE]...
                      -a  do not hide entries starting with . (includes . and ..)
                      -A  like -a, without . and ..
                      -l  long listing: mode, links, owner, group, size, time, name
                      -h  with -l, print sizes with K/M/G suffixes
                      -R  list subdirectories recursively
                      -d  list directories themselves, not their contents
                      -1  one entry per line
                      -t  sort by modification time, newest first
                      -S  sort by size, largest first
                      -r  reverse the sort order
                      -F  append an indicator (/ @ | *) to entries
                      -p  append / to directories
                      -i  print each entry's inode number
                      -n  with -l, numeric user and group IDs
                    """, asyncRun: { ctx, argv in
                await listCommand(ctx, argv)
            }),

            Command(name: "stat", summary: "print file metadata", category: .fileSystem,
                    usage: """
                    stat [-L] [-c FORMAT] FILE...
                      -L  follow symbolic links
                      -c  print FORMAT instead: %n name, %s size, %a octal mode, %A mode
                          string, %u/%g ids, %U/%G names, %F type, %h links, %i inode,
                          %X/%Y/%Z access/modify/change time
                    """) { ctx, argv in
                guard let parsed = ctx.options("stat", Array(argv.dropFirst()), "Lc:t",
                                               long: ["format": "c", "dereference": "L"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("stat: missing operand")
                    ctx.fail("Try 'stat --help' for more information.", code: 1); return
                }
                let names = ctx.userDatabase()
                var status: Int32 = 0
                var out = ""
                for path in parsed.operands {
                    let info: FileStat
                    do {
                        info = try parsed.has("L") ? ctx.statOrThrow(path) : ctx.lstatOrThrow(path)
                    } catch {
                        ctx.error("stat: cannot stat '\(path)': \(errnoText(error))")
                        status = 1
                        continue
                    }
                    let inode = ctx.inodeNumber(path, follow: parsed.has("L"))
                    if let format = parsed.value("c") {
                        out += statFormat(ctx, format, path: path, info: info, inode: inode, names: names) + "\n"
                        continue
                    }
                    var shown = path
                    if info.type == .symlink, let target = ctx.readlink(path) { shown += " -> " + target }
                    out += "  File: \(shown)\n"
                    out += "  Size: \(info.size)\tLinks: \(info.nlink)\tType: \(fileTypeName(info.type))\n"
                    out += "Access: (\(octalMode(info.mode))/\(typeCharacter(info.type))\(permissionString(info.mode)))"
                        + "\tUid: \(info.uid)\tGid: \(info.gid)\tInode: \(inode)\n"
                    out += "Access: \(ctx.statTime(info.atime))\n"
                    out += "Modify: \(ctx.statTime(info.mtime))\n"
                    out += "Change: \(ctx.statTime(info.ctime))\n"
                }
                ctx.print(out)
                ctx.exit(status)
            },

            Command(name: "cat", summary: "concatenate files (or stdin) to stdout", category: .fileSystem,
                    usage: """
                    cat [-nbsE] [FILE]...
                      -n  number all output lines
                      -b  number non-empty output lines
                      -s  squeeze repeated empty lines into one
                      -E  show $ at the end of each line
                    With no FILE, or when FILE is -, read standard input.
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("cat", Array(argv.dropFirst()), "nbsEuTAv",
                                               long: ["number": "n", "number-nonblank": "b",
                                                      "squeeze-blank": "s", "show-ends": "E"]) else { return }
                let input = CommandInput(ctx, command: "cat", files: parsed.operands)
                let plain = !["n", "b", "s", "E", "T", "A"].contains { parsed.has($0) }
                if plain {
                    // Raw copy: bytes go out as they arrive, so `cat` streams.
                    while let bytes = await input.chunk() {
                        guard await ctx.put(bytes) else { return }
                    }
                    ctx.exit(input.status)
                    return
                }
                let numberAll = parsed.has("n") && !parsed.has("b")
                let showEnds = parsed.has("E") || parsed.has("A")
                let showTabs = parsed.has("T") || parsed.has("A")
                var number = 0
                var previousEmpty = false
                while var line = await input.line() {
                    if parsed.has("s") {
                        if line.isEmpty, previousEmpty { continue }
                        previousEmpty = line.isEmpty
                    }
                    if showTabs {
                        line = line.flatMap { $0 == 0x09 ? [UInt8(ascii: "^"), UInt8(ascii: "I")] : [$0] }
                    }
                    var out: [UInt8] = []
                    if numberAll || (parsed.has("b") && !line.isEmpty) {
                        number += 1
                        out += Array((padLeft(String(number), 6) + "\t").utf8)
                    }
                    out += line
                    if showEnds { out.append(UInt8(ascii: "$")) }
                    out.append(0x0A)
                    guard await ctx.put(out) else { return }
                }
                ctx.exit(input.status)
            }),

            Command(name: "mkdir", summary: "create directories", category: .fileSystem,
                    usage: """
                    mkdir [-pv] [-m MODE] DIRECTORY...
                      -p  create missing parents; no error if the directory exists
                      -m  set the permission bits (octal) of created directories
                      -v  print a message for each created directory
                    """) { ctx, argv in
                guard let parsed = ctx.options("mkdir", Array(argv.dropFirst()), "pvm:",
                                               long: ["parents": "p", "verbose": "v", "mode": "m"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("mkdir: missing operand")
                    ctx.fail("Try 'mkdir --help' for more information.", code: 1); return
                }
                var mode: FileMode? = nil
                if let text = parsed.value("m") {
                    guard let bits = UInt16(text, radix: 8), bits <= 0o7777 else {
                        ctx.fail("mkdir: invalid mode '\(text)'", code: 1); return
                    }
                    mode = FileMode(rawValue: bits)
                }
                var status: Int32 = 0
                func create(_ path: String, shown: String) -> Bool {
                    do {
                        try ctx.makeDirectory(path)
                        if let mode { _ = ctx.chmod(path, mode: mode) }
                        if parsed.has("v") { ctx.print("mkdir: created directory '\(shown)'\n") }
                        return true
                    } catch {
                        ctx.error("mkdir: cannot create directory '\(shown)': \(errnoText(error))")
                        status = 1
                        return false
                    }
                }
                for dir in parsed.operands {
                    guard parsed.has("p") else { _ = create(dir, shown: dir); continue }
                    // -p: walk down from the root of the path, creating what is missing.
                    var prefix = dir.hasPrefix("/") ? "" : "."
                    for part in dir.split(separator: "/") {
                        prefix = prefix == "." ? String(part) : prefix + "/" + part
                        if let existing = ctx.stat(prefix) {
                            if existing.isDirectory { continue }
                            ctx.error("mkdir: cannot create directory '\(prefix)': \(SyscallError.fileExists.message)")
                            status = 1
                            break
                        }
                        if !create(prefix, shown: prefix) { break }
                    }
                }
                ctx.exit(status)
            },

            Command(name: "rmdir", summary: "remove empty directories", category: .fileSystem,
                    usage: """
                    rmdir [-pv] DIRECTORY...
                      -p  also remove each parent directory that becomes empty
                      -v  print a message for each removed directory
                    """) { ctx, argv in
                guard let parsed = ctx.options("rmdir", Array(argv.dropFirst()), "pv",
                                               long: ["parents": "p", "verbose": "v"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("rmdir: missing operand")
                    ctx.fail("Try 'rmdir --help' for more information.", code: 1); return
                }
                var status: Int32 = 0
                for dir in parsed.operands {
                    var current = dir
                    while true {
                        do {
                            try ctx.removeDirectoryOrThrow(current)
                            if parsed.has("v") { ctx.print("rmdir: removing directory, '\(current)'\n") }
                        } catch {
                            ctx.error("rmdir: failed to remove '\(current)': \(errnoText(error))")
                            status = 1
                            break
                        }
                        guard parsed.has("p") else { break }
                        let parent = directoryName(current)
                        if parent == "." || parent == "/" || parent == current { break }
                        current = parent
                    }
                }
                ctx.exit(status)
            },

            Command(name: "rm", summary: "remove files or directories", category: .fileSystem,
                    usage: """
                    rm [-rRfdvi] FILE...
                      -r, -R  remove directories and their contents recursively
                      -f      ignore nonexistent files, never fail for them
                      -d      remove empty directories
                      -v      print a message for each removed file
                      -i      accepted for compatibility (no prompt is shown)
                    """) { ctx, argv in
                guard let parsed = ctx.options("rm", Array(argv.dropFirst()), "rRfdvi",
                                               long: ["recursive": "r", "force": "f", "dir": "d",
                                                      "verbose": "v"]) else { return }
                let recursive = parsed.has("r") || parsed.has("R")
                let force = parsed.has("f")
                guard !parsed.operands.isEmpty else {
                    if force { ctx.exit(0); return }
                    ctx.error("rm: missing operand")
                    ctx.fail("Try 'rm --help' for more information.", code: 1); return
                }
                var status: Int32 = 0
                func report(_ path: String, _ error: Error) {
                    if force, (error as? SyscallError) == .noSuchFileOrDirectory { return }
                    ctx.error("rm: cannot remove '\(path)': \(errnoText(error))")
                    status = 1
                }
                // Depth-first removal on an explicit stack (a directory's
                // contents go before the directory itself), so a deeply nested
                // tree costs heap, not host stack.
                func remove(_ operand: String) {
                    var steps: [RemovalStep] = [.visit(operand)]
                    while let step = steps.popLast() {
                        switch step {
                        case let .visit(path):
                            let info: FileStat
                            do { info = try ctx.lstatOrThrow(path) } catch { report(path, error); continue }
                            guard info.isDirectory else {
                                do {
                                    try ctx.unlinkOrThrow(path)
                                    if parsed.has("v") { ctx.print("removed '\(path)'\n") }
                                } catch { report(path, error) }
                                continue
                            }
                            if recursive {
                                do {
                                    let entries = try ctx.directoryEntries(path)
                                    steps.append(.removeDirectory(path))
                                    for entry in entries.reversed() {
                                        steps.append(.visit(ctx.join(path, entry.name)))
                                    }
                                } catch { report(path, error) }
                            } else if !parsed.has("d") {
                                report(path, SyscallError.isADirectory)
                            } else {
                                steps.append(.removeDirectory(path))
                            }
                        case let .removeDirectory(path):
                            do {
                                try ctx.removeDirectoryOrThrow(path)
                                if parsed.has("v") { ctx.print("removed directory '\(path)'\n") }
                            } catch { report(path, error) }
                        }
                    }
                }
                for path in parsed.operands {
                    let base = baseName(path)
                    if base == "." || base == ".." {
                        ctx.error("rm: refusing to remove '.' or '..' directory: skipping '\(path)'")
                        status = 1
                        continue
                    }
                    if ctx.absolute(path) == "/" {
                        ctx.error("rm: it is dangerous to operate recursively on '/'")
                        status = 1
                        continue
                    }
                    remove(path)
                }
                ctx.exit(status)
            },

            Command(name: "cp", summary: "copy files and directories", category: .fileSystem,
                    usage: """
                    cp [-rRapfinv] SOURCE DEST
                    cp [-rRapfinv] SOURCE... DIRECTORY
                      -r, -R  copy directories recursively
                      -a      archive: -r and preserve mode, ownership, and times
                      -p      preserve mode, ownership, and timestamps
                      -f      replace an existing destination that cannot be opened
                      -n      do not overwrite an existing file
                      -v      explain what is being done
                      -i      accepted for compatibility (no prompt is shown)
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("cp", Array(argv.dropFirst()), "rRapfinvT",
                                               long: ["recursive": "r", "archive": "a", "preserve": "p",
                                                      "force": "f", "no-clobber": "n",
                                                      "verbose": "v"]) else { return }
                guard let (sources, target, intoDirectory) = splitTargets(ctx, "cp", parsed) else { return }
                let recursive = parsed.has("r") || parsed.has("R") || parsed.has("a")
                let preserve = parsed.has("p") || parsed.has("a")
                var status: Int32 = 0

                func copyMetadata(from info: FileStat, to path: String) {
                    _ = ctx.chmod(path, mode: info.mode)
                    guard preserve else { return }
                    _ = ctx.chown(path, uid: info.uid, gid: info.gid)
                    _ = ctx.utimes(path, atime: info.atime, mtime: info.mtime)
                }

                func copy(_ source: String, _ destination: String, topLevel: Bool) async {
                    // Operands are followed; links met during a recursive
                    // walk are copied as links.
                    let followed = topLevel && !parsed.has("a")
                    let lookup = Result { try followed ? ctx.statOrThrow(source) : ctx.lstatOrThrow(source) }
                    let info: FileStat
                    switch lookup {
                    case .success(let found):
                        info = found
                    case .failure(let error):
                        ctx.error("cp: cannot stat '\(source)': \(errnoText(error))")
                        status = 1
                        return
                    }
                    if ctx.absolute(source) == ctx.absolute(destination) {
                        ctx.error("cp: '\(source)' and '\(destination)' are the same file")
                        status = 1
                        return
                    }
                    if info.isDirectory {
                        guard recursive else {
                            ctx.error("cp: -r not specified; omitting directory '\(source)'")
                            status = 1
                            return
                        }
                        if (ctx.absolute(destination) + "/").hasPrefix(ctx.absolute(source) + "/") {
                            ctx.error("cp: cannot copy a directory, '\(source)', into itself, '\(destination)'")
                            status = 1
                            return
                        }
                        let entries: [FileSystemDirectoryEntry]
                        do {
                            entries = try ctx.directoryEntries(source)
                            if let existing = ctx.stat(destination) {
                                guard existing.isDirectory else {
                                    ctx.error("cp: cannot overwrite non-directory '\(destination)' with directory '\(source)'")
                                    status = 1
                                    return
                                }
                            } else {
                                try ctx.makeDirectory(destination)
                            }
                        } catch {
                            ctx.error("cp: cannot copy '\(source)' to '\(destination)': \(errnoText(error))")
                            status = 1
                            return
                        }
                        if parsed.has("v") { ctx.print("'\(source)' -> '\(destination)'\n") }
                        for entry in entries {
                            await copy(ctx.join(source, entry.name), ctx.join(destination, entry.name),
                                       topLevel: false)
                        }
                        copyMetadata(from: info, to: destination)
                        return
                    }
                    if parsed.has("n"), ctx.lstat(destination) != nil { return }
                    if info.type == .symlink, let linkTarget = ctx.readlink(source) {
                        if ctx.lstat(destination) != nil { try? ctx.unlinkOrThrow(destination) }
                        guard ctx.symlink(linkTarget, at: destination) else {
                            ctx.error("cp: cannot create symbolic link '\(destination)'")
                            status = 1
                            return
                        }
                    } else if info.type == .fifo {
                        guard ctx.lstat(destination) != nil || ctx.mkfifo(destination) else {
                            ctx.error("cp: cannot create fifo '\(destination)'")
                            status = 1
                            return
                        }
                    } else if !topLevel, ctx.isDeviceNode(source) {
                        ctx.error("cp: omitting device file '\(source)'")
                    } else {
                        let data: [UInt8]
                        do {
                            data = try await readOperand(ctx, source)
                        } catch {
                            ctx.error("cp: cannot open '\(source)' for reading: \(errnoText(error))")
                            status = 1
                            return
                        }
                        let existed = ctx.lstat(destination) != nil
                        var fd: Int
                        do {
                            fd = try ctx.openForWriting(destination)
                        } catch {
                            // -f: an unwritable destination is unlinked and retried.
                            guard parsed.has("f"), existed, (try? ctx.unlinkOrThrow(destination)) != nil,
                                  let retried = try? ctx.openForWriting(destination) else {
                                ctx.error("cp: cannot create regular file '\(destination)': \(errnoText(error))")
                                status = 1
                                return
                            }
                            fd = retried
                        }
                        let complete = await ctx.writeAll(fd, data)
                        ctx.close(fd)
                        guard complete else {
                            ctx.error("cp: error writing '\(destination)'")
                            status = 1
                            return
                        }
                        if !existed || preserve { copyMetadata(from: info, to: destination) }
                    }
                    if parsed.has("v") { ctx.print("'\(source)' -> '\(destination)'\n") }
                }

                for source in sources {
                    let destination = intoDirectory ? ctx.join(target, baseName(source)) : target
                    await copy(source, destination, topLevel: true)
                }
                ctx.exit(status)
            }),

            Command(name: "mv", summary: "move (rename) files", category: .fileSystem,
                    usage: """
                    mv [-finv] SOURCE DEST
                    mv [-finv] SOURCE... DIRECTORY
                      -f  do not prompt before overwriting (the default)
                      -n  do not overwrite an existing file
                      -v  explain what is being done
                      -i  accepted for compatibility (no prompt is shown)
                    """) { ctx, argv in
                guard let parsed = ctx.options("mv", Array(argv.dropFirst()), "finvT",
                                               long: ["force": "f", "no-clobber": "n",
                                                      "verbose": "v"]) else { return }
                guard let (sources, target, intoDirectory) = splitTargets(ctx, "mv", parsed) else { return }
                var status: Int32 = 0
                for source in sources {
                    let destination = intoDirectory ? ctx.join(target, baseName(source)) : target
                    guard ctx.lstat(source) != nil else {
                        ctx.error("mv: cannot stat '\(source)': \(ctx.missingReason(source).message)")
                        status = 1
                        continue
                    }
                    if ctx.absolute(source) == ctx.absolute(destination) {
                        ctx.error("mv: '\(source)' and '\(destination)' are the same file")
                        status = 1
                        continue
                    }
                    if parsed.has("n"), ctx.lstat(destination) != nil { continue }
                    do {
                        try ctx.renameOrThrow(source, to: destination)
                        if parsed.has("v") { ctx.print("renamed '\(source)' -> '\(destination)'\n") }
                    } catch SyscallError.invalidArgument {
                        ctx.error("mv: cannot move '\(source)' to a subdirectory of itself, '\(destination)'")
                        status = 1
                    } catch {
                        ctx.error("mv: cannot move '\(source)' to '\(destination)': \(errnoText(error))")
                        status = 1
                    }
                }
                ctx.exit(status)
            },

            Command(name: "ln", summary: "create links between files", category: .fileSystem,
                    usage: """
                    ln [-sfnv] TARGET LINK_NAME
                    ln [-sfnv] TARGET... DIRECTORY
                      -s  make symbolic links instead of hard links
                      -f  remove an existing destination first
                      -n  treat a LINK_NAME that is a symlink to a directory as a file
                      -v  print the name of each link created
                    """) { ctx, argv in
                guard let parsed = ctx.options("ln", Array(argv.dropFirst()), "sfnvT",
                                               long: ["symbolic": "s", "force": "f",
                                                      "verbose": "v"]) else { return }
                var operands = parsed.operands
                guard !operands.isEmpty else {
                    ctx.error("ln: missing file operand")
                    ctx.fail("Try 'ln --help' for more information.", code: 1); return
                }
                // One operand links into the current directory under the same name.
                var directory: String? = nil
                if operands.count == 1 {
                    directory = "."
                } else if let last = operands.last {
                    let isLinkToDirectory = ctx.lstat(last)?.type == .symlink
                    if ctx.stat(last)?.isDirectory == true, !(parsed.has("n") && isLinkToDirectory) {
                        directory = last
                        operands.removeLast()
                    } else if operands.count > 2 {
                        ctx.fail("ln: target '\(last)' is not a directory", code: 1); return
                    }
                }
                let symbolic = parsed.has("s")
                let kind = symbolic ? "symbolic" : "hard"
                var status: Int32 = 0
                let pairs: [(target: String, link: String)]
                if let directory {
                    pairs = operands.map { ($0, directory == "." ? baseName($0) : ctx.join(directory, baseName($0))) }
                } else {
                    pairs = [(operands[0], operands[1])]
                }
                for (target, link) in pairs {
                    func fail(_ reason: String) {
                        ctx.error("ln: failed to create \(kind) link '\(link)'"
                                  + (symbolic ? "" : " => '\(target)'") + ": \(reason)")
                        status = 1
                    }
                    if !symbolic {
                        guard let info = ctx.stat(target) else {
                            ctx.error("ln: failed to access '\(target)': \(SyscallError.noSuchFileOrDirectory.message)")
                            status = 1
                            continue
                        }
                        if info.isDirectory {
                            ctx.error("ln: \(target): hard link not allowed for directory")
                            status = 1
                            continue
                        }
                    }
                    if let existing = ctx.lstat(link) {
                        guard parsed.has("f") else { fail(SyscallError.fileExists.message); continue }
                        if existing.isDirectory { fail("cannot overwrite directory"); continue }
                        do { try ctx.unlinkOrThrow(link) } catch { fail(errnoText(error)); continue }
                    }
                    if let (parent, _) = ctx.splitPath(link), ctx.stat(parent)?.isDirectory != true {
                        fail(SyscallError.noSuchFileOrDirectory.message)
                        continue
                    }
                    let created = symbolic ? ctx.symlink(target, at: link) : ctx.link(target, at: link)
                    guard created else { fail(SyscallError.permissionDenied.message); continue }
                    if parsed.has("v") { ctx.print("'\(link)' \(symbolic ? "->" : "=>") '\(target)'\n") }
                }
                ctx.exit(status)
            },

            Command(name: "readlink", summary: "print a symbolic link's target", category: .fileSystem,
                    usage: """
                    readlink [-fn] FILE...
                      -f  canonicalize: follow every symlink in every component
                      -n  do not output the trailing newline
                    """) { ctx, argv in
                guard let parsed = ctx.options("readlink", Array(argv.dropFirst()), "fnemqsv",
                                               long: ["canonicalize": "f", "no-newline": "n"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("readlink: missing operand")
                    ctx.fail("Try 'readlink --help' for more information.", code: 1); return
                }
                let canonical = parsed.has("f") || parsed.has("e") || parsed.has("m")
                var status: Int32 = 0
                var out = ""
                for path in parsed.operands {
                    let resolved = canonical
                        ? canonicalPath(ctx, path, mustExist: parsed.has("e"), allowMissing: parsed.has("m"))
                        : ctx.readlink(path)
                    guard let resolved else { status = 1; continue }
                    out += resolved + (parsed.has("n") && parsed.operands.count == 1 ? "" : "\n")
                }
                ctx.print(out)
                ctx.exit(status)
            },

            Command(name: "realpath", summary: "print the resolved absolute path", category: .fileSystem,
                    usage: """
                    realpath [-ems] FILE...
                      -e  every component must exist
                      -m  no component need exist
                      -s  do not expand symbolic links
                    """) { ctx, argv in
                guard let parsed = ctx.options("realpath", Array(argv.dropFirst()), "emsqz",
                                               long: ["canonicalize-existing": "e",
                                                      "canonicalize-missing": "m",
                                                      "no-symlinks": "s"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("realpath: missing operand")
                    ctx.fail("Try 'realpath --help' for more information.", code: 1); return
                }
                var status: Int32 = 0
                var out = ""
                for path in parsed.operands {
                    if parsed.has("s") { out += ctx.absolute(path) + "\n"; continue }
                    guard let resolved = canonicalPath(ctx, path, mustExist: parsed.has("e"),
                                                       allowMissing: parsed.has("m")) else {
                        ctx.error("realpath: \(path): \(SyscallError.noSuchFileOrDirectory.message)")
                        status = 1
                        continue
                    }
                    out += resolved + "\n"
                }
                ctx.print(out)
                ctx.exit(status)
            },

            // chmod MODE file... — set permission bits from an octal mode
            // (`644`, `1777`) or symbolic clauses (`u+x,g-r`, `a=r`, `+X`, `o+t`).
            // Combined with the kernel's EACCES checks, this is what makes file
            // permissions teachable (`chmod 600 secret`, then a non-root user can
            // no longer read it).
            Command(name: "chmod", summary: "change file permission bits", category: .fileSystem,
                    usage: """
                    chmod [-Rvf] MODE[,MODE]... FILE...
                    chmod [-Rvf] OCTAL-MODE FILE...
                      -R  change files and directories recursively
                      -v  print a message for each file processed
                      -f  suppress most error messages
                    MODE is [ugoa]*([-+=][rwxXst]*)+, e.g. u+x,g-w or a=r.
                    """) { ctx, argv in
                var args = Array(argv.dropFirst())
                var recursive = false, verbose = false, quiet = false
                // Options come first; a mode such as `-x` also starts with a dash,
                // so only tokens made purely of option letters are options.
                while let first = args.first, first.hasPrefix("-"), first.count > 1 {
                    if first == "--" { args.removeFirst(); break }
                    let letters = first.dropFirst()
                    if first == "--recursive" { recursive = true; args.removeFirst(); continue }
                    guard letters.allSatisfy({ "Rvfc".contains($0) }) else {
                        if parseModeChange(first, current: [], isDirectory: false) != nil { break }
                        ctx.invalidOption("chmod", first.hasPrefix("--") ? first : String(letters.first { !"Rvfc".contains($0) } ?? "-"))
                        return
                    }
                    for letter in letters {
                        switch letter {
                        case "R": recursive = true
                        case "v", "c": verbose = true
                        default: quiet = true
                        }
                    }
                    args.removeFirst()
                }
                guard args.count >= 2 else {
                    ctx.error(args.isEmpty ? "chmod: missing operand" : "chmod: missing operand after '\(args[0])'")
                    ctx.fail("Try 'chmod --help' for more information.", code: 1); return
                }
                let spec = args[0]
                guard parseModeChange(spec, current: [], isDirectory: false) != nil else {
                    ctx.fail("chmod: invalid mode: '\(spec)'", code: 1); return
                }
                var status: Int32 = 0
                // Returns the entries to descend into (empty unless -R on a
                // real directory); the caller walks them on an explicit stack.
                func apply(_ path: String) -> [String] {
                    guard let info = ctx.stat(path) else {
                        if !quiet {
                            let reason = ctx.lstat(path) != nil ? "dangling symbolic link"
                                                                : ctx.missingReason(path).message
                            ctx.error("chmod: cannot access '\(path)': \(reason)")
                        }
                        status = 1
                        return []
                    }
                    let mode = parseModeChange(spec, current: info.mode, isDirectory: info.isDirectory) ?? info.mode
                    if ctx.chmod(path, mode: mode) {
                        if verbose {
                            ctx.print("mode of '\(path)' changed from \(octalMode(info.mode)) "
                                      + "(\(permissionString(info.mode))) to \(octalMode(mode)) "
                                      + "(\(permissionString(mode)))\n")
                        }
                    } else {
                        if !quiet { ctx.error("chmod: changing permissions of '\(path)': Operation not permitted") }
                        status = 1
                    }
                    guard recursive, info.isDirectory, ctx.lstat(path)?.type != .symlink else { return [] }
                    do {
                        return try ctx.directoryEntries(path).filter { $0.type != .symlink }
                            .map { ctx.join(path, $0.name) }
                    } catch {
                        if !quiet { ctx.error("chmod: cannot read directory '\(path)': \(errnoText(error))") }
                        status = 1
                        return []
                    }
                }
                for operand in args.dropFirst() {
                    var pending = [operand]
                    while let path = pending.popLast() {
                        pending.append(contentsOf: apply(path).reversed())
                    }
                }
                ctx.exit(status)
            },

            // chown OWNER[:GROUP] file... — change ownership. Names resolve through
            // /etc/passwd and /etc/group when present; numeric ids always work.
            Command(name: "chown", summary: "change file ownership", category: .fileSystem,
                    usage: """
                    chown [-Rv] OWNER[:GROUP] FILE...
                    chown [-Rv] :GROUP FILE...
                      -R  operate on files and directories recursively
                      -v  print a message for each file processed
                    """) { ctx, argv in
                guard let parsed = ctx.options("chown", Array(argv.dropFirst()), "Rvfh",
                                               long: ["recursive": "R", "verbose": "v"]) else { return }
                guard parsed.operands.count >= 2 else {
                    ctx.error("chown: missing operand")
                    ctx.fail("Try 'chown --help' for more information.", code: 1); return
                }
                let names = ctx.userDatabase()
                let spec = parsed.operands[0].split(separator: ":", maxSplits: 1,
                                                    omittingEmptySubsequences: false).map(String.init)
                var newUID: UInt32? = nil
                var newGID: UInt32? = nil
                if !spec[0].isEmpty {
                    guard let uid = names.resolveUser(spec[0])?.uid else {
                        ctx.fail("chown: invalid user: '\(parsed.operands[0])'", code: 1); return
                    }
                    newUID = uid
                }
                if spec.count > 1, !spec[1].isEmpty {
                    guard let gid = names.resolveGroupID(spec[1]) else {
                        ctx.fail("chown: invalid group: '\(parsed.operands[0])'", code: 1); return
                    }
                    newGID = gid
                }
                var status: Int32 = 0
                // Returns the entries to descend into (empty unless -R on a
                // real directory); the caller walks them on an explicit stack.
                func apply(_ path: String) -> [String] {
                    guard let info = ctx.stat(path) else {
                        ctx.error("chown: cannot access '\(path)': \(ctx.missingReason(path).message)")
                        status = 1
                        return []
                    }
                    if ctx.chown(path, uid: newUID ?? info.uid, gid: newGID ?? info.gid) {
                        if parsed.has("v") { ctx.print("ownership of '\(path)' changed\n") }
                    } else {
                        ctx.error("chown: changing ownership of '\(path)': Operation not permitted")
                        status = 1
                    }
                    guard parsed.has("R"), info.isDirectory, ctx.lstat(path)?.type != .symlink,
                          let entries = try? ctx.directoryEntries(path) else { return [] }
                    return entries.filter { $0.type != .symlink }.map { ctx.join(path, $0.name) }
                }
                for operand in parsed.operands.dropFirst() {
                    var pending = [operand]
                    while let path = pending.popLast() {
                        pending.append(contentsOf: apply(path).reversed())
                    }
                }
                ctx.exit(status)
            },

            // basename NAME [SUFFIX] / basename -a [-s SUFFIX] NAME... — strip the
            // directory (and optional suffix).
            Command(name: "basename", summary: "strip directory and suffix from a path", category: .fileSystem,
                    usage: """
                    basename NAME [SUFFIX]
                    basename [-a] [-s SUFFIX] NAME...
                      -a  support multiple arguments, treating each as a NAME
                      -s  remove a trailing SUFFIX (implies -a)
                    """) { ctx, argv in
                guard let parsed = ctx.options("basename", Array(argv.dropFirst()), "as:z",
                                               long: ["multiple": "a", "suffix": "s"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("basename: missing operand")
                    ctx.fail("Try 'basename --help' for more information.", code: 1); return
                }
                var names = parsed.operands
                var suffix = parsed.value("s")
                if !parsed.has("a"), suffix == nil {
                    guard names.count <= 2 else {
                        ctx.error("basename: extra operand '\(names[2])'")
                        ctx.fail("Try 'basename --help' for more information.", code: 1); return
                    }
                    if names.count == 2 { suffix = names[1]; names.removeLast() }
                }
                var out = ""
                for name in names {
                    var base = baseName(name)
                    if let suffix, !suffix.isEmpty, base.hasSuffix(suffix), base != suffix {
                        base = String(base.dropLast(suffix.count))
                    }
                    out += base + "\n"
                }
                ctx.print(out)
                ctx.exit(0)
            },

            // dirname NAME... — the directory portion of each path.
            Command(name: "dirname", summary: "strip the last component from a path", category: .fileSystem,
                    usage: "dirname NAME...") { ctx, argv in
                guard let parsed = ctx.options("dirname", Array(argv.dropFirst()), "z") else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("dirname: missing operand")
                    ctx.fail("Try 'dirname --help' for more information.", code: 1); return
                }
                ctx.print(parsed.operands.map { directoryName($0) + "\n" }.joined())
                ctx.exit(0)
            },

            // df [-h] — report filesystem usage. Swiftix's filesystem is an
            // in-memory tmpfs with no fixed capacity, so the total is a synthetic
            // 64 MiB and "used" is the live sum of file bytes — enough to teach
            // the command and its columns. `-h` uses human units. Numeric columns
            // are right-aligned to match Linux df(1).
            Command(name: "df", summary: "report filesystem usage", category: .fileSystem,
                    usage: """
                    df [-hk] [FILE]...
                      -h  print sizes in powers of 1024 (e.g. 64.0M)
                      -k  use 1K blocks (the default)
                    """) { ctx, argv in
                guard let parsed = ctx.options("df", Array(argv.dropFirst()), "hkPTa",
                                               long: ["human-readable": "h"]) else { return }
                let human = parsed.has("h")
                let totalBytes: Int64 = 64 * 1024 * 1024
                let usedBytes = min(totalFileBytes(ctx, under: "/"), totalBytes)
                let availBytes = totalBytes - usedBytes
                let usePercent = Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())
                func size(_ n: Int64) -> String { human ? humanBytes(n) : "\(n / 1024)" }
                let sTotal = size(totalBytes)
                let sUsed = size(usedBytes)
                let sAvail = size(availBytes)
                let sUse = "\(usePercent)%"
                if human {
                    ctx.print("Filesystem      Size  Used Avail Use% Mounted on\n")
                    ctx.print("tmpfs          \(padLeft(sTotal, 4)) \(padLeft(sUsed, 4)) \(padLeft(sAvail, 5)) \(padLeft(sUse, 4)) /\n")
                } else {
                    ctx.print("Filesystem     1K-blocks      Used Available Use% Mounted on\n")
                    ctx.print("tmpfs          \(padLeft(sTotal, 9)) \(padLeft(sUsed, 9)) \(padLeft(sAvail, 9)) \(padLeft(sUse, 4)) /\n")
                }
                ctx.exit(0)
            },

            // free [-h] — report the Kernel's aggregate managed-runtime budget
            // and actual runtime-reported heap bytes. This intentionally excludes
            // host Swift/ARC overhead and VFS storage instead of presenting either
            // as fabricated physical RAM. `-h` uses human units.
            Command(name: "free", summary: "report memory usage", category: .system,
                    usage: """
                    free [-h]
                      -h  print sizes in powers of 1024
                    """) { ctx, argv in
                guard let parsed = ctx.options("free", Array(argv.dropFirst()), "hbkmg",
                                               long: ["human": "h"]) else { return }
                let human = parsed.has("h")
                guard let fd = ctx.open("/proc/meminfo") else {
                    ctx.fail("free: cannot read /proc/meminfo", code: 1); return
                }
                let text = String(decoding: readFully(ctx, fd), as: UTF8.self)
                ctx.close(fd)
                func kib(_ field: String) -> Int64? {
                    guard let line = text.split(separator: "\n").first(where: {
                        $0.hasPrefix(field + ":")
                    }) else { return nil }
                    return line.split(separator: " ").dropFirst().first.flatMap { Int64($0) }
                }
                guard let totalKB = kib("MemTotal"), let freeKB = kib("MemFree") else {
                    ctx.fail("free: malformed /proc/meminfo", code: 1); return
                }
                let totalBytes = totalKB * 1024
                let freeBytes = freeKB * 1024
                let usedBytes = max(0, totalBytes - freeBytes)
                func size(_ n: Int64) -> String { human ? humanBytes(n) : "\(n / 1024)" }
                let sTotal = size(totalBytes), sUsed = size(usedBytes), sFree = size(freeBytes)
                let w = max(sTotal.count, sFree.count, sUsed.count, 11)
                ctx.print("              \(padLeft("total", w)) \(padLeft("used", w)) \(padLeft("free", w))\n")
                ctx.print("Mem:          \(padLeft(sTotal, w)) \(padLeft(sUsed, w)) \(padLeft(sFree, w))\n")
                ctx.print("Model: managed-runtime (excludes host memory and VFS storage)\n")
                ctx.exit(0)
            },

            // mkfifo PATH — create a named pipe (FIFO) at PATH. Two processes
            // that open the same FIFO can communicate through it.
            Command(name: "mkfifo", summary: "create a named pipe (FIFO)", category: .fileSystem,
                    usage: "mkfifo NAME...") { ctx, argv in
                guard let parsed = ctx.options("mkfifo", Array(argv.dropFirst()), "m:") else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.error("mkfifo: missing operand")
                    ctx.fail("Try 'mkfifo --help' for more information.", code: 1); return
                }
                var status: Int32 = 0
                for path in parsed.operands where !ctx.mkfifo(path) {
                    let reason: SyscallError = ctx.lstat(path) != nil ? .fileExists
                        : (ctx.splitPath(path).flatMap { ctx.stat($0.parent) } == nil ? .noSuchFileOrDirectory
                                                                                      : .permissionDenied)
                    ctx.error("mkfifo: cannot create fifo '\(path)': \(reason.message)")
                    status = 1
                }
                ctx.exit(status)
            },

            // flock [-s|-x|-u] FD CMD... — advisory file locking. Opens FILE,
            // acquires the specified lock, then runs CMD with the fd held.
            // -s = shared (read), -x = exclusive (write, default), -u = unlock.
            // Without CMD, operates on FD (numeric) and exits.
            Command(name: "flock", summary: "advisory file locking", category: .fileSystem,
                    usage: """
                    flock [-s|-x|-u] FILE
                      -s  take a shared (read) lock
                      -x  take an exclusive (write) lock (the default)
                      -u  release the lock
                    """) { ctx, argv in
                var args = Array(argv.dropFirst())
                var operation: ProcessContext.LockOperation = .exclusive
                // Deliberately stricter than `CommandArguments.isOptionToken`: the
                // three operations are mutually exclusive, so there is nothing to
                // combine and only exact two-character flags are accepted. A
                // combined `-sx` therefore falls through as the file operand.
                while let first = args.first, first.hasPrefix("-"), first.count == 2 {
                    switch first {
                    case "-s": operation = .shared
                    case "-x": operation = .exclusive
                    case "-u": operation = .unlock
                    default:
                        ctx.invalidOption("flock", String(first.dropFirst())); return
                    }
                    args.removeFirst()
                }
                guard let file = args.first else {
                    ctx.usage("flock", "flock [-s|-x|-u] <file>"); return
                }
                guard let fd = ctx.open(file, access: .readWrite) else {
                    ctx.fail("flock: \(file): cannot open", code: 1); return
                }
                if ctx.flock(fd, operation: operation) {
                    ctx.print("lock acquired\n")
                    ctx.close(fd)
                    ctx.exit(0)
                } else {
                    ctx.error("flock: \(file): lock not available")
                    ctx.close(fd)
                    ctx.exit(1)
                }
            },

            // touch [-a] [-m] [-c] [-r REF] [-t TIME] FILE... — update timestamps.
            // Without flags, sets atime and mtime to now. -a = atime only, -m =
            // mtime only, -t STAMP / -d STRING = use that time instead of now. Creates the file if it doesn't exist (like POSIX touch).
            Command(name: "touch", summary: "update file timestamps (creating files)", category: .fileSystem,
                    usage: """
                    touch [-acm] [-r REF] [-t STAMP] [-d STRING] FILE...
                      -a  change only the access time
                      -m  change only the modification time
                      -c  do not create files that do not exist
                      -r  use REF's times instead of the current time
                      -t  use [[CC]YY]MMDDhhmm[.ss] instead of the current time
                      -d  use '@EPOCH' or 'YYYY-MM-DD[ HH:MM[:SS]]' instead of the current time
                    """) { ctx, argv in
                guard let parsed = ctx.options("touch", Array(argv.dropFirst()), "amcr:t:d:f",
                                               long: ["no-create": "c", "reference": "r"]) else { return }
                var doAccess = parsed.has("a"), doModify = parsed.has("m")
                var accessTime: Double? = nil, modifyTime: Double? = nil
                if let text = parsed.value("t") ?? parsed.value("d") {
                    let offset = ctx.utcOffsetSeconds
                    let stamp = parsed.value("t") != nil
                        ? parseTouchStamp(text, now: ctx.currentCalendarTime(), utcOffsetSeconds: offset)
                        : parseDateOperand(text, utcOffsetSeconds: offset)
                    // A bare number is taken as seconds on the file-time clock.
                    guard let time = stamp.map(Double.init) ?? Double(text) else {
                        ctx.fail("touch: invalid date format '\(text)'", code: 1); return
                    }
                    accessTime = time
                    modifyTime = time
                }
                if let reference = parsed.value("r") {
                    guard let info = ctx.stat(reference) else {
                        ctx.fail("touch: failed to get attributes of '\(reference)': "
                                 + SyscallError.noSuchFileOrDirectory.message, code: 1); return
                    }
                    accessTime = info.atime
                    modifyTime = info.mtime
                }
                // No -a/-m means both.
                if !doAccess, !doModify { doAccess = true; doModify = true }
                guard !parsed.operands.isEmpty else {
                    ctx.error("touch: missing file operand")
                    ctx.fail("Try 'touch --help' for more information.", code: 1); return
                }
                var status: Int32 = 0
                for path in parsed.operands {
                    // Create the file if it doesn't exist, and close the
                    // descriptor immediately: touch must not leak one fd per path.
                    if ctx.stat(path) == nil {
                        if parsed.has("c") { continue }
                        do {
                            ctx.close(try ctx.openForWriting(path, truncate: false))
                        } catch {
                            ctx.error("touch: cannot touch '\(path)': \(errnoText(error))")
                            status = 1
                            continue
                        }
                    }
                    let updated: Bool
                    if doAccess && doModify {
                        updated = ctx.utimes(path, atime: accessTime, mtime: modifyTime)
                    } else if doAccess {
                        updated = ctx.utimes(path, atime: accessTime, mtime: ctx.stat(path)?.mtime)
                    } else {
                        updated = ctx.utimes(path, atime: ctx.stat(path)?.atime, mtime: modifyTime)
                    }
                    if !updated {
                        ctx.error("touch: cannot touch '\(path)': \(SyscallError.permissionDenied.message)")
                        status = 1
                    }
                }
                ctx.exit(status)
            },

            // mktemp [-d] [-u] [-p DIR] [TEMPLATE] — create a uniquely named file
            // or directory and print its path. Names come from a small PRNG seeded
            // by the logical clock and pid: unique, deterministic, wall-clock-free.
            Command(name: "mktemp", summary: "create a temporary file or directory", category: .fileSystem,
                    usage: """
                    mktemp [-dqu] [-p DIR] [TEMPLATE]
                      -d  create a directory instead of a file
                      -u  only print a name; do not create anything
                      -p  interpret TEMPLATE relative to DIR (default $TMPDIR or /tmp)
                      -q  suppress diagnostics
                    TEMPLATE must end in at least three X's (default tmp.XXXXXXXXXX).
                    """) { ctx, argv in
                guard let parsed = ctx.options("mktemp", Array(argv.dropFirst()), "dqutp:",
                                               long: ["directory": "d", "dry-run": "u",
                                                      "tmpdir": "p", "quiet": "q"]) else { return }
                guard parsed.operands.count <= 1 else {
                    ctx.fail("mktemp: too many templates", code: 1); return
                }
                var template = parsed.operands.first ?? "tmp.XXXXXXXXXX"
                if parsed.operands.isEmpty || parsed.has("p") || parsed.has("t") {
                    let directory = parsed.value("p") ?? ctx.getenv("TMPDIR") ?? "/tmp"
                    template = ctx.join(directory, template)
                }
                let chars = Array(template)
                var placeholders = 0
                while placeholders < chars.count, chars[chars.count - 1 - placeholders] == "X" { placeholders += 1 }
                guard placeholders >= 3 else {
                    ctx.fail("mktemp: too few X's in template '\(parsed.operands.first ?? template)'", code: 1); return
                }
                let prefix = String(chars[..<(chars.count - placeholders)])
                let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                var seed = ctx.monotonicNanoseconds &* 6364136223846793005 &+ UInt64(ctx.globalPID) &+ 1442695040888963407
                for _ in 0..<128 {
                    var name = prefix
                    for _ in 0..<placeholders {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        name.append(alphabet[Int((seed >> 33) % UInt64(alphabet.count))])
                    }
                    if ctx.lstat(name) != nil { continue }
                    if !parsed.has("u") {
                        do {
                            if parsed.has("d") {
                                try ctx.makeDirectory(name)
                                _ = ctx.chmod(name, mode: FileMode(rawValue: 0o700))
                            } else {
                                ctx.close(try ctx.openFile(name, flags: [.create, .exclusive], access: .readWrite))
                                _ = ctx.chmod(name, mode: FileMode(rawValue: 0o600))
                            }
                        } catch {
                            if !parsed.has("q") {
                                let kind = parsed.has("d") ? "directory" : "file"
                                ctx.error("mktemp: failed to create \(kind) via template '\(template)': \(errnoText(error))")
                            }
                            ctx.exit(1)
                            return
                        }
                    }
                    ctx.print(name + "\n")
                    ctx.exit(0)
                    return
                }
                ctx.fail("mktemp: failed to create a unique name via template '\(template)'", code: 1)
            },

            // truncate -s [+|-]SIZE FILE... — set a file's length, extending with
            // zero bytes or cutting the tail.
            Command(name: "truncate", summary: "shrink or extend a file to a size", category: .fileSystem,
                    usage: """
                    truncate [-c] -s [+|-]SIZE[KMG] FILE...
                      -s  set the size; a leading + or - adjusts relative to the current size
                      -c  do not create files that do not exist
                    """, asyncRun: { ctx, argv in
                // `-s -5` carries a dash-led argument, so split it off by hand.
                var args = Array(argv.dropFirst())
                var sizeText: String? = nil
                var noCreate = false
                var files: [String] = []
                var index = 0
                while index < args.count {
                    let arg = args[index]
                    if arg == "-s" || arg == "--size" {
                        guard index + 1 < args.count else {
                            ctx.error("truncate: option requires an argument -- 's'")
                            ctx.fail("Try 'truncate --help' for more information.", code: 1); return
                        }
                        sizeText = args[index + 1]
                        index += 2
                    } else if arg.hasPrefix("--size=") {
                        sizeText = String(arg.dropFirst(7)); index += 1
                    } else if arg.hasPrefix("-s") {
                        sizeText = String(arg.dropFirst(2)); index += 1
                    } else if arg == "-c" || arg == "--no-create" {
                        noCreate = true; index += 1
                    } else if arg == "--" {
                        files += args[(index + 1)...]; break
                    } else if CommandArguments.isOptionToken(arg) {
                        ctx.invalidOption("truncate", arg.hasPrefix("--") ? arg : String(arg.dropFirst().prefix(1))); return
                    } else {
                        files.append(arg); index += 1
                    }
                }
                args = files
                guard var text = sizeText.map({ Substring($0) }) else {
                    ctx.error("truncate: you must specify '--size'")
                    ctx.fail("Try 'truncate --help' for more information.", code: 1); return
                }
                guard !args.isEmpty else {
                    ctx.error("truncate: missing file operand")
                    ctx.fail("Try 'truncate --help' for more information.", code: 1); return
                }
                var relative: Character? = nil
                if let sign = text.first, sign == "+" || sign == "-" { relative = sign; text = text.dropFirst() }
                guard let amount = parseSize(String(text)) else {
                    ctx.fail("truncate: Invalid number: '\(sizeText ?? "")'", code: 1); return
                }
                var status: Int32 = 0
                for path in args {
                    if ctx.stat(path) == nil, noCreate { continue }
                    do {
                        var data = ctx.stat(path) == nil ? [] : try await readOperand(ctx, path)
                        let size: Int
                        if relative == "+" { size = data.count + amount }
                        else if relative == "-" { size = max(0, data.count - amount) }
                        else { size = amount }
                        if size < data.count {
                            data.removeLast(data.count - size)
                        } else {
                            data.append(contentsOf: [UInt8](repeating: 0, count: size - data.count))
                        }
                        let fd = try ctx.openForWriting(path)
                        _ = await ctx.writeAll(fd, data)
                        ctx.close(fd)
                    } catch {
                        ctx.error("truncate: cannot open '\(path)' for writing: \(errnoText(error))")
                        status = 1
                    }
                }
                ctx.exit(status)
            }),
        ]
    }

    // MARK: - Shared pieces

    /// Parse a byte count with an optional binary suffix (`10`, `4K`, `2M`, `1G`;
    /// `KB`/`MB` are decimal, as in coreutils).
    static func parseSize(_ text: String) -> Int? {
        var digits = Substring(text)
        var multiplier = 1
        let upper = text.uppercased()
        for (suffix, value) in [("KB", 1000), ("MB", 1_000_000), ("GB", 1_000_000_000),
                                ("KIB", 1024), ("MIB", 1 << 20), ("GIB", 1 << 30),
                                ("K", 1024), ("M", 1 << 20), ("G", 1 << 30), ("B", 1)] where upper.hasSuffix(suffix) {
            multiplier = value
            digits = digits.dropLast(suffix.count)
            break
        }
        guard let value = Int(digits), value >= 0 else { return nil }
        let (product, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : product
    }

    /// The `SOURCE... DEST` operand rule shared by `cp` and `mv`: with an existing
    /// directory as the last operand everything is placed inside it; otherwise
    /// exactly two operands name a source and a destination. Reports a usage
    /// error (exit 1) and returns `nil` when the operands do not fit.
    static func splitTargets(_ ctx: ProcessContext,
                             _ command: String,
                             _ parsed: CommandOptions) -> (sources: [String], target: String, intoDirectory: Bool)? {
        let operands = parsed.operands
        guard operands.count >= 2, let target = operands.last else {
            ctx.error(operands.isEmpty ? "\(command): missing file operand"
                                       : "\(command): missing destination file operand after '\(operands[0])'")
            ctx.fail("Try '\(command) --help' for more information.", code: 1)
            return nil
        }
        let sources = Array(operands.dropLast())
        let intoDirectory = !parsed.has("T") && ctx.stat(target)?.isDirectory == true
        if sources.count > 1, !intoDirectory {
            ctx.fail("\(command): target '\(target)' is not a directory", code: 1)
            return nil
        }
        return (sources, target, intoDirectory)
    }

    static func fileTypeName(_ type: FileType) -> String {
        if type == .directory { return "directory" }
        if type == .symlink { return "symbolic link" }
        if type == .fifo { return "fifo" }
        return "regular file"
    }

    /// Parse a POSIX `touch -t` stamp, `[[CC]YY]MMDDhhmm[.ss]`, in the zone
    /// `utcOffsetSeconds` east of UTC; a missing year is `now`'s. Epoch seconds.
    static func parseTouchStamp(_ text: String, now: CalendarTime, utcOffsetSeconds: Int) -> Int64? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              [8, 10, 12].contains(parts[0].count) else { return nil }
        var second = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]), (0...59).contains(value) else { return nil }
            second = value
        }
        let digits = Array(parts[0])
        func number(_ start: Int, _ length: Int) -> Int { Int(String(digits[start..<(start + length)])) ?? 0 }
        let tail = digits.count - 8
        var year = now.year
        if tail == 4 {
            year = number(0, 4)
        } else if tail == 2 {
            let short = number(0, 2)
            year = (short >= 69 ? 1900 : 2000) + short
        }
        let month = number(tail, 2), day = number(tail + 2, 2)
        let hour = number(tail + 4, 2), minute = number(tail + 6, 2)
        guard (1...12).contains(month), (1...CalendarTime.daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return CalendarTime.epochSeconds(year: year, month: month, day: day,
                                         hour: hour, minute: minute, second: second,
                                         utcOffsetSeconds: utcOffsetSeconds)
    }

    /// Expand a `stat -c` format string.
    static func statFormat(_ ctx: ProcessContext, _ format: String, path: String, info: FileStat, inode: UInt64,
                           names: UserDatabase) -> String {
        var out = ""
        var chars = Array(format)[...]
        while let c = chars.popFirst() {
            if c == "\\", let escaped = chars.popFirst() {
                out.append(escaped == "n" ? "\n" : (escaped == "t" ? "\t" : escaped))
                continue
            }
            guard c == "%", let directive = chars.popFirst() else { out.append(c); continue }
            switch directive {
            case "n": out += path
            case "N": out += "'\(path)'"
            case "s": out += "\(info.size)"
            case "a": out += String(info.mode.rawValue & 0o7777, radix: 8)
            case "A": out += "\(typeCharacter(info.type))\(permissionString(info.mode))"
            case "u": out += "\(info.uid)"
            case "g": out += "\(info.gid)"
            case "U": out += names.userName(uid: info.uid)
            case "G": out += names.groupName(gid: info.gid)
            case "F": out += fileTypeName(info.type)
            case "h": out += "\(info.nlink)"
            case "i": out += "\(inode)"
            case "X": out += "\(Int64(info.atime.rounded(.down)))"
            case "Y": out += "\(Int64(info.mtime.rounded(.down)))"
            case "Z": out += "\(Int64(info.ctime.rounded(.down)))"
            case "x": out += ctx.statTime(info.atime)
            case "y": out += ctx.statTime(info.mtime)
            case "z": out += ctx.statTime(info.ctime)
            case "b": out += "\((info.size + 511) / 512)"
            case "%": out += "%"
            default: out += "%\(directive)"
            }
        }
        return out
    }

    /// Resolve every symbolic link in `path` and return the canonical absolute
    /// path. By default only the final component may be missing (`readlink -f`,
    /// `realpath`); `mustExist` requires all of them, `allowMissing` none.
    static func canonicalPath(_ ctx: ProcessContext, _ path: String,
                              mustExist: Bool = false, allowMissing: Bool = false) -> String? {
        var pending = ctx.absolute(path).split(separator: "/").map(String.init)[...]
        var resolved: [String] = []
        var hops = 0
        while let part = pending.popFirst() {
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let target = ctx.readlink(candidate) {
                hops += 1
                if hops > 40 { return nil }
                if target.hasPrefix("/") { resolved = [] }
                pending = (target.split(separator: "/").map(String.init) + pending)[...]
                continue
            }
            if ctx.lstat(candidate) == nil {
                if mustExist { return nil }
                if !allowMissing, !pending.isEmpty { return nil }
            }
            resolved.append(part)
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// Apply a `chmod` mode specification to `current`. Accepts an octal mode
    /// (`755`, `1777`) or comma-separated symbolic clauses
    /// (`[ugoa]*([-+=][rwxXst]*|[ugo])+`). Returns `nil` when `spec` is malformed.
    static func parseModeChange(_ spec: String, current: FileMode, isDirectory: Bool) -> FileMode? {
        if !spec.isEmpty, spec.allSatisfy({ $0 >= "0" && $0 <= "7" }) {
            guard spec.count <= 4, let bits = UInt16(spec, radix: 8) else { return nil }
            return FileMode(rawValue: bits)
        }
        var mode = current.rawValue
        for clause in spec.split(separator: ",", omittingEmptySubsequences: false) {
            var chars = Array(clause)[...]
            var who: UInt16 = 0
            while let c = chars.first, "ugoa".contains(c) {
                switch c {
                case "u": who |= 0o4700
                case "g": who |= 0o2070
                case "o": who |= 0o1007
                default:  who |= 0o7777
                }
                chars = chars.dropFirst()
            }
            let everyone = who == 0
            if everyone { who = 0o7777 }
            guard let firstOperator = chars.first, "+-=".contains(firstOperator) else { return nil }
            while let op = chars.first, "+-=".contains(op) {
                chars = chars.dropFirst()
                var bits: UInt16 = 0
                while let p = chars.first, !"+-=".contains(p) {
                    switch p {
                    case "r": bits |= 0o444
                    case "w": bits |= 0o222
                    case "x": bits |= 0o111
                    case "X": if isDirectory || mode & 0o111 != 0 { bits |= 0o111 }
                    case "s": bits |= 0o6000
                    case "t": bits |= 0o1000
                    case "u": let v = (mode >> 6) & 7; bits |= v << 6 | v << 3 | v
                    case "g": let v = (mode >> 3) & 7; bits |= v << 6 | v << 3 | v
                    case "o": let v = mode & 7; bits |= v << 6 | v << 3 | v
                    default: return nil
                    }
                    chars = chars.dropFirst()
                }
                bits &= who
                switch op {
                case "+": mode |= bits
                case "-": mode &= ~bits
                default:
                    // `=` replaces the selected classes' rwx (and their special bit).
                    let cleared = everyone ? UInt16(0o7777) : who
                    mode = (mode & ~cleared) | bits
                }
            }
            guard chars.isEmpty else { return nil }
        }
        return FileMode(rawValue: mode & 0o7777)
    }

    // MARK: - ls

    /// One row of an `ls` listing.
    private struct ListEntry {
        let name: String
        let path: String
        let info: FileStat?
    }

    private static func listCommand(_ ctx: ProcessContext, _ argv: [String]) async {
        guard let parsed = ctx.options("ls", Array(argv.dropFirst()), "alhRd1trSFiAnpUgoCx",
                                       long: ["all": "a", "almost-all": "A", "human-readable": "h",
                                              "recursive": "R", "directory": "d", "reverse": "r",
                                              "classify": "F", "inode": "i",
                                              "numeric-uid-gid": "n"]) else { return }
        let long = parsed.has("l") || parsed.has("n") || parsed.has("g") || parsed.has("o")
        let showAll = parsed.has("a")
        let showHidden = showAll || parsed.has("A")
        let names = ctx.userDatabase()
        let onePerLine = parsed.has("1") || !ctx.isATTY(1)
        let width = Int(ctx.terminalWindowSize(1)?.columns ?? 0)
        var status: Int32 = 0
        var out = ""

        func sorted(_ entries: [ListEntry]) -> [ListEntry] {
            var result = entries
            if parsed.has("t") {
                result.sort { ($0.info?.mtime ?? 0, $1.name) > ($1.info?.mtime ?? 0, $0.name) }
            } else if parsed.has("S") {
                result.sort { ($0.info?.size ?? 0, $1.name) > ($1.info?.size ?? 0, $0.name) }
            } else if !parsed.has("U") {
                result.sort { $0.name < $1.name }
            }
            if parsed.has("r") { result.reverse() }
            return result
        }

        func indicator(_ info: FileStat?) -> String {
            guard let info else { return "" }
            if info.isDirectory { return parsed.has("F") || parsed.has("p") ? "/" : "" }
            guard parsed.has("F") else { return "" }
            if info.type == .symlink { return long ? "" : "@" }
            if info.type == .fifo { return "|" }
            return info.mode.rawValue & 0o111 != 0 ? "*" : ""
        }

        func render(_ entries: [ListEntry], showTotal: Bool) {
            let inode: (ListEntry) -> String = { parsed.has("i") ? "\(ctx.inodeNumber($0.path, follow: false)) " : "" }
            guard long else {
                let labels = entries.map { inode($0) + $0.name + indicator($0.info) }
                guard !labels.isEmpty else { return }
                if onePerLine {
                    out += labels.joined(separator: "\n") + "\n"
                } else {
                    out += columnize(labels, width: width)
                }
                return
            }
            struct Row { let lead, links, user, group, size, time, name: String }
            var rows: [Row] = []
            var blocks = 0
            for entry in entries {
                guard let info = entry.info else {
                    rows.append(Row(lead: inode(entry) + "-?????????", links: "?", user: "?", group: "?",
                                    size: "?", time: "?", name: entry.name))
                    continue
                }
                blocks += (info.size + 1023) / 1024
                var shown = entry.name + indicator(info)
                if info.type == .symlink, let target = ctx.readlink(entry.path) { shown += " -> " + target }
                rows.append(Row(
                    lead: inode(entry) + "\(typeCharacter(info.type))\(permissionString(info.mode))",
                    links: "\(info.nlink)",
                    user: parsed.has("n") ? "\(info.uid)" : names.userName(uid: info.uid),
                    group: parsed.has("n") ? "\(info.gid)" : names.groupName(gid: info.gid),
                    size: parsed.has("h") ? humanSize(Int64(info.size)) : "\(info.size)",
                    time: ctx.longListingTime(info.mtime),
                    name: shown))
            }
            if showTotal { out += "total \(blocks)\n" }
            let linkWidth = rows.map(\.links.count).max() ?? 0
            let userWidth = rows.map(\.user.count).max() ?? 0
            let groupWidth = rows.map(\.group.count).max() ?? 0
            let sizeWidth = rows.map(\.size.count).max() ?? 0
            let timeWidth = rows.map(\.time.count).max() ?? 0
            for row in rows {
                var line = "\(row.lead) \(padLeft(row.links, linkWidth)) "
                if !parsed.has("g") { line += padRight(row.user, userWidth) + " " }
                if !parsed.has("o") { line += padRight(row.group, groupWidth) + " " }
                line += "\(padLeft(row.size, sizeWidth)) \(padLeft(row.time, timeWidth)) \(row.name)\n"
                out += line
            }
        }

        var needsSeparator = false
        func list(_ path: String, header: Bool) async -> Bool {
            let listing: [FileSystemDirectoryEntry]
            switch Result(catching: { try ctx.directoryEntries(path) }) {
            case let .success(entries):
                listing = entries
            case let .failure(error):
                ctx.error("ls: cannot open directory '\(path)': \(errnoText(error))")
                status = 2
                return true
            }
            var entries: [ListEntry] = []
            if showAll {
                entries.append(ListEntry(name: ".", path: path, info: ctx.stat(path)))
                entries.append(ListEntry(name: "..", path: ctx.join(path, ".."), info: ctx.stat(ctx.join(path, ".."))))
            }
            for item in listing where showHidden || !item.name.hasPrefix(".") {
                let full = ctx.join(path, item.name)
                entries.append(ListEntry(name: item.name, path: full, info: ctx.lstat(full)))
            }
            entries = sorted(entries)
            if needsSeparator { out += "\n" }
            if header { out += "\(path):\n" }
            render(entries, showTotal: true)
            needsSeparator = true
            if out.utf8.count > 16 * 1024 {
                guard await ctx.put(out) else { return false }
                out = ""
            }
            guard parsed.has("R") else { return true }
            for entry in entries where entry.info?.isDirectory == true && entry.name != "." && entry.name != ".." {
                guard await list(entry.path, header: true) else { return false }
            }
            return true
        }

        let operands = parsed.operands.isEmpty ? ["."] : parsed.operands
        var files: [ListEntry] = []
        var directories: [ListEntry] = []
        for operand in operands {
            // An operand that is a symlink is followed unless the listing is
            // about the link itself (-l, -d, -F).
            let followOperand = !(long || parsed.has("d") || parsed.has("F"))
            var info = followOperand ? ctx.stat(operand) : ctx.lstat(operand)
            if info == nil, followOperand { info = ctx.lstat(operand) }   // dangling link
            guard let info else {
                ctx.error("ls: cannot access '\(operand)': \(missingReason(ctx, operand).message)")
                status = 2
                continue
            }
            // A trailing slash asks for the directory behind a link.
            let entersDirectory = info.isDirectory
                || (operand.hasSuffix("/") && ctx.stat(operand)?.isDirectory == true)
            if entersDirectory, !parsed.has("d") {
                directories.append(ListEntry(name: operand, path: operand, info: info))
            } else {
                files.append(ListEntry(name: operand, path: operand, info: info))
            }
        }
        if !files.isEmpty {
            render(sorted(files), showTotal: false)
            needsSeparator = true
        }
        let header = operands.count > 1 || parsed.has("R")
        for directory in sorted(directories) {
            guard await list(directory.path, header: header) else { return }
        }
        await ctx.emit(out, exit: status)
    }

    private static func missingReason(_ ctx: ProcessContext, _ path: String) -> SyscallError {
        do {
            _ = try ctx.lstatOrThrow(path)
            return .inputOutput
        } catch {
            return (error as? SyscallError) ?? .noSuchFileOrDirectory
        }
    }

    /// Lay names out in columns filled top-to-bottom, as `ls` does on a terminal.
    /// With no known width (or when everything fits) the names share one line,
    /// separated by two spaces.
    static func columnize(_ names: [String], width: Int) -> String {
        let single = names.joined(separator: "  ")
        guard width > 0, single.count > width else { return single + "\n" }
        let count = names.count
        for rows in 2...max(2, count) {
            let columns = (count + rows - 1) / rows
            var widths = [Int](repeating: 0, count: columns)
            for (index, name) in names.enumerated() {
                widths[index / rows] = max(widths[index / rows], name.count)
            }
            let total = widths.reduce(0, +) + 2 * (columns - 1)
            guard total <= width || rows == count else { continue }
            var out = ""
            for row in 0..<rows {
                var line = ""
                for column in 0..<columns {
                    let index = column * rows + row
                    guard index < count else { break }
                    let last = column == columns - 1 || index + rows >= count
                    line += last ? names[index] : padRight(names[index], widths[column] + 2)
                }
                out += line + "\n"
            }
            return out
        }
        return names.joined(separator: "\n") + "\n"
    }
}

extension ProcessContext {

    /// A stable per-inode number for `ls -i` / `stat`: two paths show the same
    /// number exactly when they are hard links to one node. Derived from the
    /// node's identity, so it is consistent for the life of the kernel (it is not
    /// a persisted on-disk inode).
    func inodeNumber(_ path: String, follow: Bool) -> UInt64 {
        guard let node = lookupNode(absolute(path), follow: follow) else { return 0 }
        return UInt64(UInt(bitPattern: ObjectIdentifier(node).hashValue) >> 4) & 0xFF_FFFF
    }

    /// Whether `path` (final symlink not followed) names a device node
    /// (`/dev/zero`, a terminal, `/proc/<pid>/fd/N`). Reading one can block
    /// forever or never end, so the recursive walkers that read file contents
    /// (`grep -r`, `cp -r`, `tar c`) skip the ones they meet, like their GNU
    /// counterparts treat devices found during recursion.
    func isDeviceNode(_ path: String, follow: Bool = false) -> Bool {
        lookupNode(absolute(path), follow: follow)?.deviceKind != nil
    }
}
