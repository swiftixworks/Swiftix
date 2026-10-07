import Testing
@testable import Swiftix

/// `bc`: the decimal bignum's scale rules, base conversion, the language
/// (variables, control flow, functions), the `-l` math library, and the
/// GNU-style diagnostics. Programs are fed on standard input through a real
/// shell and the exact stdout / stderr text is compared.
@Suite("bc calculator")
struct CalculatorCommandTests {

    // MARK: - Arithmetic and scale rules

    @Test func integerArithmetic() {
        #expect(bc("1+1") == "2\n")
        #expect(bc("2*3+4") == "10\n")
        #expect(bc("2+3*4") == "14\n")
        #expect(bc("(2+3)*4") == "20\n")
        #expect(bc("10-25") == "-15\n")
        #expect(bc("7/2") == "3\n")
        #expect(bc("-7/2") == "-3\n")
        #expect(bc("7%3") == "1\n")
        #expect(bc("-7%3") == "-1\n")
        #expect(bc("2^10") == "1024\n")
        #expect(bc("0") == "0\n")
    }

    @Test func divisionHonorsScale() {
        #expect(bc("1/3") == "0\n")
        #expect(bc("scale=2; 10/3") == "3.33\n")
        #expect(bc("scale=5; 1/3") == ".33333\n")
        #expect(bc("scale=3; -1/3") == "-.333\n")
        #expect(bc("scale=2; 1/2") == ".50\n")
        #expect(bc("scale=10; 22/7") == "3.1428571428\n")
        #expect(bc("scale=2; 0/5") == "0\n")
    }

    @Test func multiplicationScaleRule() {
        // scale(a*b) = min(a.scale + b.scale, max(scale, a.scale, b.scale))
        #expect(bc("1.5*2.5") == "3.7\n")
        #expect(bc("scale=2; 1.5*2.5") == "3.75\n")
        #expect(bc("scale=10; 1.5*2.5") == "3.75\n")
        #expect(bc("1.25*1.25") == "1.56\n")
        #expect(bc("scale=2; 5.5*2.25") == "12.37\n")
        #expect(bc(".1*.1") == "0\n")
        #expect(bc("scale=1; .1*.1") == "0\n")
        #expect(bc("scale=2; .1*.1") == ".01\n")
    }

    @Test func additionKeepsTheLargerScale() {
        #expect(bc("1.5+2.25") == "3.75\n")
        #expect(bc("1.50-1.5") == "0\n")
        #expect(bc(".5+.5") == "1.0\n")
        #expect(bc("3-3.000") == "0\n")
    }

    @Test func moduloFollowsBcDefinition() {
        // a % b is a - (a/b)*b with the division done at the current scale.
        #expect(bc("scale=2; 7%3") == ".01\n")
        #expect(bc("scale=0; 7.5%2") == "1.5\n")
        #expect(bc("10%4") == "2\n")
    }

    @Test func powerRules() {
        #expect(bc("2^0") == "1\n")
        #expect(bc("2^-2") == "0\n")
        #expect(bc("scale=4; 2^-2") == ".2500\n")
        #expect(bc("1.5^2") == "2.2\n")
        #expect(bc("scale=2; 1.5^2") == "2.25\n")
        #expect(bc("scale=10; 1.1^3") == "1.331\n")
        // Unary minus binds tighter than ^; ^ is right-associative.
        #expect(bc("-2^2") == "4\n")
        #expect(bc("2^3^2") == "512\n")
        #expect(bc("2^100") == "1267650600228229401496703205376\n")
    }

    @Test func squareRootLengthAndScaleFunctions() {
        #expect(bc("sqrt(16)") == "4\n")
        #expect(bc("sqrt(2)") == "1\n")
        #expect(bc("scale=4; sqrt(2)") == "1.4142\n")
        #expect(bc("sqrt(2.0000)") == "1.4142\n")
        #expect(bc("scale=20; sqrt(2)") == "1.41421356237309504880\n")
        #expect(bc("sqrt(0)") == "0\n")
        #expect(bc("length(123.45)") == "5\n")
        #expect(bc("length(.001)") == "3\n")
        #expect(bc("length(0)") == "1\n")
        #expect(bc("length(1000)") == "4\n")
        #expect(bc("scale(1.50)") == "2\n")
        #expect(bc("scale(7)") == "0\n")
    }

