import Testing
@testable import Swiftix

/// Name service: `/etc/passwd` + `/etc/group` parsing with the synthetic
/// fallback, and the commands built on it (`id`, `groups`, `logname`, `who`, `w`).
@Suite("User and group database")
struct UserDatabaseTests {

    static let passwd = """
        # comment line
        root:x:0:0:Super User:/root:/bin/sh
        alice:x:1000:1000:Alice Example:/home/alice:/bin/sh
        bob:x:1001:100::/home/bob:/bin/false
        broken:x:notanumber:5::/:/bin/sh
        short:x:7
        alice:x:4242:4242:duplicate name loses:/tmp:/bin/sh

        """

    static let group = """
        root:x:0:
        users:x:100:alice
        alice:x:1000:
        wheel:x:10:alice,bob
        audio:x:29:bob
        bad:x:x:alice

        """

    static var database: UserDatabase { UserDatabase(passwd: passwd, group: group) }

    // MARK: - Parsing and lookup

    @Test func parsesRecordsAndSkipsMalformedOnes() {
        let database = Self.database
        #expect(database.users.map(\.name) == ["root", "alice", "bob", "alice"])
        #expect(database.user(named: "alice") == UserDatabase.User(
            name: "alice", uid: 1000, gid: 1000, gecos: "Alice Example",
            home: "/home/alice", shell: "/bin/sh"))
        #expect(database.user(named: "bob")?.shell == "/bin/false")
        #expect(database.user(named: "broken") == nil)
        #expect(database.groups.map(\.name) == ["root", "users", "alice", "wheel", "audio"])
        #expect(database.group(named: "wheel")?.members == ["alice", "bob"])
    }

    @Test func mapsBothDirectionsAndListsSupplementaryGroups() {
        let database = Self.database
        #expect(database.userName(uid: 1001) == "bob")
        #expect(database.groupName(gid: 10) == "wheel")
        #expect(database.resolveUser("alice")?.uid == 1000)
        #expect(database.resolveUser("1001")?.name == "bob")
        #expect(database.resolveGroupID("audio") == 29)
        #expect(database.resolveGroupID("77") == 77)
        #expect(database.resolveGroupID("nope") == nil)
        #expect(database.groupIDs(for: database.user(named: "alice")!) == [1000, 10, 100])
        #expect(database.groupIDs(for: database.user(named: "bob")!) == [100, 10, 29])
    }

    @Test func fallsBackToSyntheticIdentitiesWhenUnlisted() {
        let empty = UserDatabase()
        #expect(empty.userName(uid: 0) == "root")
        #expect(empty.userName(uid: 1000) == "user1000")
        #expect(empty.groupName(gid: 1000) == "user1000")
        #expect(empty.user(named: "user1000") == UserDatabase.User(
            name: "user1000", uid: 1000, gid: 1000, gecos: "", home: "/home/user1000", shell: "/bin/sh"))
        #expect(empty.user(named: "root")?.home == "/root")
        #expect(empty.user(named: "alice") == nil)
        #expect(empty.user(named: "user0") == nil)
        #expect(empty.user(named: "user007") == nil)
        #expect(empty.resolveUser("42")?.name == "user42")

        // A listed user owns its uid: the synthetic alias for it disappears.
        let database = Self.database
        #expect(database.userName(uid: 2000) == "user2000")
        #expect(database.user(named: "user1000") == nil)
        #expect(database.user(named: "user2000")?.uid == 2000)
    }

    @Test func processReadsDatabaseFromItsFilesystem() {
        let session = SystemSession()
        #expect(session.inProcess { $0.userDatabase() } == UserDatabase())
        #expect(session.inProcess { $0.userName } == "root")
        session.write("/etc/passwd", "admin:x:0:0::/root:/bin/sh\ncarol:x:1500:1500::/home/carol:/bin/sh\n")
        #expect(session.inProcess { $0.userName } == "admin")
        #expect(session.inProcess { $0.userDatabase().userName(uid: 1500) } == "carol")
    }

    // MARK: - Switching user

    @Test func switchUserInstallsCredentialsAndLoginEnvironment() {
        struct Result: Equatable {
            var ok = false, uid: UInt32 = 0, gid: UInt32 = 0, groups: [UInt32] = []
            var home = "", user = "", logname = "", shell = "", cwd = "", regain = true
        }
        let session = SystemSession()
        session.write("/etc/passwd", Self.passwd)
        session.write("/etc/group", Self.group)
        session.run("mkdir -p /home/alice")
        let result = session.inProcess { ctx -> Result in
            var result = Result()
            let database = ctx.userDatabase()
            guard let alice = database.resolveUser("alice") else { return result }
            result.ok = ctx.switchUser(to: alice, database: database, login: true)
            result.uid = ctx.getuid()
            result.gid = ctx.getgid()
            result.groups = ctx.getgroups()
            result.home = ctx.getenv("HOME") ?? ""
            result.user = ctx.getenv("USER") ?? ""
            result.logname = ctx.getenv("LOGNAME") ?? ""
            result.shell = ctx.getenv("SHELL") ?? ""
            result.cwd = ctx.currentDirectory
            result.regain = ctx.switchUser(to: database.user(uid: 0))
            return result
        }
        #expect(result == Result(ok: true, uid: 1000, gid: 1000, groups: [10, 100],
                                 home: "/home/alice", user: "alice", logname: "alice",
                                 shell: "/bin/sh", cwd: "/home/alice", regain: false))
    }

    @Test func switchUserWithoutLoginLeavesEnvironmentAlone() {
        let session = SystemSession()
        let result = session.inProcess { ctx -> [String] in
            ctx.setenv("HOME", "/keep")
            let ok = ctx.switchUser(to: ctx.userDatabase().user(uid: 1234))
            return ["\(ok)", "\(ctx.getuid())", "\(ctx.getgid())", ctx.getenv("HOME") ?? "", ctx.currentDirectory]
        }
        #expect(result == ["true", "1234", "1234", "/keep", "/"])
    }

    // MARK: - Commands

    @Test func idReportsSyntheticRootWithoutDatabase() {
        let session = SystemSession()
        #expect(session.lines("id") == ["uid=0(root) gid=0(root) groups=0(root)"])
        #expect(session.lines("id -u") == ["0"])
        #expect(session.lines("id -un") == ["root"])
        #expect(session.lines("id 1000") == ["uid=1000(user1000) gid=1000(user1000) groups=1000(user1000)"])
        #expect(session.lines("groups") == ["root"])
    }

    @Test func idAndGroupsUseTheDatabase() {
        let session = SystemSession()
        session.write("/etc/passwd", Self.passwd)
        session.write("/etc/group", Self.group)
        #expect(session.lines("id alice") == ["uid=1000(alice) gid=1000(alice) groups=1000(alice),10(wheel),100(users)"])
        #expect(session.lines("id -G bob") == ["100 10 29"])
        #expect(session.lines("id -Gn bob") == ["users wheel audio"])
        #expect(session.lines("id -g -n bob") == ["users"])
        #expect(session.lines("id -u alice") == ["1000"])
        #expect(session.lines("groups alice") == ["alice : alice wheel users"])
        #expect(session.run("id nobody").contains("id: 'nobody': no such user"))
        #expect(session.run("id -n").contains("cannot print only names"))
        #expect(session.run("id -ug").contains("more than one choice"))
        #expect(session.lines("id zed; echo rc=$?").last == "rc=1")
    }

    /// `id` with no operand reports the *live* credentials of the process,
    /// including supplementary groups installed by `setgroups`.
    @Test func idReflectsLiveCredentialsAfterDroppingPrivileges() {
        let session = SystemSession(register: { registry in
            registry.register(Command(name: "asalice", summary: "run id as alice") { ctx, _ in
                let database = ctx.userDatabase()
                ctx.switchUser(to: database.resolveUser("alice")!, database: database)
                if let id = ctx.resolveCommand("id") { ctx.run(id, args: ["id"]) }
                ctx.wait { _ in ctx.exit(0) }
            })
        })
        session.write("/etc/passwd", Self.passwd)
        session.write("/etc/group", Self.group)
        #expect(session.lines("asalice") == ["uid=1000(alice) gid=1000(alice) groups=1000(alice),10(wheel),100(users)"])
    }

    @Test func lognameAndWhoDescribeTheTerminalSession() {
        let session = SystemSession(configure: { $0.setWallClock(epochSeconds: 1_791_376_496) })
        session.write("/etc/passwd", Self.passwd)
        #expect(session.lines("logname") == ["root"])
        #expect(session.lines("who") == ["root     pts/0        2026-10-07 12:34"])
        let w = session.lines("w")
        #expect(w.count == 3)
        #expect(w[0] == " 12:34:56 up 0:00,  1 user")
        #expect(w[1] == "USER     TTY      LOGIN@           WHAT")
        #expect(w[2] == "root     pts/0    2026-10-07 12:34 w")
    }

    /// With no terminal session at all, `who` still names the caller.
    @Test func whoFallsBackToTheCallerWithoutATerminal() {
        final class Capture { var out: [UInt8] = [] }
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let captured = Capture()
        let registry = CommandRegistry.builtins
        kernel.spawn("launcher") { ctx in
            ctx.installCommands(registry)
            for _ in 0..<3 { _ = ctx.open("/dev/null") }   // occupy fds 0/1/2
            let pipe = ctx.pipe()
            ctx.spawn("who") { child in
                child.dup2(pipe.write, onto: 1)
                child.close(pipe.write)
                child.close(pipe.read)
                if case let .sync(body)? = child.resolveCommand("who")?.body { body(child, ["who"]) }
            }
            ctx.close(pipe.write)
            ctx.wait { _ in
                captured.out = ctx.read(pipe.read, max: 4096)
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()
        #expect(String(decoding: captured.out, as: UTF8.self) == "root     ?            1970-01-01 00:00\n")
    }
}
