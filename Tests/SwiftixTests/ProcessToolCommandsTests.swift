import Testing
@testable import Swiftix

/// Process and system tools (ps/kill/pgrep/pkill/killall/pidof/env/printenv/
/// time/watch/xargs/timeout/which/nproc/sync) and the cross-cutting command
/// conventions: `--help`, unknown-option diagnostics, and `man`.
@Suite("Process tools and command conventions")
struct ProcessToolCommandsTests {

    // MARK: - ps

    @Test func psDefaultColumns() {
        let h = CommandHarness()
        let out = h.stdout("ps")
        let lines = out.split(separator: "\n")
        #expect(lines.first?.split(separator: " ").map(String.init) == ["PID", "PPID", "STAT", "COMMAND"])
        #expect(out.contains(" ps\n"))
        #expect(!out.contains("aux"))
    }

    @Test func psAuxAndFullFormatsHonorTheOptions() {
        let h = CommandHarness()
        for invocation in ["ps aux", "ps -ef", "ps -f", "ps -e -f", "ps axu"] {
            let out = h.stdout(invocation)
            let header = out.split(separator: "\n").first?.split(separator: " ").map(String.init)
            #expect(header == ["USER", "PID", "PPID", "STAT", "TIME", "COMMAND"], "\(invocation)")
            #expect(out.contains("root"), "\(invocation)")
            // The arguments are honored, not echoed back as a command name only.
            #expect(out.split(separator: "\n").contains { $0.hasSuffix(invocation) }, "\(invocation)")
            #expect(out.contains("0:00"), "\(invocation)")
        }
        #expect(h.stdout("ps -e").hasPrefix("PID") || h.stdout("ps -e").contains("PID"))
    }

    @Test func psCustomColumnsAndFilters() {
        let h = CommandHarness()
        let out = h.stdout("ps -o pid,comm")
        #expect(out.split(separator: "\n").first?.split(separator: " ").map(String.init) == ["PID", "COMMAND"])
        #expect(out.contains(" sh\n"))
        #expect(h.stdout("ps -o pid= -p 1") == "1\n")
        #expect(h.stdout("ps -p 1 -o comm=") == "sh\n")
        #expect(h.stdout("ps -o user=,uid= -p 1") == "root 0\n")
        #expect(h.stdout("ps -o comm=LABEL -p 1") == "LABEL\nsh\n")
        #expect(h.status("ps -p 99999") == 1)
        #expect(h.console("ps -o bogus").contains("ps: unknown user-defined format specifier \"bogus\""))
        #expect(h.console("ps -Z").contains("ps: invalid option -- 'Z'"))
        #expect(h.stdout("ps --no-headers -p 1 -o pid") == "1\n")
        #expect(h.stdout("ps -u 0 -o uid=").split(separator: "\n").allSatisfy { $0 == "0" })
    }

    @Test func psShowsTheOwnerOfADroppedPrivilegeProcess() {
        let h = CommandHarness()
        h.write("/etc/passwd", "root:x:0:0::/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n")
        let out = h.stdout("su 1000 ps -o user=,comm=")
        #expect(out.contains("alice ps"))
        #expect(out.contains("root  sh"))
    }

    // MARK: - kill and friends

    @Test func killListsAndConvertsSignals() {
        let h = CommandHarness()
        let table = h.stdout("kill -l")
        #expect(table.contains(" 1) SIGHUP"))
        #expect(table.contains(" 9) SIGKILL"))
        #expect(table.contains("15) SIGTERM"))
        #expect(h.stdout("kill -l 15") == "TERM\n")
        #expect(h.stdout("kill -l TERM") == "15\n")
        #expect(h.stdout("kill -l SIGKILL") == "9\n")
        #expect(h.stdout("kill -l 137") == "KILL\n")
        #expect(h.status("kill -l NOPE") == 1)
    }

    /// Start a background sleeper and return its pid.
    private func sleeper(_ h: CommandHarness, _ seconds: Int = 1000) -> String {
        h.run("sleep \(seconds) &")
        return String(h.stdout("pgrep -n sleep").dropLast())
    }