    @Test func numbersBelowOnePrintWithoutALeadingZero() {
        #expect(bc(".5") == ".5\n")
        #expect(bc("-.5") == "-.5\n")
        #expect(bc("0.50") == ".50\n")
        #expect(bc("0.00") == "0\n")
        #expect(bc("1.0") == "1.0\n")
    }

    @Test func longNumbersWrapAtSeventyColumns() {
        #expect(bc("2^300") == """
            20370359763344860862684456884093781610514683936659362506361404493543\\
            81299763336706183397376

            """)
        // Exactly 68 digits fit on one line; 69 wrap.
        #expect(bc("10^67") == "1" + String(repeating: "0", count: 67) + "\n")
        #expect(bc("10^68") == "1" + String(repeating: "0", count: 67) + "\\\n0\n")
    }

    @Test func bigNumberArithmeticIsExact() {
        #expect(bc("99999999999999999999*99999999999999999999")
                == "9999999999999999999800000000000000000001\n")
        #expect(bc("123456789012345678901234567890/987654321")
                == "124999998873437499901\n")
        #expect(bc("123456789012345678901234567890%987654321098765432109")
                == "850308642085140432108\n")
        #expect(bc("100000000000000000000-1") == "99999999999999999999\n")
        #expect(bc("scale=30; 1/7") == ".142857142857142857142857142857\n")
        // A divisor too long for the single-word fast path.
        #expect(bc("12345678901234567890123456789012345678901234567890/1234567890123456789012345")
                == "10000000000000000000000005\n")
    }

    // MARK: - Relational and logical operators

    @Test func comparisonsYieldOneOrZero() {
        #expect(bc("1<2; 2<1; 2<=2; 3>=4; 5==5; 5!=5; 1.0==1") == "1\n0\n1\n0\n1\n0\n1\n")
        #expect(bc("!0; !5; 1&&0; 1&&2; 0||0; 0||3") == "1\n0\n0\n1\n0\n1\n")
        // Relational operators bind looser than assignment, as in GNU bc.
        #expect(bc("a=3<5; a") == "1\n3\n")
        #expect(bc("1+1==2") == "1\n")
    }

    // MARK: - Variables and assignment

    @Test func variablesAndAssignmentOperators() {
        #expect(bc("a=5; a") == "5\n")
        #expect(bc("a=5; a+=2; a; a-=1; a; a*=3; a; a/=4; a; a%=3; a; a^=3; a") == "7\n6\n18\n4\n1\n1\n")
        #expect(bc("x") == "0\n")
        #expect(bc("a=b=4; a+b") == "8\n")
        #expect(bc("(a=7)") == "7\n")
        #expect(bc("long_name1=3; long_name1*2") == "6\n")
    }

    @Test func incrementAndDecrement() {
        #expect(bc("x++; x; ++x; x--; --x; x") == "0\n1\n2\n2\n0\n0\n")
    }

    @Test func lastHoldsThePreviousResult() {
        #expect(bc("5*5; last+1; .*2") == "25\n26\n52\n")
    }

    @Test func arrays() {
        #expect(bc("a[0]=5; a[3]=7; a[0]+a[3]; a[1]; i=3; a[i]*2; a[2]++; a[2]") == "12\n0\n14\n0\n1\n")
    }

    // MARK: - Bases

    @Test func outputBase() {
        #expect(bc("obase=16; 255; 256; -255") == "FF\n100\n-FF\n")
        #expect(bc("obase=2; 5; 255") == "101\n11111111\n")
        #expect(bc("obase=8; 64") == "100\n")
        #expect(bc("obase=16; .5") == ".8\n")
        #expect(bc("obase=2; scale=3; 1/4") == ".0100000000\n")
        // Bases above 16 print space-separated decimal digits.
        #expect(bc("obase=100; 12345") == " 01 23 45\n")
        #expect(bc("obase=16; 0") == "0\n")
    }

    @Test func inputBase() {
        #expect(bc("ibase=16; FF; 10; A") == "255\n16\n10\n")
        #expect(bc("ibase=2; 1010; 11111111") == "10\n255\n")
        #expect(bc("ibase=8; 17") == "15\n")
        // A single digit keeps its value in any base; longer literals clamp.
        #expect(bc("A; F; FF") == "10\n15\n99\n")
        #expect(bc("ibase=16; obase=A; 1F") == "31\n")
        #expect(bc("ibase=2; .1") == ".5\n")
        #expect(bc("ibase=16; ibase=A; 10") == "10\n")
    }

    // MARK: - Statements

    @Test func statementsSeparatedBySemicolonsAndNewlines() {
        #expect(bc("1;2\n3\n\n4;") == "1\n2\n3\n4\n")
    }

    @Test func commentsAreIgnored() {
        #expect(bc("1 /* one */ + 1 # trailing\n/* multi\nline */ 3") == "2\n3\n")
    }

    @Test func stringsAndPrint() {
        #expect(bc("\"hello\"; 1") == "hello1\n")
        #expect(bc("print \"a=\", 1+1, \"\\n\"") == "a=2\n")
        #expect(bc("print 1, 2, \"\\tx\\n\"") == "12\tx\n")
    }

    @Test func quitStopsProcessing() {
        #expect(bc("1\nquit\n2") == "1\n")
        #expect(bc("1\nhalt\n2") == "1\n")
    }

    @Test func ifElse() {
        #expect(bc("if (1 < 2) 10") == "10\n")
        #expect(bc("if (1 > 2) 10") == "")
        #expect(bc("if (1 > 2) 10 else 20") == "20\n")
        #expect(bc("x = 5\nif (x == 5) {\n  x * 2\n  x * 3\n}") == "10\n15\n")
    }

    @Test func whileAndForLoops() {
        #expect(bc("i=0; while (i<3) { i; i+=1 }") == "0\n1\n2\n")
        #expect(bc("for (i=1; i<=3; i++) i*i") == "1\n4\n9\n")
        #expect(bc("for (i=0; i<10; i++) { if (i==2) continue; if (i==4) break; i }") == "0\n1\n3\n")
        #expect(bc("s=0\nfor (i=1; i<=100; i++) {\n s += i\n}\ns") == "5050\n")
    }

    @Test func userDefinedFunctions() {
        #expect(bc("define f(x) { return (x*x); }\nf(7)") == "49\n")
        #expect(bc("define add(a, b) {\n  return a + b\n}\nadd(2, 3)") == "5\n")
        #expect(bc("define fact(n) {\n if (n <= 1) return (1)\n return (n * fact(n-1))\n}\nfact(20)")
                == "2432902008176640000\n")
        #expect(bc("define z() { }\nz()") == "0\n")
    }

    @Test func autoVariablesAndParametersAreLocal() {
        let program = """
            x = 1; t = 2
            define f(x) {
              auto t
              t = x * 10
              x = 99
              return (t)
            }
            f(5); x; t
            """
        #expect(bc(program) == "50\n1\n2\n")
    }

    // MARK: - Math library

    @Test func mathLibrarySetsScaleTwenty() {
        #expect(bc("scale; 1/3", flags: "-l") == "20\n.33333333333333333333\n")
    }

    @Test func mathLibraryFunctions() {
        #expect(bc("e(1)", flags: "-l") == "2.71828182845904523536\n")
        #expect(bc("e(0)", flags: "-l") == "1.00000000000000000000\n")
        #expect(bc("e(-1.5)", flags: "-l") == ".22313016014842982893\n")
        #expect(bc("4*a(1)", flags: "-l") == "3.14159265358979323844\n")
        #expect(bc("a(.5)", flags: "-l") == ".46364760900080611621\n")
        #expect(bc("l(2)", flags: "-l") == ".69314718055994530941\n")
        #expect(bc("l(.1)", flags: "-l") == "-2.30258509299404568401\n")
        #expect(bc("l(1000)", flags: "-l") == "6.90775527898213705205\n")
        #expect(bc("s(1)", flags: "-l") == ".84147098480789650665\n")
        #expect(bc("s(10)", flags: "-l") == "-.54402111088936981340\n")
        #expect(bc("c(0)", flags: "-l") == "1.00000000000000000000\n")
        #expect(bc("c(1)", flags: "-l") == ".54030230586813971740\n")
        #expect(bc("scale=50; 4*a(1)", flags: "-l")
                == "3.14159265358979323846264338327950288419716939937508\n")
    }

    @Test func mathFunctionsNeedTheLibraryFlag() {
        let result = run("e(1)")
        #expect(result.out == "")
        #expect(result.err == "Runtime error (func=(main), adr=4): Function e not defined.\n")
    }

    // MARK: - Diagnostics

    @Test func divideByZeroIsReportedAndExecutionContinues() {
        let result = run("1/0\n2+2\n5%0\n3")
        #expect(result.out == "4\n3\n")
        #expect(result.err == """
            Runtime error (func=(main), adr=3): Divide by zero
            Runtime error (func=(main), adr=5): Modulo by zero

            """)
        #expect(result.status == 0)
    }

    @Test func runtimeErrorInsideAFunctionNamesIt() {
        let result = run("define f(x) { return (1/x); }\nf(0)\n7")
        #expect(result.out == "7\n")
        #expect(result.err == "Runtime error (func=f, adr=4): Divide by zero\n")
    }

    @Test func squareRootOfNegativeNumber() {
        let result = run("sqrt(-1)\n1")
        #expect(result.out == "1\n")
        #expect(result.err == "Runtime error (func=(main), adr=4): Square root of a negative number\n")
    }

    @Test func syntaxErrorsNameTheLine() {
        var result = run("1 +\n2\n3 3\n(4\n5")
        #expect(result.out == "2\n5\n")
        #expect(result.err == """
            (standard_in) 1: syntax error
            (standard_in) 3: syntax error
            (standard_in) 4: syntax error

            """)
        #expect(result.status == 0)
        result = run("1 $ 2\n6")
        #expect(result.out == "6\n")
        #expect(result.err == "(standard_in) 1: illegal character: $\n")
    }

    @Test func baseWarnings() {
        let result = run("ibase=1; ibase\nobase=1; obase\nscale=-1; scale")
        #expect(result.out == "2\n10\n0\n")
        #expect(result.err.contains("ibase too small, set to 2"))
        #expect(result.err.contains("obase too small, set to 2"))
        #expect(result.err.contains("negative scale, set to 0"))
    }

    // MARK: - Files, options, pipelines

    @Test func filesAreReadBeforeStandardInput() {
        let shell = Shell()
        shell.write("/lib.bc", "define sq(x) { return (x*x); }\nscale=2\n")
        shell.write("/in", "sq(1.5)\n1/3\n")
        #expect(shell.capture("bc /lib.bc < /in").out == "2.25\n.33\n")
        #expect(shell.capture("bc -q /lib.bc < /in").out == "2.25\n.33\n")
    }

    @Test func syntaxErrorInAFileNamesTheFile() {
        let shell = Shell()
        shell.write("/bad.bc", "1\n2 2\n")
        let result = shell.capture("bc /bad.bc < /dev/null")
        #expect(result.out == "1\n")
        #expect(result.err == "/bad.bc 2: syntax error\n")
    }

    @Test func missingFileIsAnError() {
        let shell = Shell()
        let result = shell.capture("bc /missing < /dev/null")
        #expect(result.err == "File /missing is unavailable.\n")
        #expect(result.status == 1)
    }

    @Test func worksInAPipeline() {
        let shell = Shell()
        #expect(shell.capture("echo '2^64' | bc").out == "18446744073709551616\n")
        #expect(shell.capture("echo 'scale=3; 22/7' | bc | cat").out == "3.142\n")
    }

    /// On a terminal each line is evaluated as soon as it is entered, a
    /// multi-line block waits for its closing brace, and `quit` returns to
    /// the shell.
    @Test func interactiveSessionAnswersLineByLine() {
        let shell = Shell()
        shell.run("bc")
        shell.console.removeAll()
        shell.run("2+3")
        #expect(String(decoding: shell.console, as: UTF8.self) == "5\n")
        shell.console.removeAll()
        shell.run("for (i=0; i<2; i++) {")
        #expect(shell.console.isEmpty)
        shell.run("i*10")
        #expect(shell.console.isEmpty)
        shell.run("}")
        #expect(String(decoding: shell.console, as: UTF8.self) == "0\n10\n")
        shell.run("quit")
        shell.run("echo back > /flag")
        #expect(shell.text(of: "/flag") == "back\n")
    }

    @Test func invalidOptionIsRejected() {
        let shell = Shell()
        let result = shell.capture("bc -Z < /dev/null")
        #expect(result.err == "bc: invalid option -- 'Z'\nTry 'bc --help' for more information.\n")
        #expect(result.status == 2)
    }

    // MARK: - Number properties

    /// Integer division truncates toward zero and the modulus takes the sign
    /// of the dividend, so `a == (a/b)*b + a%b` for every sign combination.
    @Test func divisionIdentityHolds() {
        var program = ""
        var expected = ""
        for a in ["17", "0-17", "123456789987654321", "0-100", "0", "5"] {
            for b in ["5", "0-5", "7", "0-123", "1000000007"] {
                program += "a=\(a); b=\(b); (a/b)*b + a%b == a\n"
                expected += "1\n"
            }
        }
        #expect(bc(program) == expected)
        #expect(bc("a=0-100; a/7; a%7") == "-14\n-2\n")
        #expect(bc("123456789987654321/(0-123); 123456789987654321%(0-123)") == "-1003713739737027\n0\n")
    }

    @Test func numberFormattingRoundTrips() {
        for text in ["0", "1", "42", ".5", "123.456", "1000000000000000000000.000000001"] {
            #expect(BCNumber.parse(text, ibase: 10).formatted(obase: 10) == text)
        }
        #expect(BCNumber(-42).formatted(obase: 10) == "-42")
        #expect(BCNumber(255).formatted(obase: 16) == "FF")
        #expect(BCNumber.parse("777", ibase: 8).formatted(obase: 2) == "111111111")
    }

    // MARK: - Harness

    /// Run a bc program fed on standard input; returns stdout.
    private func bc(_ program: String, flags: String = "") -> String {
        run(program, flags: flags).out
    }

    private func run(_ program: String, flags: String = "") -> (out: String, err: String, status: Int32) {
        let shell = Shell()
        shell.write("/program.bc", program + "\n")
        return shell.capture("bc \(flags) < /program.bc")
    }

    /// Boots a kernel + pty + interactive shell (echo off), runs command lines,
    /// and reads the files they produce back out of the VFS.
    private final class Shell {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()
        /// Everything the terminal has shown (prompts, stdout, stderr).
        var console: [UInt8] = []

        init() {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak self, weak pty] in
                guard let self, let pty else { return }
                self.console.append(contentsOf: pty.readForApp(max: 65_535))
            }
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

        func run(_ line: String) {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }

        func capture(_ command: String) -> (out: String, err: String, status: Int32) {
            run("\(command) > /.out 2> /.err")
            run("echo $? > /.status")
            let status = Int32(text(of: "/.status").split(separator: "\n").first ?? "") ?? -1
            return (text(of: "/.out"), text(of: "/.err"), status)
        }

        func write(_ path: String, _ text: String) {
            kernel.spawn("seed") { ctx in
                if let fd = ctx.open(path, create: true, truncate: true) {
                    ctx.write(fd, Array(text.utf8))
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
        }

        func text(of path: String) -> String {
            final class Box { var text: String? }
            let box = Box()
            kernel.spawn("read") { ctx in
                if let fd = ctx.open(path) {
                    var data: [UInt8] = []
                    while true {
                        let chunk = ctx.read(fd, max: 1 << 16)
                        if chunk.isEmpty { break }
                        data.append(contentsOf: chunk)
                    }
                    box.text = String(decoding: data, as: UTF8.self)
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
            return box.text ?? "<missing>"
        }
    }
}
