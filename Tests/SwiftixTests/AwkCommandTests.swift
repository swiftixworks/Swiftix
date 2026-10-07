import Testing
@testable import Swiftix

/// The `awk` built-in and its helpers (`NumberFormat`, `AwkMath`). awk is
/// driven through a real shell with stdout / stderr redirected into VFS files,
/// so every assertion is on exact output; most expected values were
/// cross-checked against a reference awk.
@Suite("awk")
struct AwkCommandTests {

    private let people = "alice 30 nyc\nbob 25 sf\ncarol 35 nyc\ndave 40 la\n"
    private let passwd = """
        root:x:0:0:root:/root:/bin/sh
        alice:x:1000:1000:Alice:/home/alice:/bin/sh
        bob:x:1001:1001::/home/bob:/bin/false

        """
    private let fixtures = ["/f1": "x1 a\nx2 b\n", "/f2": "y1 c d\n"]

    // MARK: - Language (program passed with -f, so no shell quoting is involved)

    @Test func fieldSplittingDefault() {
        #expect(awk(#"{ print $1 }"#, input: "  a   b\tc  \nd e\n\nx\n").out == "a\nd\n\nx\n")
        #expect(awk(#"{ print NF }"#, input: "  a   b\tc  \nd e\n\nx\n").out == "3\n2\n0\n1\n")
        #expect(awk(#"{ print $NF }"#, input: "a b c\nd e\nf\n").out == "c\ne\nf\n")
        #expect(awk(#"{ print $(NF-1) "-" $0 }"#, input: "a b c\nd e\n").out == "b-a b c\nd-d e\n")
        #expect(awk(#"{ print $5 "|" NF }"#, input: "a b\n").out == "|2\n")
        #expect(awk(#"{ print }"#, input: "one\ntwo").out == "one\ntwo\n")
    }