    @Test func killSignalForms() {
        for form in ["-s TERM", "-s SIGTERM", "-s 15", "-SIGTERM", "-TERM", "-15", "-n 15", "-KILL", "-9", "-s kill", ""] {
            let h = CommandHarness()
            let pid = sleeper(h)
            #expect(!pid.isEmpty, "\(form)")
            #expect(h.status("kill \(form) \(pid)") == 0, "\(form)")
            #expect(h.status("pgrep sleep") == 1, "kill \(form) should end the process")
        }
    }

    @Test func killReportsBadTargetsAndSignals() {
        let h = CommandHarness()
        #expect(h.console("kill 99999").contains("kill: (99999) - No such process"))
        #expect(h.status("kill 99999") == 1)
        #expect(h.console("kill -NOSUCH 1").contains("kill: NOSUCH: invalid signal specification"))
        #expect(h.console("kill abc").contains("kill: abc: arguments must be process or job IDs"))
        #expect(h.status("kill -0 1") == 0)
        #expect(h.status("kill -0 99999") == 1)
        #expect(h.status("kill") == 2)
    }

    @Test func pgrepPkillKillallPidof() {
        let h = CommandHarness()
        h.run("sleep 500 &")
        h.run("sleep 600 &")
        let pids = h.stdout("pgrep sleep").split(separator: "\n").map(String.init)
        #expect(pids.count == 2)
        #expect(h.stdout("pgrep -l sleep") == pids.map { "\($0) sleep\n" }.joined())
        #expect(h.stdout("pgrep -f 'sleep 600'") == "\(pids[1])\n")
        #expect(h.stdout("pgrep -lf 600") == "\(pids[1]) sleep 600\n")
        #expect(h.stdout("pgrep -c sleep") == "2\n")
        #expect(h.stdout("pgrep -x slee") == "")
        #expect(h.status("pgrep nosuchprocess") == 1)
        #expect(h.stdout("pgrep -o sleep") == "\(pids[0])\n")
        #expect(h.stdout("pidof sleep") == "\(pids[1]) \(pids[0])\n")
        #expect(h.stdout("pidof -s sleep") == "\(pids[1])\n")
        #expect(h.status("pidof nosuchprocess") == 1)

        #expect(h.status("pkill -f 'sleep 600'") == 0)
        #expect(h.stdout("pgrep sleep") == "\(pids[0])\n")
        #expect(h.status("pkill nosuchprocess") == 1)
        #expect(h.status("killall -KILL sleep") == 0)
        #expect(h.status("pgrep sleep") == 1)
        #expect(h.console("killall sleep").contains("sleep: no process found"))
        #expect(h.status("killall -q sleep") == 1)
        h.run("sleep 700 &")
        #expect(h.status("pkill -9 sleep") == 0)
        #expect(h.status("pgrep sleep") == 1)
        h.run("sleep 800 &")
        #expect(h.status("killall -s TERM sleep") == 0)
        #expect(h.status("pidof sleep") == 1)
    }

    // MARK: - env / printenv

    @Test func envIgnoreAndUnset() {
        let h = CommandHarness()
        h.run("export KEEP=1 DROP=2")
        #expect(h.stdout("env -i") == "")
        #expect(h.stdout("env -i A=1 B=2") == "A=1\nB=2\n")
        #expect(h.stdout("env -i X=y printenv X") == "y\n")
        #expect(h.stdout("env - X=y env") == "X=y\n")
        #expect(h.stdout("env -u DROP printenv KEEP") == "1\n")
        #expect(h.status("env -u DROP printenv DROP") == 1)
        #expect(h.stdout("env -u DROP -u KEEP Z=9 printenv Z") == "9\n")
        #expect(h.stdout("env | grep '^KEEP='") == "KEEP=1\n")
        // The caller's own environment is untouched.
        #expect(h.stdout("printenv DROP") == "2\n")
        #expect(h.status("env nosuchcommand") == 127)
        #expect(h.console("env -Z").contains("env: invalid option -- 'Z'"))
    }

    @Test func printenvValuesAndStatus() {
        let h = CommandHarness()
        h.run("export ONE=1 TWO=2")
        #expect(h.stdout("printenv ONE TWO") == "1\n2\n")
        #expect(h.stdout("printenv | grep -c '^ONE=1$'") == "1\n")
        #expect(h.status("printenv MISSING") == 1)
        #expect(h.status("printenv ONE") == 0)
    }

