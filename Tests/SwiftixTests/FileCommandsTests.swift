import Testing
@testable import Swiftix

/// The filesystem built-ins: listing, metadata, and the create/copy/move/remove
/// family, including the errno text each reports on failure.
@Suite("File commands")
struct FileCommandsTests {

    // MARK: - ls

    @Test func lsAcceptsAFileOperand() {
        let h = CommandHarness()
        h.write("/etc/hosts", "127.0.0.1 localhost\n")
        #expect(h.stdout("ls /etc/hosts") == "/etc/hosts\n")
        let long = h.stdout("ls -l /etc/hosts")
        #expect(long == "-rw-r--r-- 1 root root 20 Jan  1 00:00 /etc/hosts\n")
        #expect(h.stdout("ls -ln /etc/hosts").hasPrefix("-rw-r--r-- 1 0 0 20 "))
        #expect(long.hasSuffix(" /etc/hosts\n"))
        #expect(h.status("ls -l /etc/hosts") == 0)
    }

    @Test func lsListsMultipleOperandsWithHeaders() {
        let h = CommandHarness()
        h.run("mkdir /a /b")
        h.write("/a/one", "1")
        h.write("/b/two", "2")
        h.write("/f.txt", "x")
        #expect(h.stdout("ls /a /f.txt /b") == "/f.txt\n\n/a:\none\n\n/b:\ntwo\n")
    }

    @Test func lsReportsMissingOperandAndKeepsGoing() {
        let h = CommandHarness()
        h.write("/here", "x")
        let out = h.console("ls /nope /here")
        #expect(out.contains("ls: cannot access '/nope': No such file or directory"))
        #expect(out.contains("/here"))
        #expect(h.status("ls /nope /here") == 2)
    }

    @Test func lsLongShowsSymlinkAsLinkWithTarget() {
        let h = CommandHarness()
        h.run("mkdir -p /usr/bin")
        h.run("ln -s /usr/bin /bin2")
        let line = h.stdout("ls -l / | grep bin2")
        #expect(line.hasPrefix("lrwxrwxrwx"))
        #expect(line.hasSuffix("bin2 -> /usr/bin\n"))
        // An operand that is a link is listed as the link under -l, followed otherwise.
        h.write("/usr/bin/tool", "x")
        #expect(h.stdout("ls -l /bin2").contains("/bin2 -> /usr/bin"))
        #expect(h.stdout("ls /bin2") == "tool\n")
        #expect(h.stdout("ls -l /bin2/").contains("tool"))
    }

    @Test func lsLongShowsStickyAndSetuidBits() {
        let h = CommandHarness()
        h.run("mkdir /tmp2")
        h.run("chmod 1777 /tmp2")
        #expect(h.stdout("ls -ld /tmp2").hasPrefix("drwxrwxrwt"))
        h.write("/su", "x")
        h.run("chmod 4755 /su")
        #expect(h.stdout("ls -l /su").hasPrefix("-rwsr-xr-x"))
        h.run("chmod 2644 /su")
        #expect(h.stdout("ls -l /su").hasPrefix("-rw-r-Sr--"))
    }

    @Test func lsAllIncludesDotAndDotDot() {
        let h = CommandHarness()
        h.run("mkdir /d")
        h.write("/d/.hidden", "")
        h.write("/d/shown", "")
        #expect(h.stdout("ls /d") == "shown\n")
        #expect(h.stdout("ls -a /d") == ".\n..\n.hidden\nshown\n")
        #expect(h.stdout("ls -A /d") == ".hidden\nshown\n")
        #expect(h.stdout("ls -lah /d").contains(" .hidden\n"))
    }

