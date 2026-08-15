/// Extended filesystem built-ins (category .fileSystem): cp/mv/ln/readlink/
/// chmod/chown/find/basename/dirname/du/df/free/diff.
extension BuiltinCommands {

    // MARK: - Extended filesystem (category: .fileSystem)

    static func extendedFileSystem() -> [Command] {
        [
            // cp SRC DST — copy a regular file's contents.
            Command(name: "cp", summary: "copy a file", category: .fileSystem) { ctx, argv in
                guard argv.count == 3 else {
                    ctx.usage("cp", "cp <src> <dst>"); return
                }
                guard let src = ctx.open(argv[1]) else {
                    ctx.fail("cp: \(argv[1]): No such file", code: 1); return
                }
                let data = readFully(ctx, src)
                ctx.close(src)
                guard let dst = ctx.open(argv[2], create: true, truncate: true) else {
                    ctx.fail("cp: \(argv[2]): cannot create", code: 1); return
                }
                ctx.write(dst, data)
                ctx.close(dst)
                ctx.exit(0)
            },

            // mv SRC DST — move/rename a regular file. There is no `rename`
            // syscall, so this is copy-then-remove of the source.
            Command(name: "mv", summary: "move (rename) a file", category: .fileSystem) { ctx, argv in
                guard argv.count == 3 else {
                    ctx.usage("mv", "mv <src> <dst>"); return
                }
                guard let src = ctx.open(argv[1]) else {
                    ctx.fail("mv: \(argv[1]): No such file", code: 1); return
                }
                let data = readFully(ctx, src)
                ctx.close(src)
                guard let dst = ctx.open(argv[2], create: true, truncate: true) else {
                    ctx.fail("mv: \(argv[2]): cannot create", code: 1); return
                }
                ctx.write(dst, data)
                ctx.close(dst)
                _ = ctx.remove(argv[1])
                ctx.exit(0)
            },

            // ln [-s] TARGET LINK — create a hard or symbolic link. Without `-s`,
            // creates a hard link (same inode, nlink incremented); with `-s`,
            // creates a symbolic link (stored target path, resolved on lookup).
            Command(name: "ln", summary: "create a link", category: .fileSystem) { ctx, argv in
                var args = Array(argv.dropFirst())
                let symbolic = args.first == "-s"
                if symbolic { args.removeFirst() }
                guard args.count == 2 else {
                    ctx.usage("ln", "ln [-s] <target> <link>"); return
                }
                if symbolic {
                    if ctx.symlink(args[0], at: args[1]) {
                        ctx.exit(0)
                    } else {
                        ctx.error("ln: \(args[1]): cannot create symlink (already exists?)")
                        ctx.exit(1)
                    }
                } else {
                    if ctx.link(args[0], at: args[1]) {
                        ctx.exit(0)
                    } else {
                        ctx.error("ln: failed to create hard link '\(args[1])' => '\(args[0])'")
                        ctx.exit(1)
                    }
                }
            },

            // readlink LINK — print the target of a symbolic link.
            Command(name: "readlink", summary: "print a symbolic link's target", category: .fileSystem) { ctx, argv in
                guard argv.count > 1 else { ctx.usage("readlink", "readlink <link>"); return }
                guard let target = ctx.readlink(argv[1]) else {
                    ctx.fail("readlink: \(argv[1]): not a symbolic link", code: 1); return
                }
                ctx.print(target + "\n")
                ctx.exit(0)
            },

            // chmod MODE file... — set permission bits from an octal mode
            // (e.g. 644, 0600, 755). Combined with the kernel's EACCES checks,
            // this is what makes file permissions teachable (`chmod 600 secret`,
            // then a non-root user can no longer read it).
            Command(name: "chmod", summary: "change file permission bits", category: .fileSystem) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count >= 2, let bits = UInt16(args[0], radix: 8) else {
                    ctx.usage("chmod", "chmod <octal-mode> <file>..."); return
                }
                let mode = FileMode(rawValue: bits & 0o777)
                var status: Int32 = 0
                for path in args.dropFirst() where !ctx.chmod(path, mode: mode) {
                    ctx.error("chmod: \(path): No such file"); status = 1
                }
                ctx.exit(status)
            },

            // chown UID[:GID] file... — change ownership. UID/GID are numeric
            // (there is no /etc/passwd). Selects which permission triad applies to
            // a process, so it pairs with `chmod` for the permissions lesson.
            Command(name: "chown", summary: "change file ownership", category: .fileSystem) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count >= 2 else {
                    ctx.usage("chown", "chown <uid[:gid]> <file>..."); return
                }
                let spec = args[0].split(separator: ":", maxSplits: 1).map(String.init)
                guard let uid = UInt32(spec[0]) else {
                    ctx.fail("chown: \(args[0]): invalid owner"); return
                }
                // Keep the current gid when only a uid is given.
                var status: Int32 = 0
                for path in args.dropFirst() {
                    let currentGid = ctx.stat(path)?.gid ?? 0
                    let gid = spec.count > 1 ? (UInt32(spec[1]) ?? currentGid) : currentGid
                    if !ctx.chown(path, uid: uid, gid: gid) {
                        ctx.error("chown: \(path): No such file"); status = 1
                    }
                }
                ctx.exit(status)
            },

