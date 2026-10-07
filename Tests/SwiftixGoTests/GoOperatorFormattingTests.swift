/// `gofmt` and `gofmt -r` over bitwise operators and conversions.
///
/// The operators have no AST case of their own (they are call-shaped nodes
/// with a reserved callee), so these tests prove that formatting and rewriting
/// always print them back as Go operator syntax and that the result is stable.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go operator and conversion formatting")
struct GoOperatorFormattingTests: GoTestHarness {

    private let unformatted = """
        package main
        import "fmt"
        func mask(b byte,n int)byte{return b&^1|byte(n<<2)^3}
        func main(){x:=^1&255
        p:=&x
        bs:=[]byte("hi")
        s:=string(bs[0:1])+string(65)
        y:=*p>>1&3
        z:=-x|^y
        w:=x|
        y|
        z
        vs:=[]int{^x,-y,x&^y}
        for _,v:=range vs{fmt.Println(v<<1)}
        if x&1==0&&p!=nil{fmt.Println(x<<3,int(mask(bs[0],x)),s,y,z,w,uint8(x)>>1)}
        }

        """

    private let formatted = [
        "package main",
        "",
        "import \"fmt\"",
        "",
        "func mask(b byte, n int) byte {",
        "\treturn b &^ 1 | byte(n << 2) ^ 3",
        "}",
        "",
        "func main() {",
        "\tx := ^1 & 255",
        "\tp := &x",
        "\tbs := []byte(\"hi\")",
        "\ts := string(bs[0:1]) + string(65)",
        "\ty := *p >> 1 & 3",
        "\tz := -x | ^y",
        "\tw := x | y | z",
        "\tvs := []int{^x, -y, x &^ y}",
        "\tfor _, v := range vs {",
        "\t\tfmt.Println(v << 1)",
        "\t}",
        "\tif x & 1 == 0 && p != nil {",
        "\t\tfmt.Println(x << 3, int(mask(bs[0], x)), s, y, z, w, uint8(x) >> 1)",
        "\t}",
        "}",
        "",
    ].joined(separator: "\n")

    private func format(_ text: String) throws -> String {
        try GoFormatter.format(GoSourceFile(path: "main.go", text: text))
    }