    @Test func lsSortAndFormatFlags() {
        let h = CommandHarness()
        h.run("mkdir /s /s/sub")
        h.write("/s/big", String(repeating: "x", count: 2048))
        h.write("/s/small", "x")
        h.write("/s/run", "x")
        h.run("chmod 755 /s/run")
        h.run("ln -s big /s/link")
        #expect(h.stdout("ls -1 /s") == "big\nlink\nrun\nsmall\nsub\n")
        #expect(h.stdout("ls -r /s") == "sub\nsmall\nrun\nlink\nbig\n")
        #expect(h.stdout("ls -S /s").hasPrefix("big\n"))
        #expect(h.stdout("ls -F /s") == "big\nlink@\nrun*\nsmall\nsub/\n")
        #expect(h.stdout("ls -p /s").contains("sub/\n"))
        #expect(h.stdout("ls -d /s") == "/s\n")
        #expect(h.stdout("ls -lh /s | grep big").contains(" 2.0K "))
        // -t: newest first. `touch -t` sets logical modification times.
        h.run("touch -t 50 /s/small")
        h.run("touch -t 10 /s/big")
        #expect(h.stdout("ls -t /s").hasPrefix("small\n"))
        #expect(h.stdout("ls -tr /s").hasSuffix("small\n"))
    }

    @Test func lsRecursiveAndInode() {
        let h = CommandHarness()
        h.run("mkdir -p /r/x/y")
        h.write("/r/top", "")
        h.write("/r/x/y/deep", "")
        #expect(h.stdout("ls -R /r") == "/r:\ntop\nx\n\n/r/x:\ny\n\n/r/x/y:\ndeep\n")
        // Hard links share an inode number; distinct files do not.
        h.run("ln /r/top /r/twin")
        let rows = h.stdout("ls -i /r").split(separator: "\n").map { $0.split(separator: " ") }
        let inode = Dictionary(uniqueKeysWithValues: rows.map { (String($0[1]), String($0[0])) })
        #expect(inode["top"] == inode["twin"])
        #expect(inode["top"] != inode["x"])
    }

