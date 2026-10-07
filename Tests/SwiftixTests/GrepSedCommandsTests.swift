import Testing
@testable import Swiftix

/// `grep` (selection, output modes, context, recursion, exit codes), `sed`
/// (addresses, commands, in-place editing), and the regex dialects they use.
@Suite("grep, sed, and regex dialects")
struct GrepSedCommandsTests {

    private func fixture() -> CommandHarness {
        let h = CommandHarness()
        h.run("mkdir -p /g/sub")
        h.write("/g/a.txt", "apple pie\nBanana split\ncherry tart\napple crumble\n")
        h.write("/g/b.txt", "plain rice\npineapple\n")
        h.write("/g/sub/c.txt", "an apple a day\n")
        return h
    }

    // MARK: - grep

    @Test func grepMultipleFilesPrefixNames() {
        let h = fixture()
        #expect(h.stdout("grep apple /g/a.txt /g/b.txt") == "/g/a.txt:apple pie\n/g/a.txt:apple crumble\n/g/b.txt:pineapple\n")
        #expect(h.stdout("grep -h apple /g/a.txt /g/b.txt") == "apple pie\napple crumble\npineapple\n")
        #expect(h.stdout("grep -H cherry /g/a.txt") == "/g/a.txt:cherry tart\n")
        #expect(h.stdout("grep -n apple /g/a.txt /g/b.txt") == "/g/a.txt:1:apple pie\n/g/a.txt:4:apple crumble\n/g/b.txt:2:pineapple\n")
        #expect(h.stdout("grep -c apple /g/a.txt /g/b.txt") == "/g/a.txt:2\n/g/b.txt:1\n")
    }

    @Test func grepRecursive() {
        let h = fixture()
        #expect(h.stdout("grep -r apple /g") == "/g/a.txt:apple pie\n/g/a.txt:apple crumble\n/g/b.txt:pineapple\n/g/sub/c.txt:an apple a day\n")
        #expect(h.stdout("grep -rl day /g") == "/g/sub/c.txt\n")
        h.run("cd /g")
        #expect(h.stdout("grep -R day") == "sub/c.txt:an apple a day\n")
        #expect(h.console("grep apple /g/sub").contains("grep: /g/sub: Is a directory"))
    }

    @Test func grepOutputModes() {
        let h = fixture()
        #expect(h.stdout("grep -o 'ap*le' /g/a.txt") == "apple\napple\n")
        #expect(h.stdout("grep -on 'p[a-z]' /g/b.txt") == "1:pl\n2:pi\n2:pp\n")
        #expect(h.stdout("grep -l apple /g/a.txt /g/b.txt /g/sub/c.txt") == "/g/a.txt\n/g/b.txt\n/g/sub/c.txt\n")
        #expect(h.stdout("grep -L cherry /g/a.txt /g/b.txt") == "/g/b.txt\n")
        #expect(h.stdout("grep -q apple /g/a.txt") == "")
        #expect(h.stdout("grep -m 1 apple /g/a.txt") == "apple pie\n")
    }

    @Test func grepWordLineAndFixedMatching() {
        let h = fixture()
        #expect(h.stdout("grep -w apple /g/b.txt /g/sub/c.txt") == "/g/sub/c.txt:an apple a day\n")
        #expect(h.stdout("grep -x pineapple /g/b.txt") == "pineapple\n")
        #expect(h.stdout("grep -x apple /g/b.txt") == "")
        h.write("/dots", "a.c\nabc\n")
        #expect(h.stdout("grep -F a.c /dots") == "a.c\n")
        #expect(h.stdout("grep a.c /dots") == "a.c\nabc\n")
        #expect(h.stdout("grep -i banana /g/a.txt") == "Banana split\n")
        #expect(h.stdout("grep -v apple /g/a.txt") == "Banana split\ncherry tart\n")
        #expect(h.stdout("grep -vc apple /g/a.txt") == "2\n")
    }