    // MARK: - time / watch / timeout / xargs

    @Test func timeReportsLogicalElapsedTime() {
        let h = CommandHarness()
        h.clearOutput()
        h.run("time sleep 2")
        h.advance(by: 2)
        #expect(h.output().contains("real\t0m2.000s"))
        #expect(h.output().contains("user\t0m0.000s"))
        h.clearOutput()
        h.run("time -p sleep 90")
        h.advance(by: 90)
        #expect(h.output().contains("real 90.00"))
        #expect(h.console("time echo hi").contains("hi\n"))
        #expect(h.status("time false") == 1)
        #expect(h.status("time nosuchcommand") == 127)
    }

    @Test func watchRepeatsUntilInterrupted() {
        let h = CommandHarness()
        h.clearOutput()
        h.run("watch -n 5 echo tick")
        #expect(h.output().contains("Every 5.0s: echo tick"))
        #expect(h.output().components(separatedBy: "\n\ntick\n").count == 2)
        h.advance(by: 4)
        #expect(h.output().components(separatedBy: "\n\ntick\n").count == 2)
        h.advance(by: 1)
        #expect(h.output().components(separatedBy: "\n\ntick\n").count == 3)
        h.advance(by: 5)
        #expect(h.output().components(separatedBy: "\n\ntick\n").count == 4)
        h.kernel.interruptForeground(signal: Signal.sigint.rawValue)
        h.loop.runUntilIdle()
        h.advance(by: 20)
        #expect(h.output().components(separatedBy: "\n\ntick\n").count == 4)
        #expect(h.stdout("echo back") == "back\n")
        #expect(h.console("watch -t -n 1 nosuch").contains("watch: nosuch: command not found"))
    }

    @Test func timeoutSignalOption() {
        let h = CommandHarness()
        h.run("timeout -s KILL 3 sleep 100")
        h.advance(by: 3)
        #expect(h.status("true") == 0)
        h.run("timeout -s KILL 3 sleep 100")
        h.advance(by: 3)
        h.run("echo $? > /code")
        #expect(h.contents(of: "/code") == "124\n")
        h.run("timeout 1m sleep 5")
        h.advance(by: 5)
        h.run("echo $? > /code")
        #expect(h.contents(of: "/code") == "0\n")
        #expect(h.console("timeout -s BOGUS 1 sleep 1").contains("timeout: BOGUS: invalid signal"))
        #expect(h.console("timeout x sleep 1").contains("timeout: invalid time interval 'x'"))
        #expect(h.status("timeout 5 nosuchcommand") == 127)
    }

    @Test func xargsBatching() {
        let h = CommandHarness()
        #expect(h.stdout("echo a b c | xargs") == "a b c\n")
        #expect(h.stdout("echo a b c | xargs -n 1") == "a\nb\nc\n")
        #expect(h.stdout("echo a b c | xargs -n 2 echo x") == "x a b\nx c\n")
        #expect(h.stdout("printf 'one\\ntwo\\n' | xargs -I {} echo '<{}>'") == "<one>\n<two>\n")
        #expect(h.stdout("printf 'a b\\n' | xargs -I % echo %-%") == "a b-a b\n")
        #expect(h.stdout("echo '\"two words\" three' | xargs -n 1") == "two words\nthree\n")
        #expect(h.stdout("printf '' | xargs -r echo never") == "")
        #expect(h.stdout("printf '' | xargs echo once") == "once\n")
        #expect(h.stdout("printf 'a,b,c' | xargs -d , -n 1") == "a\nb\nc\n")
        #expect(h.status("echo x | xargs false") == 123)
        #expect(h.status("echo x | xargs nosuchcommand") == 127)
        #expect(h.console("echo a | xargs -t echo").contains("echo a\n"))
        h.write("/f1", "1\n")
        h.write("/f2", "2\n")
        #expect(h.stdout("echo /f1 /f2 | xargs cat") == "1\n2\n")
        #expect(BuiltinCommands.xargsWords("a 'b c' d\\ e \"f\"") == ["a", "b c", "d e", "f"])
    }

    // MARK: - which / nproc / sync