            // find [path] — print `path` and, recursively, everything under it.
            Command(name: "find", summary: "walk a directory tree", category: .fileSystem) { ctx, argv in
                let root = argv.count > 1 ? argv[1] : "."
                func walk(_ path: String) {
                    ctx.print(path + "\n")
                    guard let entries = ctx.listDirectory(path) else { return }
                    for entry in entries {
                        let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                        let child = path == "/" ? "/" + name : path + "/" + name
                        walk(child)
                    }
                }
                walk(root)
                ctx.exit(0)
            },

            // basename PATH [suffix] — strip the directory (and optional suffix).
            Command(name: "basename", summary: "strip directory from a path", category: .fileSystem) { ctx, argv in
                guard argv.count > 1 else { ctx.usage("basename", "basename <path> [suffix]"); return }
                var base = String(argv[1].split(separator: "/").last ?? "")
                if base.isEmpty { base = "/" }
                if argv.count > 2, base.hasSuffix(argv[2]), base != argv[2] {
                    base = String(base.dropLast(argv[2].count))
                }
                ctx.print(base + "\n")
                ctx.exit(0)
            },

            // dirname PATH — the directory portion of a path.
            Command(name: "dirname", summary: "strip last component from a path", category: .fileSystem) { ctx, argv in
                guard argv.count > 1 else { ctx.usage("dirname", "dirname <path>"); return }
                let parts = argv[1].split(separator: "/").map(String.init)
                if parts.count <= 1 {
                    ctx.print(argv[1].hasPrefix("/") ? "/\n" : ".\n")
                } else {
                    ctx.print((argv[1].hasPrefix("/") ? "/" : "") + parts.dropLast().joined(separator: "/") + "\n")
                }
                ctx.exit(0)
            },

            // du [-s] [-h] [-b] [path] — summarize disk usage of a directory
            // tree. Sizes are the summed bytes of regular files (directories add
            // nothing themselves). Default reports one line per directory in
            // post-order plus the total; `-s` prints only the grand total, `-h`
            // uses human units, `-b` exact bytes (default is 1K blocks).
            Command(name: "du", summary: "summarize disk usage of a tree", category: .fileSystem) { ctx, argv in
                var args = Array(argv.dropFirst())
                var summary = false, human = false, bytes = false
                while let first = args.first, CommandArguments.isOptionToken(first) {
                    for flag in first.dropFirst() {
                        switch flag {
                        case "s": summary = true
                        case "h": human = true
                        case "b": bytes = true
                        default: ctx.fail("du: unknown option -\(flag)"); return
                        }
                    }
                    args.removeFirst()
                }
                let root = args.first ?? "."
                guard ctx.stat(root) != nil else {
                    ctx.fail("du: \(root): No such file or directory", code: 1); return
                }
                func format(_ n: Int64) -> String {
                    if human { return humanBytes(n) }
                    if bytes { return "\(n)" }
                    return "\((n + 1023) / 1024)"           // default: 1K blocks, rounded up
                }
                var out = ""
                // Post-order walk: subdirectories print before their parent.
                func walk(_ path: String) -> Int64 {
                    guard let entries = ctx.listDirectory(path) else {
                        return Int64(ctx.stat(path)?.size ?? 0)   // a file argument
                    }
                    var total: Int64 = 0
                    for entry in entries {
                        let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                        let child = path == "/" ? "/" + name : path + "/" + name
                        if entry.hasSuffix("/") {
                            total += walk(child)
                        } else {
                            total += Int64(ctx.stat(child)?.size ?? 0)
                        }
                    }
                    if !summary { out += "\(format(total))\t\(path)\n" }
                    return total
                }
                let total = walk(root)
                if summary || ctx.stat(root)?.isDirectory != true {
                    out += "\(format(total))\t\(root)\n"
                }
                ctx.print(out)
                ctx.exit(0)
            },