    @Test func grepMultiplePatterns() {
        let h = fixture()
        #expect(h.stdout("grep -e cherry -e Banana /g/a.txt") == "Banana split\ncherry tart\n")
        #expect(h.stdout("grep -E 'cherry|Banana' /g/a.txt") == "Banana split\ncherry tart\n")
        #expect(h.stdout(#"grep 'cherry\|Banana' /g/a.txt"#) == "Banana split\ncherry tart\n")
        h.write("/pats", "pie\nrice\n")
        #expect(h.stdout("grep -h -f /pats /g/a.txt /g/b.txt") == "apple pie\nplain rice\n")
        #expect(h.stdout("grep -e -x- /dev/null") == "")
    }

    @Test func grepBasicVersusExtendedSyntax() {
        let h = CommandHarness()
        h.write("/r", "aa\na+\n(a)\nab\n")
        // In a basic regex `+`, `(`, `)` are ordinary characters.
        #expect(h.stdout("grep 'a+' /r") == "a+\n")
        #expect(h.stdout("grep -E 'a+' /r") == "aa\na+\n(a)\nab\n")
        #expect(h.stdout(#"grep 'a\+b' /r"#) == "ab\n")
        #expect(h.stdout("grep '(a)' /r") == "(a)\n")
        #expect(h.stdout(#"grep '\(a\)\1' /r"#) == "aa\n")
        #expect(h.stdout("grep -E '^(a)\\1$' /r") == "aa\n")
        #expect(h.stdout("grep '[[:punct:]]' /r") == "a+\n(a)\n")
        #expect(h.stdout(#"grep -E '\ba\b' /r"#) == "a+\n(a)\n")
    }

    @Test func grepContext() {
        let h = CommandHarness()
        h.write("/c", (1...12).map { "l\($0)" }.joined(separator: "\n") + "\n")
        #expect(h.stdout("grep -A 1 'l3$' /c") == "l3\nl4\n")
        #expect(h.stdout("grep -B 2 'l3$' /c") == "l1\nl2\nl3\n")
        #expect(h.stdout("grep -C 1 -n 'l3$' /c") == "2-l2\n3:l3\n4-l4\n")
        // Separate groups get a `--` line; adjacent ones merge.
        #expect(h.stdout("grep -A 1 -e 'l2$' -e 'l8$' /c") == "l2\nl3\n--\nl8\nl9\n")
        #expect(h.stdout("grep -A 1 -e 'l2$' -e 'l3$' /c") == "l2\nl3\nl4\n")
    }

    @Test func grepExitCodes() {
        let h = fixture()
        #expect(h.status("grep apple /g/a.txt") == 0)
        #expect(h.status("grep zebra /g/a.txt") == 1)
        #expect(h.status("grep apple /g/missing") == 2)
        #expect(h.status("grep apple /g/a.txt /g/missing") == 2)
        #expect(h.status("grep -q apple /g/a.txt /g/missing") == 0)
        #expect(h.status("grep -s apple /g/missing") == 2)
        #expect(h.console("grep -s apple /g/missing").contains("No such file") == false)
        #expect(h.status("grep '[' /g/a.txt") == 2)
        #expect(h.status("grep") == 2)
        #expect(h.status("echo apple | grep -q apple") == 0)
        #expect(h.console("grep -Z x /g/a.txt").contains("grep: invalid option -- 'Z'"))
    }

    @Test func grepStreamsStandardInput() {
        let h = CommandHarness()
        #expect(h.stdout("seq 30 | grep 7") == "7\n17\n27\n")
        #expect(h.stdout("seq 30 | grep -c 1") == "12\n")
        // -q exits at the first match, so an endless producer is cut off.
        #expect(h.status("yes | grep -q y") == 0)
        #expect(h.stdout("yes | grep -m 2 y") == "y\ny\n")
    }

    // MARK: - regex dialects