    private func output(of text: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    @Test func formatterPrintsOperatorsAndConversionsAsGoSyntax() throws {
        #expect(try format(unformatted) == formatted)
    }

    @Test func formattingIsIdempotentAndPreservesMeaning() throws {
        let once = try format(unformatted)
        #expect(try format(once) == once)
        #expect(!once.contains("$"))
        let expected = try output(of: unformatted)
        #expect(expected == "-510\n-6\n504\n2032 251 hA 3 -2 -1 127\n")
        #expect(try output(of: once) == expected)
    }

    @Test func unaryAndBinaryFormsOfSharedSpellingsStayDistinct() throws {
        // `&` is address-of or bitwise and; `^` is complement or xor.
        let source = """
            package main
            func take(p *int, n int) int { return *p ^ n }
            func main() {
            a := 6
            b := take(&a, ^a) & a
            c := a ^ ^b
            d := a & -b
            ch := make(chan *int, 1)
            ch <- &a
            e := [2]int{^a, a &^ b}
            println(b, c, d, e[-^0], *<-ch & 2)
            }

            """
        let once = try format(source)

        #expect(once.contains("\tb := take(&a, ^a) & a\n"))
        #expect(once.contains("\tc := a ^ ^b\n"))
        #expect(once.contains("\td := a & -b\n"))
        #expect(once.contains("\tch <- &a\n"))
        #expect(once.contains("\te := [2]int{^a, a &^ b}\n"))
        #expect(try format(once) == once)
    }

    @Test func rewriteRulesMatchAndPrintOperators() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\n\nfunc main() {\n\tprintln(n << 1, m << 1 | k, n << 2, ^n, a &^ b, a | b, a || b, a & b)\n}\n")
        func rewritten(_ rule: String) throws -> String {
            let text = try GoSourceRewriter.rewrite(source, rule: rule).text
            return String(text.split(separator: "\n")[2])
        }

        #expect(
            try rewritten("x << 1 -> x * 2")
                == "\tprintln(n * 2, m * 2 | k, n << 2, ^n, a &^ b, a | b, a || b, a & b)")
        #expect(
            try rewritten("^x -> -x - 1")
                == "\tprintln(n << 1, m << 1 | k, n << 2, -n - 1, a &^ b, a | b, a || b, a & b)")
        #expect(
            try rewritten("x &^ y -> x & ^y")
                == "\tprintln(n << 1, m << 1 | k, n << 2, ^n, a & ^b, a | b, a || b, a & b)")
        #expect(
            try rewritten("x | y -> y ^ x")
                == "\tprintln(n << 1, k ^ m << 1, n << 2, ^n, a &^ b, b ^ a, a || b, a & b)")
        #expect(
            try rewritten("x & y -> y >> x")
                == "\tprintln(n << 1, m << 1 | k, n << 2, ^n, a &^ b, a | b, a || b, b >> a)")
        // No rule sees an operator as an ordinary call.
        #expect(try rewritten("f(x, y) -> f(y, x)") == "\tprintln(n << 1, m << 1 | k, n << 2, ^n, a &^ b, a | b, a || b, a & b)")
    }

    @Test func rewriteReplacementsParenthesizeLooserOperands() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\n\nfunc main() {\n\tprintln(mix(a, b))\n}\n")
        func rewritten(_ rule: String) throws -> String {
            let text = try GoSourceRewriter.rewrite(source, rule: rule).text
            return String(text.split(separator: "\n")[2])
        }

        #expect(try rewritten("mix(x, y) -> x & (y | 1)") == "\tprintln(a & (b | 1))")
        #expect(try rewritten("mix(x, y) -> x | y & 1") == "\tprintln(a | b & 1)")
        #expect(try rewritten("mix(x, y) -> ^(x + y) << 2") == "\tprintln(^(a + b) << 2)")
        #expect(try rewritten("mix(x, y) -> x << (y << 1)") == "\tprintln(a << (b << 1))")
        #expect(try rewritten("mix(x, y) -> (x ^ y) &^ y") == "\tprintln((a ^ b) &^ b)")
    }

    @Test func rewriteRulesTreatConversionTypeNamesLiterally() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\n\nfunc main() {\n\tprintln(byte(n), int(n), other(n), []byte(s), string(b))\n}\n")
        func rewritten(_ rule: String) throws -> String {
            let text = try GoSourceRewriter.rewrite(source, rule: rule).text
            return String(text.split(separator: "\n")[2])
        }

        #expect(
            try rewritten("byte(x) -> uint8(x)")
                == "\tprintln(uint8(n), int(n), other(n), []byte(s), string(b))")
        #expect(
            try rewritten("[]byte(x) -> bytes(x)")
                == "\tprintln(byte(n), int(n), other(n), bytes(s), string(b))")
        #expect(
            try rewritten("string(x) -> string(x[:])")
                == "\tprintln(byte(n), int(n), other(n), []byte(s), string(b[:]))")
        #expect(
            try rewritten("int(x) -> int(byte(x) << 1)")
                == "\tprintln(byte(n), int(byte(n) << 1), other(n), []byte(s), string(b))")
    }

    @Test func rewrittenAndFormattedSourceIsStable() throws {
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(path: "main.go", text: formatted), rule: "x << 1 -> x * 2")
        let once = try format(rewritten.text)

        #expect(once.contains("fmt.Println(v * 2)"))
        #expect(try format(once) == once)
        #expect(try output(of: once) == "-510\n-6\n504\n2032 251 hA 3 -2 -1 127\n")
    }
}