            // df [-h] — report filesystem usage. Swiftix's filesystem is an
            // in-memory tmpfs with no fixed capacity, so the total is a synthetic
            // 64 MiB and "used" is the live sum of file bytes — enough to teach
            // the command and its columns. `-h` uses human units. Numeric columns
            // are right-aligned to match Linux df(1).
            Command(name: "df", summary: "report filesystem usage", category: .fileSystem) { ctx, argv in
                let human = argv.dropFirst().contains("-h")
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

            // free [-h] — report memory usage. There is no separate memory model;
            // the filesystem is the in-memory store, so "used" is the live sum of
            // file bytes against a synthetic 128 MiB total. Honest and synthetic,
            // enough to teach the command. `-h` uses human units. Columns are
            // right-aligned to match Linux free(1).
            Command(name: "free", summary: "report memory usage", category: .system) { ctx, argv in
                let human = argv.dropFirst().contains("-h")
                let totalBytes: Int64 = 128 * 1024 * 1024
                let usedBytes = min(totalFileBytes(ctx, under: "/"), totalBytes)
                let freeBytes = totalBytes - usedBytes
                func size(_ n: Int64) -> String { human ? humanBytes(n) : "\(n / 1024)" }
                let sTotal = size(totalBytes), sUsed = size(usedBytes), sFree = size(freeBytes)
                let w = max(sTotal.count, sFree.count, sUsed.count, 11)
                ctx.print("              \(padLeft("total", w)) \(padLeft("used", w)) \(padLeft("free", w))\n")
                ctx.print("Mem:          \(padLeft(sTotal, w)) \(padLeft(sUsed, w)) \(padLeft(sFree, w))\n")
                ctx.exit(0)
            },

            // diff FILE1 FILE2 — compare two files line by line, printing the
            // classic normal-diff edit script (`a`/`d`/`c` hunks with `<`/`>`
            // lines). Exit 0 when identical, 1 when they differ, 2 on error.
            Command(name: "diff", summary: "compare two files line by line", category: .fileSystem) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count == 2 else {
                    ctx.usage("diff", "diff <file1> <file2>"); return
                }
                guard let fd1 = ctx.open(args[0]) else {
                    ctx.fail("diff: \(args[0]): No such file or directory"); return
                }
                let data1 = readFully(ctx, fd1); ctx.close(fd1)
                guard let fd2 = ctx.open(args[1]) else {
                    ctx.fail("diff: \(args[1]): No such file or directory"); return
                }
                let data2 = readFully(ctx, fd2); ctx.close(fd2)
                let output = normalDiff(splitLines(data1), splitLines(data2))
                ctx.print(output)
                ctx.exit(output.isEmpty ? 0 : 1)
            },

            // mkfifo PATH — create a named pipe (FIFO) at PATH. Two processes
            // that open the same FIFO can communicate through it.
            Command(name: "mkfifo", summary: "create a named pipe (FIFO)", category: .fileSystem) { ctx, argv in
                guard argv.count > 1 else {
                    ctx.usage("mkfifo", "mkfifo <path>..."); return
                }
                var status: Int32 = 0
                for path in argv.dropFirst() {
                    if !ctx.mkfifo(path) {
                        ctx.error("mkfifo: \(path): cannot create fifo (already exists?)")
                        status = 1
                    }
                }
                ctx.exit(status)
            },

            // flock [-s|-x|-u] FD CMD... — advisory file locking. Opens FILE,
            // acquires the specified lock, then runs CMD with the fd held.
            // -s = shared (read), -x = exclusive (write, default), -u = unlock.
            // Without CMD, operates on FD (numeric) and exits.
            Command(name: "flock", summary: "advisory file locking", category: .fileSystem) { ctx, argv in
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
                        ctx.fail("flock: unknown option \(first)"); return
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

            // touch [-a] [-m] [-t TIME] FILE... — update timestamps. Without
            // flags, sets atime and mtime to now. -a = atime only, -m = mtime
            // only, -t TIME = use TIME (a logical clock value) instead of now.
            // Creates the file if it doesn't exist (like POSIX touch).
            Command(name: "touch", summary: "update file timestamps", category: .fileSystem) { ctx, argv in
                var args = Array(argv.dropFirst())
                var doAccess = false, doModify = false
                var explicitTime: Double? = nil
                while let first = args.first, CommandArguments.isOptionToken(first) {
                    if first == "--" { args.removeFirst(); break }
                    for flag in first.dropFirst() {
                        switch flag {
                        case "a": doAccess = true
                        case "m": doModify = true
                        case "t":
                            args.removeFirst()
                            guard let timeArg = args.first, let t = Double(timeArg) else {
                                ctx.fail("touch: -t requires a numeric time"); return
                            }
                            explicitTime = t
                        default:
                            ctx.fail("touch: unknown option -\(flag)"); return
                        }
                    }
                    args.removeFirst()
                }
                // No -a/-m means both.
                if !doAccess, !doModify { doAccess = true; doModify = true }
                guard !args.isEmpty else {
                    ctx.usage("touch", "touch [-a] [-m] [-t time] <file>..."); return
                }
                var status: Int32 = 0
                for path in args {
                    // Create the file if it doesn't exist, and close the
                    // descriptor immediately: touch must not leak one fd per path.
                    if ctx.stat(path) == nil {
                        guard let fd = ctx.open(path, create: true) else {
                            ctx.error("touch: cannot touch '\(path)'")
                            status = 1
                            continue
                        }
                        ctx.close(fd)
                    }
                    let atime: Double? = doAccess ? explicitTime : nil
                    let mtime: Double? = doModify ? explicitTime : nil
                    let updated: Bool
                    if doAccess && doModify {
                        updated = ctx.utimes(path, atime: atime, mtime: mtime)
                    } else if doAccess {
                        updated = ctx.utimes(path, atime: atime, mtime: ctx.stat(path)?.mtime)
                    } else {
                        updated = ctx.utimes(path, atime: ctx.stat(path)?.atime, mtime: mtime)
                    }
                    if !updated {
                        ctx.error("touch: cannot touch '\(path)'")
                        status = 1
                    }
                }
                ctx.exit(status)
            },
        ]
    }

}