    @Test func basicSyntaxOperators() {
        func basic(_ pattern: String) -> Regex? { Regex(pattern: pattern, syntax: .basic) }
        #expect(basic("a|b")!.matches("a|b"))
        #expect(!basic("a|b")!.matches("a"))
        #expect(basic(#"a\|b"#)!.matches("b"))
        #expect(basic(#"a\{2\}"#)!.matches("aa"))
        #expect(!basic(#"^a\{2\}$"#)!.matches("aaa"))
        #expect(basic("a{2}")!.matches("a{2}"))
        #expect(basic("*a")!.matches("*a"))
        #expect(basic("a^b$c")!.matches("a^b$c"))
        #expect(basic(#"\(ab\)*c"#)!.matches("ababc"))
        #expect(basic(#"\("#) == nil)
        #expect(basic(#"a\?b"#)!.matches("b"))
    }

    @Test func classesBoundariesAndBackReferences() {
        #expect(Regex(pattern: "^[[:alpha:]]+$")!.matches("hello"))
        #expect(!Regex(pattern: "^[[:alpha:]]+$")!.matches("hello1"))
        #expect(Regex(pattern: "^[[:digit:][:space:]]+$")!.matches("1 2 3"))
        #expect(Regex(pattern: "^[[:upper:]][[:lower:]]+$")!.matches("Hello"))
        #expect(Regex(pattern: "[[:bogus:]]") == nil)
        #expect(Regex(pattern: "[]a]")!.matches("]"))
        #expect(Regex(pattern: "[^]a]")!.matches("b"))
        #expect(Regex(pattern: "[a-]")!.matches("-"))
        #expect(Regex(pattern: #"\bcat\b"#)!.matches("a cat sat"))
        #expect(!Regex(pattern: #"\bcat\b"#)!.matches("concatenate"))
        #expect(Regex(pattern: #"\Bcat\B"#)!.matches("concatenate"))
        #expect(Regex(pattern: #"\<in"#)!.matches("go inside"))
        #expect(!Regex(pattern: #"in\>"#)!.matches("inside"))
        #expect(Regex(pattern: #"(a|b)x\1"#)!.matches("bxb"))
        #expect(!Regex(pattern: #"(a|b)x\1"#)!.matches("axb"))
        #expect(Regex(pattern: #"(a)\2"#) == nil)
        #expect(Regex(pattern: "[A-Z]+", ignoreCase: true)!.matches("abc"))
        #expect(Regex(pattern: "[[:upper:]]", ignoreCase: true)!.matches("x"))
    }

    @Test func captureGroupsAndWholeMatch() {
        let regex = Regex(pattern: "(\\w+)@(\\w+)\\.com")!
        let chars = Array("mail bob@example.com now")
        let match = regex.match(in: chars, from: 0)
        #expect(match.map { String(chars[$0.range]) } == "bob@example.com")
        #expect(match?.groups.count == 3)
        #expect(match?.groups[1].map { String(chars[$0]) } == "bob")
        #expect(match?.groups[2].map { String(chars[$0]) } == "example")
        #expect(regex.groupCount == 2)
        // An unused alternative leaves its group unset.
        let alt = Regex(pattern: "(a)|(b)")!.match(in: Array("b"), from: 0)
        #expect(alt?.groups[1] == nil)
        #expect(alt?.groups[2] == 0..<1)
        #expect(Regex(pattern: "a.c")!.matchesEntire(Array("abc")))
        #expect(!Regex(pattern: "a.c")!.matchesEntire(Array("abcd")))
        // Long runs do not recurse per character.
        #expect(Regex(pattern: "^x*y$")!.matches(String(repeating: "x", count: 50_000) + "y"))
    }

    // MARK: - sed

    @Test func sedPrintAndDeleteWithAddresses() {
        let h = CommandHarness()
        h.write("/s", "one\ntwo\nthree\nfour\nfive\n")
        #expect(h.stdout("sed -n 2p /s") == "two\n")
        #expect(h.stdout("sed -n '$p' /s") == "five\n")
        #expect(h.stdout("sed -n '2,4p' /s") == "two\nthree\nfour\n")
        #expect(h.stdout("sed -n '/two/,/four/p' /s") == "two\nthree\nfour\n")
        #expect(h.stdout("sed -n '/t/p' /s") == "two\nthree\n")
        #expect(h.stdout("sed 2d /s") == "one\nthree\nfour\nfive\n")
        #expect(h.stdout("sed '2,$d' /s") == "one\n")
        #expect(h.stdout("sed '/o/d' /s") == "three\nfive\n")
        #expect(h.stdout("sed '2!d' /s") == "two\n")
        #expect(h.stdout("sed -n '2,+1p' /s") == "two\nthree\n")
        #expect(h.stdout("sed -n '1~2p' /s") == "one\nthree\nfive\n")
        #expect(h.stdout("sed -n '/THREE/Ip' /s") == "three\n")
        #expect(h.stdout("sed -n '3,1p' /s") == "three\n")
    }

