import Testing
@testable import Swiftix

/// End-to-end regression list for the userland baseline: one kernel booted the
/// way a host app boots it (built-in commands, loopback, `/etc/passwd` and
/// `/etc/group`, an injected wall clock, a shell on a PTY) and the everyday
/// command lines that were broken or missing in v0.12.0, each asserted on its
/// exact terminal output.
///
/// Logical time only: nothing here advances the clock, so every timestamp is
/// the injected instant, 2026-10-07 12:34:56 UTC.
@Suite("Userland baseline (end to end)")
struct UserlandBaselineTests {

    private static let script = """
        #!/bin/sh
        # exercises the POSIX shell subset a script relies on
        greet() {
            local who="$1"
            [ -z "$who" ] && return 1
            echo "hello $who"
            return 0
        }
        if [ $# -eq 2 ]; then echo "argc=$#"; else echo "bad"; fi
        for a in "$@"; do
            case $a in
                a) greet "$a" ;;
                *) echo "other $a" ;;
            esac
        done
        n=0
        while read line; do
            n=$((n + 1))
        done < /etc/passwd
        echo "lines=$n"
        unset missing
        echo "default=${missing:-d} sub=$(echo inner)"
        greet "" || echo "greet failed $?"
        exit 7

        """

    /// Loopback whose egress feeds its own ingress, and the injected clock.
    private static func configure(_ kernel: Kernel) {
        kernel.setWallClock(epochSeconds: 1_791_376_496)       // 2026-10-07 12:34:56 UTC
        let loop = kernel.loop
        kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(127, 0, 0, 1),
            mac: MACAddress("00:00:00:00:00:00")!,
            prefixLength: 8)))
        let lo = kernel.netns.stack.interface(at: 0)!
        lo.onEgress = { [weak kernel, weak lo] frame in
            guard let kernel, let lo else { return }
            loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: lo) }
        }
    }

    private static let passwd = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:Alice:/home/alice:/bin/sh\n"
    private static let group = "root:x:0:\nalice:x:1000:\nstaff:x:50:alice\n"

    /// A session whose shell is PID 1, with the system files in place and
    /// `/tmp` as the working directory.
    private func boot() -> SystemSession {
        let session = SystemSession(configure: Self.configure)
        session.write("/etc/passwd", Self.passwd)
        session.write("/etc/group", Self.group)
        session.write("/etc/hosts", "127.0.0.1 localhost\n")
        session.run("mkdir -p /tmp /root /home/alice /srv")
        session.run("chmod 700 /root; chmod 1777 /tmp; chown alice:alice /home/alice")
        session.write("/tmp/x.sh", Self.script)
        session.run("cd /tmp")
        return session
    }

    // MARK: - Text and pipelines

    @Test func pipelinesAndTextFilters() {
        let s = boot()
        #expect(s.lines("ls /etc | wc -l") == ["3"])
        #expect(s.lines("printf '3\\n10\\n2\\n' | sort -rn") == ["10", "3", "2"])
        #expect(s.lines("printf 'a\\na\\nb\\n' | uniq -c") == ["      2 a", "      1 b"])
        #expect(s.lines("printf '%5d|%-5s|%x\\n' 42 ab 255") == ["   42|ab   |ff"])
        #expect(s.run("echo -n no-newline") == "no-newlineroot@swiftix:/tmp# ")
        #expect(s.lines("cat <<< x") == ["x"])
        s.run("printf 'one\\ntwo\\nthree\\n' > n.txt")
        #expect(s.lines("sed -n 2p n.txt") == ["two"])
        #expect(s.lines("grep -rn two /tmp") == ["/tmp/n.txt:2:two"])
        #expect(s.lines("cut -d: -f1 /etc/passwd") == ["root", "alice"])
        #expect(s.lines("head -c 4 /dev/zero | od") == ["0000000 000000 000000", "0000004"])
    }

    @Test func awkRunsTheUsualOneLiners() {
        let s = boot()
        s.run("printf 'a 1\\nb 2\\nc 3\\nd 4\\n' > t.txt")
        #expect(s.lines("awk '{print $2}' t.txt") == ["1", "2", "3", "4"])
        #expect(s.lines("awk -F: '{print $1}' /etc/passwd") == ["root", "alice"])
        #expect(s.lines("awk '{s+=$2} END {print s}' t.txt") == ["10"])
        #expect(s.lines("awk 'NR%2==0' t.txt") == ["b 2", "d 4"])
        #expect(s.lines("awk '/[bc]/ {n++} END {print n+0}' t.txt") == ["2"])
        #expect(s.lines("awk 'BEGIN{printf \"%5.2f\\n\", 3.14159}'") == [" 3.14"])
        #expect(s.lines("cat t.txt | awk '{ print $1 | \"sort -r\" }' | head -n 1") == ["d"])
    }

    // MARK: - Files

    @Test func fileListingAndTreeTools() {
        let s = boot()
        s.run("echo hi > f.txt; ln -s f.txt l")
        #expect(s.lines("ls -l f.txt") == ["-rw-r--r-- 1 root root 3 Oct  7 12:34 f.txt"])
        #expect(s.lines("ls -l l") == ["lrwxrwxrwx 1 root root 5 Oct  7 12:34 l -> f.txt"])
        s.run("mkdir -p d/e; touch d/e/g.txt d/h.log")
        #expect(s.lines("find /tmp -name '*.txt'") == ["/tmp/d/e/g.txt", "/tmp/f.txt"])
        #expect(s.lines("cp -r d d2; find d2") == ["d2", "d2/e", "d2/e/g.txt", "d2/h.log"])
        #expect(s.lines("rm -rf d d2; ls") == ["f.txt  l  x.sh"])
        #expect(s.lines("chmod u+x f.txt; ls -l f.txt") == ["-rwxr--r-- 1 root root 3 Oct  7 12:34 f.txt"])
        #expect(s.lines("cat /proc/self/status | head -n 2") == ["Name:\tcat", "State:\tS (sleeping)"])
    }

    // MARK: - Shell language

    @Test func shellLanguageAndScripts() {
        let s = boot()
        #expect(s.lines("echo $$") == ["1"])
        #expect(s.lines("( cd /; pwd ); pwd") == ["/", "/tmp"])
        #expect(s.lines("echo ~ {a,b}") == ["/root a b"])
        #expect(s.lines("sh -c 'echo from-sh $0 $1' zero one") == ["from-sh zero one"])
        s.run("chmod u+x x.sh")
        #expect(s.lines("./x.sh a b; echo rc=$?") == [
            "argc=2", "hello a", "other b", "lines=2", "default=d sub=inner", "greet failed 1", "rc=7",
        ])
    }

    @Test func jobsAndKill() {
        let s = boot()
        let started = s.lines("sleep 1 & jobs")
        #expect(started.count == 2)
        #expect(started.first?.hasPrefix("[1] ") == true)
        #expect(started.first.flatMap { Int($0.dropFirst(4)) } != nil)
        #expect(started.last == "[1] Running\tsleep 1")
        #expect(s.lines("kill %1") == ["[1]+ Done\tsleep 1"])
        #expect(s.lines("jobs") == [])
        #expect(s.lines("kill %1; echo rc=$?") == ["kill: %1: no such job", "rc=1"])
    }

    // MARK: - Time and identity

    @Test func clockAndIdentity() {
        let s = boot()
        #expect(s.lines("date +%Y") == ["2026"])
        #expect(s.lines("date") == ["Wed Oct  7 12:34:56 UTC 2026"])
        #expect(s.lines("id") == ["uid=0(root) gid=0(root) groups=0(root)"])
        #expect(s.lines("whoami") == ["root"])
        #expect(s.lines("su alice -c whoami") == ["alice"])
        #expect(s.lines("su alice -c id") == ["uid=1000(alice) gid=1000(alice) groups=1000(alice),50(staff)"])
        #expect(s.lines("su 1000 ls /root; echo rc=$?")
                == ["ls: cannot open directory '/root': Permission denied", "rc=2"])
    }

    // MARK: - Network

    @Test func networkToolsOverLoopback() {
        let s = boot()
        #expect(s.lines("ip addr") == [
            "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN",
            "    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00",
            "    inet 127.0.0.1/8 scope host lo",
            "       valid_lft forever preferred_lft forever",
        ])
        #expect(s.lines("ping -c1 localhost") == [
            "PING localhost (127.0.0.1) 56(84) bytes of data.",
            "64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.000 ms",
            "",
            "--- localhost ping statistics ---",
            "1 packets transmitted, 1 received, 0.0% packet loss, time 0ms",
            "rtt min/avg/max/mdev = 0.000/0.000/0.000/0.000 ms",
        ])
        s.run("echo '<h1>hi</h1>' > /srv/index.html")
        #expect(s.run("httpd -p 8080 /srv &").contains("httpd: serving /srv on 8080\n"))
        // HTTP header lines end in CRLF.
        #expect(s.run("curl -sI http://localhost:8080/index.html")
                == "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
                + "root@swiftix:/tmp# ")
        #expect(s.lines("curl -s http://127.0.0.1:8080/index.html") == ["<h1>hi</h1>"])
        #expect(s.lines("ss -tln") == [
            "Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port",
            "tcp   LISTEN 0      0            0.0.0.0:8080         0.0.0.0:*",
        ])
    }

    // MARK: - The session itself

    @Test func initIsProtectedFromItsOwnKill() {
        let s = boot()
        #expect(s.shellPID == 1)
        #expect(s.lines("kill -9 1; echo alive") == ["alive"])
        #expect(s.shellIsAlive)
    }

    /// `exit 3` ends the shell process with status 3, observed the way a
    /// parent observes it: through `wait`.
    @Test func exitEndsTheShellWithItsStatus() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        pty.echo = false
        var output: [UInt8] = []
        pty.onOutput = { [unowned pty] in output += pty.readForApp(max: 65_535) }
        let status = ResultBox<ProcessWaitStatus>()
        let shell = Programs.shell(tty: pty.slave)
        kernel.spawn("init") { ctx in
            ctx.spawn("sh", args: ["sh"]) { child in shell(child) }
            ctx.wait { result in
                if case let .success(event) = result { status.value = event.status }
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()
        #expect(status.value == nil)
        pty.writeFromApp(Array("echo still-here; exit 3\n".utf8))
        loop.runUntilIdle()
        #expect(String(decoding: output, as: UTF8.self).contains("still-here\n"))
        #expect(status.value == .exited(3))
        #expect(!kernel.snapshotProcesses().contains { $0.name == "sh" })
    }
}
