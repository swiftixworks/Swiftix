/// Control-group commands: the shell-facing half of the cgroups (pids controller)
/// model in `Cgroup.swift`. Together with `unshare`/`nsenter` (namespaces) they
/// let a learner demonstrate the two pillars of containers — isolation and
/// resource limiting — from a real shell:
///
///   cgcreate demo            # make /sys/fs/cgroup/demo
///   cgset demo pids.max 2    # cap the subtree at two processes
///   cgexec demo <program>    # run <program> inside the group
///   cat /sys/fs/cgroup/demo/pids.current
///   cgdelete demo            # remove the (empty) group
///
/// A process placed in `demo` and its descendants count against `pids.max`;
/// spawning past the limit returns pid 0 without allocating a process, which is
/// how a `pids.max` contains a fork bomb.
///
/// These run on the single loop-bound executor like every other command.
extension BuiltinCommands {

    static func controlGroupCommands() -> [Command] {
        [
            // cgcreate GROUP — create a cgroup (and any missing parents).
            Command(name: "cgcreate", summary: "create a cgroup", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard let group = args.first else {
                    ctx.usage("cgcreate", "cgcreate <group>"); return
                }
                if ctx.createCgroup(group) {
                    ctx.exit(0)
                } else {
                    ctx.fail("cgcreate: cannot create cgroup '\(group)'", code: 1)
                }
            },

            // cgset GROUP pids.max N — set the subtree process limit (N or "max").
            Command(name: "cgset", summary: "set a cgroup limit (pids.max)", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count == 3, args[1] == "pids.max" else {
                    ctx.usage("cgset", "cgset <group> pids.max <N|max>"); return
                }
                let group = args[0]
                let raw = args[2]
                let limit: Int?
                if raw == "max" {
                    limit = nil
                } else if let parsed = Int(raw), parsed >= 0 {
                    limit = parsed
                } else {
                    ctx.error("cgset: invalid value '\(raw)' (expected a non-negative integer or 'max')")
                    ctx.exit(2); return
                }
                if ctx.setCgroupPidsMax(group, limit) {
                    ctx.exit(0)
                } else {
                    ctx.fail("cgset: cgroup '\(group)' does not exist", code: 1)
                }
            },

            // cgdelete GROUP — remove an empty leaf cgroup.
            Command(name: "cgdelete", summary: "remove an empty cgroup", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard let group = args.first else {
                    ctx.usage("cgdelete", "cgdelete <group>"); return
                }
                if ctx.removeCgroup(group) {
                    ctx.exit(0)
                } else {
                    ctx.error("cgdelete: cannot remove cgroup '\(group)' (not empty, has children, or is root)")
                    ctx.exit(1)
                }
            },

            // cgexec GROUP CMD [args...] — run CMD inside GROUP. The child joins the
            // group before its body runs; if the group is already full it reports
            // the limit and exits without running.
            Command(name: "cgexec", summary: "run a command in a cgroup", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count >= 2 else {
                    ctx.usage("cgexec", "cgexec <group> <command> [args...]"); return
                }
                let group = args[0]
                let commandArgs = Array(args.dropFirst())
                guard ctx.cgroupPidsCurrent(group) != nil else {
                    ctx.fail("cgexec: cgroup '\(group)' does not exist", code: 1); return
                }
                guard let command = ctx.resolveCommand(commandArgs[0]) else {
                    ctx.fail("cgexec: \(commandArgs[0]): command not found", code: 127); return
                }
                // Existing-process migration is allowed above pids.max; the
                // limit applies when the child subsequently spawns.
                func placeIntoGroup(_ child: ProcessContext) -> Bool {
                    if child.joinCgroup(group) { return true }
                    child.error("cgexec: cgroup '\(group)' does not exist")
                    child.exit(1)
                    return false
                }
                switch command.body {
                case let .sync(body):
                    let wrapped = Command(name: command.name, summary: command.summary, category: command.category) { child, childArgs in
                        if placeIntoGroup(child) { body(child, childArgs) }
                    }
                    ctx.run(wrapped, args: commandArgs)
                case let .async(body):
                    ctx.spawn(commandArgs[0], args: commandArgs) { (child: ProcessContext) async in
                        if placeIntoGroup(child) { await body(child, commandArgs) }
                    }
                }
                ctx.wait { result in
                    switch result {
                    case .success(let event): ctx.exit(event.status.code)
                    case .failure: ctx.exit(1)
                    }
                }
            },
        ]
    }
}