    @Test func sedQuitAndLineNumber() {
        let h = CommandHarness()
        h.write("/s", "one\ntwo\nthree\n")
        #expect(h.stdout("sed 2q /s") == "one\ntwo\n")
        #expect(h.stdout("sed -n '$=' /s") == "3\n")
        #expect(h.stdout("sed = /s") == "1\none\n2\ntwo\n3\nthree\n")
        #expect(h.status("sed '2q5' /s") == 5)
        // q stops reading: an endless producer upstream is cut off.
        #expect(h.stdout("yes | sed 3q") == "y\ny\ny\n")
    }

    @Test func sedSubstituteFlagsAndBackReferences() {
        let h = CommandHarness()
        #expect(h.stdout("echo 'aaa bbb' | sed 's/a/X/'") == "Xaa bbb\n")
        #expect(h.stdout("echo 'aaa bbb' | sed 's/a/X/g'") == "XXX bbb\n")
        #expect(h.stdout("echo 'aaa bbb' | sed 's/a/X/2'") == "aXa bbb\n")
        #expect(h.stdout("echo 'aaa bbb' | sed 's/a/X/2g'") == "aXX bbb\n")
        #expect(h.stdout("echo 'Hello' | sed 's/hello/bye/i'") == "bye\n")
        #expect(h.stdout("echo 'cat' | sed 's/cat/[&]/'") == "[cat]\n")
        #expect(h.stdout(#"echo 'a&b' | sed 's/&/\&\&/'"#) == "a&&b\n")
        #expect(h.stdout(#"echo 'john smith' | sed 's/\(.*\) \(.*\)/\2, \1/'"#) == "smith, john\n")
        #expect(h.stdout(#"echo 'john smith' | sed -E 's/(\w+) (\w+)/\2 \1/'"#) == "smith john\n")
        #expect(h.stdout("echo '/usr/bin' | sed 's|/|_|g'") == "_usr_bin\n")
        #expect(h.stdout("echo 'a,b' | sed 's#,#/#'") == "a/b\n")
        #expect(h.stdout(#"echo 'a/b' | sed 's/\//-/'"#) == "a-b\n")
        #expect(h.stdout("printf 'x\\ny\\n' | sed -n 's/x/z/p'") == "z\n")
        #expect(h.stdout("echo abc | sed 's/x*/-/g'") == "-a-b-c-\n")
        #expect(h.stdout("echo 'a b' | sed -E 's/(a)|(b)/[\\1\\2]/g'") == "[a] [b]\n")
        #expect(h.stdout("printf 'foo\\nbar\\n' | sed '/foo/s//baz/'") == "baz\nbar\n")
    }

    @Test func sedTransliterateAppendInsertChange() {
        let h = CommandHarness()
        h.write("/s", "one\ntwo\nthree\n")
        #expect(h.stdout("sed 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/' /s") == "ONE\nTWO\nTHREE\n")
        #expect(h.stdout("sed 'y/eo/30/' /s") == "0n3\ntw0\nthr33\n")
        #expect(h.stdout("sed '2a after' /s") == "one\ntwo\nafter\nthree\n")
        #expect(h.stdout("sed '2i before' /s") == "one\nbefore\ntwo\nthree\n")
        #expect(h.stdout("sed '2c changed' /s") == "one\nchanged\nthree\n")
        #expect(h.stdout("sed '1,2c gone' /s") == "gone\nthree\n")
        #expect(h.stdout("sed '$a last' /s") == "one\ntwo\nthree\nlast\n")
        #expect(h.stdout("sed '/two/a\\  indented' /s") == "one\ntwo\n  indented\nthree\n")
        #expect(h.console("sed 'y/ab/c/' /s").contains("strings for `y' command are different lengths"))
    }

