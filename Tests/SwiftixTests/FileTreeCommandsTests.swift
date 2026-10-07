import Testing
@testable import Swiftix

/// Tree-walking tools: find's expression language, du, tree, file, and diff.
@Suite("File tree commands")
struct FileTreeCommandsTests {

    /// /w/a.txt, /w/b.log, /w/sub/c.txt, /w/sub/deep/D.TXT, /w/empty/, /w/link -> a.txt
    private func tree() -> CommandHarness {
        let h = CommandHarness()
        h.run("mkdir -p /w/sub/deep /w/empty")
        h.write("/w/a.txt", "alpha\n")
        h.write("/w/b.log", String(repeating: "x", count: 3000))
        h.write("/w/sub/c.txt", "")
        h.write("/w/sub/deep/D.TXT", "d\n")
        h.run("ln -s a.txt /w/link")
        return h
    }

    // MARK: - find

    @Test func findWithoutExpressionPrintsTheTree() {
        let h = tree()
        #expect(h.stdout("find /w") == """
            /w
            /w/a.txt
            /w/b.log
            /w/empty
            /w/link
            /w/sub
            /w/sub/c.txt
            /w/sub/deep
            /w/sub/deep/D.TXT

            """)
    }

    @Test func findNameFiltersInsteadOfPrintingEverything() {
        let h = tree()
        #expect(h.stdout("find /w -name '*.txt'") == "/w/a.txt\n/w/sub/c.txt\n")
        #expect(h.stdout("find /w -iname '*.txt'") == "/w/a.txt\n/w/sub/c.txt\n/w/sub/deep/D.TXT\n")
        #expect(h.stdout("find /w -name 'nomatch'") == "")
        #expect(h.stdout("find /w -path '*/sub/*.txt'") == "/w/sub/c.txt\n")
    }

    @Test func findTypePredicates() {
        let h = tree()
        #expect(h.stdout("find /w -type d") == "/w\n/w/empty\n/w/sub\n/w/sub/deep\n")
        #expect(h.stdout("find /w -type l") == "/w/link\n")
        #expect(h.stdout("find /w -type f -name '*.log'") == "/w/b.log\n")
    }

    @Test func findDepthLimits() {
        let h = tree()
        #expect(h.stdout("find /w -maxdepth 1 -type f") == "/w/a.txt\n/w/b.log\n")
        #expect(h.stdout("find /w -mindepth 3") == "/w/sub/deep/D.TXT\n")
        #expect(h.stdout("find /w -maxdepth 0") == "/w\n")
    }

    @Test func findOperators() {
        let h = tree()
        #expect(h.stdout("find /w -name '*.log' -o -name '*.TXT'") == "/w/b.log\n/w/sub/deep/D.TXT\n")
        #expect(h.stdout("find /w -type f ! -name '*.txt'") == "/w/b.log\n/w/sub/deep/D.TXT\n")
        #expect(h.stdout("find /w -type f -a -not -name '*.t*' -print") == "/w/b.log\n/w/sub/deep/D.TXT\n")
        #expect(h.stdout("find /w '(' -name a.txt -o -name b.log ')' -type f") == "/w/a.txt\n/w/b.log\n")
    }

    @Test func findSizeEmptyNewerAndPrune() {
        let h = tree()
        #expect(h.stdout("find /w -type f -size +1k") == "/w/b.log\n")
        #expect(h.stdout("find /w -type f -size -1c") == "/w/sub/c.txt\n")
        #expect(h.stdout("find /w -empty") == "/w/empty\n/w/sub/c.txt\n")
        h.run("touch -t 100 /w/a.txt")
        h.run("touch -t 200 /w/b.log")
        h.run("touch -t 50 /w/sub/c.txt /w/sub/deep/D.TXT")
        #expect(h.stdout("find /w -type f -newer /w/a.txt") == "/w/b.log\n")
        #expect(h.stdout("find /w -name sub -prune -o -type f -print") == "/w/a.txt\n/w/b.log\n")
    }

    @Test func findExecRunsACommandPerFile() {
        let h = tree()
        #expect(h.stdout("find /w -name '*.txt' -exec echo found {} ';'") == "found /w/a.txt\nfound /w/sub/c.txt\n")
        #expect(h.stdout("find /w -name '*.txt' -exec echo {} +") == "/w/a.txt /w/sub/c.txt\n")
        // -exec is a test: a failing command filters the file out.
        #expect(h.stdout("find /w -type f -exec grep -q alpha {} ';' -print") == "/w/a.txt\n")
    }

    @Test func findExecAcceptsBackslashSemicolon() {
        let h = tree()
        #expect(h.stdout(#"find /w -name a.txt -exec cat {} \;"#) == "alpha\n")
    }

    @Test func findDeleteRemovesMatchesDepthFirst() {
        let h = tree()
        #expect(h.status("find /w/sub -delete") == 0)
        #expect(!h.exists("/w/sub"))
        #expect(h.exists("/w/a.txt"))
        h.run("find /w -name '*.log' -delete")
        #expect(!h.exists("/w/b.log"))
    }

    @Test func findRejectsUnknownPredicates() {
        let h = tree()
        let out = h.console("find /w -bogus")
        #expect(out.contains("find: unknown predicate `-bogus'"))
        #expect(!out.contains("/w/a.txt"))
        #expect(h.status("find /w -bogus") == 1)
        #expect(h.console("find /w -name").contains("find: missing argument to `-name'"))
        #expect(h.console("find /w -type z").contains("Unknown argument to -type"))
        #expect(h.console("find /nope").contains("find: '/nope': No such file or directory"))
        #expect(h.console("find /w -exec echo {}").contains("missing argument to `-exec'"))
    }

    @Test func findDefaultsToCurrentDirectory() {
        let h = tree()
        h.run("cd /w/sub")
        #expect(h.stdout("find -name '*.txt'") == "./c.txt\n")
        #expect(h.stdout("find . -maxdepth 1") == ".\n./c.txt\n./deep\n")
    }

    // MARK: - du

    @Test func duSummaryDepthAndAll() {
        let h = tree()
        #expect(h.stdout("du -sb /w") == "3008\t/w\n")
        #expect(h.stdout("du -b /w") == "0\t/w/empty\n2\t/w/sub/deep\n2\t/w/sub\n3008\t/w\n")
        #expect(h.stdout("du -b -d 1 /w") == "0\t/w/empty\n2\t/w/sub\n3008\t/w\n")
        #expect(h.stdout("du -ab /w/sub") == "0\t/w/sub/c.txt\n2\t/w/sub/deep/D.TXT\n2\t/w/sub/deep\n2\t/w/sub\n")
        #expect(h.stdout("du -sh /w") == "2.9K\t/w\n")
        #expect(h.stdout("du -s /w") == "3\t/w\n")
        #expect(h.stdout("du -sbc /w/sub /w/a.txt") == "2\t/w/sub\n6\t/w/a.txt\n8\ttotal\n")
        #expect(h.console("du /nope").contains("du: cannot access '/nope': No such file or directory"))
    }

    // MARK: - tree

    @Test func treeDrawsTheHierarchy() {
        let h = tree()
        #expect(h.stdout("tree /w") == """
            /w
            ├── a.txt
            ├── b.log
            ├── empty
            ├── link -> a.txt
            └── sub
                ├── c.txt
                └── deep
                    └── D.TXT

            3 directories, 5 files

            """)
        #expect(h.stdout("tree -d -L 1 /w") == "/w\n├── empty\n└── sub\n\n2 directories\n")
    }

    // MARK: - file

    @Test func fileClassifiesContents() {
        let h = tree()
        h.write("/w/script", "#!/bin/sh\necho hi\n")
        h.writeBytes("/w/bin", [0, 1, 2, 3, 255, 254])
        h.writeBytes("/w/prog", Array("\u{7f}SWIFTIXGO".utf8) + [1, 0, 0, 0])
        h.write("/w/utf8", "héllo wörld\n")
        #expect(h.stdout("file -b /w/a.txt") == "ASCII text\n")
        #expect(h.stdout("file -b /w/sub/c.txt") == "empty\n")
        #expect(h.stdout("file -b /w/sub") == "directory\n")
        #expect(h.stdout("file -b /w/link") == "symbolic link to a.txt\n")
        #expect(h.stdout("file -bL /w/link") == "ASCII text\n")
        #expect(h.stdout("file -b /w/script") == "/bin/sh script, ASCII text executable\n")
        #expect(h.stdout("file -b /w/bin") == "data\n")
        #expect(h.stdout("file -b /w/prog") == "Swiftix Go executable\n")
        #expect(h.stdout("file -b /w/utf8") == "UTF-8 Unicode text\n")
        #expect(h.stdout("file /w/a.txt /w/sub") == "/w/a.txt: ASCII text\n/w/sub:   directory\n")
        #expect(h.stdout("file /w/nope").contains("cannot open"))
    }

    // MARK: - diff

    @Test func diffNormalAndUnified() {
        let h = CommandHarness()
        h.write("/one", "a\nb\nc\nd\ne\nf\ng\nh\n")
        h.write("/two", "a\nb\nC\nd\ne\nf\ng\nh\ni\n")
        #expect(h.stdout("diff /one /two") == "3c3\n< c\n---\n> C\n8a9\n> i\n")
        #expect(h.stdout("diff -u /one /two") == """
            --- /one
            +++ /two
            @@ -1,8 +1,9 @@
             a
             b
            -c
            +C
             d
             e
             f
             g
             h
            +i

            """)
        #expect(h.stdout("diff -U 0 /one /two") == "--- /one\n+++ /two\n@@ -3 +3 @@\n-c\n+C\n@@ -8,0 +9 @@\n+i\n")
        #expect(h.status("diff /one /two") == 1)
        #expect(h.status("diff /one /one") == 0)
        #expect(h.stdout("diff -q /one /two") == "Files /one and /two differ\n")
        #expect(h.status("diff /one /missing") == 2)
    }

    @Test func unifiedDiffSplitsDistantChangesIntoHunks() {
        let a = (1...20).map(String.init)
        var b = a
        b[1] = "two"
        b[17] = "eighteen"
        let out = BuiltinCommands.unifiedDiff(a, b, context: 1)
        #expect(out == "@@ -1,3 +1,3 @@\n 1\n-2\n+two\n 3\n@@ -17,3 +17,3 @@\n 17\n-18\n+eighteen\n 19\n")
        #expect(BuiltinCommands.unifiedDiff(a, a, context: 3) == "")
        #expect(BuiltinCommands.unifiedDiff([], ["x"], context: 3) == "@@ -0,0 +1 @@\n+x\n")
    }

    @Test func wildcardMatching() {
        #expect(BuiltinCommands.wildcardMatch("*.txt", "a.txt"))
        #expect(!BuiltinCommands.wildcardMatch("*.txt", "a.txt.bak"))
        #expect(BuiltinCommands.wildcardMatch("a?c", "abc"))
        #expect(BuiltinCommands.wildcardMatch("[a-c]*[!0-9]", "bxyz"))
        #expect(!BuiltinCommands.wildcardMatch("[a-c]*[!0-9]", "bxy9"))
        #expect(BuiltinCommands.wildcardMatch("\\*", "*"))
        #expect(BuiltinCommands.wildcardMatch("*", ""))
        #expect(BuiltinCommands.wildcardMatch("A*", "abc", ignoreCase: true))
    }


    // MARK: - wall-clock predicates

    @Test func findAgeTestsUseTheWallClock() {
        let session = SystemSession(configure: { $0.setWallClock(epochSeconds: 1_791_376_496) })
        session.run("mkdir /t; touch /t/now; touch -d '2026-10-07 12:00:00' /t/halfhour")
        session.run("touch -d '2026-10-01 00:00:00' /t/lastweek; touch -t 202601010000 /t/january")
        #expect(session.lines("find /t -type f -mmin -5") == ["/t/now"])
        #expect(session.lines("find /t -type f -mmin +30") == ["/t/halfhour", "/t/january", "/t/lastweek"])
        #expect(session.lines("find /t -type f -mtime +5") == ["/t/january", "/t/lastweek"])
        #expect(session.lines("find /t -type f -newer /t/lastweek") == ["/t/halfhour", "/t/now"])
        #expect(session.lines("ls -t /t") == ["now  halfhour  lastweek  january"])
        #expect(session.lines("ls -l /t/now /t/january") == [
            "-rw-r--r-- 1 root root 0 Jan  1  2026 /t/january",
            "-rw-r--r-- 1 root root 0 Oct  7 12:34 /t/now",
        ])
        #expect(session.lines("stat -c %y /t/halfhour") == ["2026-10-07 12:00:00 +0000"])
        #expect(session.lines("tar cf /a.tar -C /t january; tar tvf /a.tar")
                == ["-rw-r--r-- root/root         0 2026-01-01 00:00 january"])
        #expect(session.lines("touch -d nonsense /t/x; echo rc=$?")
                == ["touch: invalid date format 'nonsense'", "rc=1"])
    }

    @Test func recursiveReadersSkipDeviceNodes() {
        let h = CommandHarness()
        h.run("mkdir /tmp; echo needle > /tmp/hay")
        #expect(h.stdout("grep -r needle /dev /tmp") == "/tmp/hay:needle\n")
        #expect(h.console("cp -r /dev /tmp/devcopy").contains("cp: omitting device file '/dev/zero'"))
        #expect(h.exists("/tmp/devcopy/stdin"))          // links are copied as links
        #expect(!h.exists("/tmp/devcopy/zero"))
        #expect(h.console("tar cf /tmp/dev.tar /dev").contains("tar: /dev/null: device file ignored"))
        #expect(h.stdout("tar tf /tmp/dev.tar | grep -c .") != "0\n")
        // A device named on the command line is still read.
        #expect(h.stdout("grep -c x /dev/null") == "0\n")
    }
}