    @Test func fieldSeparatorOption() {
        #expect(awk(#"{ print $1 }"#, #"-F:"#, input: passwd).out == "root\nalice\nbob\n")
        #expect(awk(#"{ print $1, $7 }"#, #"-F :"#, input: passwd).out
            == "root /bin/sh\nalice /bin/sh\nbob /bin/false\n")
        #expect(awk(#"{ print $2 }"#, #"-F '\t'"#, input: "a b\tc d\te\n").out == "c d\n")
        #expect(awk(#"{ print $2 }"#, #"-Ft"#, input: "a b\tc d\te\n").out == "c d\n")
        #expect(awk(#"{ print $2 "/" NF }"#, #"-F '[0-9]+'"#, input: "ab12cd345ef\n").out == "cd/3\n")
        #expect(awk(#"{ print $3 }"#, #"-F '|'"#, input: "a|b|c\n").out == "c\n")
        #expect(awk(#"{ print $2 }"#, #"-F ', *'"#, input: "a,  b,c\n").out == "b\n")
        #expect(awk(#"{ print NF ":" $2 ":" $3 }"#, #"-F,"#, input: "a,,c\n").out == "3::c\n")
        #expect(awk(#"BEGIN { FS = "," } { print $2 }"#, input: "a,b,c\n").out == "b\n")
        #expect(awk(#"{ print $1; FS = ":" }"#, input: "a:b c:d\ne:f g:h\n").out == "a:b\ne\n")
    }

    @Test func assignOptionAndOperands() {
        #expect(awk(#"BEGIN { print x, y + 1 }"#, #"-v x=hello -v y=41"#).out == "hello 42\n")
        #expect(awk(#"BEGIN { print (n == 10) ? "num" : "str" }"#, #"-v n=10.0"#).out == "num\n")
        #expect(awk(#"BEGIN { printf "%s", t }"#, #"-v 't=a\tb\n'"#).out == "a\tb\n")
        #expect(awk(#"{ print tag, $1 }"#, #"tag=A /f1 tag=B /f2"#, files: fixtures).out == "A x1\nA x2\nB y1\n")
        #expect(awk(#"END { print NR, x }"#, #"/f1 x=late"#, files: fixtures).out == "2 late\n")
    }

    @Test func beginEndAndCounters() {
        #expect(awk(#"BEGIN { print "start" } { n++ } END { print "lines", n, NR }"#, input: people).out
            == "start\nlines 4 4\n")
        #expect(awk(#"BEGIN { print "only" }"#).out == "only\n")
        #expect(awk(#"END { print $0, NF }"#, input: people).out == "dave 40 la 3\n")
        #expect(awk(#"{ print FILENAME, NR, FNR }"#, #"/f1 /f2"#, files: fixtures).out
            == "/f1 1 1\n/f1 2 2\n/f2 3 1\n")
        #expect(awk("BEGIN { x = 1 }\nBEGIN { print x + 1 }").out == "2\n")
    }

    @Test func patterns() {
        #expect(awk(#"/nyc/"#, input: people).out == "alice 30 nyc\ncarol 35 nyc\n")
        #expect(awk(#"!/nyc/"#, input: people).out == "bob 25 sf\ndave 40 la\n")
        #expect(awk(#"$2 > 28"#, input: people).out == "alice 30 nyc\ncarol 35 nyc\ndave 40 la\n")
        #expect(awk(#"NR % 2 == 0"#, input: people).out == "bob 25 sf\ndave 40 la\n")
        #expect(awk(#"$3 ~ /^n/ { print $1 }"#, input: people).out == "alice\ncarol\n")
        #expect(awk(#"$3 !~ /^n/ { print $1 }"#, input: people).out == "bob\ndave\n")
        #expect(awk(#"$1 ~ "^[ab]" { print $1 }"#, input: people).out == "alice\nbob\n")
        #expect(awk(#"NR == 2, NR == 3 { print NR ": " $1 }"#, input: people).out == "2: bob\n3: carol\n")
        #expect(awk(#"/bob/, /carol/"#, input: people).out == "bob 25 sf\ncarol 35 nyc\n")
        #expect(awk("/bob/, /bob/ { print $1 }\n/dave/, /nomatch/ { print \"tail\", $1 }", input: people).out
            == "bob\ntail dave\n")
        #expect(awk("$2 >= 30 && $3 == \"nyc\" { print $1 }\n$2 < 30 || $1 == \"dave\" { print \"*\" $1 }", input: people).out
            == "alice\n*bob\ncarol\n*dave\n")
        #expect(awk(#"NR == 1 { next } { print $1 }"#, input: people).out == "bob\ncarol\ndave\n")
        #expect(awk("# leading comment\n/alice/ { print \"A\" } # trailing\n/bob/ { print \"B\" } ; /carol/ { print \"C\" }", input: people).out
            == "A\nB\nC\n")
    }

    @Test func arithmetic() {
        #expect(awk(#"BEGIN { print 1 + 2 * 3, (1 + 2) * 3, 7 / 2, 7 % 3, -7 % 3, 2 ^ 10, 2 ^ 3 ^ 2, -2 ^ 2 }"#).out
            == "7 9 3.5 1 -1 1024 512 -4\n")
        #expect(awk(#"BEGIN { print 1e3, 0.1 + 0.2, 1 / 3, 100000 * 100000, 2 ^ 53, .5, 3.0 }"#).out
            == "1000 0.3 0.333333 10000000000 9007199254740992 0.5 3\n")
        #expect(awk(#"BEGIN { x = 5; x += 2; print x; x -= 3; print x; x *= 4; print x; x /= 8; print x; x %= 2; print x; x ^= 3; print x }"#).out
            == "7\n4\n16\n2\n0\n0\n")
        #expect(awk(#"BEGIN { i = 5; print i++, i, ++i, i--, i, --i; print -i, +i, !i, !0, !"", !"a" }"#).out
            == "5 6 7 7 6 5\n-5 5 0 1 1 0\n")
        #expect(awk(#"BEGIN { print 2 ** 3, 10 - 2 - 3, 2 * 3 % 4, 1 - -1, 2 ^ -1 }"#).out == "8 5 2 2 0.5\n")
        #expect(awk(#"BEGIN { print "3x" + 4, "abc" + 1, " 12 " * 2, "1e2" + 0, ".5" + 0, "+3" - 1 }"#).out
            == "7 1 24 100 0.5 2\n")
        #expect(awk(#"{ $2 = $2 * 2; print; print $1 + $3 }"#, input: "1 2 3\n").out == "1 4 3\n4\n")
        #expect(awk(#"BEGIN { print (1 == 1.0), ("a" < "b"), (10 < 9), ("10" < "9"), (2 < 10) }"#).out
            == "1 1 0 1 1\n")
        #expect(awk(#"BEGIN { print (1 > 2 ? "y" : "n"), (1 < 2 ? "y" : "n"); x = 3; print (x > 2 ? x > 5 ? "big" : "mid" : "small") }"#).out
            == "n y\nmid\n")
        #expect(awk(#"BEGIN { print 1 && 0, 1 || 0, 0 || 0, 1 && 1, "a" && "", !(1 && 0) }"#).out == "0 1 0 1 0 1\n")
        #expect(awk(#"BEGIN { print 0x1F + 1, 1 + 2 " " 3 + 4, 1 " " -1, 10 % 4 * 2 }"#).out == "32 3 7 1-1 4\n")
        #expect(awk(#"BEGIN { OFMT = "%.2f"; x = 3.14159; print x, x ""; CONVFMT = "%.3g"; print x, x "", 17 "" }"#).out
            == "3.14 3.14159\n3.14 3.14 17\n")
    }

    @Test func concatenationAndComparison() {
        #expect(awk(#"BEGIN { a = "x"; b = "y"; c = a b; print c, a "-" b, a b c, length(a b) }"#).out
            == "xy x-y xyxy 2\n")
        #expect(awk(#"{ print ($1 < $2), ($1 == $3), ($4 < $5), ($1 < "9"), ($6 == 0), ($7 == 0), ($1 == "10") }"#, input: "10 9 10.0 abc abd 0x 0\n").out
            == "0 1 1 1 0 1 1\n")
        #expect(awk(#"{ if ($1 == $2) print "eq"; else print "ne" }"#, input: "1 1.0\na a\n1 1x\n +5 5\n").out
            == "eq\neq\nne\neq\n")
        #expect(awk(#"BEGIN { if (x == 0 && x == "") print "uninit"; if (!x) print "false"; print length(x), x + 0 }"#).out
            == "uninit\nfalse\n0 0\n")
        #expect(awk(#"{ print ($1 ? "t" : "f") }"#, input: "0\n1\n0.0\na\n\n 0 \n").out == "f\nt\nf\nt\nf\nf\n")
    }

    @Test func arrays() {
        #expect(awk(#"BEGIN { a["x"] = 1; a["y"] = 2; a[3] = "three"; print a["x"] + a["y"], a[3], length(a); print ("x" in a), ("z" in a), (3 in a), length(a) }"#).out
            == "3 three 3\n1 0 1 3\n")
        #expect(awk(#"BEGIN { a["x"]; if ("x" in a) print "created"; if (!("q" in a)) print "absent"; if (a["q"] == "") print "empty"; print length(a) }"#).out
            == "created\nabsent\nempty\n2\n")
        #expect(awk(#"BEGIN { a[1] = "a"; a[2] = "b"; a[3] = "c"; delete a[2]; print length(a), (2 in a); delete a; print length(a) }"#).out
            == "2 0\n0\n")
        #expect(awk(#"BEGIN { a[1,2] = "p"; a["x","y"] = "q"; print a[1,2], ((1,2) in a), ((2,1) in a); for (k in a) { split(k, parts, SUBSEP); print parts[1] "+" parts[2] } }"#).out
            == "p 1 0\n1+2\nx+y\n")
        #expect(awk(#"BEGIN { for (i = 10; i >= 1; i--) sq[i] = i * i; for (k in sq) s = s k ":" sq[k] " "; print s }"#).out
            == "1:1 2:4 3:9 4:16 5:25 6:36 7:49 8:64 9:81 10:100 \n")
        #expect(awk(#"{ count[$3]++; total[$3] += $2 } END { for (city in count) print city, count[city], total[city] }"#, input: people).out
            == "la 1 40\nnyc 2 65\nsf 1 25\n")
        #expect(awk(#"{ for (i = 1; i <= NF; i++) freq[tolower($i)]++ } END { for (w in freq) print w, freq[w] }"#, input: "the cat The dog\nthe end\n").out
            == "cat 1\ndog 1\nend 1\nthe 3\n")
        #expect(awk(#"!seen[$0]++"#, input: "a\nb\na\nc\nb\n").out == "a\nb\nc\n")
        #expect(awk(#"{ line[NR] = $0 } END { for (i = NR; i >= 1; i--) print line[i] }"#, input: "1\n2\n3\n").out
            == "3\n2\n1\n")
        #expect(awk(#"BEGIN { a[1.0] = "one"; a["01"] = "zero-one"; print a[1], a[0.5 + 0.5], ("01" in a), a[01] }"#).out
            == "one one 1 one\n")
        #expect(awk(#"BEGIN { n = split("c a b", arr); for (k in arr) delete arr[k]; print n, length(arr) }"#).out
            == "3 0\n")
    }

    @Test func controlFlow() {
        #expect(awk(#"{ if ($2 >= 35) print $1, "senior"; else if ($2 >= 30) print $1, "mid"; else print $1, "junior" }"#, input: people).out
            == "alice mid\nbob junior\ncarol senior\ndave senior\n")
        #expect(awk(#"BEGIN { i = 0; while (i < 3) { printf "%d ", i; i++ }; print ""; do { printf "%d ", i; i-- } while (i > 0); print "" }"#).out
            == "0 1 2 \n3 2 1 \n")
        #expect(awk(#"BEGIN { for (i = 0; i < 10; i++) { if (i == 2) continue; if (i == 5) break; printf "%d", i }; print ""; for (;;) { if (++n > 3) break }; print n }"#).out
            == "0134\n4\n")
        #expect(awk("BEGIN { for (i = 1; i <= 3; i++)\n  for (j = 1; j <= i; j++)\n    s = s i j \" \"\n  print s }").out
            == "11 21 22 31 32 33 \n")
        #expect(awk("BEGIN {\n  if (1)\n    print \"a\"\n  else\n    print \"b\"\n  if (0) print \"c\"; else print \"d\"\n  if (0) { print \"e\" }\n  else { print \"f\" }\n  x = 1 +\\\n      2\n  print x\n}").out
            == "a\nd\nf\n3\n")
        #expect(awk(#"BEGIN { i = 5; while (i --> 0) ; print i; do i++; while (i < 3); print i }"#).out == "-1\n3\n")
        #expect(awk(#"{ if ($1 == "bob") next; print $1 } END { print "done" }"#, input: people).out
            == "alice\ncarol\ndave\ndone\n")
        #expect(awk(#"NR == 2 { exit } { print $1 } END { print "end ran" }"#, input: people).out
            == "alice\nend ran\n")
        #expect(awk("BEGIN { a = 1; b = 2\n c = a &&\n b\n print c, (a ||\n 0), (1 ? \"t\" : \"f\") }").out
            == "1 1 t\n")
    }

    @Test func printForms() {
        #expect(awk(#"BEGIN { OFS = "-"; ORS = "!\n"; print "a", "b", "c"; print; print "x" "y" }"#).out
            == "a-b-c!\n!\nxy!\n")
        #expect(awk(#"{ $1 = $1; print } END { print NF }"#, #"-v OFS=,"#, input: "a b  c\n").out == "a,b,c\n3\n")
        #expect(awk(#"BEGIN { OFS = ":" } { $3 = "X"; print; print NF }"#, input: "a b\n").out == "a:b:X\n3\n")
        #expect(awk(#"{ $5 = "e"; print; print NF }"#, #"-v OFS=,"#, input: "a b c\n").out == "a,b,c,,e\n5\n")
        #expect(awk(#"{ NF = 2; print; NF = 4; print; print NF }"#, #"-v OFS=-"#, input: "a b c d\n").out
            == "a-b\na-b--\n4\n")
        #expect(awk(#"{ $0 = "x y z"; print NF, $2; $2 = ""; print; print NF }"#, input: "a b\n").out
            == "3 y\nx  z\n3\n")
        #expect(awk(#"BEGIN { print (1, 2); print (3 > 2), ("a")("b"); print(1, 2) > "/dev/stdout" }"#).out
            == "1 2\n1 ab\n1 2\n")
        #expect(awk(#"BEGIN { print 1e6, 1e16, 1e17, 123456789, 0.000001, 1234567.5, -0.5, 1/4, 100/3, 1e-5 }"#).out
            == "1000000 10000000000000000 100000000000000000 123456789 1e-06 1.23457e+06 -0.5 0.25 33.3333 1e-05\n")
    }

    @Test func printfFormats() {
        #expect(awk(#"BEGIN { printf "%d|%5d|%-5d|%05d|%+d|% d|%i\n", 42, 42, 42, 42, 42, 42, -7.9 }"#).out
            == "42|   42|42   |00042|+42| 42|-7\n")
        #expect(awk(#"BEGIN { printf "%o|%x|%X|%u|%#o|%#x|%c|%c|%c\n", 8, 255, 255, 3, 8, 255, 65, "hello", "" }"#).out
            == "10|ff|FF|3|010|0xff|A|h|\n")
        #expect(awk(#"BEGIN { printf "%s|%10s|%-10s|%.2s|%5.1s|%%\n", "abc", "abc", "abc", "abc", "abc" }"#).out
            == "abc|       abc|abc       |ab|    a|%\n")
        #expect(awk(#"BEGIN { printf "%f|%.2f|%10.3f|%-10.1f|%010.2f|%+.1f|%.0f|%.0f|%.0f\n", 3.14159, 3.14159, 3.14159, 3.14159, -3.14159, 2.5, 0.5, 1.5, 2.5 }"#).out
            == "3.141590|3.14|     3.142|3.1       |-000003.14|+2.5|0|2|2\n")
        #expect(awk(#"BEGIN { printf "%e|%.2e|%E|%.0e|%12.3e\n", 12345.678, 0.00012345, 12345.678, 5e10, -1.5 }"#).out
            == "1.234568e+04|1.23e-04|1.234568E+04|5e+10|  -1.500e+00\n")
        #expect(awk(#"BEGIN { printf "%g|%g|%g|%g|%g|%G|%.3g|%.10g|%g|%#g\n", 100000, 1000000, 0.0001, 0.00001, 3.14159265, 1e-10, 2.5, 1/3, 0, 1.5 }"#).out
            == "100000|1e+06|0.0001|1e-05|3.14159|1E-10|2.5|0.3333333333|0|1.50000\n")
        #expect(awk(#"BEGIN { printf "%*d|%-*d|%.*f|%5.2f%%\n", 5, 42, 5, 42, 2, 3.14159, 99.5 }"#).out
            == "   42|42   |3.14|99.50%\n")
        #expect(awk(#"BEGIN { printf "%d %s %d|", "12abc", 3.0, 2147483648 * 4; printf "%s %s\n", 0.1 + 0.2, 1e18 }"#).out
            == "12 3 8589934592|0.3 1000000000000000000\n")
        #expect(awk(#"BEGIN { printf "%5s|%-5s|%05d\n", "é", "日本", -42 }"#).out == "    é|日本   |-0042\n")
        #expect(awk(#"BEGIN { printf "%.3f %.3f %.1f %.2f %.15g %.17g\n", 2.0005, 1.0005, 0.25, 1.005, 0.1, 0.1 }"#).out
            == "2.001 1.000 0.2 1.00 0.1 0.10000000000000001\n")
        #expect(awk(#"BEGIN { printf "no newline"; printf "%s-%s\n", "a"; printf("%d:%d\n", 1, 2) }"#).out
            == "no newlinea-\n1:2\n")
        #expect(awk(#"{ printf "%-6s %3d %s\n", $1, $2, toupper($3) }"#, input: people).out
            == "alice   30 NYC\nbob     25 SF\ncarol   35 NYC\ndave    40 LA\n")
        #expect(awk(#"BEGIN { x = sprintf("%03d-%s-%.1f", 7, "z", 2.25); print x, length(x) }"#).out
            == "007-z-2.2 9\n")
    }

    @Test func stringFunctions() {
        #expect(awk(#"BEGIN { print length("hello"), length(""), length(12345), length("日本語") } { print length, length($0), length($1) }"#, input: "ab cde\n").out
            == "5 0 5 3\n6 6 2\n")
        #expect(awk(#"BEGIN { s = "hello world"; print substr(s, 1, 5) "|" substr(s, 7) "|" substr(s, 0, 2) "|" substr(s, -1, 3) "|" substr(s, 10, 100) "|" substr(s, 20) "|" substr(s, 2, 0) "|" substr(s, 1.5, 2) }"#).out
            == "hello|world|h|h|ld|||el\n")
        #expect(awk(#"BEGIN { print index("hello", "ll"), index("hello", "z"), index("hello", ""), index("hello", "h"), index("abc", "abcd") }"#).out
            == "3 0 0 1 0\n")
        #expect(awk(#"BEGIN { print toupper("MiXed 123"), tolower("MiXed 123") }"#).out == "MIXED 123 mixed 123\n")
        #expect(awk(#"BEGIN { n = split("a b  c", p); print n, p[1], p[2], p[3]; n = split("a:b:c", p, ":"); print n, p[3]; n = split("a1b22c", p, /[0-9]+/); print n, p[1] p[2] p[3]; n = split("", p); print n, length(p); n = split("x.y.z", p, "."); print n, p[2] }"#).out
            == "3 a b c\n3 c\n3 abc\n0 0\n3 y\n")
        #expect(awk(#"BEGIN { n = split("2024-01-15", d, "-"); print d[1] + 0, d[2] + 0, d[3] + 0, (d[2] == 1) }"#).out
            == "2024 1 15 1\n")
        #expect(awk(#"{ n = sub(/o/, "0"); print n, $0 }"#, input: "foo boo\nxyz\n").out == "1 f0o boo\n0 xyz\n")
        #expect(awk(#"{ n = gsub(/o/, "0"); print n, $0, NF }"#, input: "foo boo\nxyz\n").out
            == "4 f00 b00 2\n0 xyz 1\n")
        #expect(awk(#"BEGIN { s = "hello"; gsub(/l/, "[&]", s); print s; t = "hello"; gsub(/l/, "\\&", t); print t; u = "a.b.c"; gsub(/\./, "-", u); print u; v = "aaa"; print gsub(/a/, "b", v), v }"#).out
            == "he[l][l]o\nhe&&o\na-b-c\n3 bbb\n")
        #expect(awk(#"BEGIN { s = "abc"; gsub(/x*/, "-", s); print s; t = "abc"; gsub(//, "-", t); print t; w = "hello world"; gsub(/o+/, "<&&>", w); print w }"#).out
            == "-a-b-c-\n-a-b-c-\nhell<oo> w<oo>rld\n")
        #expect(awk(#"{ gsub(/[0-9]+/, "N", $2); print; sub("^a", "A", $1); print }"#, input: "a1 b22 c333\n").out
            == "a1 bN c333\nA1 bN c333\n")
        #expect(awk(#"BEGIN { s = "foo bar"; sub(/o+/, "0", s); print s; sub(/^/, ">", s); print s; sub(/$/, "<", s); print s; gsub("a|r", "_", s); print s }"#).out
            == "f0 bar\n>f0 bar\n>f0 bar<\n>f0 b__<\n")
        #expect(awk(#"BEGIN { print match("foobar", /o+/), RSTART, RLENGTH; print match("foobar", /z/), RSTART, RLENGTH; if (match("key=value", /=/)) print substr("key=value", 1, RSTART - 1), substr("key=value", RSTART + 1) }"#).out
            == "2 2 2\n0 0 -1\nkey value\n")
        #expect(awk(#"BEGIN { s = "The Quick"; print (s ~ /quick/), (tolower(s) ~ /quick/), (s ~ "Q.*k$"), ("a.c" ~ /a\.c/), ("abc" ~ /a\.c/), ("a/b" ~ /a\/b/) }"#).out
            == "0 1 1 1 0 1\n")
    }

    @Test func mathFunctions() {
        #expect(awk(#"BEGIN { print int(3.9), int(-3.9), int("42abc"), int("x"), sqrt(16), sqrt(2), exp(0), exp(1), log(1), log(10) }"#).out
            == "3 -3 42 0 4 1.41421 1 2.71828 0 2.30259\n")
        #expect(awk(#"BEGIN { printf "%.12f %.12f %.12f %.12f\n", sin(0), sin(1), cos(0), cos(1); printf "%.12f %.12f %.12f\n", atan2(1, 1) * 4, atan2(0, -1), atan2(-1, 0) }"#).out
            == "0.000000000000 0.841470984808 1.000000000000 0.540302305868\n3.141592653590 3.141592653590 -1.570796326795\n")
        #expect(awk(#"BEGIN { printf "%.10f %.10f %.10f %.10f %.10f\n", exp(10), exp(-5.5), log(2), log(1e10), log(0.001); printf "%.10f %.10f %.10f %.10f\n", sin(100), cos(100), sin(-3.5), cos(1e6) }"#).out
            == "22026.4657948067 0.0040867714 0.6931471806 23.0258509299 -6.9077552790\n-0.5063656411 0.8623188723 0.3507832277 0.9367521275\n")
        #expect(awk(#"BEGIN { printf "%.10f %.10f %.10f %.6f %.10g\n", 2 ^ 0.5, 10 ^ -2.5, 1.5 ^ 2.5, 2 ^ 100.5 / 1e30, exp(log(7) * 3) }"#).out
            == "1.4142135624 0.0031622777 2.7556759606 1.792729 343\n")
        #expect(awk(#"BEGIN { printf "%.10f %.10f %.10f %.10f\n", atan2(1, 2), atan2(-3, -4), atan2(5, 0.001), atan2(0.3, 1) }"#).out
            == "0.4636476090 -2.4980915448 1.5705963268 0.2914567945\n")
    }

    @Test func userFunctions() {
        #expect(awk("function add(a, b) { return a + b }\nfunction fact(n) { return n <= 1 ? 1 : n * fact(n - 1) }\nBEGIN { print add(2, 3), fact(10), add(\"1\", fact(3)) }").out
            == "5 3628800 7\n")
        #expect(awk("function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2) }\nBEGIN { for (i = 0; i < 12; i++) printf \"%d \", fib(i); print \"\" }").out
            == "0 1 1 2 3 5 8 13 21 34 55 89 \n")
        #expect(awk("function fill(arr, n,   i) { for (i = 1; i <= n; i++) arr[i] = i * 2; return n }\nfunction sum(arr,   k, s) { for (k in arr) s += arr[k]; return s }\nBEGIN { fill(data, 4); print sum(data), length(data), (i \"\" == \"\") }").out
            == "20 4 1\n")
        #expect(awk("function setx(v) { v = 99; g = v }\nBEGIN { x = 1; setx(x); print x, g; setx(y); print y \"|\" g }").out
            == "1 99\n|99\n")
        #expect(awk("function noret() { }\nfunction early(n) { if (n > 0) return \"pos\"; return }\nBEGIN { print \"[\" noret() \"]\", early(1), \"[\" early(-1) \"]\" }").out
            == "[] pos []\n")
        #expect(awk("function max(a, b) { return a > b ? a : b }\n{ m = max(m, $2) } END { print m }", input: people).out
            == "40\n")
        #expect(awk("function join(a, n, sep,   i, s) {\n  for (i = 1; i <= n; i++) s = s (i > 1 ? sep : \"\") a[i]\n  return s\n}\n{ n = split($0, w); print join(w, n, \"+\") }", input: "a b c\nd\n").out
            == "a+b+c\nd\n")
        #expect(awk("function depth(n) { return n == 0 ? 0 : 1 + depth(n - 1) }\nBEGIN { print depth(1000) }").out
            == "1000\n")
        #expect(awk("function mk(a) { a[\"k\"] = 1 }\nfunction outer(b) { mk(b) }\nBEGIN { outer(arr); print length(arr), arr[\"k\"] }").out
            == "1 1\n")
        #expect(awk("function count(s, ch,   n, i) { for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++; return n + 0 }\nBEGIN { print count(\"banana\", \"a\"), count(\"banana\", \"z\") }").out
            == "3 0\n")
    }

    @Test func getline() {
        #expect(awk(#"BEGIN { while ((getline line < "/f1") > 0) n++; print n, line; close("/f1"); getline first < "/f1"; print first; print (getline x < "/nope") }"#, files: fixtures).out
            == "2 x2 b\nx1 a\n-1\n")
        #expect(awk(#"NR == 1 { getline; print "after", $0, NR } NR == 3 { getline nxt; print "var", nxt, $0, NR }"#, input: "l1\nl2\nl3\nl4\n").out
            == "after l2 2\nvar l4 l3 4\n")
        #expect(awk(#"BEGIN { while ((getline < "/f2") > 0) print NF ":" $1; print NR }"#, files: fixtures).out
            == "3:y1\n0\n")
        #expect(awk(#"BEGIN { getline; print "first=" $0; getline; print "second=" $0 } END { print NR }"#, input: "a\nb\nc\n").out
            == "first=a\nsecond=b\n3\n")
    }

    @Test func recordSeparators() {
        #expect(awk(#"BEGIN { RS = ";" } { print NR ":" $1 }"#, input: #"a 1;b 2;c 3"#).out == "1:a\n2:b\n3:c\n")
        #expect(awk(#"BEGIN { RS = "" } { print NR ": " $1 " / " $NF " / " NF }"#, input: "\n\na b\nc\n\n\n\nd e f\n\ng\n").out
            == "1: a / c / 3\n2: d / f / 3\n3: g / g / 1\n")
        #expect(awk(#"BEGIN { RS = ""; FS = ":" } { print $1 "|" $2 "|" $3 }"#, input: "a:b\nc\n\nd:e\n").out
            == "a|b|c\nd|e|\n")
        #expect(awk(#"{ print NR, $0 }"#, #"-v 'RS=,'"#, input: "x,y,z\n").out == "1 x\n2 y\n3 z\n\n")
    }

    @Test func specialVariables() {
        #expect(awk(#"BEGIN { print ARGC, ARGV[0], ARGV[1], ARGV[2] }"#, #"one two"#).out == "3 awk one two\n")
        #expect(awk(#"BEGIN { print length(SUBSEP), ENVIRON["AWKTEST"] "|" ("NOPE_X" in ENVIRON) }"#, environment: #"AWKTEST="env value""#).out
            == "1 env value|0\n")
        #expect(awk(#"BEGIN { ARGV[1] = "/f2"; ARGC = 2 } { print FILENAME ":" $1 }"#, #"/f1 /f1"#, files: fixtures).out
            == "/f2:y1\n")
        #expect(awk(#"{ print NR; NR = 10 } END { print NR }"#, input: "a\nb\n").out == "1\n11\n10\n")
        #expect(awk(#"BEGIN { SUBSEP = ":"; a[1,2] = 3; for (k in a) print k }"#).out == "1:2\n")
    }

    @Test func oneLiners() {
        #expect(awk(#"{ print $1 }"#, #"-F:"#, input: passwd).out == "root\nalice\nbob\n")
        #expect(awk(#"NR % 2 == 0"#, input: "1\n2\n3\n4\n5\n").out == "2\n4\n")
        #expect(awk(#"{ print $NF }"#, input: "a b c\nd e\n").out == "c\ne\n")
        #expect(awk(#"{ s += $1 } END { print s, s / NR }"#, input: "10\n20\n30\n40\n").out == "100 25\n")
        #expect(awk(#"END { print NR }"#, input: "a\nb\nc\n").out == "3\n")
        #expect(awk(#"NF"#, input: "a\n\n  \nb\n").out == "a\nb\n")
        #expect(awk(#"{ $1 = ""; print substr($0, 2) }"#, input: "drop this keep\n").out == "this keep\n")
        #expect(awk(#"length($0) > 3"#, input: "ab\nabcd\nabc\nabcde\n").out == "abcd\nabcde\n")
        #expect(awk(#"{ for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? OFS : ORS) }"#, input: "1 2 3\na b\n").out
            == "3 2 1\nb a\n")
        #expect(awk(#"$3 == "/bin/sh" || $NF ~ /false$/ { n++ } END { print n + 0 }"#, #"-F:"#, input: passwd).out
            == "1\n")
        #expect(awk(#"{ sum[$3] += $2; n[$3]++ } END { for (c in sum) printf "%s %.1f\n", c, sum[c] / n[c] }"#, input: people).out
            == "la 40.0\nnyc 32.5\nsf 25.0\n")
        #expect(awk(#"$2 > max { max = $2; who = $1 } END { print who, max }"#, input: people).out == "dave 40\n")
        #expect(awk(#"{ print NR ": " $0 }"#, input: "x\ny\n").out == "1: x\n2: y\n")
        #expect(awk(#"BEGIN { while (i++ < 3) print "line", i }"#).out == "line 1\nline 2\nline 3\n")
        #expect(awk(#"{ a[NR % 3] = a[NR % 3] $0 } END { print a[0], a[1], a[2] }"#, input: "1\n2\n3\n4\n5\n6\n7\n").out
            == "36 147 25\n")
    }

    @Test func fieldAssignment() {
        #expect(awk(#"{ $2++; $1 += 10; print; print $1 * 2 }"#, input: "5 7 x\n").out == "15 8 x\n30\n")
        #expect(awk(#"{ $NF = ""; print; print NF; $(NF + 2) = "z"; print; print NF }"#, input: "a b c\n").out
            == "a b \n3\na b   z\n5\n")
        #expect(awk(#"{ i = 1; print $i++, i, $i; print $(i + 1) $(1) $NF }"#, input: "a b c\n").out
            == "0 1 1\nb1c\n")
        #expect(awk(#"{ $3 = "new"; print $0; print $3 }"#, input: "one   two   three   four\n").out
            == "one two new four\nnew\n")
        #expect(awk(#"{ $0 = toupper($0); print $2; n = NF; $0 = ""; print n, NF }"#, input: "ab cd\n").out
            == "CD\n2 0\n")
        #expect(awk(#"{ print ($1 == 1000), ($1 == "1e3"), ($2 == "abc"), ($2 < "abd"), ($3 == 0) }"#, input: "1e3 abc\n").out
            == "1 1 1 1 1\n")
        #expect(awk(#"{ sub(/b/, "X", $2); print; print NF }"#, #"-F, -v 'OFS=;'"#, input: "a,b,c\n").out
            == "a;X;c\n3\n")
    }

    @Test func regexFeatures() {
        #expect(awk(#"/^[[:upper:]][a-z]+$/ { print "cap", $0 } /(ab)+c?$/ { print "ab", $0 } /a{2,}/ { print "aa", $0 } /^$/ { print "empty" } /x|y/ { print "xy", $0 } /[^a-z ]/ { print "other", $0 }"#, input: "Hello\nabab\nbaaad\n\nyes\nhello world\n").out
            == "cap Hello\nother Hello\nab abab\naa baaad\nempty\nxy yes\n")
        #expect(awk(#"{ print ($0 ~ "^" $1 "$"), ($2 ~ $1), ($1 ~ /./) }"#, input: "ab cabd\nab\n").out
            == "0 1 1\n1 0 1\n")
        #expect(awk(#"BEGIN { re = "[0-9]+"; s = "abc123def45"; while (match(s, re)) { printf "%s ", substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }; print "" }"#).out
            == "123 45 \n")
        #expect(awk(#"BEGIN { x = 4; print 6 / 2 / 3, x /2/ 1, ("a" ~ /a/ ? "y" : "n"); y = x / 2; y /= 2; print y }"#).out
            == "1 2 y\n1\n")
        #expect(awk(#"$0 ~ /\$[0-9]+\.[0-9][0-9]/ { print "price" } /a\/b/ { print "slash" } /\t/ { print "tab" } /\\/ { print "backslash" }"#, input: "$12.50\na/b\nx\ty\nc\\d\n").out
            == "price\nslash\ntab\nbackslash\n")
    }

    @Test func miscSemantics() {
        #expect(awk(#"FNR == 1 { print FILENAME; nextfile } { print "never" }"#, #"/f1 /f2"#, files: fixtures).out
            == "/f1\n/f2\n")
        #expect(awk(#"BEGIN { x = y = 3; z = x == 3 ? "three" : "other"; print x, y, z; a = b = c = "s"; print a b c }"#).out
            == "3 3 three\nsss\n")
        #expect(awk(#"BEGIN { a["k"] = 1; print ("k" in a) + 1, !("z" in a), (("k" in a) == 1) }"#).out == "2 1 1\n")
        #expect(awk(#"BEGIN { s = "a\tb\\c\"d\/e\101"; print s, length(s) }"#).out == "a\tb\\c\"d/eA 10\n")
        #expect(awk(#"BEGIN { print length() } END { print length }"#, input: "hello\n").out == "0\n5\n")
        #expect(awk(#"BEGIN { print substr("hello", 2, 3) substr("hello", 5), index("a b", " "), 1 2, 1 + 2 3 }"#).out
            == "ello 2 12 33\n")
        #expect(awk(#"BEGIN { n = 3; while (n) print n--; print (n ? "t" : "f"); s = "0"; if (s) print "string zero is true"; if (0 + s) print "no"; else print "numeric zero is false" }"#).out
            == "3\n2\n1\nf\nstring zero is true\nnumeric zero is false\n")
        #expect(awk(#"{ a = $1; b = $2 } END { print (a < b), (a "" < b "") }"#, input: "9 10\n").out == "1 0\n")
        #expect(awk(#"BEGIN { $0 = "a b c"; print NF, $2; $5 = "e"; print NF; print }"#).out == "3 b\n5\na b c  e\n")
        #expect(awk(#"BEGIN { printf "%s %s %s\n", 1e6, 1000000 * 3, 0.1 * 3; print 3 / 2 "", 1e6 "", 17 / 4 * 4 }"#).out
            == "1000000 3000000 0.3\n1.5 1000000 17\n")
        #expect(awk(#"BEGIN { OFS = "-" } { $1 = $1 } 1"#, input: "a b c\nd  e\n").out == "a-b-c\nd-e\n")
        #expect(awk(#"BEGIN { if (!(3 in a)) print "no"; a[3]; if (3 in a) print "yes"; if (("x", "y") in a) print "bad"; else print "ok" }"#).out
            == "no\nyes\nok\n")
    }

    @Test func functionCallsInsideExpressions() {
        #expect(awk("function id(x) { calls++; return x }\nBEGIN { a[id(1)] = id(\"one\"); a[id(2)] = id(\"two\"); print a[1], a[id(2)], calls; a[id(1)]++; x += id(5); x *= id(2); print a[1], x, (id(1) in a), ((id(1), id(2)) in a), calls }").out
            == "one two 5\n1 10 1 0 11\n")
        #expect(awk("function id(x) { calls++; return x }\nBEGIN { print (0 && id(1)), (1 || id(1)), calls + 0; print (1 && id(0)), (0 || id(7)), calls; print (id(1) ? id(\"t\") : id(\"f\")), calls }").out
            == "0 1 0\n0 1 2\nt 4\n")
        #expect(awk("function field() { return 2 }\nfunction text() { return \"banana\" }\n{ print $field(), $(field() + 1), -field(), !field(), field() \"\" field(), field() ^ field() }\nEND { s = text(); print length(text()), substr(text(), field()), index(text(), \"n\"), toupper(text()), (text() ~ /^b/), (text() ~ text()), sub(/a/, field(), s), s, split(text(), parts, \"a\"), parts[field()] }", input: "a b c\n").out
            == "b c -2 0 22 4\n6 anana 3 BANANA 1 1 1 b2nana 4 n\n")
        #expect(awk("function sep() { return \":\" }\nfunction pick(n) { return n }\n{ n = split($0, f, sep()); $pick(2) = toupper($pick(2)); f[pick(1)] = \"X\"; delete f[pick(3)]; print n, f[1], (3 in f), $0; gsub(sep(), \"-\", $pick(1)); print $1 }", input: "a:b c:d\n").out
            == "3 X 0 a:b C:D\na-b\n")
        #expect(awk("function twice(n,   i, out) { for (i = 0; i < 2; i++) out = out n; return out }\nfunction find(arr, want,   k) { for (k in arr) { if (arr[k] == want) return k }; return \"none\" }\nBEGIN { a[1] = \"x\"; a[2] = \"y\"; a[3] = \"z\"; printf \"%s %s %d\\n\", twice(\"ab\"), find(a, \"y\") find(a, \"q\"), length(twice(twice(\"c\"))) }").out
            == "abab 2none 4\n")
        #expect(awk("function nth(n,   i, r) { r = 1; for (i = 1; i <= 10; i++) { if (i % 2) continue; if (i > n) break; r *= i; while (1) { r++; if (r % 2 == 0) break } }; return r }\nBEGIN { print nth(2), nth(4), nth(100) }").out
            == "4 18 8822\n")
        #expect(awk("function isBig(v) { return v > 28 }\nfunction isBob(v) { return v == \"bob\" }\nisBig($2) { print \"big\", $1 }\nisBob($1), isBig($2) { print \"range\", $1 }", input: people).out
            == "big alice\nrange bob\nbig carol\nrange carol\nbig dave\n")
        #expect(awk("function next3(file,   line, n) { while (n < 3 && (getline line < file) > 0) n++; return n \":\" line }\nBEGIN { print next3(\"/f1\"), next3(\"/f2\"); while ((getline l < \"/f2\") > 0) c++; print c + 0 }", files: fixtures).out
            == "2:x2 b 1:y1 c d\n0\n")
        #expect(awk("function code() { return 3 }\nfunction hanoi(n, from, to, via) { if (n == 0) return 0; return hanoi(n - 1, from, via, to) + 1 + hanoi(n - 1, via, to, from) }\nBEGIN { print hanoi(10, \"a\", \"c\", \"b\"); exit code() }").out
            == "1023\n")
        #expect(awk("function push(stack, v) { stack[++stack[\"n\"]] = v }\nfunction pop(stack) { return stack[stack[\"n\"]--] }\nBEGIN { push(s, \"a\"); push(s, \"b\"); push(s, \"c\"); print pop(s) pop(s), s[\"n\"]; push(s, pop(s) \"!\"); print s[1] }").out
            == "cb 1\na!\n")
    }

    // MARK: - Redirection, errors, exit status

    @Test func outputRedirection() {
        let result = awk(#"""
            { print $1 > "/first"; print $2 >> "/second"; printf "%s!", $1 > ("/out_" NR) }
            END {
                close("/first")
                while ((getline line < "/first") > 0) print "back", line
                print "to stderr" > "/dev/stderr"
                print close("/never-opened")
            }
            """#, input: "a b\nc d\n", files: ["/second": "old\n"],
            reading: ["/first", "/second", "/out_1", "/out_2"])
        #expect(result.out == "back a\nback c\n-1\n")
        #expect(result.err == "to stderr\n")
        #expect(result.files["/first"] == "a\nc\n")
        #expect(result.files["/second"] == "old\nb\nd\n")
        #expect(result.files["/out_1"] == "a!")
        #expect(result.files["/out_2"] == "c!")
        #expect(result.status == "0\n")

        let failed = awk(#"BEGIN { print "x" > "/no/such/dir/file" }"#)
        #expect(failed.err == "awk: can't redirect to /no/such/dir/file: No such file or directory\n")
        #expect(failed.status == "2\n")
    }

    @Test func syntaxErrorsExitTwo() {
        let bad = awk("BEGIN { print 1 +* 2 }")
        #expect(bad.out == "")
        #expect(bad.err == "awk: syntax error at source line 1: unexpected *\n")
        #expect(bad.status == "2\n")

        let second = awk("BEGIN { print \"a\"\n x = }")
        #expect(second.err == "awk: syntax error at source line 2: unexpected }\n")
        #expect(second.status == "2\n")

        #expect(awk("BEGIN { print \"abc }").err == "awk: syntax error at source line 1: non-terminated string\n")
        #expect(awk("/abc { print }").err
            == "awk: syntax error at source line 1: non-terminated regular expression\n")
        #expect(awk("BEGIN { if (1) { print 1 }").err == "awk: syntax error at source line 1: missing '}'\n")
        #expect(awk("BEGIN { foo(1) }").err == "awk: syntax error at source line 1: calling undefined function foo\n")
        #expect(awk("BEGIN { break }").err == "awk: syntax error at source line 1: 'break' outside a loop\n")
        #expect(awk("BEGIN { return 1 }").err == "awk: syntax error at source line 1: 'return' outside a function\n")
        #expect(awk("BEGIN { 3 = x }").err
            == "awk: syntax error at source line 1: assignment to something that is not a variable\n")
        #expect(awk("BEGIN").err == "awk: syntax error at source line 1: BEGIN requires an action\n")
        #expect(awk("BEGIN { x = 1 &&\n\n }").err == "awk: syntax error at source line 3: unexpected }\n")
    }

    /// Nesting is bounded so that no program text can overflow the native
    /// stack (in the parser or in the tree walkers that follow it).
    @Test func deepNestingIsRejectedNotFatal() {
        func wrapped(_ open: String, _ close: String, _ count: Int, _ core: String = "7") -> String {
            "BEGIN { x = " + String(repeating: open, count: count) + core
                + String(repeating: close, count: count) + "; print x }"
        }
        let tooDeep = "awk: syntax error at source line 1: program nested too deeply\n"
        #expect(awk(wrapped("(", ")", 20)).out == "7\n")
        #expect(awk(wrapped("(", ")", 500)).err == tooDeep)
        #expect(awk(wrapped("- ", "", 40)).out == "7\n")
        #expect(awk(wrapped("(1 + ", ")", 14)).out == "21\n")
        #expect(awk(wrapped("length(1 ", ")", 20, "\"abc\"")).out == "2\n")
        #expect(awk(wrapped("- ", "", 5000)).err == tooDeep)
        #expect(awk(wrapped("!", "", 5000)).err == tooDeep)
        #expect(awk(wrapped("--", "", 5000)).err == tooDeep)
        #expect(awk(wrapped("a[", "]", 500)).err == tooDeep)
        #expect(awk(wrapped("length(", ")", 500)).err == tooDeep)
        #expect(awk(wrapped("1 ? 2 : ", "", 500)).err == tooDeep)
        #expect(awk(wrapped("2 ^ ", "", 500)).err == tooDeep)
        #expect(awk(wrapped("y = ", "", 500)).err == tooDeep)
        #expect(awk(wrapped("$", "", 500)).err == tooDeep)
        #expect(awk("BEGIN { x = 1" + String(repeating: " + 1", count: 40) + "; print x }").out == "41\n")
        #expect(awk("BEGIN { x = 1" + String(repeating: " + 1", count: 5000) + "; print x }").err == tooDeep)
        #expect(awk("BEGIN { x = 1" + String(repeating: " || y", count: 5000) + " }").err == tooDeep)
        #expect(awk("BEGIN { " + String(repeating: "if (1) { ", count: 20) + "print 7 "
            + String(repeating: "}", count: 20) + " }").out == "7\n")
        #expect(awk("BEGIN { " + String(repeating: "if (1) { ", count: 500) + "print 7 "
            + String(repeating: "}", count: 500) + " }").err == tooDeep)
        #expect(awk("BEGIN { " + String(repeating: "if (0) x = 1; else ", count: 40) + "print 7 }").out == "7\n")
        #expect(awk("BEGIN { " + String(repeating: "while (1) ", count: 500) + "break }").err == tooDeep)
        // Juxtaposition is flat, so a long concatenation is not "deep".
        let parts = (1...2000).map { "\"\($0 % 10)\"" }.joined(separator: " ")
        #expect(awk("BEGIN { s = " + parts + "; print length(s) }").out == "2000\n")
        let call = "function f(x) { return x }\nBEGIN { s = " + Array(repeating: "f(1)", count: 300).joined(separator: " ")
            + "; print length(s) }"
        #expect(awk(call).out == "300\n")
    }

    @Test func outputPipesRunThroughTheShell() {
        // The command's output is complete before awk exits.
        #expect(awk(#"{ print $1 | "sort -r" } END { print "done" }"#, input: "b\na\nc\n").out == "done\nc\nb\na\n")
        // close() drains the pipe, waits, and returns the command's status.
        #expect(awk(#"BEGIN { print "x" | "cat; exit 3"; r = close("cat; exit 3"); print "status", r }"#).out
            == "x\nstatus 3\n")
        #expect(awk(#"BEGIN { printf "%s\n", "b" | "sort"; print "a" | "sort" }"#).out == "a\nb\n")
        // Two commands at once: neither holds the other's pipe open.
        #expect(awk(#"{ print | "cat > /o1"; print $1 | "cat > /o2" }"#, input: "p q\nr s\n", reading: ["/o1", "/o2"]).files
            == ["/o1": "p q\nr s\n", "/o2": "p\nr\n"])
    }

    @Test func inputPipesAndSystem() {
        #expect(awk(#"BEGIN { "echo hello world" | getline line; print line; "echo a b c" | getline; print NF, $2 }"#).out
            == "hello world\n3 b\n")
        #expect(awk(#"BEGIN { while (("seq 1 3" | getline n) > 0) s += n; print s; print close("seq 1 3") }"#).out == "6\n0\n")
        #expect(awk(#"BEGIN { cmd = "printf 'x\\ny\\n'"; while ((cmd | getline v) > 0) out = out v; print out }"#).out == "xy\n")
        let system = awk(#"BEGIN { print "before"; r = system("echo mid; exit 4"); print "after", r }"#)
        #expect(system.out == "before\nmid\nafter 4\n")
        #expect(system.status == "0\n")
        #expect(awk(#"{ system("echo got " $1) }"#, input: "one\ntwo\n").out == "got one\ngot two\n")
    }

    @Test func runtimeErrorsExitTwo() {
        let division = awk(#"BEGIN { print "before"; print 1 / 0; print "after" }"#)
        #expect(division.out == "before\n")
        #expect(division.err == "awk: division by zero\n")
        #expect(division.status == "2\n")
        #expect(awk("BEGIN { x = 5 % 0 }").err == "awk: division by zero in %\n")
        #expect(awk("{ x = $1 / $2 }", input: "1 0\n").status == "2\n")
        #expect(awk(#"BEGIN { if ("a" ~ "(") print 1 }"#).err == "awk: invalid regular expression /(/\n")
        #expect(awk("BEGIN { a[1] = 1; a = 2 }").err == "awk: can't assign to a; it's an array name\n")
        #expect(awk("BEGIN { a = 1; a[1] = 2 }").err == "awk: can't use scalar a as an array\n")
        #expect(awk("BEGIN { a[1] = 1; print a + 1 }").err == "awk: can't use array a in a scalar context\n")
        #expect(awk("BEGIN { print $(-1) }").err == "awk: attempt to access field -1\n")
        #expect(awk("function f(a) { return a }\nBEGIN { f(1, 2) }").err
            == "awk: function f called with 2 arguments, accepts only 1\n")
        #expect(awk("function f(n) { return f(n + 1) }\nBEGIN { f(0) }").err
            == "awk: function call nesting too deep in f\n")
    }

    @Test func exitStatus() {
        #expect(awk("BEGIN { exit 3 }").status == "3\n")
        let main = awk(#"{ print $1; exit 4 } END { print "end" }"#, input: "a\nb\n")
        #expect(main.out == "a\nend\n")
        #expect(main.status == "4\n")
        let end = awk(#"END { print "x"; exit 1; print "unreachable" }"#, input: "a\n")
        #expect(end.out == "x\n")
        #expect(end.status == "1\n")
        let begin = awk(#"BEGIN { exit } END { print "end still runs" }"#, input: "a\n")
        #expect(begin.out == "end still runs\n")
        #expect(begin.status == "0\n")
        let nested = awk("function quit() { exit 7 }\n{ quit(); print \"no\" } END { print NR }", input: "a\nb\n")
        #expect(nested.out == "1\n")
        #expect(nested.status == "7\n")
        #expect(awk("BEGIN { exit 1 } END { exit }").status == "1\n")
    }

    @Test func commandLineErrors() {
        let missing = awk("{ print }", "/nope /f1", files: fixtures)
        #expect(missing.out == "x1 a\nx2 b\n")
        #expect(missing.err == "awk: /nope: No such file or directory\n")
        #expect(missing.status == "2\n")

        let harness = Harness(files: [:])
        harness.run("awk -z 'x' > /out 2> /err")
        harness.run("echo $? > /status")
        #expect(harness.contents(of: "/err").hasPrefix("awk: invalid option -- 'z'\n"))
        #expect(harness.contents(of: "/status") == "2\n")
        harness.run("awk > /out 2> /err")
        harness.run("echo $? > /status")
        #expect(harness.contents(of: "/err").hasPrefix("awk: usage: awk [-F fs]"))
        #expect(harness.contents(of: "/status") == "2\n")
        harness.run("awk -f /missing.awk > /out 2> /err")
        #expect(harness.contents(of: "/err") == "awk: can't open file /missing.awk: No such file or directory\n")
        harness.run("awk -v novalue 'BEGIN { }' > /out 2> /err")
        #expect(harness.contents(of: "/err") == "awk: invalid -v argument 'novalue': expected var=value\n")
        harness.run("awk --help > /out 2> /err")
        #expect(harness.contents(of: "/out").hasPrefix("Usage: awk [-F fs] [-v var=value]"))
    }

    @Test func multipleProgramFiles() {
        let harness = Harness(files: [
            "/lib.awk": "function double(n) { return n * 2 }\n",
            "/main.awk": "{ print double($1) }\n",
            "/nums": "1\n2\n",
        ])
        harness.run("awk -f /lib.awk -f /main.awk /nums > /out")
        #expect(harness.contents(of: "/out") == "2\n4\n")
    }

    @Test func randomNumbersAreDeterministic() {
        let program = """
            BEGIN {
                a = rand(); b = rand()
                print (a != b), (a >= 0 && a < 1), (b >= 0 && b < 1), srand(5), srand(7)
                x = rand(); srand(7); y = rand(); srand(8); z = rand()
                print (x == y), (x != z)
                for (i = 0; i < 1000; i++) { r = rand(); if (r < 0 || r >= 1) bad++; sum += r }
                print bad + 0, (sum > 400 && sum < 600)
                printf "%.6f\\n", a
            }
            """
        let first = awk(program)
        #expect(first.out.hasPrefix("1 1 1 0 5\n1 1\n0 1\n"))
        #expect(awk(program).out == first.out)
    }

    // MARK: - Through the shell: quoting, pipelines, streaming

    @Test func shellQuotedOneLiners() {
        let files = ["/passwd": passwd, "/people": people, "/nums": "1\n2\n3\n4\n5\n",
                     "/words": "the cat the dog\na cat\n"]
        #expect(sh("awk -F: '{print $1}' /passwd", files: files) == "root\nalice\nbob\n")
        #expect(sh("awk 'NR%2==0' /nums", files: files) == "2\n4\n")
        #expect(sh("awk '{print $NF}' /people", files: files) == "nyc\nsf\nnyc\nla\n")
        #expect(sh("awk '{ print $2, $1 }' /people", files: files) == "30 alice\n25 bob\n35 carol\n40 dave\n")
        #expect(sh(#"awk -v n=3 'BEGIN { for (i = 1; i <= n; i++) printf "%d ", i; print "" }'"#) == "1 2 3 \n")
        #expect(sh(#"awk -F '\t' -v OFS=, '{ $1 = $1; print }' /tabs"#, files: ["/tabs": "a b\tc\n"]) == "a b,c\n")
        #expect(sh("awk '/cat/ { n++ } END { print n }' /words", files: files) == "2\n")
        #expect(sh("awk '{ for (i = 1; i <= NF; i++) n[$i]++ } END { for (w in n) print w, n[w] }' /words",
                   files: files) == "a 1\ncat 2\ndog 1\nthe 2\n")
        #expect(sh("awk 'BEGIN { print length(\"a b\") }'") == "3\n")
    }

    @Test func pipelines() {
        let files = ["/people": people, "/f1": "x1 a\nx2 b\n", "/f2": "y1 c d\n"]
        #expect(sh("seq 5 | awk '{s+=$1} END {print s}'") == "15\n")
        #expect(sh("cat /people | awk '$2 > 28 { print $1 }' | sort", files: files) == "alice\ncarol\ndave\n")
        #expect(sh("cat /f1 | awk '{ print FILENAME \"|\" $1 }' /f2 -", files: files) == "/f2|y1\n|x1\n|x2\n")
        #expect(sh("seq 3 | awk '{ print $1 * $1 }' | awk '{ s = s $1 \",\" } END { print s }'") == "1,4,9,\n")
        #expect(sh("echo 'a b c' | awk '{ print NF }'") == "3\n")
        #expect(sh("seq 4 | awk 'BEGIN { getline; print \"first\", $0 } { print } END { print NR }'")
            == "first 1\n2\n3\n4\n4\n")
    }

    @Test func streamsLargeOutputAndStopsEarly() {
        // More output than any buffer: nothing may be lost or reordered.
        #expect(sh("awk 'BEGIN { for (i = 1; i <= 20000; i++) print i }' | awk '{ print $1 * 2 }' | tail -n 1")
            == "40000\n")
        let files = ["/big": (1...20000).map { "\($0) x\n" }.joined()]
        #expect(sh("awk '{ print $1 * 2 }' /big | tail -n 1", files: files) == "40000\n")
        #expect(sh("awk '{ print }' /big | awk '{ n++; s += $1 } END { print n, s }'", files: files)
            == "20000 200010000\n")
        #expect(sh("awk 'BEGIN { for (i = 1; i <= 30000; i++) print i, \"padding padding padding\" }' "
            + "| awk '{ n++; s += $1 } END { print n, s }'") == "30000 450015000\n")
        // The reader goes away after three lines: awk stops instead of spinning.
        #expect(sh("awk 'BEGIN { for (i = 1; i <= 200000; i++) print i }' | head -n 3") == "1\n2\n3\n")
        // stdout and stderr keep their relative order across the flush.
        let harness = Harness(files: [:])
        harness.run("awk 'BEGIN { print \"one\"; print \"two\" > \"/dev/stderr\"; print \"three\" }' > /out 2>&1")
        #expect(harness.contents(of: "/out") == "one\ntwo\nthree\n")
    }

    /// Entering an `async` function costs one event-loop job on this kernel,
    /// so the interpreter runs everything that cannot suspend synchronously.
    /// Guard that: these programs must finish inside a single default drain
    /// (100 000 jobs), which an `await` per statement would blow through.
    @Test func ordinaryProgramsStayWithinOneLoopDrain() {
        let lines = (1...20000).map { "\($0) x\n" }.joined()
        let harness = Harness(files: ["/big": lines])
        #expect(harness.run("awk '$1 % 2 { n++; s += $1 } END { print n, s }' /big > /out") == 0)
        #expect(harness.contents(of: "/out") == "10000 100000000\n")
        #expect(harness.run("awk 'BEGIN { for (i = 0; i < 200000; i++) if (i % 3) s += i; print s }' > /out") == 0)
        #expect(harness.contents(of: "/out") == "13333266667\n")
        #expect(harness.run("awk '{ a[NR] = $1 } END { for (k in a) t += a[k]; print t }' /big > /out") == 0)
        #expect(harness.contents(of: "/out") == "200010000\n")
    }

    @Test func longLoopsYieldAndFinish() {
        #expect(awk("BEGIN { for (i = 0; i < 400000; i++) s += i; print s }").out == "79999800000\n")
        #expect(awk("BEGIN { while (n < 300000) n++; print n }").out == "300000\n")
    }

    // MARK: - NumberFormat

    @Test func exactFloatFormatting() {
        #expect(NumberFormat.format(0.1, conversion: "f", precision: 20) == "0.10000000000000000555")
        #expect(NumberFormat.format(1e22, conversion: "f", precision: 0) == "10000000000000000000000")
        #expect(NumberFormat.format(1e23, conversion: "f", precision: 0) == "99999999999999991611392")
        #expect(NumberFormat.format(5e-324, conversion: "e", precision: 3) == "4.941e-324")
        #expect(NumberFormat.format(Double.greatestFiniteMagnitude, conversion: "g", precision: 17)
            == "1.7976931348623157e+308")
        #expect(NumberFormat.format(0.5, conversion: "f", precision: 0) == "0")
        #expect(NumberFormat.format(1.5, conversion: "f", precision: 0) == "2")
        #expect(NumberFormat.format(2.5, conversion: "f", precision: 0) == "2")
        #expect(NumberFormat.format(0.125, conversion: "f", precision: 2) == "0.12")
        #expect(NumberFormat.format(0.375, conversion: "f", precision: 2) == "0.38")
        #expect(NumberFormat.format(1.005, conversion: "f", precision: 2) == "1.00")
        #expect(NumberFormat.format(-0.0, conversion: "f", precision: 1) == "-0.0")
        #expect(NumberFormat.format(0, conversion: "e") == "0.000000e+00")
        #expect(NumberFormat.format(0.999999, conversion: "f", precision: 3) == "1.000")
        #expect(NumberFormat.format(123.456, conversion: "f") == "123.456000")
        #expect(NumberFormat.format(0.000123456, conversion: "f", precision: 5) == "0.00012")
    }

    @Test func generalAndExponentForms() {
        #expect(NumberFormat.format(0.0001234, conversion: "g") == "0.0001234")
        #expect(NumberFormat.format(0.00001234, conversion: "g") == "1.234e-05")
        #expect(NumberFormat.format(123456789, conversion: "g") == "1.23457e+08")
        #expect(NumberFormat.format(123456, conversion: "g") == "123456")
        #expect(NumberFormat.format(9.9999995, conversion: "g") == "10")
        #expect(NumberFormat.format(999999.5, conversion: "g") == "1e+06")
        #expect(NumberFormat.format(100, conversion: "g", flags: .alternate) == "100.000")
        #expect(NumberFormat.format(0, conversion: "g") == "0")
        #expect(NumberFormat.format(1e100, conversion: "G", precision: 3) == "1E+100")
        #expect(NumberFormat.format(3, conversion: "g", precision: 0) == "3")
        #expect(NumberFormat.format(12345.678, conversion: "E", precision: 2) == "1.23E+04")
        #expect(NumberFormat.format(9.995, conversion: "e", precision: 2) == "9.99e+00")
        #expect(NumberFormat.format(9.996, conversion: "e", precision: 2) == "1.00e+01")
        #expect(NumberFormat.format(1, conversion: "e", flags: .alternate, precision: 0) == "1.e+00")
    }

    @Test func flagsWidthAndSpecialValues() {
        #expect(NumberFormat.format(123.456, conversion: "e", flags: .plus, width: 14, precision: 2)
            == "     +1.23e+02")
        #expect(NumberFormat.format(3.5, conversion: "f", flags: .zeroPad, width: 8, precision: 2) == "00003.50")
        #expect(NumberFormat.format(-3.5, conversion: "f", flags: .zeroPad, width: 8, precision: 2) == "-0003.50")
        #expect(NumberFormat.format(3.5, conversion: "f", flags: .leftAlign, width: 8, precision: 1) == "3.5     ")
        #expect(NumberFormat.format(3.5, conversion: "f", flags: .space, precision: 1) == " 3.5")
        #expect(NumberFormat.format(.infinity, conversion: "f", flags: .zeroPad, width: 6) == "   inf")
        #expect(NumberFormat.format(-.infinity, conversion: "E") == "-INF")
        #expect(NumberFormat.format(.nan, conversion: "G") == "NAN")
        #expect(NumberFormat.formatInteger(-42, conversion: "d", flags: .zeroPad, width: 6) == "-00042")
        #expect(NumberFormat.formatInteger(255, conversion: "x", flags: .alternate) == "0xff")
        #expect(NumberFormat.formatInteger(255, conversion: "X", width: 4) == "  FF")
        #expect(NumberFormat.formatInteger(8, conversion: "o", flags: .alternate) == "010")
        #expect(NumberFormat.formatInteger(5, conversion: "d", width: 6, precision: 3) == "   005")
        #expect(NumberFormat.formatInteger(5, conversion: "d", flags: [.zeroPad, .plus], width: 6, precision: 3)
            == "  +005")
        #expect(NumberFormat.formatInteger(-1, conversion: "u") == "18446744073709551615")
        #expect(NumberFormat.formatInteger(0, conversion: "d", precision: 0) == "")
        #expect(NumberFormat.formatInteger(.min, conversion: "d") == "-9223372036854775808")
        #expect(NumberFormat.pad(body: "ab", flags: .leftAlign, width: 4) == "ab  ")
    }

    @Test func parseDoubleTakesLongestNumericPrefix() {
        func parse(_ text: String) -> String {
            guard let parsed = NumberFormat.parseDouble(text[...]) else { return "nil" }
            return "\(parsed.value)/\(parsed.length)"
        }
        #expect(parse("  12.5e3xyz") == "12500.0/8")
        #expect(parse("1e") == "1.0/1")
        #expect(parse("1.5e+") == "1.5/3")
        #expect(parse(".5") == "0.5/2")
        #expect(parse("+7.") == "7.0/3")
        #expect(parse("-3") == "-3.0/2")
        #expect(parse("-.e") == "nil")
        #expect(parse("abc") == "nil")
        #expect(parse("") == "nil")
        #expect(parse("0x10") == "0.0/1")
        #expect(parse("inf") == "nil")
        #expect(parse("1e400") == "inf/5")
        #expect(parse("\t42 ") == "42.0/3")
        #expect(parse("0.1") == "0.1/3")
    }

    /// Every finite double must round-trip through 17 significant digits —
    /// a property that only holds if the decimal expansion is exact.
    @Test func seventeenDigitsRoundTrip() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<2000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = Double(bitPattern: state)
            guard value.isFinite else { continue }
            let text = NumberFormat.format(value, conversion: "e", precision: 16)
            #expect(Double(text) == value, "\(value) formatted as \(text)")
        }
    }

    // MARK: - AwkMath

    @Test func mathFunctionsAreAccurate() {
        func close(_ actual: Double, _ expected: Double) -> Bool {
            (actual - expected).magnitude <= 1e-13 * Swift.max(1, expected.magnitude)
        }
        #expect(close(AwkMath.exp(1), 2.718281828459045))
        #expect(close(AwkMath.exp(-20), 2.061153622438558e-09 ))
        #expect(close(AwkMath.exp(700) / 1e304, 1.0142320547350045))
        #expect(AwkMath.exp(0) == 1)
        #expect(AwkMath.exp(1000) == .infinity)
        #expect(AwkMath.exp(-1000) == 0)
        #expect(close(AwkMath.log(2), 0.6931471805599453))
        #expect(close(AwkMath.log(1e-300), -690.7755278982137))
        #expect(close(AwkMath.log(123456.789), 11.723646487185881))
        #expect(AwkMath.log(1) == 0)
        #expect(AwkMath.log(0) == -.infinity)
        #expect(AwkMath.log(-1).isNaN)
        #expect(close(AwkMath.sin(0.5), 0.479425538604203))
        #expect(close(AwkMath.sin(10), -0.5440211108893698))
        #expect(close(AwkMath.cos(10), -0.8390715290764524))
        #expect(close(AwkMath.sin(AwkMath.pi / 6), 0.5))
        #expect(close(AwkMath.cos(AwkMath.pi / 3), 0.5))
        #expect(close(AwkMath.sin(-100), 0.5063656411097588))
        #expect(close(AwkMath.cos(1e6), 0.9367521275331447))
        #expect(close(AwkMath.atan2(1, 1) * 4, AwkMath.pi))
        #expect(close(AwkMath.atan2(1, 0), AwkMath.pi / 2))
        #expect(close(AwkMath.atan2(0, -1), AwkMath.pi))
        #expect(close(AwkMath.atan2(-3, -4), -2.498091544796509))
        #expect(close(AwkMath.atan(1e10), 1.5707963266948965))
        #expect(close(AwkMath.pow(2, 0.5), 1.4142135623730951))
        #expect(AwkMath.pow(2, 10) == 1024)
        #expect(AwkMath.pow(2, -2) == 0.25)
        #expect(AwkMath.pow(0, 0) == 1)
        #expect(AwkMath.pow(-2, 3) == -8)
        #expect(AwkMath.pow(-8, 1.0 / 3).isNaN)
        #expect(close(AwkMath.pow(10, -2.5), 0.0031622776601683794))
        var x = 0.001
        while x < 1e6 {
            #expect(close(AwkMath.exp(AwkMath.log(x)), x))
            let s = AwkMath.sin(x), c = AwkMath.cos(x)
            #expect(close(s * s + c * c, 1))
            #expect(close(AwkMath.atan2(s, c), AwkMath.atan2(AwkMath.sin(x), AwkMath.cos(x))))
            x *= 3.7
        }
    }

    // MARK: - Harness

    private struct Outcome {
        let out: String
        let err: String
        let status: String
        var files: [String: String] = [:]
    }

    /// Boots a kernel + pty + shell and reads result files back out of the VFS.
    private final class Harness {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()

        init(files: [String: String]) {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak pty] in
                guard let pty else { return }
                _ = pty.readForApp(max: 65_535)
            }
            kernel.spawn("seed") { ctx in
                for (path, text) in files {
                    if let fd = ctx.open(path, create: true) {
                        ctx.write(fd, Array(text.utf8))
                        ctx.close(fd)
                    }
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

        /// Feed one command line and drain the loop. One drain is capped by
        /// the loop's step budget, so keep draining until nothing is left;
        /// returns how many extra drains that took.
        @discardableResult
        func run(_ line: String) -> Int {
            pty.writeFromApp(Array((line + "\n").utf8))
            var extraDrains = 0
            while loop.runUntilIdle() == .budgetExceeded, extraDrains < 100_000 { extraDrains += 1 }
            return extraDrains
        }

        func contents(of path: String) -> String {
            final class Box { var text: String? }
            let box = Box()
            kernel.spawn("read") { ctx in
                if let fd = ctx.open(path) {
                    box.text = String(decoding: ctx.read(fd, max: 1 << 22), as: UTF8.self)
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
            return box.text ?? "<missing>"
        }
    }

    /// Run `awk -f <program> <arguments> [input file]`. The program travels in
    /// a file, so it reaches awk without any shell quoting in the way.
    private func awk(_ program: String,
                     _ arguments: String = "",
                     input: String? = nil,
                     files: [String: String] = [:],
                     environment: String? = nil,
                     reading: [String] = []) -> Outcome {
        var seeded = files
        seeded["/prog.awk"] = program
        if let input { seeded["/in"] = input }
        let harness = Harness(files: seeded)
        if let environment { harness.run("export \(environment)") }
        let operands = input == nil ? "" : " /in"
        harness.run("awk -f /prog.awk \(arguments)\(operands) > /out 2> /err")
        harness.run("echo $? > /status")
        var outcome = Outcome(out: harness.contents(of: "/out"),
                              err: harness.contents(of: "/err"),
                              status: harness.contents(of: "/status"))
        for path in reading { outcome.files[path] = harness.contents(of: path) }
        return outcome
    }

    /// Run one shell command line with stdout captured; returns that output.
    private func sh(_ line: String, files: [String: String] = [:]) -> String {
        let harness = Harness(files: files)
        harness.run("\(line) > /out 2> /err")
        return harness.contents(of: "/out")
    }
}
