/// Mount commands: the shell-facing half of the mount-namespace model in
/// `Mount.swift`. Together with `unshare -m` they let a learner demonstrate the
/// last container pillar — an isolated view of *what is mounted where*:
///
///   mkdir /mnt
///   mount -t tmpfs tmpfs /mnt      # a private, empty filesystem at /mnt
///   echo hi > /mnt/f ; ls /mnt
///   mount                          # list the current mount table
///   umount /mnt
///   mount --bind /etc /mnt         # /mnt now mirrors /etc (same files)
///   unshare -m sh-script           # mounts inside stay invisible to the parent
///
/// Only tmpfs and bind mounts are modeled (no on-disk filesystem types yet). These
/// run on the single loop-bound executor like every other command.
extension BuiltinCommands {

    static func mountCommands() -> [Command] {
        [
            // mount — with no arguments, list the caller's mount table; otherwise
            // `mount -t tmpfs <src> <dir>` or `mount --bind <src> <dir>` (also
            // `mount -o bind …`).
            Command(name: "mount", summary: "mount a filesystem, or list mounts", category: .fileSystem) { ctx, argv in
                let args = Array(argv.dropFirst())
                if args.isEmpty {
                    for row in ctx.mountTable() {
                        ctx.print("\(row.source) on \(row.mountpoint) type \(row.type)\n")
                    }
                    ctx.exit(0)
                    return
                }
                func usage() {
                    ctx.usage("mount", "mount [-t tmpfs|--bind] <source> <dir>")
                }
                var type: String?
                var bind = false
                var positional: [String] = []
                var index = 0
                while index < args.count {
                    switch args[index] {
                    case "-t":
                        index += 1
                        guard index < args.count else { usage(); return }
                        type = args[index]
                    case "--bind":
                        bind = true
                    case "-o":
                        index += 1
                        guard index < args.count else { usage(); return }
                        if args[index] == "bind" { bind = true }
                    default:
                        positional.append(args[index])
                    }
                    index += 1
                }
                guard positional.count == 2 else { usage(); return }
                let source = positional[0], mountpoint = positional[1]
                let ok: Bool
                if bind {
                    ok = ctx.mountBind(source: source, at: mountpoint)
                } else if type == "tmpfs" {
                    ok = ctx.mountTmpfs(at: mountpoint)
                } else {
                    ctx.fail("mount: unsupported type '\(type ?? "?")' (only tmpfs and --bind are modeled)")
                    return
                }
                if ok {
                    ctx.exit(0)
                } else {
                    ctx.error("mount: cannot mount at '\(mountpoint)' (source/mountpoint must be existing directories, and not the root)")
                    ctx.exit(1)
                }
            },

            // umount MOUNTPOINT — detach the filesystem mounted there.
            Command(name: "umount", summary: "unmount a filesystem", category: .fileSystem) { ctx, argv in
                guard argv.count > 1 else {
                    ctx.usage("umount", "umount <mountpoint>"); return
                }
                if ctx.unmount(argv[1]) {
                    ctx.exit(0)
                } else {
                    ctx.fail("umount: \(argv[1]): not mounted", code: 1)
                }
            },
        ]
    }
}