    @Test func sedMultipleCommands() {
        let h = CommandHarness()
        h.write("/s", "one\ntwo\nthree\n")
        #expect(h.stdout("sed -e 's/one/1/' -e 's/two/2/' /s") == "1\n2\nthree\n")
        #expect(h.stdout("sed 's/one/1/;s/two/2/;3d' /s") == "1\n2\n")
        #expect(h.stdout("sed -n '/t/{s/t/T/;p}' /s") == "Two\nThree\n")
        #expect(h.stdout("sed -n '2{p;p}' /s") == "two\ntwo\n")
        h.write("/script.sed", "s/one/uno/\n# comment\n$d\n")
        #expect(h.stdout("sed -f /script.sed /s") == "uno\ntwo\n")
        #expect(h.stdout("sed -n -e 1p -e 3p /s /s") == "one\nthree\n")
        #expect(h.stdout("sed -s -n '$p' /s /s") == "three\nthree\n")
    }

    @Test func sedHoldSpaceAndBranches() {
        let h = CommandHarness()
        h.write("/s", "1\n2\n3\n")
        #expect(h.stdout("sed -n '1!G;h;$p' /s") == "3\n2\n1\n")                 // tac
        #expect(h.stdout("sed 'N;s/\\n/+/' /s") == "1+2\n3\n")
        #expect(h.stdout("sed -n 'n;p' /s") == "2\n")
        #expect(h.stdout("sed '$!N;P;D' /s") == "1\n2\n3\n")
        #expect(h.stdout("sed -n 'x;p' /s") == "\n1\n2\n")
        #expect(h.stdout("echo aaa | sed ':a;s/a/b/;ta'") == "bbb\n")
        #expect(h.stdout("sed ':a;N;$!ba;s/\\n/,/g' /s") == "1,2,3\n")          // join lines
        #expect(h.stdout("sed -n '2{p;b};p' /s") == "1\n2\n3\n")
        #expect(h.console("sed 'b nowhere' /s").contains("can't find label for jump to `nowhere'"))
    }

    @Test func sedInPlace() {
        let h = CommandHarness()
        h.write("/f", "alpha\nbeta\n")
        h.write("/g", "alpha\n")
        #expect(h.stdout("sed -i 's/alpha/ALPHA/' /f /g") == "")
        #expect(h.contents(of: "/f") == "ALPHA\nbeta\n")
        #expect(h.contents(of: "/g") == "ALPHA\n")
        h.run("sed -i.bak '1d' /f")
        #expect(h.contents(of: "/f") == "beta\n")
        #expect(h.contents(of: "/f.bak") == "ALPHA\nbeta\n")
        h.run("sed -n -i '/beta/p' /f")
        #expect(h.contents(of: "/f") == "beta\n")
        #expect(h.console("sed -i s/a/b/ /nope").contains("sed: can't read /nope: No such file or directory"))
        #expect(h.console("sed -i s/a/b/").contains("sed: no input files"))
    }

    @Test func sedErrors() {
        let h = CommandHarness()
        h.write("/s", "x\n")
        #expect(h.console("sed 'k' /s").contains("unknown command: `k'"))
        #expect(h.status("sed 'k' /s") == 1)
        #expect(h.console("sed 's/a/b' /s").contains("unterminated `s' command"))
        #expect(h.console("sed 's/a/b/z' /s").contains("unknown option to `s'"))
        #expect(h.console("sed '{p' /s").contains("unmatched `{'"))
        #expect(h.console("sed p /missing").contains("sed: /missing: No such file or directory"))
        #expect(h.status("sed p /missing") == 2)
        #expect(h.console("sed").contains("Usage: sed"))
        #expect(h.console("sed -Z p /s").contains("sed: invalid option -- 'Z'"))
        #expect(h.stdout("printf 'no newline' | sed 's/no/a/'") == "a newline\n")
    }
}