    @Test func whichAllAndStatus() {
        let h = CommandHarness()
        #expect(h.stdout("which ls") == "/bin/ls\n")
        #expect(h.stdout("which -a ls") == "/bin/ls\n")
        #expect(h.status("which nosuchcommand") == 1)
        // A program on $PATH is listed first; -a shows it and the built-in.
        h.run("mkdir -p /opt/bin")
        h.write("/opt/bin/ls", "#!/bin/sh\n")
        h.run("chmod 755 /opt/bin/ls")
        h.run("export PATH=/opt/bin:/bin")
        #expect(h.stdout("which -a ls") == "/opt/bin/ls\n/bin/ls\n")
    }

    @Test func nprocAndSync() {
        let h = CommandHarness()
        #expect(h.stdout("nproc") == "1\n")
        #expect(h.status("sync") == 0)
        #expect(h.status("true") == 0)
        #expect(h.status("false") == 1)
    }

    // MARK: - conventions: --help, unknown options, man

    @Test func everyBuiltinAnswersHelp() {
        let h = CommandHarness()
        let registry = CommandRegistry.builtins
        // Names the shell runs itself (`cd`, `type`) answer through the shell's
        // own builtin table, in the same shape. Only the commands whose
        // arguments are all data are exempt.
        let skipped = BuiltinCommands.commandsWithoutHelpOption
        for name in registry.names where !skipped.contains(name) {
            let out = h.stdout("\(name) --help")
            #expect(out.hasPrefix("Usage: "), "\(name) --help printed: \(out.prefix(60))")
            #expect(h.status("\(name) --help") == 0, "\(name) --help exit status")
        }
        #expect(h.stdout("echo --help") == "--help\n")
    }

    @Test func helpShowsTheSynopsisAndOptions() {
        let h = CommandHarness()
        let out = h.stdout("ls --help")
        #expect(out.hasPrefix("Usage: ls [-alhRd1trSFiAnp] [FILE]...\nlist directory contents\n"))
        #expect(out.contains("  -l  long listing"))
        #expect(h.stdout("grep --help").contains("-r, -R  search directories recursively"))
        // A command registered without usage text still gets a generic line.
        #expect(h.stdout("pwd --help").hasPrefix("Usage: pwd\n"))
    }

    @Test func consumerCommandsKeepTheirOwnHelpHandling() {
        var sawHelp = false
        let custom = Command(name: "custom", summary: "consumer command") { ctx, argv in
            sawHelp = argv.contains("--help")
            ctx.exit(0)
        }
        #expect(custom.usage == nil)
        #expect(custom.synopsis == "custom [OPTION]... [ARG]...")
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("custom", args: ["custom", "--help"]) { ctx in
            if case let .sync(run) = custom.body { run(ctx, ctx.arguments) }
        }
        loop.runUntilIdle()
        #expect(sawHelp)
    }

    @Test func unknownOptionsUseTheStandardDiagnostic() {
        let h = CommandHarness()
        let commands = ["ls", "cat", "mkdir", "rmdir", "rm", "cp", "mv", "ln", "readlink", "realpath", "chown",
                        "touch", "mktemp", "du", "df", "tree", "file", "diff", "stat", "basename",
                        "wc", "sort", "uniq", "cut", "paste", "join", "comm", "tr", "fold", "expand", "column",
                        "tee", "nl", "tac", "rev", "grep", "head", "tail", "pgrep", "pidof", "which",
                        "xargs", "printenv", "uname"]
        for name in commands {
            let out = h.console("\(name) -%")
            #expect(out.contains("\(name): invalid option -- '%'"), "\(name): \(out.prefix(80))")
            #expect(out.contains("Try '\(name) --help' for more information."), "\(name)")
            #expect(h.status("\(name) -%") == 2, "\(name) exit status")
        }
        #expect(h.console("ls --nope").contains("ls: unrecognized option '--nope'"))
        #expect(h.console("head -n").contains("head: option requires an argument -- 'n'"))
        #expect(h.console("cut -f").contains("cut: option requires an argument -- 'f'"))
    }

