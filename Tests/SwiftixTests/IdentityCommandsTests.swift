import Testing
@testable import Swiftix

/// One name service for every tool: `ls -l`, `stat`, `chown`, `find -user`,
/// `ps`, `whoami`, `su`, and the shell's own defaults all resolve users and
/// groups through `UserDatabase` (`/etc/passwd`, `/etc/group`, with the
/// synthetic `root` / `userN` fallback).
@Suite("Identity across commands")
struct IdentityCommandsTests {

    private func session(withDatabase: Bool = true) -> SystemSession {
        let session = SystemSession()
        if withDatabase {
            session.write("/etc/passwd",
                          "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:Alice:/home/alice:/bin/sh\n")
            session.write("/etc/group", "root:x:0:\nalice:x:1000:\nstaff:x:50:alice\n")
        }
        session.run("mkdir -p /root /home/alice /tmp; chmod 700 /root; chmod 1777 /tmp")
        return session
    }

    @Test func listingAndOwnershipUseNames() {
        let s = session()
        s.run("touch /tmp/f; chown alice:staff /tmp/f")
        #expect(s.lines("ls -l /tmp/f") == ["-rw-r--r-- 1 alice staff 0 Jan  1 00:00 /tmp/f"])
        #expect(s.lines("ls -ln /tmp/f") == ["-rw-r--r-- 1 1000 50 0 Jan  1 00:00 /tmp/f"])
        #expect(s.lines("stat -c '%U %G %u %g' /tmp/f") == ["alice staff 1000 50"])
        #expect(s.lines("find /tmp -user alice") == ["/tmp/f"])
        #expect(s.lines("find /tmp -user 1000") == ["/tmp/f"])
        #expect(s.lines("chown 0:0 /tmp/f; stat -c %U:%G /tmp/f") == ["root:root"])
        #expect(s.lines("chown nobody /tmp/f; echo rc=$?") == ["chown: invalid user: 'nobody'", "rc=1"])
        #expect(s.lines("chown :nogroup /tmp/f; echo rc=$?") == ["chown: invalid group: ':nogroup'", "rc=1"])
    }

    @Test func syntheticNamesApplyWithoutADatabase() {
        let s = session(withDatabase: false)
        s.run("touch /tmp/f; chown 1000:1000 /tmp/f")
        #expect(s.lines("ls -l /tmp/f") == ["-rw-r--r-- 1 user1000 user1000 0 Jan  1 00:00 /tmp/f"])
        #expect(s.lines("chown root /tmp/f; stat -c %U /tmp/f") == ["root"])
        #expect(s.lines("chown user7 /tmp/f; stat -c %u /tmp/f") == ["7"])
        #expect(s.lines("su 1000 whoami") == ["user1000"])
        #expect(s.lines("su user1000 -c 'echo $HOME'") == ["/home/user1000"])
    }

    @Test func processListingShowsUserNames() {
        let s = session()
        #expect(s.lines("su alice ps -o user=,comm=").contains("alice ps"))
        #expect(s.lines("ps -o user=,comm= | head -n 1") == ["root sh"])
    }

    @Test func suAcceptsNamesUidsAndCommandForms() {
        let s = session()
        #expect(s.lines("su alice whoami") == ["alice"])
        #expect(s.lines("su 1000 whoami") == ["alice"])
        #expect(s.lines("su alice -c 'whoami; id -Gn'") == ["alice", "alice staff"])
        #expect(s.lines("su -c whoami") == ["root"])
        #expect(s.lines("su -c 'echo $1' alice") == ["", ])
        #expect(s.lines("su 1000 ls -d /tmp") == ["/tmp"])          // options belong to the command
        s.run("touch /root/x; chmod 600 /root/x")
        #expect(s.lines("su 1000 cat /root/x; echo rc=$?") == ["cat: /root/x: Permission denied", "rc=1"])
        #expect(s.lines("su nobody; echo rc=$?") == ["su: user nobody does not exist", "rc=1"])
        #expect(s.lines("su alice -x; echo rc=$?") == [
            "su: invalid option -- '-x'",
            "su: usage: su [-] [USER] [-c COMMAND] | su USER COMMAND [ARG]...",
            "rc=2",
        ])
        #expect(s.lines("su alice nosuchcmd; echo rc=$?") == ["su: nosuchcmd: command not found", "rc=127"])
        // The exit status of the command is su's.
        #expect(s.lines("su alice -c 'exit 5'; echo rc=$?") == ["rc=5"])
    }

    @Test func suWithoutPrivilegeIsRefused() {
        let s = session()
        #expect(s.lines("su alice -c 'su root -c id'; echo rc=$?") == ["su: Authentication failure", "rc=1"])
        #expect(s.lines("su alice -c 'su'; echo rc=$?") == ["su: Authentication failure", "rc=1"])
        // Becoming yourself is always allowed.
        #expect(s.lines("su alice -c 'su alice -c whoami'") == ["alice"])
    }

    @Test func loginFormsResetTheEnvironmentAndDirectory() {
        let s = session()
        s.run("cd /tmp")
        #expect(s.lines("su alice -c 'pwd; echo $HOME $USER $LOGNAME'") == ["/tmp", "/home/alice alice alice"])
        #expect(s.lines("su - alice -c 'pwd; echo $HOME $USER $SHELL'") == ["/home/alice", "/home/alice alice /bin/sh"])
        #expect(s.lines("su -l alice -c pwd") == ["/home/alice"])
        #expect(s.lines("pwd; whoami") == ["/tmp", "root"])          // the caller is untouched
    }

    @Test func suStartsAnInteractiveShell() {
        let s = session()
        #expect(s.run("su - alice") == "alice@swiftix:~$ ")
        #expect(s.lines("whoami; pwd; id -u") == ["alice", "/home/alice", "1000"])
        #expect(s.run("cd /tmp") == "alice@swiftix:/tmp$ ")
        #expect(s.run("exit") == "root@swiftix:/# ")
        #expect(s.run("su") == "root@swiftix:/# ")
        #expect(s.lines("echo $$") != ["1"])
        s.run("exit")
        #expect(s.lines("echo $$") == ["1"])
    }

    /// A shell started for a non-root uid takes USER, HOME and its prompt from
    /// the database rather than from hard-coded `userN` names.
    @Test func shellDefaultsComeFromTheDatabase() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in
            ctx.mkdir("/home/alice")
            _ = ctx.chown("/home/alice", uid: 1000, gid: 1000)
            if let fd = ctx.open("/etc/passwd", create: true) {
                ctx.write(fd, Array("alice:x:1000:1000:Alice:/home/alice:/bin/sh\n".utf8))
                ctx.close(fd)
            }
        }
        loop.runUntilIdle()
        let pty = PseudoTerminal()
        pty.echo = false
        var shown: [UInt8] = []
        pty.onOutput = { [unowned pty] in shown += pty.readForApp(max: 65_535) }
        let shell = Programs.shell(tty: pty.slave)
        kernel.spawn("login") { ctx in
            ctx.setgid(1000)
            ctx.setuid(1000)
            shell(ctx)
        }
        loop.runUntilIdle()
        #expect(String(decoding: shown, as: UTF8.self) == "alice@swiftix:~$ ")
        shown = []
        pty.writeFromApp(Array("echo $USER $LOGNAME $HOME; pwd\n".utf8))
        loop.runUntilIdle()
        #expect(String(decoding: shown, as: UTF8.self) == "alice alice /home/alice\n/home/alice\nalice@swiftix:~$ ")
    }
}