    @Test func lsOnATerminalUsesColumnsThatFit() {
        #expect(BuiltinCommands.columnize(["a", "b", "c"], width: 80) == "a  b  c\n")
        #expect(BuiltinCommands.columnize(["aaaa", "bbbb", "cccc", "dddd", "eeee"], width: 12)
                == "aaaa  dddd\nbbbb  eeee\ncccc\n")
        let h = CommandHarness()
        h.run("mkdir /c")
        h.write("/c/a", "")
        h.write("/c/b", "")
        #expect(h.console("ls /c").contains("a  b\n"))
    }

    @Test func lsRejectsUnknownOption() {
        let h = CommandHarness()
        let out = h.console("ls -Z")
        #expect(out.contains("ls: invalid option -- 'Z'"))
        #expect(out.contains("Try 'ls --help' for more information."))
        #expect(h.status("ls -Z") == 2)
    }

    // MARK: - errno text

    @Test func permissionDeniedIsReportedAsSuch() {
        let h = CommandHarness()
        h.run("mkdir /root2")
        h.run("chmod 700 /root2")
        h.write("/root2/secret", "s3cret\n")
        h.run("chmod 600 /root2/secret")
        #expect(h.console("su 1000 ls /root2").contains("ls: cannot open directory '/root2': Permission denied"))
        #expect(h.console("su 1000 cat /root2/secret").contains("cat: /root2/secret: Permission denied"))
        #expect(h.console("su 1000 touch /root2/new").contains("touch: cannot touch '/root2/new': Permission denied"))
        #expect(h.console("su 1000 mkdir /root2/d").contains("mkdir: cannot create directory '/root2/d': Permission denied"))
        #expect(h.console("su 1000 rm /root2/secret").contains("rm: cannot remove '/root2/secret': Permission denied"))
        #expect(h.console("su 1000 cp /root2/secret /copy").contains("Permission denied"))
        #expect(h.console("su 1000 mv /root2/secret /moved").contains("Permission denied"))
        // The file cannot even be reached through the 0700 directory, so chmod
        // fails on the lookup (EACCES), as on Linux; EPERM is for a reachable
        // file the caller does not own.
        #expect(h.console("su 1000 chmod 777 /root2/secret").contains("chmod: cannot access '/root2/secret': Permission denied"))
        h.write("/reachable", "x\n")
        #expect(h.console("su 1000 chmod 777 /reachable").contains("Operation not permitted"))
        #expect(h.exists("/root2/secret"))
    }

    @Test func commandsReportTheRealErrno() {
        let h = CommandHarness()
        h.run("mkdir /d")
        h.write("/d/f", "x")
        h.write("/plain", "x")
        #expect(h.console("cat /missing").contains("cat: /missing: No such file or directory"))
        #expect(h.console("cat /d").contains("cat: /d: Is a directory"))
        #expect(h.console("rm /d").contains("rm: cannot remove '/d': Is a directory"))
        #expect(h.console("rmdir /d").contains("rmdir: failed to remove '/d': Directory not empty"))
        #expect(h.console("rmdir /plain").contains("rmdir: failed to remove '/plain': Not a directory"))
        #expect(h.console("mkdir /d").contains("mkdir: cannot create directory '/d': File exists"))
        #expect(h.console("mkdir /no/such/dir").contains("mkdir: cannot create directory '/no/such/dir': No such file or directory"))
        #expect(h.console("ls /plain/x").contains("ls: cannot access '/plain/x': Not a directory"))
        #expect(h.console("stat /missing").contains("stat: cannot stat '/missing': No such file or directory"))
        #expect(h.console("cp /missing /x").contains("cp: cannot stat '/missing': No such file or directory"))
        #expect(h.console("cp /plain /no/dir/x").contains("No such file or directory"))
        #expect(h.console("mv /missing /x").contains("mv: cannot stat '/missing': No such file or directory"))
        #expect(h.console("touch /no/dir/x").contains("touch: cannot touch '/no/dir/x': No such file or directory"))
        #expect(h.console("chmod 644 /missing").contains("chmod: cannot access '/missing': No such file or directory"))
        #expect(h.status("cat /missing") == 1)
    }

    // MARK: - stat

    @Test func statFormatsTimesAndUsesLstat() {
        let h = CommandHarness()
        h.write("/f", "hello")
        h.run("touch -d '2026-10-07 12:34:56' /f")
        let out = h.stdout("stat /f")
        #expect(out.contains("  File: /f\n"))
        #expect(out.contains("Size: 5"))
        #expect(out.contains("(0644/-rw-r--r--)"))
        #expect(out.contains("Access: 2026-10-07 12:34:56 +0000\n"))
        #expect(out.contains("Modify: 2026-10-07 12:34:56 +0000\n"))
        h.run("ln -s /f /l")
        #expect(h.stdout("stat /l").contains("File: /l -> /f"))
        #expect(h.stdout("stat /l").contains("symbolic link"))
        #expect(h.stdout("stat -L /l").contains("regular file"))
        #expect(h.stdout("stat -c '%n %s %a %A %F' /f") == "/f 5 644 -rw-r--r-- regular file\n")
        #expect(h.stdout("stat -c %Y /f") == "1791376496\n")
        #expect(h.stdout("stat -c %y /f") == "2026-10-07 12:34:56 +0000\n")
        #expect(h.stdout("stat -c '%U:%G' /f") == "root:root\n")
        // A bare number is still accepted as seconds on the file-time clock.
        h.run("touch -t 90 /f")
        #expect(h.stdout("stat -c %Y /f") == "90\n")
    }

    @Test func touchStampParsesThePosixForms() {
        let now = CalendarTime(epoch: 86_400 * 366)          // some time in 1971
        func stamp(_ text: String) -> Int64? {
            BuiltinCommands.parseTouchStamp(text, now: now, utcOffsetSeconds: 0)
        }
        #expect(stamp("200102030405.07") == 981_173_107)   // 2001-02-03 04:05:07 UTC
        #expect(stamp("0102030405") == 981_173_100)        // two-digit year
        #expect(stamp("01020304") == 31_633_440)           // this year (1971): Jan 2 03:04
        #expect(stamp("12345") == nil)
        #expect(stamp("200113010000") == nil)              // month 13
        #expect(stamp("200102030405.99") == nil)
    }

    // MARK: - cat

    @Test func catNumbersAndSqueezes() {
        let h = CommandHarness()
        h.write("/c", "a\n\n\nb\n")
        #expect(h.stdout("cat -n /c") == "     1\ta\n     2\t\n     3\t\n     4\tb\n")
        #expect(h.stdout("cat -b /c") == "     1\ta\n\n\n     2\tb\n")
        #expect(h.stdout("cat -s /c") == "a\n\nb\n")
        #expect(h.stdout("cat -E /c") == "a$\n$\n$\nb$\n")
        #expect(h.stdout("cat /c /c") == "a\n\n\nb\na\n\n\nb\n")
    }

    @Test func largeOutputSurvivesAPipe() {
        // More than a pipe's 64 KiB capacity: writers must park, not truncate.
        let h = CommandHarness()
        #expect(h.stdout("seq 20000 | cat | wc -l") == "20000\n")
        #expect(h.stdout("seq 20000 | sort -n | tail -n 1") == "20000\n")
    }

    // MARK: - mkdir / rmdir / rm

    @Test func mkdirParentsAndMode() {
        let h = CommandHarness()
        #expect(h.status("mkdir -p /a/b/c") == 0)
        #expect(h.stat("/a/b/c")?.isDirectory == true)
        #expect(h.status("mkdir -p /a/b/c") == 0)            // already there: fine
        #expect(h.status("mkdir /a/b/c") == 1)
        h.run("mkdir -m 700 /private")
        #expect(h.stat("/private")?.mode.rawValue == 0o700)
        #expect(h.console("mkdir -v /v").contains("mkdir: created directory '/v'"))
        #expect(h.console("mkdir").contains("mkdir: missing operand"))
    }

    @Test func rmdirRemovesEmptyDirectoriesAndParents() {
        let h = CommandHarness()
        h.run("mkdir -p /p/q/r /keep")
        #expect(h.status("rmdir /keep") == 0)
        #expect(!h.exists("/keep"))
        h.run("cd /")
        #expect(h.status("rmdir -p p/q/r") == 0)
        #expect(!h.exists("/p"))
        #expect(h.status("rmdir /nope") == 1)
    }

    @Test func rmRecursiveAndForce() {
        let h = CommandHarness()
        h.run("mkdir -p /t/a/b")
        h.write("/t/a/b/f", "x")
        h.write("/t/g", "x")
        h.run("ln -s /t/g /t/link")
        #expect(h.status("rm /t") == 1)
        #expect(h.status("rm -rf /t") == 0)
        #expect(!h.exists("/t"))
        #expect(h.status("rm -f /does/not/exist") == 0)
        #expect(h.status("rm /does/not/exist") == 1)
        #expect(h.status("rm -f") == 0)
        h.run("mkdir /e")
        #expect(h.status("rm -d /e") == 0)
        h.write("/one", "")
        h.write("/two", "")
        #expect(h.console("rm -v /one /two").contains("removed '/one'\nremoved '/two'"))
    }

    @Test func rmDoesNotFollowSymlinks() {
        let h = CommandHarness()
        h.run("mkdir /real /holder")
        h.write("/real/keep", "x")
        h.run("ln -s /real /holder/link")
        h.run("rm -r /holder")
        #expect(h.exists("/real/keep"))
    }

    // MARK: - cp / mv

    @Test func cpRecursiveAndIntoDirectory() {
        let h = CommandHarness()
        h.run("mkdir -p /src/sub /dst")
        h.write("/src/a", "A")
        h.write("/src/sub/b", "B")
        h.run("ln -s a /src/l")
        #expect(h.console("cp /src /copy").contains("cp: -r not specified; omitting directory '/src'"))
        #expect(h.status("cp -r /src /copy") == 0)
        #expect(h.contents(of: "/copy/a") == "A")
        #expect(h.contents(of: "/copy/sub/b") == "B")
        #expect(h.stat("/copy/l", follow: false)?.type == .symlink)
        // Existing directory target: the source lands inside it.
        h.run("cp -r /src /dst")
        #expect(h.contents(of: "/dst/src/sub/b") == "B")
        // Several sources into a directory.
        h.write("/x", "X")
        h.write("/y", "Y")
        #expect(h.status("cp /x /y /dst") == 0)
        #expect(h.contents(of: "/dst/x") == "X")
        #expect(h.contents(of: "/dst/y") == "Y")
        #expect(h.console("cp /x /y /x").contains("cp: target '/x' is not a directory"))
        #expect(h.console("cp /x /x").contains("are the same file"))
        #expect(h.console("cp -r /src /src/inner").contains("into itself"))
    }

    @Test func cpPreservesModeAndFlags() {
        let h = CommandHarness()
        h.write("/tool", "#!/bin/sh\n")
        h.run("chmod 755 /tool")
        h.run("touch -t 7 /tool")
        h.run("cp /tool /tool2")
        #expect(h.stat("/tool2")?.mode.rawValue == 0o755)
        h.run("cp -p /tool /tool3")
        #expect(h.stat("/tool3")?.mtime == 7)
        h.write("/keep", "old")
        h.run("cp -n /tool /keep")
        #expect(h.contents(of: "/keep") == "old")
        #expect(h.console("cp -v /tool /tool4").contains("'/tool' -> '/tool4'"))
        #expect(h.status("cp -f -i /tool /tool5") == 0)
    }

    @Test func mvRenamesAndMovesIntoDirectory() {
        let h = CommandHarness()
        h.write("/a", "A")
        h.write("/b", "B")
        h.run("mkdir /dir /tree")
        h.write("/tree/leaf", "L")
        #expect(h.status("mv /a /a2") == 0)
        #expect(!h.exists("/a"))
        #expect(h.contents(of: "/a2") == "A")
        #expect(h.status("mv /a2 /b /dir") == 0)
        #expect(h.contents(of: "/dir/a2") == "A")
        #expect(h.contents(of: "/dir/b") == "B")
        // Directories move too (a rename, not a copy).
        #expect(h.status("mv /tree /dir/tree") == 0)
        #expect(h.contents(of: "/dir/tree/leaf") == "L")
        #expect(h.console("mv /dir /dir/tree/x").contains("subdirectory of itself"))
        #expect(h.console("mv -v /dir/b /b").contains("renamed '/dir/b' -> '/b'"))
        h.write("/c", "C")
        h.run("mv -n /c /b")
        #expect(h.contents(of: "/b") == "B")
    }

    // MARK: - ln / readlink / realpath

    @Test func lnForceReplacesExistingLink() {
        let h = CommandHarness()
        h.write("/one", "1")
        h.write("/two", "2")
        h.run("ln -s /one /cur")
        #expect(h.console("ln -s /two /cur").contains("ln: failed to create symbolic link '/cur': File exists"))
        #expect(h.status("ln -sf /two /cur") == 0)
        #expect(h.stdout("readlink /cur") == "/two\n")
        #expect(h.stdout("cat /cur") == "2")
        h.run("mkdir /links")
        #expect(h.status("ln -s /one /two /links") == 0)
        #expect(h.stdout("readlink /links/one") == "/one\n")
        #expect(h.status("ln /one /hard") == 0)
        #expect(h.stat("/one")?.nlink == 2)
        #expect(h.console("ln /missing /h2").contains("No such file or directory"))
    }

    @Test func readlinkCanonicalizeAndRealpath() {
        let h = CommandHarness()
        h.run("mkdir -p /usr/bin")
        h.write("/usr/bin/tool", "")
        h.run("ln -s /usr/bin /bin2")
        h.run("ln -s tool /usr/bin/alias")
        #expect(h.stdout("readlink -f /bin2/alias") == "/usr/bin/tool\n")
        #expect(h.stdout("realpath /bin2/alias") == "/usr/bin/tool\n")
        #expect(h.stdout("realpath /bin2/../bin2/./tool") == "/usr/bin/tool\n")
        h.run("cd /usr")
        #expect(h.stdout("realpath bin") == "/usr/bin\n")
        #expect(h.stdout("realpath /usr/bin/newfile") == "/usr/bin/newfile\n")
        #expect(h.status("realpath -e /usr/bin/newfile") == 1)
        #expect(h.status("realpath /no/such/dir/file") == 1)
        #expect(h.stdout("realpath -m /no/such/dir/file") == "/no/such/dir/file\n")
        #expect(h.status("readlink /usr/bin/tool") == 1)
    }

    // MARK: - chmod / chown

    @Test func chmodSymbolicModes() {
        let h = CommandHarness()
        h.write("/f", "")
        func mode() -> UInt16 { h.stat("/f")?.mode.rawValue ?? 0 }
        h.run("chmod 644 /f")
        h.run("chmod u+x,g-r /f")
        #expect(mode() == 0o704)
        h.run("chmod a=r /f")
        #expect(mode() == 0o444)
        h.run("chmod +x /f")
        #expect(mode() == 0o555)
        h.run("chmod go-rx,u+w /f")
        #expect(mode() == 0o700)
        h.run("chmod o=u /f")
        #expect(mode() == 0o707)
        h.run("chmod -x /f")
        #expect(mode() == 0o606)
        h.run("chmod u+s,+t /f")
        #expect(mode() == 0o5606)
        #expect(h.console("chmod u+q /f").contains("chmod: invalid mode: 'u+q'"))
        #expect(h.console("chmod 644").contains("chmod: missing operand after '644'"))
    }

    @Test func chmodRecursiveAndCapitalX() {
        let h = CommandHarness()
        h.run("mkdir -p /m/sub")
        h.write("/m/sub/file", "")
        h.run("chmod -R 600 /m")
        #expect(h.stat("/m/sub/file")?.mode.rawValue == 0o600)
        // X adds execute only to directories (and already-executable files).
        h.run("chmod -R a+X /m")
        #expect(h.stat("/m/sub")?.mode.rawValue == 0o711)
        #expect(h.stat("/m/sub/file")?.mode.rawValue == 0o600)
        #expect(h.console("chmod -v 644 /m/sub/file").contains("mode of '/m/sub/file' changed from 0600"))
    }

    @Test func modeChangeParser() {
        let base = FileMode(rawValue: 0o644)
        #expect(BuiltinCommands.parseModeChange("755", current: base, isDirectory: false)?.rawValue == 0o755)
        #expect(BuiltinCommands.parseModeChange("1777", current: base, isDirectory: true)?.rawValue == 0o1777)
        #expect(BuiltinCommands.parseModeChange("g+w", current: base, isDirectory: false)?.rawValue == 0o664)
        #expect(BuiltinCommands.parseModeChange("u=rwx,go=", current: base, isDirectory: false)?.rawValue == 0o700)
        #expect(BuiltinCommands.parseModeChange("789", current: base, isDirectory: false) == nil)
        #expect(BuiltinCommands.parseModeChange("u+", current: base, isDirectory: false)?.rawValue == 0o644)
        #expect(BuiltinCommands.parseModeChange("rwx", current: base, isDirectory: false) == nil)
    }

    @Test func chownByIdAndName() {
        let h = CommandHarness()
        h.write("/etc/passwd", "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n")
        h.write("/etc/group", "root:x:0:\nstaff:x:50:\n")
        h.write("/f", "")
        h.run("chown 5:6 /f")
        #expect(h.stat("/f")?.uid == 5)
        #expect(h.stat("/f")?.gid == 6)
        h.run("chown alice:staff /f")
        #expect(h.stat("/f")?.uid == 1000)
        #expect(h.stat("/f")?.gid == 50)
        // ls -l resolves names through /etc/passwd and /etc/group.
        #expect(h.stdout("ls -l /f").contains(" alice staff "))
        #expect(h.stdout("ls -ln /f").contains(" 1000 50 "))
        h.run("chown :0 /f")
        #expect(h.stat("/f")?.uid == 1000)
        #expect(h.stat("/f")?.gid == 0)
        #expect(h.console("chown nobody /f").contains("chown: invalid user: 'nobody'"))
    }

    // MARK: - touch / mktemp / truncate / basename / dirname

    @Test func touchCreatesSeveralFiles() {
        let h = CommandHarness()
        #expect(h.status("touch /t1 /t2 /t3") == 0)
        #expect(h.exists("/t1") && h.exists("/t2") && h.exists("/t3"))
        h.run("touch -c /never")
        #expect(!h.exists("/never"))
        h.run("touch -t 9 /t1")
        h.run("touch -r /t1 /t2")
        #expect(h.stat("/t2")?.mtime == 9)
    }

    @Test func mktempCreatesUniqueFilesAndDirectories() {
        let h = CommandHarness()
        h.run("mkdir /tmp")
        let first = h.stdout("mktemp").dropLast()
        let second = h.stdout("mktemp").dropLast()
        #expect(first.hasPrefix("/tmp/tmp.") && first.count == "/tmp/tmp.".count + 10)
        #expect(first != second)
        #expect(h.stat(String(first))?.type == .regular)
        #expect(h.stat(String(first))?.mode.rawValue == 0o600)
        let dir = h.stdout("mktemp -d").dropLast()
        #expect(h.stat(String(dir))?.isDirectory == true)
        let named = h.stdout("mktemp /tmp/job-XXXXXX.log")
        #expect(named.contains("too few X's") || named.isEmpty)   // X's must be the suffix
        let custom = h.stdout("mktemp /tmp/job.XXXX").dropLast()
        #expect(custom.hasPrefix("/tmp/job.") && h.exists(String(custom)))
        let dry = h.stdout("mktemp -u").dropLast()
        #expect(!h.exists(String(dry)))
    }

    @Test func truncateSetsExtendsAndShrinks() {
        let h = CommandHarness()
        h.write("/f", "0123456789")
        h.run("truncate -s 4 /f")
        #expect(h.contents(of: "/f") == "0123")
        h.run("truncate -s +2 /f")
        #expect(h.bytes(of: "/f") == Array("0123".utf8) + [0, 0])
        h.run("truncate -s -5 /f")
        #expect(h.bytes(of: "/f")?.count == 1)
        h.run("truncate -s 1K /new")
        #expect(h.stat("/new")?.size == 1024)
        #expect(h.console("truncate /f").contains("you must specify"))
    }

    @Test func basenameAndDirnameTakeSeveralNames() {
        let h = CommandHarness()
        #expect(h.stdout("basename /usr/lib/libc.so .so") == "libc\n")
        #expect(h.stdout("basename -a /a/b /c/d") == "b\nd\n")
        #expect(h.stdout("basename -s .txt /a/one.txt two.txt") == "one\ntwo\n")
        #expect(h.stdout("basename /") == "/\n")
        #expect(h.stdout("dirname /usr/lib/x /y z /a/b/") == "/usr/lib\n/\n.\n/a\n")
    }

    @Test func dfAcceptsHumanFlag() {
        let h = CommandHarness()
        #expect(h.stdout("df -h").contains("Size  Used Avail Use% Mounted on"))
        #expect(h.stdout("df").contains("1K-blocks"))
        #expect(h.status("df -Q") == 2)
    }
}