    @Test func optionParserBehaviors() {
        let h = CommandHarness()
        final class Box { var parsed: CommandOptions?; var stopped: CommandOptions? }
        let box = Box()
        h.inProcess { ctx in
            box.parsed = ctx.options("t", ["-ab", "file", "-n", "5", "-m7", "--long=9", "--flag", "--", "-x"],
                                     "abn:m:l:f", long: ["long": "l", "flag": "f"])
            box.stopped = ctx.options("t", ["-a", "cmd", "-b"], "ab", stopAtOperand: true)
        }
        let parsed = box.parsed
        #expect(parsed?.has("a") == true && parsed?.has("b") == true && parsed?.has("f") == true)
        #expect(parsed?.value("n") == "5")
        #expect(parsed?.value("m") == "7")
        #expect(parsed?.value("l") == "9")
        #expect(parsed?.operands == ["file", "-x"])
        #expect(box.stopped?.operands == ["cmd", "-b"])
        #expect(box.stopped?.has("b") == false)
    }

    @Test func manShowsSynopsisAndOptions() {
        let h = CommandHarness()
        let page = h.stdout("man grep")
        #expect(page.contains("NAME\n    grep - print lines that match patterns"))
        #expect(page.contains("SYNOPSIS\n    grep [OPTION]... PATTERNS [FILE]...\n"))
        #expect(page.contains("OPTIONS\n"))
        #expect(page.contains("      -i      ignore case"))
        #expect(page.contains("SECTION\n    text"))
        // Several synopsis forms all land under SYNOPSIS.
        let cp = h.stdout("man cp")
        #expect(cp.contains("SYNOPSIS\n    cp [-rRapfinv] SOURCE DEST\n    cp [-rRapfinv] SOURCE... DIRECTORY\n"))
        #expect(h.status("man nosuchcommand") != 0)
    }

    @Test func signalTableLookups() {
        #expect(BuiltinCommands.signalNumber(forName: "term") == 15)
        #expect(BuiltinCommands.signalNumber(forName: "SIGINT") == 2)
        #expect(BuiltinCommands.signalNumber(forName: "9") == 9)
        #expect(BuiltinCommands.signalNumber(forName: "HUP") == 1)
        #expect(BuiltinCommands.signalNumber(forName: "nope") == nil)
        #expect(BuiltinCommands.signalName(Signal.sigtstp.rawValue) == "TSTP")
        #expect(SyscallError.permissionDenied.message == "Permission denied")
        #expect(SyscallError.directoryNotEmpty.message == "Directory not empty")
        #expect(SyscallError.notADirectory.message == "Not a directory")
    }


    // MARK: - meta-programs, scripts and shell builtins

    @Test func metaProgramsRunExecutableScripts() {
        let h = CommandHarness()
        h.run("mkdir -p /usr/local/bin /work")
        h.write("/usr/local/bin/hello", "#!/bin/sh\necho hello $1\n")
        h.run("chmod +x /usr/local/bin/hello")
        #expect(h.stdout("env GREETING=1 hello a") == "hello a\n")
        #expect(h.stdout("echo b | xargs hello") == "hello b\n")
        #expect(h.stdout("timeout 5 hello c") == "hello c\n")
        #expect(h.stdout("nohup hello d") == "hello d\n")
        #expect(h.stdout("time -p hello e") == "hello e\n")
        h.run("touch /work/f")
        #expect(h.stdout("find /work -name f -exec hello {} \\;") == "hello /work/f\n")
        #expect(h.stdout("su 1000 hello g") == "hello g\n")
        #expect(h.stdout("su 1000 -c 'hello h | tr a-z A-Z'") == "HELLO H\n")
        h.run("watch -n 1 -t hello i > /watch.out &")
        #expect(h.contents(of: "/watch.out").contains("hello i\n"))
        h.run("kill %1")
    }

    @Test func metaProgramsRunShellBuiltinsThroughSh() {
        let h = CommandHarness()
        #expect(h.stdout("env umask") == "0022\n")
        #expect(h.stdout("timeout 5 umask -S") == "u=rwx,g=rx,o=rx\n")
        #expect(h.status("time cd /") == 0)
        #expect(h.status("nohup cd /nonexistent") == 1)
        // A word with shell metacharacters reaches the builtin intact.
        #expect(h.stdout("env type 'a;b'") == "a;b: not found\n")
        #expect(h.status("env nosuchcommand") == 127)
        #expect(h.status("timeout 5 nosuchcommand") == 127)
    }
}
