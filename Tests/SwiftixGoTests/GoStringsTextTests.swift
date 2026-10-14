/// The functions of `strings` that are Go text of the library
/// (`Sources/SwiftixGoLibrary/strings`): replacing, cutting, splitting with a
/// count, trimming a set, the functions that take a function, `Replacer`,
/// and the whole of `Reader`. They are built on the searches the VM does
/// natively, so most cost VM instructions for each piece and not for each
/// byte.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports. The text
/// itself is held to Go's `strings` with random inputs, bytes that are no
/// UTF-8 among them, by `Scripts/go-library-harness/run.sh strings`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go strings in Go text")
struct GoStringsTextTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// `Replace` with every count, an empty old string (found before each
    /// character and at the end), and an old string that is the new one.
    @Test func replaceAndReplaceAll() throws {
        #expect(
            try runGoMain(
                #"""
                for _, s := range texts {
                    for _, old := range seps {
                        fmt.Printf("%q %q:", s, old)
                        for _, n := range []int{-1, 0, 1, 2, 100} {
                            fmt.Printf(" %q", strings.Replace(s, old, "<>", n))
                        }
                        fmt.Printf(" %q %q\n", strings.ReplaceAll(s, old, ""), strings.ReplaceAll(s, old, old))
                    }
                }
                """#,
                imports: ["fmt", "strings"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == #"""
                "" "": "<>" "" "<>" "<>" "<>" "" ""
                "" "a": "" "" "" "" "" "" ""
                "" ",": "" "" "" "" "" "" ""
                "" "ab": "" "" "" "" "" "" ""
                "" "aa": "" "" "" "" "" "" ""
                "" "é": "" "" "" "" "" "" ""
                "" "世": "" "" "" "" "" "" ""
                "" ",,": "" "" "" "" "" "" ""
                "" "x": "" "" "" "" "" "" ""
                "" "xa": "" "" "" "" "" "" ""
                "a" "": "<>a<>" "a" "<>a" "<>a<>" "<>a<>" "a" "a"
                "a" "a": "<>" "a" "<>" "<>" "<>" "" "a"
                "a" ",": "a" "a" "a" "a" "a" "a" "a"
                "a" "ab": "a" "a" "a" "a" "a" "a" "a"
                "a" "aa": "a" "a" "a" "a" "a" "a" "a"
                "a" "é": "a" "a" "a" "a" "a" "a" "a"
                "a" "世": "a" "a" "a" "a" "a" "a" "a"
                "a" ",,": "a" "a" "a" "a" "a" "a" "a"
                "a" "x": "a" "a" "a" "a" "a" "a" "a"
                "a" "xa": "a" "a" "a" "a" "a" "a" "a"
                "abc" "": "<>a<>b<>c<>" "abc" "<>abc" "<>a<>bc" "<>a<>b<>c<>" "abc" "abc"
                "abc" "a": "<>bc" "abc" "<>bc" "<>bc" "<>bc" "bc" "abc"
                "abc" ",": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "abc" "ab": "<>c" "abc" "<>c" "<>c" "<>c" "c" "abc"
                "abc" "aa": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "abc" "é": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "abc" "世": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "abc" ",,": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "abc" "x": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "abc" "xa": "abc" "abc" "abc" "abc" "abc" "abc" "abc"
                "a,b,,c" "": "<>a<>,<>b<>,<>,<>c<>" "a,b,,c" "<>a,b,,c" "<>a<>,b,,c" "<>a<>,<>b<>,<>,<>c<>" "a,b,,c" "a,b,,c"
                "a,b,,c" "a": "<>,b,,c" "a,b,,c" "<>,b,,c" "<>,b,,c" "<>,b,,c" ",b,,c" "a,b,,c"
                "a,b,,c" ",": "a<>b<><>c" "a,b,,c" "a<>b,,c" "a<>b<>,c" "a<>b<><>c" "abc" "a,b,,c"
                "a,b,,c" "ab": "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "aa": "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "é": "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "世": "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" ",,": "a,b<>c" "a,b,,c" "a,b<>c" "a,b<>c" "a,b<>c" "a,bc" "a,b,,c"
                "a,b,,c" "x": "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "xa": "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c" "a,b,,c"
                "," "": "<>,<>" "," "<>," "<>,<>" "<>,<>" "," ","
                "," "a": "," "," "," "," "," "," ","
                "," ",": "<>" "," "<>" "<>" "<>" "" ","
                "," "ab": "," "," "," "," "," "," ","
                "," "aa": "," "," "," "," "," "," ","
                "," "é": "," "," "," "," "," "," ","
                "," "世": "," "," "," "," "," "," ","
                "," ",,": "," "," "," "," "," "," ","
                "," "x": "," "," "," "," "," "," ","
                "," "xa": "," "," "," "," "," "," ","
                ",," "": "<>,<>,<>" ",," "<>,," "<>,<>," "<>,<>,<>" ",," ",,"
                ",," "a": ",," ",," ",," ",," ",," ",," ",,"
                ",," ",": "<><>" ",," "<>," "<><>" "<><>" "" ",,"
                ",," "ab": ",," ",," ",," ",," ",," ",," ",,"
                ",," "aa": ",," ",," ",," ",," ",," ",," ",,"
                ",," "é": ",," ",," ",," ",," ",," ",," ",,"
                ",," "世": ",," ",," ",," ",," ",," ",," ",,"
                ",," ",,": "<>" ",," "<>" "<>" "<>" "" ",,"
                ",," "x": ",," ",," ",," ",," ",," ",," ",,"
                ",," "xa": ",," ",," ",," ",," ",," ",," ",,"
                "héllo wörld" "": "<>h<>é<>l<>l<>o<> <>w<>ö<>r<>l<>d<>" "héllo wörld" "<>héllo wörld" "<>h<>éllo wörld" "<>h<>é<>l<>l<>o<> <>w<>ö<>r<>l<>d<>" "héllo wörld" "héllo wörld"
                "héllo wörld" "a": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" ",": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "ab": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "aa": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "é": "h<>llo wörld" "héllo wörld" "h<>llo wörld" "h<>llo wörld" "h<>llo wörld" "hllo wörld" "héllo wörld"
                "héllo wörld" "世": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" ",,": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "x": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "xa": "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld" "héllo wörld"
                "世界" "": "<>世<>界<>" "世界" "<>世界" "<>世<>界" "<>世<>界<>" "世界" "世界"
                "世界" "a": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" ",": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" "ab": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" "aa": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" "é": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" "世": "<>界" "世界" "<>界" "<>界" "<>界" "界" "世界"
                "世界" ",,": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" "x": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                "世界" "xa": "世界" "世界" "世界" "世界" "世界" "世界" "世界"
                " \t x \n" "": "<> <>\t<> <>x<> <>\n<>" " \t x \n" "<> \t x \n" "<> <>\t x \n" "<> <>\t<> <>x<> <>\n<>" " \t x \n" " \t x \n"
                " \t x \n" "a": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" ",": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "ab": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "aa": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "é": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "世": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" ",,": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "x": " \t <> \n" " \t x \n" " \t <> \n" " \t <> \n" " \t <> \n" " \t  \n" " \t x \n"
                " \t x \n" "xa": " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n" " \t x \n"
                "aaa" "": "<>a<>a<>a<>" "aaa" "<>aaa" "<>a<>aa" "<>a<>a<>a<>" "aaa" "aaa"
                "aaa" "a": "<><><>" "aaa" "<>aa" "<><>a" "<><><>" "" "aaa"
                "aaa" ",": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "aaa" "ab": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "aaa" "aa": "<>a" "aaa" "<>a" "<>a" "<>a" "a" "aaa"
                "aaa" "é": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "aaa" "世": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "aaa" ",,": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "aaa" "x": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "aaa" "xa": "aaa" "aaa" "aaa" "aaa" "aaa" "aaa" "aaa"
                "abab" "": "<>a<>b<>a<>b<>" "abab" "<>abab" "<>a<>bab" "<>a<>b<>a<>b<>" "abab" "abab"
                "abab" "a": "<>b<>b" "abab" "<>bab" "<>b<>b" "<>b<>b" "bb" "abab"
                "abab" ",": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "abab" "ab": "<><>" "abab" "<>ab" "<><>" "<><>" "" "abab"
                "abab" "aa": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "abab" "é": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "abab" "世": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "abab" ",,": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "abab" "x": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "abab" "xa": "abab" "abab" "abab" "abab" "abab" "abab" "abab"
                "xxabcxx" "": "<>x<>x<>a<>b<>c<>x<>x<>" "xxabcxx" "<>xxabcxx" "<>x<>xabcxx" "<>x<>x<>a<>b<>c<>x<>x<>" "xxabcxx" "xxabcxx"
                "xxabcxx" "a": "xx<>bcxx" "xxabcxx" "xx<>bcxx" "xx<>bcxx" "xx<>bcxx" "xxbcxx" "xxabcxx"
                "xxabcxx" ",": "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "ab": "xx<>cxx" "xxabcxx" "xx<>cxx" "xx<>cxx" "xx<>cxx" "xxcxx" "xxabcxx"
                "xxabcxx" "aa": "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "é": "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "世": "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" ",,": "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "x": "<><>abc<><>" "xxabcxx" "<>xabcxx" "<><>abcxx" "<><>abc<><>" "abc" "xxabcxx"
                "xxabcxx" "xa": "x<>bcxx" "xxabcxx" "x<>bcxx" "x<>bcxx" "x<>bcxx" "xbcxx" "xxabcxx"

                """#)
    }

    /// `SplitN`, `SplitAfter`, and `SplitAfterN`: the pieces, and the length,
    /// capacity, and nil-ness of the slice, which are Go's too.
    @Test func splitWithACountAndAfter() throws {
        #expect(
            try runGoMain(
                """
                for _, s := range texts {
                    for _, sep := range seps {
                        fmt.Printf("%q %q: %s", s, sep, d(strings.SplitAfter(s, sep)))
                        for _, n := range []int{-1, 0, 1, 2, 3, 100} {
                            fmt.Printf(" | %s | %s", d(strings.SplitN(s, sep, n)), d(strings.SplitAfterN(s, sep, n)))
                        }
                        fmt.Println()
                    }
                }
                """,
                imports: ["fmt", "strings"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == #"""
                "" "": [] 0 0 false | [] 0 0 false | [] 0 0 false | [] 0 0 true | [] 0 0 true | [] 0 0 false | [] 0 0 false | [] 0 0 false | [] 0 0 false | [] 0 0 false | [] 0 0 false | [] 0 0 false | [] 0 0 false
                "" "a": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" ",": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" "ab": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" "aa": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" "é": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" "世": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" ",,": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" "x": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "" "xa": [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [] 0 0 true | [] 0 0 true | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false | [""] 1 1 false
                "a" "": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false
                "a" "a": ["a" ""] 2 2 false | ["" ""] 2 2 false | ["a" ""] 2 2 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["" ""] 2 2 false | ["a" ""] 2 2 false | ["" ""] 2 2 false | ["a" ""] 2 2 false | ["" ""] 2 2 false | ["a" ""] 2 2 false
                "a" ",": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" "ab": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" "aa": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" "é": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" "世": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" ",,": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" "x": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "a" "xa": ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a"] 1 1 false | ["a"] 1 1 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false | ["a"] 1 2 false
                "abc" "": ["a" "b" "c"] 3 3 false | ["a" "b" "c"] 3 3 false | ["a" "b" "c"] 3 3 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["a" "bc"] 2 2 false | ["a" "bc"] 2 2 false | ["a" "b" "c"] 3 3 false | ["a" "b" "c"] 3 3 false | ["a" "b" "c"] 3 3 false | ["a" "b" "c"] 3 3 false
                "abc" "a": ["a" "bc"] 2 2 false | ["" "bc"] 2 2 false | ["a" "bc"] 2 2 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["" "bc"] 2 2 false | ["a" "bc"] 2 2 false | ["" "bc"] 2 3 false | ["a" "bc"] 2 3 false | ["" "bc"] 2 4 false | ["a" "bc"] 2 4 false
                "abc" ",": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "abc" "ab": ["ab" "c"] 2 2 false | ["" "c"] 2 2 false | ["ab" "c"] 2 2 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["" "c"] 2 2 false | ["ab" "c"] 2 2 false | ["" "c"] 2 3 false | ["ab" "c"] 2 3 false | ["" "c"] 2 4 false | ["ab" "c"] 2 4 false
                "abc" "aa": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "abc" "é": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "abc" "世": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "abc" ",,": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "abc" "x": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "abc" "xa": ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abc"] 1 1 false | ["abc"] 1 1 false | ["abc"] 1 2 false | ["abc"] 1 2 false | ["abc"] 1 3 false | ["abc"] 1 3 false | ["abc"] 1 4 false | ["abc"] 1 4 false
                "a,b,,c" "": ["a" "," "b" "," "," "c"] 6 6 false | ["a" "," "b" "," "," "c"] 6 6 false | ["a" "," "b" "," "," "c"] 6 6 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a" ",b,,c"] 2 2 false | ["a" ",b,,c"] 2 2 false | ["a" "," "b,,c"] 3 3 false | ["a" "," "b,,c"] 3 3 false | ["a" "," "b" "," "," "c"] 6 6 false | ["a" "," "b" "," "," "c"] 6 6 false
                "a,b,,c" "a": ["a" ",b,,c"] 2 2 false | ["" ",b,,c"] 2 2 false | ["a" ",b,,c"] 2 2 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["" ",b,,c"] 2 2 false | ["a" ",b,,c"] 2 2 false | ["" ",b,,c"] 2 3 false | ["a" ",b,,c"] 2 3 false | ["" ",b,,c"] 2 7 false | ["a" ",b,,c"] 2 7 false
                "a,b,,c" ",": ["a," "b," "," "c"] 4 4 false | ["a" "b" "" "c"] 4 4 false | ["a," "b," "," "c"] 4 4 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a" "b,,c"] 2 2 false | ["a," "b,,c"] 2 2 false | ["a" "b" ",c"] 3 3 false | ["a," "b," ",c"] 3 3 false | ["a" "b" "" "c"] 4 7 false | ["a," "b," "," "c"] 4 7 false
                "a,b,,c" "ab": ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 7 false | ["a,b,,c"] 1 7 false
                "a,b,,c" "aa": ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 7 false | ["a,b,,c"] 1 7 false
                "a,b,,c" "é": ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 7 false | ["a,b,,c"] 1 7 false
                "a,b,,c" "世": ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 7 false | ["a,b,,c"] 1 7 false
                "a,b,,c" ",,": ["a,b,," "c"] 2 2 false | ["a,b" "c"] 2 2 false | ["a,b,," "c"] 2 2 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b" "c"] 2 2 false | ["a,b,," "c"] 2 2 false | ["a,b" "c"] 2 3 false | ["a,b,," "c"] 2 3 false | ["a,b" "c"] 2 7 false | ["a,b,," "c"] 2 7 false
                "a,b,,c" "x": ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 7 false | ["a,b,,c"] 1 7 false
                "a,b,,c" "xa": ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | [] 0 0 true | [] 0 0 true | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 1 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 2 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 3 false | ["a,b,,c"] 1 7 false | ["a,b,,c"] 1 7 false
                "," "": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [","] 1 1 false
                "," "a": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," ",": ["," ""] 2 2 false | ["" ""] 2 2 false | ["," ""] 2 2 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | ["" ""] 2 2 false | ["," ""] 2 2 false | ["" ""] 2 2 false | ["," ""] 2 2 false | ["" ""] 2 2 false | ["," ""] 2 2 false
                "," "ab": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," "aa": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," "é": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," "世": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," ",,": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," "x": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                "," "xa": [","] 1 1 false | [","] 1 1 false | [","] 1 1 false | [] 0 0 true | [] 0 0 true | [","] 1 1 false | [","] 1 1 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false | [","] 1 2 false
                ",," "": ["," ","] 2 2 false | ["," ","] 2 2 false | ["," ","] 2 2 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | ["," ","] 2 2 false | ["," ","] 2 2 false | ["," ","] 2 2 false | ["," ","] 2 2 false | ["," ","] 2 2 false | ["," ","] 2 2 false
                ",," "a": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                ",," ",": ["," "," ""] 3 3 false | ["" "" ""] 3 3 false | ["," "," ""] 3 3 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | ["" ","] 2 2 false | ["," ","] 2 2 false | ["" "" ""] 3 3 false | ["," "," ""] 3 3 false | ["" "" ""] 3 3 false | ["," "," ""] 3 3 false
                ",," "ab": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                ",," "aa": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                ",," "é": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                ",," "世": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                ",," ",,": [",," ""] 2 2 false | ["" ""] 2 2 false | [",," ""] 2 2 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | ["" ""] 2 2 false | [",," ""] 2 2 false | ["" ""] 2 3 false | [",," ""] 2 3 false | ["" ""] 2 3 false | [",," ""] 2 3 false
                ",," "x": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                ",," "xa": [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 1 false | [] 0 0 true | [] 0 0 true | [",,"] 1 1 false | [",,"] 1 1 false | [",,"] 1 2 false | [",,"] 1 2 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false | [",,"] 1 3 false
                "héllo wörld" "": ["h" "é" "l" "l" "o" " " "w" "ö" "r" "l" "d"] 11 11 false | ["h" "é" "l" "l" "o" " " "w" "ö" "r" "l" "d"] 11 11 false | ["h" "é" "l" "l" "o" " " "w" "ö" "r" "l" "d"] 11 11 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["h" "éllo wörld"] 2 2 false | ["h" "éllo wörld"] 2 2 false | ["h" "é" "llo wörld"] 3 3 false | ["h" "é" "llo wörld"] 3 3 false | ["h" "é" "l" "l" "o" " " "w" "ö" "r" "l" "d"] 11 11 false | ["h" "é" "l" "l" "o" " " "w" "ö" "r" "l" "d"] 11 11 false
                "héllo wörld" "a": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" ",": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" "ab": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" "aa": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" "é": ["hé" "llo wörld"] 2 2 false | ["h" "llo wörld"] 2 2 false | ["hé" "llo wörld"] 2 2 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["h" "llo wörld"] 2 2 false | ["hé" "llo wörld"] 2 2 false | ["h" "llo wörld"] 2 3 false | ["hé" "llo wörld"] 2 3 false | ["h" "llo wörld"] 2 14 false | ["hé" "llo wörld"] 2 14 false
                "héllo wörld" "世": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" ",,": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" "x": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "héllo wörld" "xa": ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | [] 0 0 true | [] 0 0 true | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 1 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 2 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 3 false | ["héllo wörld"] 1 14 false | ["héllo wörld"] 1 14 false
                "世界" "": ["世" "界"] 2 2 false | ["世" "界"] 2 2 false | ["世" "界"] 2 2 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世" "界"] 2 2 false | ["世" "界"] 2 2 false | ["世" "界"] 2 2 false | ["世" "界"] 2 2 false | ["世" "界"] 2 2 false | ["世" "界"] 2 2 false
                "世界" "a": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" ",": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" "ab": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" "aa": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" "é": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" "世": ["世" "界"] 2 2 false | ["" "界"] 2 2 false | ["世" "界"] 2 2 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["" "界"] 2 2 false | ["世" "界"] 2 2 false | ["" "界"] 2 3 false | ["世" "界"] 2 3 false | ["" "界"] 2 7 false | ["世" "界"] 2 7 false
                "世界" ",,": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" "x": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                "世界" "xa": ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 1 false | [] 0 0 true | [] 0 0 true | ["世界"] 1 1 false | ["世界"] 1 1 false | ["世界"] 1 2 false | ["世界"] 1 2 false | ["世界"] 1 3 false | ["世界"] 1 3 false | ["世界"] 1 7 false | ["世界"] 1 7 false
                " \t x \n" "": [" " "\t" " " "x" " " "\n"] 6 6 false | [" " "\t" " " "x" " " "\n"] 6 6 false | [" " "\t" " " "x" " " "\n"] 6 6 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" " "\t x \n"] 2 2 false | [" " "\t x \n"] 2 2 false | [" " "\t" " x \n"] 3 3 false | [" " "\t" " x \n"] 3 3 false | [" " "\t" " " "x" " " "\n"] 6 6 false | [" " "\t" " " "x" " " "\n"] 6 6 false
                " \t x \n" "a": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" ",": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" "ab": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" "aa": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" "é": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" "世": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" ",,": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                " \t x \n" "x": [" \t x" " \n"] 2 2 false | [" \t " " \n"] 2 2 false | [" \t x" " \n"] 2 2 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t " " \n"] 2 2 false | [" \t x" " \n"] 2 2 false | [" \t " " \n"] 2 3 false | [" \t x" " \n"] 2 3 false | [" \t " " \n"] 2 7 false | [" \t x" " \n"] 2 7 false
                " \t x \n" "xa": [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [] 0 0 true | [] 0 0 true | [" \t x \n"] 1 1 false | [" \t x \n"] 1 1 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 2 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 3 false | [" \t x \n"] 1 7 false | [" \t x \n"] 1 7 false
                "aaa" "": ["a" "a" "a"] 3 3 false | ["a" "a" "a"] 3 3 false | ["a" "a" "a"] 3 3 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["a" "aa"] 2 2 false | ["a" "aa"] 2 2 false | ["a" "a" "a"] 3 3 false | ["a" "a" "a"] 3 3 false | ["a" "a" "a"] 3 3 false | ["a" "a" "a"] 3 3 false
                "aaa" "a": ["a" "a" "a" ""] 4 4 false | ["" "" "" ""] 4 4 false | ["a" "a" "a" ""] 4 4 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["" "aa"] 2 2 false | ["a" "aa"] 2 2 false | ["" "" "a"] 3 3 false | ["a" "a" "a"] 3 3 false | ["" "" "" ""] 4 4 false | ["a" "a" "a" ""] 4 4 false
                "aaa" ",": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "aaa" "ab": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "aaa" "aa": ["aa" "a"] 2 2 false | ["" "a"] 2 2 false | ["aa" "a"] 2 2 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["" "a"] 2 2 false | ["aa" "a"] 2 2 false | ["" "a"] 2 3 false | ["aa" "a"] 2 3 false | ["" "a"] 2 4 false | ["aa" "a"] 2 4 false
                "aaa" "é": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "aaa" "世": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "aaa" ",,": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "aaa" "x": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "aaa" "xa": ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 1 false | [] 0 0 true | [] 0 0 true | ["aaa"] 1 1 false | ["aaa"] 1 1 false | ["aaa"] 1 2 false | ["aaa"] 1 2 false | ["aaa"] 1 3 false | ["aaa"] 1 3 false | ["aaa"] 1 4 false | ["aaa"] 1 4 false
                "abab" "": ["a" "b" "a" "b"] 4 4 false | ["a" "b" "a" "b"] 4 4 false | ["a" "b" "a" "b"] 4 4 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["a" "bab"] 2 2 false | ["a" "bab"] 2 2 false | ["a" "b" "ab"] 3 3 false | ["a" "b" "ab"] 3 3 false | ["a" "b" "a" "b"] 4 4 false | ["a" "b" "a" "b"] 4 4 false
                "abab" "a": ["a" "ba" "b"] 3 3 false | ["" "b" "b"] 3 3 false | ["a" "ba" "b"] 3 3 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["" "bab"] 2 2 false | ["a" "bab"] 2 2 false | ["" "b" "b"] 3 3 false | ["a" "ba" "b"] 3 3 false | ["" "b" "b"] 3 5 false | ["a" "ba" "b"] 3 5 false
                "abab" ",": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "abab" "ab": ["ab" "ab" ""] 3 3 false | ["" "" ""] 3 3 false | ["ab" "ab" ""] 3 3 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["" "ab"] 2 2 false | ["ab" "ab"] 2 2 false | ["" "" ""] 3 3 false | ["ab" "ab" ""] 3 3 false | ["" "" ""] 3 5 false | ["ab" "ab" ""] 3 5 false
                "abab" "aa": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "abab" "é": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "abab" "世": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "abab" ",,": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "abab" "x": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "abab" "xa": ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 1 false | [] 0 0 true | [] 0 0 true | ["abab"] 1 1 false | ["abab"] 1 1 false | ["abab"] 1 2 false | ["abab"] 1 2 false | ["abab"] 1 3 false | ["abab"] 1 3 false | ["abab"] 1 5 false | ["abab"] 1 5 false
                "xxabcxx" "": ["x" "x" "a" "b" "c" "x" "x"] 7 7 false | ["x" "x" "a" "b" "c" "x" "x"] 7 7 false | ["x" "x" "a" "b" "c" "x" "x"] 7 7 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["x" "xabcxx"] 2 2 false | ["x" "xabcxx"] 2 2 false | ["x" "x" "abcxx"] 3 3 false | ["x" "x" "abcxx"] 3 3 false | ["x" "x" "a" "b" "c" "x" "x"] 7 7 false | ["x" "x" "a" "b" "c" "x" "x"] 7 7 false
                "xxabcxx" "a": ["xxa" "bcxx"] 2 2 false | ["xx" "bcxx"] 2 2 false | ["xxa" "bcxx"] 2 2 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xx" "bcxx"] 2 2 false | ["xxa" "bcxx"] 2 2 false | ["xx" "bcxx"] 2 3 false | ["xxa" "bcxx"] 2 3 false | ["xx" "bcxx"] 2 8 false | ["xxa" "bcxx"] 2 8 false
                "xxabcxx" ",": ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 8 false | ["xxabcxx"] 1 8 false
                "xxabcxx" "ab": ["xxab" "cxx"] 2 2 false | ["xx" "cxx"] 2 2 false | ["xxab" "cxx"] 2 2 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xx" "cxx"] 2 2 false | ["xxab" "cxx"] 2 2 false | ["xx" "cxx"] 2 3 false | ["xxab" "cxx"] 2 3 false | ["xx" "cxx"] 2 8 false | ["xxab" "cxx"] 2 8 false
                "xxabcxx" "aa": ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 8 false | ["xxabcxx"] 1 8 false
                "xxabcxx" "é": ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 8 false | ["xxabcxx"] 1 8 false
                "xxabcxx" "世": ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 8 false | ["xxabcxx"] 1 8 false
                "xxabcxx" ",,": ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 2 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 3 false | ["xxabcxx"] 1 8 false | ["xxabcxx"] 1 8 false
                "xxabcxx" "x": ["x" "x" "abcx" "x" ""] 5 5 false | ["" "" "abc" "" ""] 5 5 false | ["x" "x" "abcx" "x" ""] 5 5 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["" "xabcxx"] 2 2 false | ["x" "xabcxx"] 2 2 false | ["" "" "abcxx"] 3 3 false | ["x" "x" "abcxx"] 3 3 false | ["" "" "abc" "" ""] 5 8 false | ["x" "x" "abcx" "x" ""] 5 8 false
                "xxabcxx" "xa": ["xxa" "bcxx"] 2 2 false | ["x" "bcxx"] 2 2 false | ["xxa" "bcxx"] 2 2 false | [] 0 0 true | [] 0 0 true | ["xxabcxx"] 1 1 false | ["xxabcxx"] 1 1 false | ["x" "bcxx"] 2 2 false | ["xxa" "bcxx"] 2 2 false | ["x" "bcxx"] 2 3 false | ["xxa" "bcxx"] 2 3 false | ["x" "bcxx"] 2 8 false | ["xxa" "bcxx"] 2 8 false

                """#)
    }

    /// `Cut`, `CutPrefix`, `CutSuffix`, and `Compare`.
    @Test func cutAndCompare() throws {
        #expect(
            try runGoMain(
                #"""
                for _, s := range texts {
                    for _, sep := range seps {
                        before, after, found := strings.Cut(s, sep)
                        rest, had := strings.CutPrefix(s, sep)
                        head, ended := strings.CutSuffix(s, sep)
                        fmt.Printf("%q %q: %q %q %v | %q %v | %q %v | %d\n", s, sep, before, after, found, rest, had, head, ended, strings.Compare(s, sep))
                    }
                }
                key, value, ok := strings.Cut("Content-Type: text/html", ": ")
                fmt.Println(key, value, ok)
                """#,
                imports: ["fmt", "strings"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == #"""
                "" "": "" "" true | "" true | "" true | 0
                "" "a": "" "" false | "" false | "" false | -1
                "" ",": "" "" false | "" false | "" false | -1
                "" "ab": "" "" false | "" false | "" false | -1
                "" "aa": "" "" false | "" false | "" false | -1
                "" "é": "" "" false | "" false | "" false | -1
                "" "世": "" "" false | "" false | "" false | -1
                "" ",,": "" "" false | "" false | "" false | -1
                "" "x": "" "" false | "" false | "" false | -1
                "" "xa": "" "" false | "" false | "" false | -1
                "a" "": "" "a" true | "a" true | "a" true | 1
                "a" "a": "" "" true | "" true | "" true | 0
                "a" ",": "a" "" false | "a" false | "a" false | 1
                "a" "ab": "a" "" false | "a" false | "a" false | -1
                "a" "aa": "a" "" false | "a" false | "a" false | -1
                "a" "é": "a" "" false | "a" false | "a" false | -1
                "a" "世": "a" "" false | "a" false | "a" false | -1
                "a" ",,": "a" "" false | "a" false | "a" false | 1
                "a" "x": "a" "" false | "a" false | "a" false | -1
                "a" "xa": "a" "" false | "a" false | "a" false | -1
                "abc" "": "" "abc" true | "abc" true | "abc" true | 1
                "abc" "a": "" "bc" true | "bc" true | "abc" false | 1
                "abc" ",": "abc" "" false | "abc" false | "abc" false | 1
                "abc" "ab": "" "c" true | "c" true | "abc" false | 1
                "abc" "aa": "abc" "" false | "abc" false | "abc" false | 1
                "abc" "é": "abc" "" false | "abc" false | "abc" false | -1
                "abc" "世": "abc" "" false | "abc" false | "abc" false | -1
                "abc" ",,": "abc" "" false | "abc" false | "abc" false | 1
                "abc" "x": "abc" "" false | "abc" false | "abc" false | -1
                "abc" "xa": "abc" "" false | "abc" false | "abc" false | -1
                "a,b,,c" "": "" "a,b,,c" true | "a,b,,c" true | "a,b,,c" true | 1
                "a,b,,c" "a": "" ",b,,c" true | ",b,,c" true | "a,b,,c" false | 1
                "a,b,,c" ",": "a" "b,,c" true | "a,b,,c" false | "a,b,,c" false | 1
                "a,b,,c" "ab": "a,b,,c" "" false | "a,b,,c" false | "a,b,,c" false | -1
                "a,b,,c" "aa": "a,b,,c" "" false | "a,b,,c" false | "a,b,,c" false | -1
                "a,b,,c" "é": "a,b,,c" "" false | "a,b,,c" false | "a,b,,c" false | -1
                "a,b,,c" "世": "a,b,,c" "" false | "a,b,,c" false | "a,b,,c" false | -1
                "a,b,,c" ",,": "a,b" "c" true | "a,b,,c" false | "a,b,,c" false | 1
                "a,b,,c" "x": "a,b,,c" "" false | "a,b,,c" false | "a,b,,c" false | -1
                "a,b,,c" "xa": "a,b,,c" "" false | "a,b,,c" false | "a,b,,c" false | -1
                "," "": "" "," true | "," true | "," true | 1
                "," "a": "," "" false | "," false | "," false | -1
                "," ",": "" "" true | "" true | "" true | 0
                "," "ab": "," "" false | "," false | "," false | -1
                "," "aa": "," "" false | "," false | "," false | -1
                "," "é": "," "" false | "," false | "," false | -1
                "," "世": "," "" false | "," false | "," false | -1
                "," ",,": "," "" false | "," false | "," false | -1
                "," "x": "," "" false | "," false | "," false | -1
                "," "xa": "," "" false | "," false | "," false | -1
                ",," "": "" ",," true | ",," true | ",," true | 1
                ",," "a": ",," "" false | ",," false | ",," false | -1
                ",," ",": "" "," true | "," true | "," true | 1
                ",," "ab": ",," "" false | ",," false | ",," false | -1
                ",," "aa": ",," "" false | ",," false | ",," false | -1
                ",," "é": ",," "" false | ",," false | ",," false | -1
                ",," "世": ",," "" false | ",," false | ",," false | -1
                ",," ",,": "" "" true | "" true | "" true | 0
                ",," "x": ",," "" false | ",," false | ",," false | -1
                ",," "xa": ",," "" false | ",," false | ",," false | -1
                "héllo wörld" "": "" "héllo wörld" true | "héllo wörld" true | "héllo wörld" true | 1
                "héllo wörld" "a": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | 1
                "héllo wörld" ",": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | 1
                "héllo wörld" "ab": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | 1
                "héllo wörld" "aa": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | 1
                "héllo wörld" "é": "h" "llo wörld" true | "héllo wörld" false | "héllo wörld" false | -1
                "héllo wörld" "世": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | -1
                "héllo wörld" ",,": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | 1
                "héllo wörld" "x": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | -1
                "héllo wörld" "xa": "héllo wörld" "" false | "héllo wörld" false | "héllo wörld" false | -1
                "世界" "": "" "世界" true | "世界" true | "世界" true | 1
                "世界" "a": "世界" "" false | "世界" false | "世界" false | 1
                "世界" ",": "世界" "" false | "世界" false | "世界" false | 1
                "世界" "ab": "世界" "" false | "世界" false | "世界" false | 1
                "世界" "aa": "世界" "" false | "世界" false | "世界" false | 1
                "世界" "é": "世界" "" false | "世界" false | "世界" false | 1
                "世界" "世": "" "界" true | "界" true | "世界" false | 1
                "世界" ",,": "世界" "" false | "世界" false | "世界" false | 1
                "世界" "x": "世界" "" false | "世界" false | "世界" false | 1
                "世界" "xa": "世界" "" false | "世界" false | "世界" false | 1
                " \t x \n" "": "" " \t x \n" true | " \t x \n" true | " \t x \n" true | 1
                " \t x \n" "a": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" ",": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" "ab": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" "aa": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" "é": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" "世": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" ",,": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" "x": " \t " " \n" true | " \t x \n" false | " \t x \n" false | -1
                " \t x \n" "xa": " \t x \n" "" false | " \t x \n" false | " \t x \n" false | -1
                "aaa" "": "" "aaa" true | "aaa" true | "aaa" true | 1
                "aaa" "a": "" "aa" true | "aa" true | "aa" true | 1
                "aaa" ",": "aaa" "" false | "aaa" false | "aaa" false | 1
                "aaa" "ab": "aaa" "" false | "aaa" false | "aaa" false | -1
                "aaa" "aa": "" "a" true | "a" true | "a" true | 1
                "aaa" "é": "aaa" "" false | "aaa" false | "aaa" false | -1
                "aaa" "世": "aaa" "" false | "aaa" false | "aaa" false | -1
                "aaa" ",,": "aaa" "" false | "aaa" false | "aaa" false | 1
                "aaa" "x": "aaa" "" false | "aaa" false | "aaa" false | -1
                "aaa" "xa": "aaa" "" false | "aaa" false | "aaa" false | -1
                "abab" "": "" "abab" true | "abab" true | "abab" true | 1
                "abab" "a": "" "bab" true | "bab" true | "abab" false | 1
                "abab" ",": "abab" "" false | "abab" false | "abab" false | 1
                "abab" "ab": "" "ab" true | "ab" true | "ab" true | 1
                "abab" "aa": "abab" "" false | "abab" false | "abab" false | 1
                "abab" "é": "abab" "" false | "abab" false | "abab" false | -1
                "abab" "世": "abab" "" false | "abab" false | "abab" false | -1
                "abab" ",,": "abab" "" false | "abab" false | "abab" false | 1
                "abab" "x": "abab" "" false | "abab" false | "abab" false | -1
                "abab" "xa": "abab" "" false | "abab" false | "abab" false | -1
                "xxabcxx" "": "" "xxabcxx" true | "xxabcxx" true | "xxabcxx" true | 1
                "xxabcxx" "a": "xx" "bcxx" true | "xxabcxx" false | "xxabcxx" false | 1
                "xxabcxx" ",": "xxabcxx" "" false | "xxabcxx" false | "xxabcxx" false | 1
                "xxabcxx" "ab": "xx" "cxx" true | "xxabcxx" false | "xxabcxx" false | 1
                "xxabcxx" "aa": "xxabcxx" "" false | "xxabcxx" false | "xxabcxx" false | 1
                "xxabcxx" "é": "xxabcxx" "" false | "xxabcxx" false | "xxabcxx" false | -1
                "xxabcxx" "世": "xxabcxx" "" false | "xxabcxx" false | "xxabcxx" false | -1
                "xxabcxx" ",,": "xxabcxx" "" false | "xxabcxx" false | "xxabcxx" false | 1
                "xxabcxx" "x": "" "xabcxx" true | "xabcxx" true | "xxabcx" true | 1
                "xxabcxx" "xa": "x" "bcxx" true | "xxabcxx" false | "xxabcxx" false | 1
                Content-Type text/html true

                """#)
    }

    /// `IndexAny`, `LastIndexAny`, `ContainsAny`, and `LastIndexByte`.
    @Test func searchingForAnyOfASet() throws {
        #expect(
            try runGoMain(
                #"""
                for _, s := range texts {
                    for _, chars := range []string{"", "a", ",x", "é世", "界", "zq", "\t\n "} {
                        fmt.Printf("%q %q: %d %d %v\n", s, chars, strings.IndexAny(s, chars), strings.LastIndexAny(s, chars), strings.ContainsAny(s, chars))
                    }
                    for _, c := range []byte{'a', ',', 'x', 0, 0xa9, 0xc3, 0xff} {
                        fmt.Print(strings.LastIndexByte(s, c), " ")
                    }
                    fmt.Println()
                }
                """#,
                imports: ["fmt", "strings"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == "\"\" \"\": -1 -1 false\n\"\" \"a\": -1 -1 false\n\"\" \",x\": -1 -1 false\n\"\" \"é世\": -1 -1 false\n\"\" \"界\": -1 -1 false\n\"\" \"zq\": -1 -1 false\n\"\" \"\\t\\n \": -1 -1 false\n-1 -1 -1 -1 -1 -1 -1 \n\"a\" \"\": -1 -1 false\n\"a\" \"a\": 0 0 true\n\"a\" \",x\": -1 -1 false\n\"a\" \"é世\": -1 -1 false\n\"a\" \"界\": -1 -1 false\n\"a\" \"zq\": -1 -1 false\n\"a\" \"\\t\\n \": -1 -1 false\n0 -1 -1 -1 -1 -1 -1 \n\"abc\" \"\": -1 -1 false\n\"abc\" \"a\": 0 0 true\n\"abc\" \",x\": -1 -1 false\n\"abc\" \"é世\": -1 -1 false\n\"abc\" \"界\": -1 -1 false\n\"abc\" \"zq\": -1 -1 false\n\"abc\" \"\\t\\n \": -1 -1 false\n0 -1 -1 -1 -1 -1 -1 \n\"a,b,,c\" \"\": -1 -1 false\n\"a,b,,c\" \"a\": 0 0 true\n\"a,b,,c\" \",x\": 1 4 true\n\"a,b,,c\" \"é世\": -1 -1 false\n\"a,b,,c\" \"界\": -1 -1 false\n\"a,b,,c\" \"zq\": -1 -1 false\n\"a,b,,c\" \"\\t\\n \": -1 -1 false\n0 4 -1 -1 -1 -1 -1 \n\",\" \"\": -1 -1 false\n\",\" \"a\": -1 -1 false\n\",\" \",x\": 0 0 true\n\",\" \"é世\": -1 -1 false\n\",\" \"界\": -1 -1 false\n\",\" \"zq\": -1 -1 false\n\",\" \"\\t\\n \": -1 -1 false\n-1 0 -1 -1 -1 -1 -1 \n\",,\" \"\": -1 -1 false\n\",,\" \"a\": -1 -1 false\n\",,\" \",x\": 0 1 true\n\",,\" \"é世\": -1 -1 false\n\",,\" \"界\": -1 -1 false\n\",,\" \"zq\": -1 -1 false\n\",,\" \"\\t\\n \": -1 -1 false\n-1 1 -1 -1 -1 -1 -1 \n\"héllo wörld\" \"\": -1 -1 false\n\"héllo wörld\" \"a\": -1 -1 false\n\"héllo wörld\" \",x\": -1 -1 false\n\"héllo wörld\" \"é世\": 1 1 true\n\"héllo wörld\" \"界\": -1 -1 false\n\"héllo wörld\" \"zq\": -1 -1 false\n\"héllo wörld\" \"\\t\\n \": 6 6 true\n-1 -1 -1 -1 2 8 -1 \n\"世界\" \"\": -1 -1 false\n\"世界\" \"a\": -1 -1 false\n\"世界\" \",x\": -1 -1 false\n\"世界\" \"é世\": 0 0 true\n\"世界\" \"界\": 3 3 true\n\"世界\" \"zq\": -1 -1 false\n\"世界\" \"\\t\\n \": -1 -1 false\n-1 -1 -1 -1 -1 -1 -1 \n\" \\t x \\n\" \"\": -1 -1 false\n\" \\t x \\n\" \"a\": -1 -1 false\n\" \\t x \\n\" \",x\": 3 3 true\n\" \\t x \\n\" \"é世\": -1 -1 false\n\" \\t x \\n\" \"界\": -1 -1 false\n\" \\t x \\n\" \"zq\": -1 -1 false\n\" \\t x \\n\" \"\\t\\n \": 0 5 true\n-1 -1 3 -1 -1 -1 -1 \n\"aaa\" \"\": -1 -1 false\n\"aaa\" \"a\": 0 2 true\n\"aaa\" \",x\": -1 -1 false\n\"aaa\" \"é世\": -1 -1 false\n\"aaa\" \"界\": -1 -1 false\n\"aaa\" \"zq\": -1 -1 false\n\"aaa\" \"\\t\\n \": -1 -1 false\n2 -1 -1 -1 -1 -1 -1 \n\"abab\" \"\": -1 -1 false\n\"abab\" \"a\": 0 2 true\n\"abab\" \",x\": -1 -1 false\n\"abab\" \"é世\": -1 -1 false\n\"abab\" \"界\": -1 -1 false\n\"abab\" \"zq\": -1 -1 false\n\"abab\" \"\\t\\n \": -1 -1 false\n2 -1 -1 -1 -1 -1 -1 \n\"xxabcxx\" \"\": -1 -1 false\n\"xxabcxx\" \"a\": 2 2 true\n\"xxabcxx\" \",x\": 0 6 true\n\"xxabcxx\" \"é世\": -1 -1 false\n\"xxabcxx\" \"界\": -1 -1 false\n\"xxabcxx\" \"zq\": -1 -1 false\n\"xxabcxx\" \"\\t\\n \": -1 -1 false\n2 -1 6 -1 -1 -1 -1 \n")
    }

    /// `Trim`, `TrimLeft`, and `TrimRight` take a set of characters, not a
    /// prefix.
    @Test func trimmingASet() throws {
        #expect(
            try runGoMain(
                #"""
                for _, s := range append(texts, "  héllo  ", "xxhixx", "世界世", "éaé", "/a/b/", "abcba") {
                    for _, cutset := range []string{"", " ", "x", "ab", "é", "世界", " \t\n", "/", "abc,"} {
                        fmt.Printf("%q %q: %q %q %q\n", s, cutset, strings.Trim(s, cutset), strings.TrimLeft(s, cutset), strings.TrimRight(s, cutset))
                    }
                }
                """#,
                imports: ["fmt", "strings"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == #"""
                "" "": "" "" ""
                "" " ": "" "" ""
                "" "x": "" "" ""
                "" "ab": "" "" ""
                "" "é": "" "" ""
                "" "世界": "" "" ""
                "" " \t\n": "" "" ""
                "" "/": "" "" ""
                "" "abc,": "" "" ""
                "a" "": "a" "a" "a"
                "a" " ": "a" "a" "a"
                "a" "x": "a" "a" "a"
                "a" "ab": "" "" ""
                "a" "é": "a" "a" "a"
                "a" "世界": "a" "a" "a"
                "a" " \t\n": "a" "a" "a"
                "a" "/": "a" "a" "a"
                "a" "abc,": "" "" ""
                "abc" "": "abc" "abc" "abc"
                "abc" " ": "abc" "abc" "abc"
                "abc" "x": "abc" "abc" "abc"
                "abc" "ab": "c" "c" "abc"
                "abc" "é": "abc" "abc" "abc"
                "abc" "世界": "abc" "abc" "abc"
                "abc" " \t\n": "abc" "abc" "abc"
                "abc" "/": "abc" "abc" "abc"
                "abc" "abc,": "" "" ""
                "a,b,,c" "": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" " ": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "x": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "ab": ",b,,c" ",b,,c" "a,b,,c"
                "a,b,,c" "é": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "世界": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" " \t\n": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "/": "a,b,,c" "a,b,,c" "a,b,,c"
                "a,b,,c" "abc,": "" "" ""
                "," "": "," "," ","
                "," " ": "," "," ","
                "," "x": "," "," ","
                "," "ab": "," "," ","
                "," "é": "," "," ","
                "," "世界": "," "," ","
                "," " \t\n": "," "," ","
                "," "/": "," "," ","
                "," "abc,": "" "" ""
                ",," "": ",," ",," ",,"
                ",," " ": ",," ",," ",,"
                ",," "x": ",," ",," ",,"
                ",," "ab": ",," ",," ",,"
                ",," "é": ",," ",," ",,"
                ",," "世界": ",," ",," ",,"
                ",," " \t\n": ",," ",," ",,"
                ",," "/": ",," ",," ",,"
                ",," "abc,": "" "" ""
                "héllo wörld" "": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" " ": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "x": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "ab": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "é": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "世界": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" " \t\n": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "/": "héllo wörld" "héllo wörld" "héllo wörld"
                "héllo wörld" "abc,": "héllo wörld" "héllo wörld" "héllo wörld"
                "世界" "": "世界" "世界" "世界"
                "世界" " ": "世界" "世界" "世界"
                "世界" "x": "世界" "世界" "世界"
                "世界" "ab": "世界" "世界" "世界"
                "世界" "é": "世界" "世界" "世界"
                "世界" "世界": "" "" ""
                "世界" " \t\n": "世界" "世界" "世界"
                "世界" "/": "世界" "世界" "世界"
                "世界" "abc,": "世界" "世界" "世界"
                " \t x \n" "": " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" " ": "\t x \n" "\t x \n" " \t x \n"
                " \t x \n" "x": " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "ab": " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "é": " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "世界": " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" " \t\n": "x" "x \n" " \t x"
                " \t x \n" "/": " \t x \n" " \t x \n" " \t x \n"
                " \t x \n" "abc,": " \t x \n" " \t x \n" " \t x \n"
                "aaa" "": "aaa" "aaa" "aaa"
                "aaa" " ": "aaa" "aaa" "aaa"
                "aaa" "x": "aaa" "aaa" "aaa"
                "aaa" "ab": "" "" ""
                "aaa" "é": "aaa" "aaa" "aaa"
                "aaa" "世界": "aaa" "aaa" "aaa"
                "aaa" " \t\n": "aaa" "aaa" "aaa"
                "aaa" "/": "aaa" "aaa" "aaa"
                "aaa" "abc,": "" "" ""
                "abab" "": "abab" "abab" "abab"
                "abab" " ": "abab" "abab" "abab"
                "abab" "x": "abab" "abab" "abab"
                "abab" "ab": "" "" ""
                "abab" "é": "abab" "abab" "abab"
                "abab" "世界": "abab" "abab" "abab"
                "abab" " \t\n": "abab" "abab" "abab"
                "abab" "/": "abab" "abab" "abab"
                "abab" "abc,": "" "" ""
                "xxabcxx" "": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" " ": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "x": "abc" "abcxx" "xxabc"
                "xxabcxx" "ab": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "é": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "世界": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" " \t\n": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "/": "xxabcxx" "xxabcxx" "xxabcxx"
                "xxabcxx" "abc,": "xxabcxx" "xxabcxx" "xxabcxx"
                "  héllo  " "": "  héllo  " "  héllo  " "  héllo  "
                "  héllo  " " ": "héllo" "héllo  " "  héllo"
                "  héllo  " "x": "  héllo  " "  héllo  " "  héllo  "
                "  héllo  " "ab": "  héllo  " "  héllo  " "  héllo  "
                "  héllo  " "é": "  héllo  " "  héllo  " "  héllo  "
                "  héllo  " "世界": "  héllo  " "  héllo  " "  héllo  "
                "  héllo  " " \t\n": "héllo" "héllo  " "  héllo"
                "  héllo  " "/": "  héllo  " "  héllo  " "  héllo  "
                "  héllo  " "abc,": "  héllo  " "  héllo  " "  héllo  "
                "xxhixx" "": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" " ": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" "x": "hi" "hixx" "xxhi"
                "xxhixx" "ab": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" "é": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" "世界": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" " \t\n": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" "/": "xxhixx" "xxhixx" "xxhixx"
                "xxhixx" "abc,": "xxhixx" "xxhixx" "xxhixx"
                "世界世" "": "世界世" "世界世" "世界世"
                "世界世" " ": "世界世" "世界世" "世界世"
                "世界世" "x": "世界世" "世界世" "世界世"
                "世界世" "ab": "世界世" "世界世" "世界世"
                "世界世" "é": "世界世" "世界世" "世界世"
                "世界世" "世界": "" "" ""
                "世界世" " \t\n": "世界世" "世界世" "世界世"
                "世界世" "/": "世界世" "世界世" "世界世"
                "世界世" "abc,": "世界世" "世界世" "世界世"
                "éaé" "": "éaé" "éaé" "éaé"
                "éaé" " ": "éaé" "éaé" "éaé"
                "éaé" "x": "éaé" "éaé" "éaé"
                "éaé" "ab": "éaé" "éaé" "éaé"
                "éaé" "é": "a" "aé" "éa"
                "éaé" "世界": "éaé" "éaé" "éaé"
                "éaé" " \t\n": "éaé" "éaé" "éaé"
                "éaé" "/": "éaé" "éaé" "éaé"
                "éaé" "abc,": "éaé" "éaé" "éaé"
                "/a/b/" "": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" " ": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" "x": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" "ab": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" "é": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" "世界": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" " \t\n": "/a/b/" "/a/b/" "/a/b/"
                "/a/b/" "/": "a/b" "a/b/" "/a/b"
                "/a/b/" "abc,": "/a/b/" "/a/b/" "/a/b/"
                "abcba" "": "abcba" "abcba" "abcba"
                "abcba" " ": "abcba" "abcba" "abcba"
                "abcba" "x": "abcba" "abcba" "abcba"
                "abcba" "ab": "c" "cba" "abc"
                "abcba" "é": "abcba" "abcba" "abcba"
                "abcba" "世界": "abcba" "abcba" "abcba"
                "abcba" " \t\n": "abcba" "abcba" "abcba"
                "abcba" "/": "abcba" "abcba" "abcba"
                "abcba" "abc,": "" "" ""

                """#)
    }

    /// `IndexFunc`, `LastIndexFunc`, `ContainsFunc`, the three `Trim...Func`,
    /// `FieldsFunc`, and `Map` call the function of the program for the
    /// characters Go calls it for, in Go's order: the log shows each call.
    @Test func theFunctionsThatTakeAFunction() throws {
        #expect(
            try runGoMain(
                #"""
                var log []rune
                isSep := func(r rune) bool {
                    log = append(log, r)
                    return r == ',' || r == ' ' || r == '世' || unicode.IsUpper(r)
                }
                show := func(name string, result any) {
                    fmt.Printf("  %s %q after %q\n", name, result, string(log))
                    log = nil
                }
                for _, s := range append(texts, "  Héllo, Wörld  ", "世a世b世", "A", "ÉaÉ") {
                    fmt.Printf("%q\n", s)
                    show("IndexFunc", strings.IndexFunc(s, isSep))
                    show("LastIndexFunc", strings.LastIndexFunc(s, isSep))
                    show("ContainsFunc", strings.ContainsFunc(s, isSep))
                    show("TrimFunc", strings.TrimFunc(s, isSep))
                    show("TrimLeftFunc", strings.TrimLeftFunc(s, isSep))
                    show("TrimRightFunc", strings.TrimRightFunc(s, isSep))
                    show("FieldsFunc", d(strings.FieldsFunc(s, isSep)))
                    show("Map", strings.Map(func(r rune) rune {
                        log = append(log, r)
                        switch {
                        case r == ',':
                            return -1
                        case r == 'a':
                            return '世'
                        case r == '世':
                            return 'w'
                        case r == 'x':
                            return 0x110000
                        }
                        return unicode.ToUpper(r)
                    }, s))
                }
                """#,
                imports: ["fmt", "strings", "unicode"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == #"""
                ""
                  IndexFunc '�' after ""
                  LastIndexFunc '�' after ""
                  ContainsFunc %!q(bool=false) after ""
                  TrimFunc "" after ""
                  TrimLeftFunc "" after ""
                  TrimRightFunc "" after ""
                  FieldsFunc "[] 0 0 false" after ""
                  Map "" after ""
                "a"
                  IndexFunc '�' after "a"
                  LastIndexFunc '�' after "a"
                  ContainsFunc %!q(bool=false) after "a"
                  TrimFunc "a" after "aa"
                  TrimLeftFunc "a" after "a"
                  TrimRightFunc "a" after "a"
                  FieldsFunc "[\"a\"] 1 1 false" after "a"
                  Map "世" after "a"
                "abc"
                  IndexFunc '�' after "abc"
                  LastIndexFunc '�' after "cba"
                  ContainsFunc %!q(bool=false) after "abc"
                  TrimFunc "abc" after "ac"
                  TrimLeftFunc "abc" after "a"
                  TrimRightFunc "abc" after "c"
                  FieldsFunc "[\"abc\"] 1 1 false" after "abc"
                  Map "世BC" after "abc"
                "a,b,,c"
                  IndexFunc '\x01' after "a,"
                  LastIndexFunc '\x04' after "c,"
                  ContainsFunc %!q(bool=true) after "a,"
                  TrimFunc "a,b,,c" after "ac"
                  TrimLeftFunc "a,b,,c" after "a"
                  TrimRightFunc "a,b,,c" after "c"
                  FieldsFunc "[\"a\" \"b\" \"c\"] 3 3 false" after "a,b,,c"
                  Map "世BC" after "a,b,,c"
                ","
                  IndexFunc '\x00' after ","
                  LastIndexFunc '\x00' after ","
                  ContainsFunc %!q(bool=true) after ","
                  TrimFunc "" after ","
                  TrimLeftFunc "" after ","
                  TrimRightFunc "" after ","
                  FieldsFunc "[] 0 0 false" after ","
                  Map "" after ","
                ",,"
                  IndexFunc '\x00' after ","
                  LastIndexFunc '\x01' after ","
                  ContainsFunc %!q(bool=true) after ","
                  TrimFunc "" after ",,"
                  TrimLeftFunc "" after ",,"
                  TrimRightFunc "" after ",,"
                  FieldsFunc "[] 0 0 false" after ",,"
                  Map "" after ",,"
                "héllo wörld"
                  IndexFunc '\x06' after "héllo "
                  LastIndexFunc '\x06' after "dlröw "
                  ContainsFunc %!q(bool=true) after "héllo "
                  TrimFunc "héllo wörld" after "hd"
                  TrimLeftFunc "héllo wörld" after "h"
                  TrimRightFunc "héllo wörld" after "d"
                  FieldsFunc "[\"héllo\" \"wörld\"] 2 2 false" after "héllo wörld"
                  Map "HÉLLO WÖRLD" after "héllo wörld"
                "世界"
                  IndexFunc '\x00' after "世"
                  LastIndexFunc '\x00' after "界世"
                  ContainsFunc %!q(bool=true) after "世"
                  TrimFunc "界" after "世界界"
                  TrimLeftFunc "界" after "世界"
                  TrimRightFunc "世界" after "界"
                  FieldsFunc "[\"界\"] 1 1 false" after "世界"
                  Map "w界" after "世界"
                " \t x \n"
                  IndexFunc '\x00' after " "
                  LastIndexFunc '\x04' after "\n "
                  ContainsFunc %!q(bool=true) after " "
                  TrimFunc "\t x \n" after " \t\n"
                  TrimLeftFunc "\t x \n" after " \t"
                  TrimRightFunc " \t x \n" after "\n"
                  FieldsFunc "[\"\\t\" \"x\" \"\\n\"] 3 3 false" after " \t x \n"
                  Map " \t � \n" after " \t x \n"
                "aaa"
                  IndexFunc '�' after "aaa"
                  LastIndexFunc '�' after "aaa"
                  ContainsFunc %!q(bool=false) after "aaa"
                  TrimFunc "aaa" after "aa"
                  TrimLeftFunc "aaa" after "a"
                  TrimRightFunc "aaa" after "a"
                  FieldsFunc "[\"aaa\"] 1 1 false" after "aaa"
                  Map "世世世" after "aaa"
                "abab"
                  IndexFunc '�' after "abab"
                  LastIndexFunc '�' after "baba"
                  ContainsFunc %!q(bool=false) after "abab"
                  TrimFunc "abab" after "ab"
                  TrimLeftFunc "abab" after "a"
                  TrimRightFunc "abab" after "b"
                  FieldsFunc "[\"abab\"] 1 1 false" after "abab"
                  Map "世B世B" after "abab"
                "xxabcxx"
                  IndexFunc '�' after "xxabcxx"
                  LastIndexFunc '�' after "xxcbaxx"
                  ContainsFunc %!q(bool=false) after "xxabcxx"
                  TrimFunc "xxabcxx" after "xx"
                  TrimLeftFunc "xxabcxx" after "x"
                  TrimRightFunc "xxabcxx" after "x"
                  FieldsFunc "[\"xxabcxx\"] 1 1 false" after "xxabcxx"
                  Map "��世BC��" after "xxabcxx"
                "  Héllo, Wörld  "
                  IndexFunc '\x00' after " "
                  LastIndexFunc '\x11' after " "
                  ContainsFunc %!q(bool=true) after " "
                  TrimFunc "éllo, Wörld" after "  Hé  d"
                  TrimLeftFunc "éllo, Wörld  " after "  Hé"
                  TrimRightFunc "  Héllo, Wörld" after "  d"
                  FieldsFunc "[\"éllo\" \"örld\"] 2 2 false" after "  Héllo, Wörld  "
                  Map "  HÉLLO WÖRLD  " after "  Héllo, Wörld  "
                "世a世b世"
                  IndexFunc '\x00' after "世"
                  LastIndexFunc '\b' after "世"
                  ContainsFunc %!q(bool=true) after "世"
                  TrimFunc "a世b" after "世a世b"
                  TrimLeftFunc "a世b世" after "世a"
                  TrimRightFunc "世a世b" after "世b"
                  FieldsFunc "[\"a\" \"b\"] 2 2 false" after "世a世b世"
                  Map "w世wBw" after "世a世b世"
                "A"
                  IndexFunc '\x00' after "A"
                  LastIndexFunc '\x00' after "A"
                  ContainsFunc %!q(bool=true) after "A"
                  TrimFunc "" after "A"
                  TrimLeftFunc "" after "A"
                  TrimRightFunc "" after "A"
                  FieldsFunc "[] 0 0 false" after "A"
                  Map "A" after "A"
                "ÉaÉ"
                  IndexFunc '\x00' after "É"
                  LastIndexFunc '\x03' after "É"
                  ContainsFunc %!q(bool=true) after "É"
                  TrimFunc "a" after "ÉaÉa"
                  TrimLeftFunc "aÉ" after "Éa"
                  TrimRightFunc "Éa" after "Éa"
                  FieldsFunc "[\"a\"] 1 1 false" after "ÉaÉ"
                  Map "É世É" after "ÉaÉ"

                """#)
        #expect(
            try runGoMain(
                """
                fmt.Println(strings.TrimFunc("123abc456", unicode.IsDigit), strings.IndexFunc("abc1", unicode.IsDigit))
                fmt.Println(strings.Map(unicode.ToUpper, "héllo"), strings.FieldsFunc("a1b22c", unicode.IsDigit))
                rot13 := func(r rune) rune {
                    switch {
                    case r >= 'a' && r <= 'z':
                        return 'a' + (r-'a'+13)%26
                    case r >= 'A' && r <= 'Z':
                        return 'A' + (r-'A'+13)%26
                    }
                    return r
                }
                fmt.Println(strings.Map(rot13, "Hello, World"))
                notLetter := func(r rune) bool { return !unicode.IsLetter(r) }
                f := strings.FieldsFunc
                fmt.Println(f("one, two;three", notLetter), len(f("", notLetter)))
                """,
                imports: ["fmt", "strings", "unicode"])
                == "abc 3\nHÉLLO [a b c]\nUryyb, Jbeyq\n[one two three] 0\n")
    }

    /// `EqualFold` by Unicode's simple folding (the Kelvin sign is a `k`, the
    /// long s an `s`, and the dotted capital I of Turkish nothing but itself),
    /// `ToTitle`, and `Title`.
    @Test func caseFoldingAndTitleCase() throws {
        #expect(
            try runGoMain(
                #"""
                pairs := [][2]string{
                    {"Go", "GO"}, {"", ""}, {"a", ""}, {"abc", "abd"}, {"Content-Type", "content-type"}, {"héllo", "HÉLLO"},
                    {"K", "\u212a"}, {"k", "\u212a"}, {"ſ", "S"}, {"ß", "SS"}, {"ß", "ẞ"}, {"İ", "i"}, {"ı", "I"}, {"I", "i"},
                    {"σ", "ς"}, {"Σ", "ς"}, {"ǅ", "ǆ"}, {"Ǆ", "ǆ"}, {"世界", "世界"}, {"世", "界"}, {"aé", "Aé"}, {"aé", "AÉx"},
                    {"[", "{"}, {"@", "`"}, {"z", "Z"}, {"é", "e"}, {"ა", "Ა"}, {"abc", "ABCD"},
                }
                for _, p := range pairs {
                    fmt.Printf("%q %q %v %v\n", p[0], p[1], strings.EqualFold(p[0], p[1]), strings.EqualFold(p[1], p[0]))
                }
                for _, s := range []string{"", "hello wörld", "ǆemal ǅ Ǆ ǉ ǌ ǳ", "ß ſ", "აბგ", "her royal highness", "loud_and clear", "o'neil x-ray 3d 世界 étude", " leading", "ÉCOLE élan", "a\u2028b\u00a0c"} {
                    fmt.Printf("%q %q %q\n", s, strings.ToTitle(s), strings.Title(s))
                }
                """#,
                imports: ["fmt", "strings"])
                == #"""
                "Go" "GO" true true
                "" "" true true
                "a" "" false false
                "abc" "abd" false false
                "Content-Type" "content-type" true true
                "héllo" "HÉLLO" true true
                "K" "K" true true
                "k" "K" true true
                "ſ" "S" true true
                "ß" "SS" false false
                "ß" "ẞ" true true
                "İ" "i" false false
                "ı" "I" false false
                "I" "i" true true
                "σ" "ς" true true
                "Σ" "ς" true true
                "ǅ" "ǆ" true true
                "Ǆ" "ǆ" true true
                "世界" "世界" true true
                "世" "界" false false
                "aé" "Aé" true true
                "aé" "AÉx" false false
                "[" "{" false false
                "@" "`" false false
                "z" "Z" true true
                "é" "e" false false
                "ა" "Ა" true true
                "abc" "ABCD" false false
                "" "" ""
                "hello wörld" "HELLO WÖRLD" "Hello Wörld"
                "ǆemal ǅ Ǆ ǉ ǌ ǳ" "ǅEMAL ǅ ǅ ǈ ǋ ǲ" "ǅemal ǅ ǅ ǈ ǋ ǲ"
                "ß ſ" "ß S" "ß S"
                "აბგ" "აბგ" "აბგ"
                "her royal highness" "HER ROYAL HIGHNESS" "Her Royal Highness"
                "loud_and clear" "LOUD_AND CLEAR" "Loud_and Clear"
                "o'neil x-ray 3d 世界 étude" "O'NEIL X-RAY 3D 世界 ÉTUDE" "O'Neil X-Ray 3d 世界 Étude"
                " leading" " LEADING" " Leading"
                "ÉCOLE élan" "ÉCOLE ÉLAN" "ÉCOLE Élan"
                "a\u2028b\u00a0c" "A\u2028B\u00a0C" "A\u2028B\u00a0C"

                """#)
    }

    /// A `Replacer` looks at one place of the text after another and takes
    /// the first pair of its arguments that is found there; what it wrote is
    /// not looked at again. An odd number of arguments panics.
    @Test func aReplacerReplacesWhatComesFirst() throws {
        #expect(
            try runGoMain(
                #"""
                html := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&#34;", "'", "&#39;")
                fmt.Println(html.Replace(`<a href="x?a=1&b=2">it's</a>`))
                show := func(text string, oldnew ...string) {
                    fmt.Printf("%q %q -> %q\n", oldnew, text, strings.NewReplacer(oldnew...).Replace(text))
                }
                show("abc")
                show("", "a", "b")
                show("banana", "a", "b", "b", "a")
                show("banana", "a", "1", "a", "2")
                show("banana", "an", "<>")
                show("banana", "ana", "X", "an", "Y", "b", "")
                show("banana", "an", "Y", "ana", "X")
                show("banana", "a", "")
                show("banana", "a", "aa", "aa", "never")
                show("abc", "", "-")
                show("abc", "", "-", "b", "B")
                show("abc", "b", "B", "", "-")
                show("", "", "-")
                show("héllo wörld", "é", "e", "ö", "oe", "l", "L")
                show("世界 and 世", "世", "world", "世界", "never")
                show("aaaa", "aa", "b")
                show("a.b.c", ".", "..", "..", "!")
                show("hello", "hello", "bye")
                show("hello", "l", "L", "hello", "bye")
                r := strings.NewReplacer("a", "1", "b", "2")
                fmt.Println(r.Replace("abcab"), r.Replace(""), r.Replace("xyz"))
                fmt.Printf("%T\n", r)
                try("odd", func() { strings.NewReplacer("a", "b", "c") })
                """#,
                imports: ["fmt", "strings"],
                declarations: #"""
                    func d(a []string) string { return fmt.Sprintf("%q %d %d %v", a, len(a), cap(a), a == nil) }

                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, "->", recover()) }()
                        f()
                    }

                    var texts = []string{"", "a", "abc", "a,b,,c", ",", ",,", "héllo wörld", "世界", " \t x \n", "aaa", "abab", "xxabcxx"}
                    var seps = []string{"", "a", ",", "ab", "aa", "é", "世", ",,", "x", "xa"}
                    """#)
                == """
                &lt;a href=&#34;x?a=1&amp;b=2&#34;&gt;it&#39;s&lt;/a&gt;
                [] "abc" -> "abc"
                ["a" "b"] "" -> ""
                ["a" "b" "b" "a"] "banana" -> "abnbnb"
                ["a" "1" "a" "2"] "banana" -> "b1n1n1"
                ["an" "<>"] "banana" -> "b<><>a"
                ["ana" "X" "an" "Y" "b" ""] "banana" -> "Xna"
                ["an" "Y" "ana" "X"] "banana" -> "bYYa"
                ["a" ""] "banana" -> "bnn"
                ["a" "aa" "aa" "never"] "banana" -> "baanaanaa"
                ["" "-"] "abc" -> "-a-b-c-"
                ["" "-" "b" "B"] "abc" -> "-a-B-c-"
                ["b" "B" "" "-"] "abc" -> "-aB-c-"
                ["" "-"] "" -> "-"
                ["é" "e" "ö" "oe" "l" "L"] "héllo wörld" -> "heLLo woerLd"
                ["世" "world" "世界" "never"] "世界 and 世" -> "world界 and world"
                ["aa" "b"] "aaaa" -> "bb"
                ["." ".." ".." "!"] "a.b.c" -> "a..b..c"
                ["hello" "bye"] "hello" -> "bye"
                ["l" "L" "hello" "bye"] "hello" -> "bye"
                12c12  xyz
                *strings.Replacer
                odd -> strings.NewReplacer: odd argument count

                """)
    }

    /// `WriteString` writes the text between replacements and the
    /// replacements with a call each, through `WriteString` when the writer
    /// has it, counts the bytes, and stops at the writer's first error. The
    /// calls are Go's, which differ with the kind of the pairs.
    @Test func aReplacerWritesPieceByPiece() throws {
        #expect(
            try runGoMain(
                #"""
                kinds := [][]string{
                    {"a", "1", "b", "2"},
                    {"a", "one", "b", ""},
                    {"an", "<>"},
                    {"an", "<>", "b", "B"},
                    {"", "-"},
                    {},
                }
                for _, oldnew := range kinds {
                    r := strings.NewReplacer(oldnew...)
                    for _, s := range []string{"banana", "", "xyz", "ab"} {
                        var w recorder
                        n, err := r.WriteString(&w, s)
                        fmt.Printf("%q %q: %d %v %q\n", oldnew, s, n, err, w.log)
                        var sw stringRecorder
                        n, err = r.WriteString(&sw, s)
                        fmt.Printf("    %d %v %q\n", n, err, sw.log)
                        full := recorder{limit: 3, limited: true}
                        n, err = r.WriteString(&full, s)
                        fmt.Printf("    %d %v %q\n", n, err, full.log)
                    }
                }
                var b strings.Builder
                n, err := strings.NewReplacer("<", "&lt;").WriteString(&b, "a<b")
                fmt.Println(n, err, b.String())
                """#,
                imports: ["errors", "fmt", "strings"],
                declarations: """
                    type recorder struct {
                        log     []string
                        limit   int
                        limited bool
                    }

                    func (w *recorder) Write(p []byte) (int, error) {
                        w.log = append(w.log, "W:"+string(p))
                        if w.limited && len(p) > w.limit {
                            n := w.limit
                            w.limit = 0
                            return n, errors.New("full")
                        }
                        w.limit -= len(p)
                        return len(p), nil
                    }

                    type stringRecorder struct{ log []string }

                    func (w *stringRecorder) Write(p []byte) (int, error) {
                        w.log = append(w.log, "W:"+string(p))
                        return len(p), nil
                    }

                    func (w *stringRecorder) WriteString(s string) (int, error) {
                        w.log = append(w.log, "S:"+s)
                        return len(s), nil
                    }
                    """)
                == """
                ["a" "1" "b" "2"] "banana": 6 <nil> ["W:2" "W:1" "W:n" "W:1" "W:n" "W:1"]
                    6 <nil> ["W:2" "W:1" "S:n" "W:1" "S:n" "W:1"]
                    3 full ["W:2" "W:1" "W:n" "W:1"]
                ["a" "1" "b" "2"] "": 0 <nil> []
                    0 <nil> []
                    0 <nil> []
                ["a" "1" "b" "2"] "xyz": 3 <nil> ["W:xyz"]
                    3 <nil> ["S:xyz"]
                    3 <nil> ["W:xyz"]
                ["a" "1" "b" "2"] "ab": 2 <nil> ["W:1" "W:2"]
                    2 <nil> ["W:1" "W:2"]
                    2 <nil> ["W:1" "W:2"]
                ["a" "one" "b" ""] "banana": 11 <nil> ["W:" "W:one" "W:n" "W:one" "W:n" "W:one"]
                    11 <nil> ["W:" "W:one" "S:n" "W:one" "S:n" "W:one"]
                    3 full ["W:" "W:one" "W:n"]
                ["a" "one" "b" ""] "": 0 <nil> []
                    0 <nil> []
                    0 <nil> []
                ["a" "one" "b" ""] "xyz": 3 <nil> ["W:xyz"]
                    3 <nil> ["S:xyz"]
                    3 <nil> ["W:xyz"]
                ["a" "one" "b" ""] "ab": 3 <nil> ["W:one" "W:"]
                    3 <nil> ["W:one" "W:"]
                    3 <nil> ["W:one" "W:"]
                ["an" "<>"] "banana": 6 <nil> ["W:b" "W:<>" "W:" "W:<>" "W:a"]
                    6 <nil> ["S:b" "S:<>" "S:" "S:<>" "S:a"]
                    3 full ["W:b" "W:<>" "W:" "W:<>"]
                ["an" "<>"] "": 0 <nil> ["W:"]
                    0 <nil> ["S:"]
                    0 <nil> ["W:"]
                ["an" "<>"] "xyz": 3 <nil> ["W:xyz"]
                    3 <nil> ["S:xyz"]
                    3 <nil> ["W:xyz"]
                ["an" "<>"] "ab": 2 <nil> ["W:ab"]
                    2 <nil> ["S:ab"]
                    2 <nil> ["W:ab"]
                ["an" "<>" "b" "B"] "banana": 6 <nil> ["W:" "W:B" "W:" "W:<>" "W:" "W:<>" "W:a"]
                    6 <nil> ["S:" "S:B" "S:" "S:<>" "S:" "S:<>" "S:a"]
                    3 full ["W:" "W:B" "W:" "W:<>" "W:" "W:<>"]
                ["an" "<>" "b" "B"] "": 0 <nil> []
                    0 <nil> []
                    0 <nil> []
                ["an" "<>" "b" "B"] "xyz": 3 <nil> ["W:xyz"]
                    3 <nil> ["S:xyz"]
                    3 <nil> ["W:xyz"]
                ["an" "<>" "b" "B"] "ab": 2 <nil> ["W:a" "W:B"]
                    2 <nil> ["S:a" "S:B"]
                    2 <nil> ["W:a" "W:B"]
                ["" "-"] "banana": 13 <nil> ["W:" "W:-" "W:b" "W:-" "W:a" "W:-" "W:n" "W:-" "W:a" "W:-" "W:n" "W:-" "W:a" "W:-"]
                    13 <nil> ["S:" "S:-" "S:b" "S:-" "S:a" "S:-" "S:n" "S:-" "S:a" "S:-" "S:n" "S:-" "S:a" "S:-"]
                    3 full ["W:" "W:-" "W:b" "W:-" "W:a"]
                ["" "-"] "": 1 <nil> ["W:" "W:-"]
                    1 <nil> ["S:" "S:-"]
                    1 <nil> ["W:" "W:-"]
                ["" "-"] "xyz": 7 <nil> ["W:" "W:-" "W:x" "W:-" "W:y" "W:-" "W:z" "W:-"]
                    7 <nil> ["S:" "S:-" "S:x" "S:-" "S:y" "S:-" "S:z" "S:-"]
                    3 full ["W:" "W:-" "W:x" "W:-" "W:y"]
                ["" "-"] "ab": 5 <nil> ["W:" "W:-" "W:a" "W:-" "W:b" "W:-"]
                    5 <nil> ["S:" "S:-" "S:a" "S:-" "S:b" "S:-"]
                    3 full ["W:" "W:-" "W:a" "W:-" "W:b"]
                [] "banana": 6 <nil> ["W:banana"]
                    6 <nil> ["S:banana"]
                    3 full ["W:banana"]
                [] "": 0 <nil> []
                    0 <nil> []
                    0 <nil> []
                [] "xyz": 3 <nil> ["W:xyz"]
                    3 <nil> ["S:xyz"]
                    3 <nil> ["W:xyz"]
                [] "ab": 2 <nil> ["W:ab"]
                    2 <nil> ["S:ab"]
                    2 <nil> ["W:ab"]
                6 <nil> a&lt;b

                """)
    }

    /// `strings.Reader` has all the methods of Go's: `ReadByte`, `ReadRune`
    /// and their `Unread`s with Go's errors, `ReadAt`, `Seek`, `WriteTo`,
    /// `Reset`, and `Size` as an `int64`.
    @Test func aReaderReadsBytesAndCharacters() throws {
        #expect(
            try runGoMain(
                #"""
                r := strings.NewReader("héy世")
                fmt.Println(r.Len(), r.Size())
                fmt.Println(r.UnreadByte(), r.UnreadRune())
                c, err := r.ReadByte()
                fmt.Println(c, err, r.Len())
                fmt.Println(r.UnreadRune())
                ch, size, err := r.ReadRune()
                fmt.Println(ch, size, err, r.Len())
                fmt.Println(r.UnreadRune(), r.Len())
                fmt.Println(r.UnreadRune(), r.Len())
                ch, size, err = r.ReadRune()
                fmt.Println(string(ch), size, err)
                fmt.Println(r.UnreadByte(), r.Len())
                p := make([]byte, 3)
                n, err := r.Read(p)
                fmt.Println(n, err, p, r.UnreadRune())
                for {
                    ch, size, err := r.ReadRune()
                    fmt.Println(ch, size, err)
                    if err != nil {
                        fmt.Println(err == io.EOF)
                        break
                    }
                }
                _, err = r.ReadByte()
                fmt.Println(err, r.UnreadByte(), r.Len())

                n, err = r.ReadAt(p, 1)
                fmt.Println(n, err, string(p), r.Len())
                n, err = r.ReadAt(p, 5)
                fmt.Println(n, err, p[:n])
                n, err = r.ReadAt(p, 7)
                fmt.Println(n, err)
                n, err = r.ReadAt(p, -1)
                fmt.Println(n, err)

                for _, seek := range []struct {
                    offset int64
                    whence int
                }{{2, io.SeekStart}, {1, io.SeekCurrent}, {-1, io.SeekEnd}, {100, io.SeekStart}, {-1, io.SeekStart}, {0, 9}, {-3, io.SeekCurrent}} {
                    at, err := r.Seek(seek.offset, seek.whence)
                    fmt.Println(at, err, r.Len())
                }
                var at int64
                at, _ = r.Seek(1, io.SeekStart)
                var b strings.Builder
                wrote, err := r.WriteTo(&b)
                fmt.Printf("%d %d %v %q %d %T\n", at, wrote, err, b.String(), r.Len(), wrote)
                wrote, err = r.WriteTo(&b)
                fmt.Println(wrote, err)
                r.Reset("again")
                all, err := io.ReadAll(r)
                fmt.Println(string(all), err, r.Len(), r.Size())
                var zero strings.Reader
                fmt.Println(zero.Len(), zero.Size(), zero.UnreadRune())
                r.Seek(0, io.SeekStart)
                short := &few{}
                wrote, err = r.WriteTo(short)
                fmt.Println(wrote, err, err == io.ErrShortWrite, r.Len())
                var rs io.Reader = r
                _, isSeeker := rs.(interface{ Seek(int64, int) (int64, error) })
                fmt.Println(isSeeker)
                """#,
                imports: ["fmt", "io", "strings"],
                declarations: """
                    type few struct{}

                    func (*few) Write(p []byte) (int, error) { return 2, nil }
                    """)
                == """
                7 7
                strings.Reader.UnreadByte: at beginning of string strings.Reader.UnreadRune: at beginning of string
                104 <nil> 6
                strings.Reader.UnreadRune: previous operation was not ReadRune
                233 2 <nil> 4
                <nil> 6
                strings.Reader.UnreadRune: previous operation was not ReadRune 6
                é 2 <nil>
                <nil> 5
                3 <nil> [169 121 228] strings.Reader.UnreadRune: previous operation was not ReadRune
                65533 1 <nil>
                65533 1 <nil>
                0 0 EOF
                true
                EOF <nil> 1
                3 <nil> éy 1
                2 EOF [184 150]
                0 EOF
                0 strings.Reader.ReadAt: negative offset
                2 <nil> 5
                3 <nil> 4
                6 <nil> 1
                100 <nil> 0
                0 strings.Reader.Seek: negative position 0
                0 strings.Reader.Seek: invalid whence 0
                97 <nil> 0
                1 6 <nil> "éy世" 0 int64
                0 <nil>
                again <nil> 0 5
                0 0 strings.Reader.UnreadRune: at beginning of string
                2 short write true 3
                true

                """)
    }

    /// A wrong argument is Go's error at Go's place, with the functions named
    /// as Go names them.
    @Test func theTextIsCheckedLikeGo() {
        #expect(
            firstError("fmt.Println(strings.ReplaceAll(\"a\", \"b\", 3))", imports: ["fmt", "strings"])
                == "6:42: cannot use 3 (untyped int constant) as string value in argument to strings.ReplaceAll")
        #expect(
            firstError("fmt.Println(strings.Replace(\"a\", \"b\", \"c\", \"d\"))", imports: ["fmt", "strings"])
                == "6:44: cannot use \"d\" (untyped string constant) as int value in argument to strings.Replace")
        #expect(
            firstError(
                """
                before, after := strings.Cut("a", "b")
                fmt.Println(before, after)
                """,
                imports: ["fmt", "strings"])
                == "6:18: assignment mismatch: 2 variables but strings.Cut returns 3 values")
        #expect(
            firstError(
                """
                var n int = strings.NewReader("a").Size()
                fmt.Println(n)
                """,
                imports: ["fmt", "strings"])
                == "6:13: cannot use strings.NewReader(\"a\").Size() (value of type int64) as int value in variable declaration")
        #expect(
            firstError("fmt.Println(strings.NewReplacer(\"a\", 1))", imports: ["fmt", "strings"])
                == "6:38: cannot use 1 (untyped int constant) as string value in argument to strings.NewReplacer")
        #expect(
            firstError("fmt.Println(strings.TrimAll(\"a\"))", imports: ["fmt", "strings"])
                == "6:21: undefined: strings.TrimAll")
    }
}
