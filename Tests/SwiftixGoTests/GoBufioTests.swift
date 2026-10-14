/// `bufio`: a buffer between a program and an `io.Reader` or an
/// `io.Writer`, and the ways of taking text apart.
///
/// The package is Go text of the library (`Sources/SwiftixGoLibrary/bufio`),
/// compiled with the program that uses it. What each program here prints is
/// what Go 1.24.5 prints for it. The text itself is also run in real Go
/// against Go's package, with random operations over sources that give
/// their data in pieces: `Scripts/go-library-harness/run.sh bufio`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go bufio")
struct GoBufioTests: GoTestHarness {

    /// A byte, a rune, and what can be given back; a look ahead, a skip, and
    /// the three ways of reading a line, over a source that gives three bytes
    /// at a time.
    @Test func aReaderReadsBytesRunesAndLines() throws {
        #expect(
            try runGoMain(
                #"""
                r := bufio.NewReader(&chunks{text: []byte("héllo wörld\nsecond line\r\nlast")})
                c, _ := r.ReadByte()
                fmt.Println(c, r.Buffered(), r.UnreadByte(), r.UnreadByte(), r.Buffered())
                ch, size, err := r.ReadRune()
                fmt.Println(ch, size, err)
                ch, size, err = r.ReadRune()
                fmt.Println(string(ch), size, err, r.UnreadRune(), r.UnreadRune())
                p, err := r.Peek(5)
                fmt.Printf("%q %v\n", p, err)
                n, err := r.Discard(2)
                fmt.Println(n, err)
                s, err := r.ReadString('\n')
                fmt.Printf("%q %v\n", s, err)
                line, more, err := r.ReadLine()
                fmt.Printf("%q %v %v\n", line, more, err)
                b, err := r.ReadBytes('\n')
                fmt.Printf("%q %v %v\n", b, err, err == io.EOF)
                _, err = r.ReadByte()
                fmt.Println(err)
                _, err = r.Peek(-1)
                fmt.Println(err, err == bufio.ErrNegativeCount)
                """#,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: """
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }
                    """)
                == #"""
                104 2 <nil> bufio: invalid use of UnreadByte 3
                104 1 <nil>
                é 2 <nil> <nil> bufio: invalid use of UnreadRune
                "éllo" <nil>
                2 <nil>
                "llo wörld\n" <nil>
                "second line" false <nil>
                "last" EOF true
                EOF
                bufio: negative count true

                """#)
    }

    /// What a Reader asks of its source, call by call: a buffer of the smallest
    /// size is filled as far as each read reaches, and a read of at least the
    /// buffer's size goes past the buffer.
    @Test func aReaderAsksItsSourceAsGoDoes() throws {
        #expect(
            try runGoMain(
                """
                r := bufio.NewReaderSize(&chunks{text: []byte("0123456789abcdefghijklmnopqrstuvwxyz"), log: true}, 4)
                fmt.Println(r.Size())
                p := make([]byte, 5)
                n, _ := r.Read(p)
                fmt.Println(n, string(p[:n]))
                line, err := r.ReadSlice('9')
                fmt.Println(string(line), err)
                big := make([]byte, 20)
                n, _ = r.Read(big)
                fmt.Println(n, string(big[:n]))
                n, _ = r.Read(big)
                fmt.Println(n, string(big[:n]))
                peeked, err := r.Peek(7)
                fmt.Println(string(peeked), err)
                rest, err := io.ReadAll(r)
                fmt.Println(string(rest), err)
                """,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: """
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }
                    """)
                == """
                16
                read 16 3
                3 012
                read 16 3
                read 13 3
                read 10 3
                3456789 <nil>
                2 ab
                read 20 3
                3 cde
                read 16 3
                read 13 3
                read 10 3
                fghijkl <nil>
                read 503 3
                read 500 3
                read 497 3
                read 494 3
                fghijklmnopqrstuvwxyz <nil>

                """)
    }

    /// `ReadLine` marks the parts of a long line, `ReadSlice` and `Peek` report
    /// a full buffer, and `ReadString` joins the parts.
    @Test func aLineLongerThanTheBufferComesInParts() throws {
        #expect(
            try runGoMain(
                #"""
                text := "a line that is longer than the buffer\r\nshort\n"
                small := bufio.NewReaderSize(strings.NewReader(text), 16)
                for {
                    line, more, err := small.ReadLine()
                    if err != nil {
                        fmt.Println(err)
                        break
                    }
                    fmt.Printf("%q %v\n", line, more)
                }
                _, err := bufio.NewReaderSize(strings.NewReader(strings.Repeat("x", 40)), 16).ReadSlice('\n')
                fmt.Println(err, err == bufio.ErrBufferFull)
                _, err = bufio.NewReaderSize(strings.NewReader("abc"), 16).Peek(17)
                fmt.Println(err)
                whole, err := bufio.NewReaderSize(strings.NewReader(text), 16).ReadString('\n')
                fmt.Printf("%q %v\n", whole, err)
                r := bufio.NewReader(strings.NewReader("first"))
                r.Reset(strings.NewReader("second\n"))
                whole, err = r.ReadString('\n')
                fmt.Printf("%q %v\n", whole, err)
                """#,
                imports: ["bufio", "fmt", "strings"])
                == #"""
                "a line that is l" true
                "onger than the b" true
                "uffer" false
                "short" false
                EOF
                bufio: buffer full true
                bufio: buffer full
                "a line that is longer than the buffer\r\n" <nil>
                "second\n" <nil>

                """#)
    }

    /// Writes reach the destination a buffer at a time, a write longer than the
    /// buffer directly once the buffer is empty, and the rest at `Flush`. After
    /// an error the Writer accepts nothing until it is reset.
    @Test func aWriterGathersSmallWrites() throws {
        #expect(
            try runGoMain(
                """
                out := &sink{}
                w := bufio.NewWriterSize(out, 8)
                fmt.Println(w.Available(), w.Buffered(), w.Size())
                w.WriteString("abc")
                w.WriteByte('d')
                n, err := w.WriteRune('世')
                fmt.Println(n, err, w.Available(), w.Buffered(), len(out.writes))
                w.Write([]byte("efgh"))
                fmt.Println(w.Available(), w.Buffered(), out.writes)
                n, err = w.WriteString("a string longer than the buffer")
                fmt.Println(n, err)
                fmt.Fprintf(w, "%d-%s", 42, "x")
                fmt.Fprintln(w, "!")
                fmt.Println(w.Flush(), fmt.Sprintf("%q", out.writes))
                out.fail = true
                n, err = w.WriteString("lost")
                fmt.Println(n, err, w.Flush(), w.Flush(), w.WriteByte('x'))
                n, err = w.Write([]byte("more than eight"))
                fmt.Println(n, err)
                w.Reset(out)
                out.fail = false
                fmt.Println(w.Flush(), w.Buffered(), len(out.writes))
                """,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: """
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }
                    """)
                == #"""
                8 0 8
                3 <nil> 1 7 0
                5 3 [abcd世e]
                31 <nil>
                <nil> ["abcd世e" "fgha str" "ing long" "er than " "the buff" "er42-x!\n"]
                4 <nil> sink is closed sink is closed sink is closed
                0 sink is closed
                <nil> 0 6

                """#)
    }

    /// The four split functions of the package, over a source that gives three
    /// bytes at a time.
    @Test func aScannerReadsLinesWordsRunesAndBytes() throws {
        #expect(
            try runGoMain(
                #"""
                sc := bufio.NewScanner(&chunks{text: []byte("one two\r\n\nthree  four\nfive")})
                for sc.Scan() {
                    fmt.Printf("%q ", sc.Text())
                }
                fmt.Println(sc.Err())
                sc = bufio.NewScanner(strings.NewReader("  alpha\tbeta\n gamma  "))
                sc.Split(bufio.ScanWords)
                count := 0
                for sc.Scan() {
                    count++
                    fmt.Print(sc.Text(), len(sc.Bytes()), ";")
                }
                fmt.Println(count)
                sc = bufio.NewScanner(&chunks{text: []byte("aé世😀")})
                sc.Split(bufio.ScanRunes)
                for sc.Scan() {
                    fmt.Print(sc.Text(), "|")
                }
                sc = bufio.NewScanner(strings.NewReader("ab"))
                sc.Split(bufio.ScanBytes)
                for sc.Scan() {
                    fmt.Print(sc.Bytes())
                }
                fmt.Println(sc.Scan(), sc.Err())
                """#,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: """
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }
                    """)
                == """
                "one two" "" "three  four" "five" <nil>
                alpha5;beta4;gamma5;3
                a|é|世|😀|[97][98]false <nil>

                """)
    }

    /// A line that does not fit the limit given with `Buffer` ends the scan with
    /// `ErrTooLong`; the default limit is 64 KiB. `Buffer` and `Split` panic
    /// after the first `Scan`.
    @Test func aTokenTooLongStopsTheScan() throws {
        #expect(
            try runGoMain(
                #"""
                sc := bufio.NewScanner(strings.NewReader("short\n" + strings.Repeat("x", 100) + "\nnever"))
                sc.Buffer(make([]byte, 0, 16), 32)
                for sc.Scan() {
                    fmt.Println(sc.Text())
                }
                fmt.Println(sc.Err(), sc.Err() == bufio.ErrTooLong, bufio.MaxScanTokenSize)
                defer func() { fmt.Println("recovered:", recover()) }()
                sc.Buffer(nil, 0)
                """#,
                imports: ["bufio", "fmt", "strings"])
                == """
                short
                bufio.Scanner: token too long true 65536
                recovered: Buffer called after Scan

                """)
        #expect(
            try runGoMain(
                #"""
                sc := bufio.NewScanner(strings.NewReader(strings.Repeat("y", 5000) + "\nend\n"))
                for sc.Scan() {
                    fmt.Println(len(sc.Text()))
                }
                fmt.Println(sc.Err())
                defer func() { fmt.Println("recovered:", recover()) }()
                sc.Split(bufio.ScanWords)
                """#,
                imports: ["bufio", "fmt", "strings"])
                == "5000\n3\n<nil>\nrecovered: Split called after Scan\n")
    }

    /// A split function is a function of the program: a literal that captures a
    /// variable, a `bufio.SplitFunc` variable, and one that ends the scan with
    /// `ErrFinalToken` or with an error of its own.
    @Test func aSplitFunctionOfTheProgramFindsTheTokens() throws {
        #expect(
            try runGoMain(
                """
                calls := 0
                sc := bufio.NewScanner(strings.NewReader("a,b,,c"))
                sc.Split(func(data []byte, atEOF bool) (int, []byte, error) {
                    calls++
                    for i, c := range data {
                        if c == ',' {
                            return i + 1, data[:i], nil
                        }
                    }
                    if !atEOF {
                        return 0, nil, nil
                    }
                    return 0, data, bufio.ErrFinalToken
                })
                for sc.Scan() {
                    fmt.Printf("%q ", sc.Text())
                }
                fmt.Println(sc.Err(), calls)
                var pairs bufio.SplitFunc = func(data []byte, atEOF bool) (advance int, token []byte, err error) {
                    if len(data) >= 2 {
                        return 2, data[:2], nil
                    }
                    if atEOF && len(data) > 0 {
                        return 0, nil, errors.New("an odd byte")
                    }
                    return 0, nil, nil
                }
                sc = bufio.NewScanner(strings.NewReader("aabbc"))
                sc.Split(pairs)
                for sc.Scan() {
                    fmt.Print(sc.Text(), " ")
                }
                fmt.Println(sc.Err())
                sc = bufio.NewScanner(strings.NewReader("abc"))
                sc.Split(func(data []byte, atEOF bool) (int, []byte, error) { return len(data) + 1, nil, nil })
                fmt.Println(sc.Scan(), sc.Err(), sc.Err() == bufio.ErrAdvanceTooFar)
                """,
                imports: ["bufio", "fmt", "strings", "errors"])
                == """
                "a" "b" "" "c" <nil> 5
                aa bb an odd byte
                false bufio.Scanner: SplitFunc returns advance count beyond input true

                """)
    }

    /// The loop of a line protocol: a `ReadWriter` over one value that reads
    /// and writes, with `fmt.Fprintf` into it and its promoted methods called
    /// as statements.
    @Test func aReadWriterServesAConnection() throws {
        #expect(
            try runGoMain(
                #"""
                reply := &sink{}
                serve(conn{in: strings.NewReader("PING\r\nECHO hey\r\nQUIT\r\nhalf"), out: reply})
                fmt.Printf("%q\n", reply.writes)
                """#,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: #"""
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }

                    type conn struct {
                        in  *strings.Reader
                        out *sink
                    }

                    func (c conn) Read(p []byte) (int, error)  { return c.in.Read(p) }
                    func (c conn) Write(p []byte) (int, error) { return c.out.Write(p) }

                    func serve(rw io.ReadWriter) {
                        b := bufio.NewReadWriter(bufio.NewReader(rw), bufio.NewWriter(rw))
                        for {
                            line, err := b.ReadString('\n')
                            if err != nil {
                                fmt.Printf("end: %q %v\n", line, err)
                                break
                            }
                            words := strings.Fields(line)
                            switch words[0] {
                            case "PING":
                                b.WriteString("+PONG\r\n")
                            case "ECHO":
                                fmt.Fprintf(b, "$%d\r\n%s\r\n", len(words[1]), words[1])
                            default:
                                b.WriteString("-ERR unknown command\r\n")
                            }
                            b.Flush()
                        }
                    }
                    """#)
                == #"""
                end: "half" EOF
                ["+PONG\r\n" "$3\r\nhey\r\n" "-ERR unknown command\r\n"]

                """#)
    }

    /// `WriteTo` and `ReadFrom`, and `io.Copy` through them: a Reader writes its
    /// buffer out as it fills, a Writer reads into its buffer, and each hands
    /// over to a source or destination that can do the whole copy.
    @Test func copiesTakeTheShortWay() throws {
        #expect(
            try runGoMain(
                #"""
                out := &sink{}
                n, err := bufio.NewReaderSize(&chunks{text: []byte("copied through a reader")}, 16).WriteTo(out)
                fmt.Println(n, err, fmt.Sprintf("%q", out.writes))
                w := bufio.NewWriterSize(out, 16)
                n, err = w.ReadFrom(&chunks{text: []byte("read into the buffer of a writer")})
                fmt.Println(n, err, w.Buffered(), w.Flush(), fmt.Sprintf("%q", out.writes[len(out.writes)-3:]))
                copied, err := io.Copy(w, bufio.NewReader(strings.NewReader("both")))
                fmt.Println(copied, err, w.Buffered(), w.Flush(), out.writes[len(out.writes)-1])
                fmt.Printf("%T %T %T\n", bufio.NewReader(nil), w, bufio.NewScanner(nil))
                """#,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: """
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }
                    """)
                == """
                23 <nil> ["" "cop" "ied" " th" "rou" "gh " "a r" "ead" "er"]
                32 <nil> 0 <nil> ["er" "read into the bu" "ffer of a writer"]
                4 <nil> 4 <nil> both
                *bufio.Reader *bufio.Writer *bufio.Scanner

                """)
    }

    /// A Reader and a Scanner hand out the bytes of their source unchanged, and
    /// decode what is not UTF-8 as U+FFFD of width 1, as Go does. Only the
    /// strings they make (`ReadString`, `Text`) are text: a string of this
    /// dialect is valid UTF-8, so such bytes become U+FFFD there. See
    /// `docs/go-toolchain.md`, Known Gaps.
    @Test func bytesThatAreNoTextAreReadAsTheyAre() throws {
        #expect(
            try runGoMain(
                #"""
                raw := []byte{'a', 0xff, 0xe4, 0xb8, '\n', 0xc3, 0xa9}
                r := bufio.NewReader(&chunks{text: raw})
                r.ReadByte()
                ch, size, _ := r.ReadRune()
                fmt.Println(ch, size)
                ch, size, _ = r.ReadRune()
                fmt.Println(ch, size)
                line, _ := r.ReadBytes('\n')
                fmt.Println(line)
                ch, size, _ = r.ReadRune()
                fmt.Println(ch, size)
                sc := bufio.NewScanner(&chunks{text: raw})
                sc.Split(bufio.ScanRunes)
                for sc.Scan() {
                    fmt.Print(sc.Bytes())
                }
                fmt.Println()
                sc = bufio.NewScanner(&chunks{text: raw})
                sc.Scan()
                fmt.Println(sc.Bytes())
                """#,
                imports: ["bufio", "fmt", "io", "strings", "errors"],
                declarations: """
                    // A source that gives its text three bytes at a time, and says so.
                    type chunks struct {
                        text []byte
                        at   int
                        log  bool
                    }

                    func (c *chunks) Read(p []byte) (int, error) {
                        if c.at >= len(c.text) {
                            return 0, io.EOF
                        }
                        n := copy(p, c.text[c.at:min(c.at+3, len(c.text))])
                        c.at += n
                        if c.log {
                            fmt.Println("read", len(p), n)
                        }
                        return n, nil
                    }

                    // A destination that keeps each write apart.
                    type sink struct {
                        writes []string
                        fail   bool
                    }

                    func (s *sink) Write(p []byte) (int, error) {
                        if s.fail {
                            return 0, errors.New("sink is closed")
                        }
                        s.writes = append(s.writes, string(p))
                        return len(p), nil
                    }
                    """)
                == """
                65533 1
                65533 1
                [184 10]
                233 2
                [97][239 191 189][239 191 189][239 191 189][10][195 169]
                [97 255 228 184]

                """)
    }

    /// The package under another name, its types in the declarations of a
    /// program (a field, a parameter, a result, an embedded pointer), and its
    /// values in a function literal.
    @Test func everyPassSeesThePackage() throws {
        #expect(
            try runGoMain(
                #"""
                l := newLines("x\ny\n")
                next := func() string {
                    s, _ := l.r.ReadString('\n')
                    return s
                }
                fmt.Printf("%q %q\n", next(), next())
                var e emitter
                e.Writer = buffered.NewWriter(&e.out)
                e.WriteString("promoted")
                e.Flush()
                fmt.Println(e.out.String(), count(buffered.NewScanner(strings.NewReader("a b c"))))
                """#,
                imports: ["bytes", "fmt", "strings"],
                declarations: """
                    import buffered "bufio"

                    type lines struct {
                        r *buffered.Reader
                    }

                    func newLines(text string) *lines { return &lines{r: buffered.NewReader(strings.NewReader(text))} }

                    type emitter struct {
                        *buffered.Writer
                        out bytes.Buffer
                    }

                    func count(s *buffered.Scanner) int {
                        s.Split(buffered.ScanWords)
                        n := 0
                        for s.Scan() {
                            n++
                        }
                        return n
                    }
                    """)
                == #"""
                "x\n" "y\n"
                promoted 3

                """#)
    }
}
