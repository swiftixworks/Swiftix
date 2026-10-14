/// `bytes`: the `Buffer`, the `Reader`, and for slices of bytes the
/// functions `strings` has for strings.
///
/// The package is Go text of the library (`Sources/SwiftixGoLibrary/bytes`),
/// compiled with the program that uses it. What each program here prints is
/// what Go 1.24.5 prints for it, the capacity of a `Buffer` included. The
/// text itself is also run in real Go against Go's package with random
/// inputs, and its folding of case against Go's table for every pair of
/// cased characters: `Scripts/go-library-harness/run.sh bytes`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go bytes")
struct GoBytesTests: GoTestHarness {

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

    /// The zero value is ready; what is written is read in order, by bytes,
    /// runes, a count, or up to a delimiter, and `fmt.Fprintf` writes into it.
    @Test func aBufferIsWrittenAtOneEndAndReadAtTheOther() throws {
        #expect(
            try runGoMain(
                #"""
                var b bytes.Buffer
                fmt.Println(b.Len(), b.Cap(), b.String() == "")
                b.WriteString("héllo")
                b.WriteByte(' ')
                b.Write([]byte("wörld"))
                n, err := b.WriteRune('世')
                fmt.Println(n, err, b.Len(), b.Cap(), b.String())
                fmt.Fprintf(&b, " %d-%s\n", 7, "x")
                p := make([]byte, 3)
                n, err = b.Read(p)
                fmt.Println(n, err, p, b.Len())
                c, _ := b.ReadByte()
                r, size, _ := b.ReadRune()
                fmt.Println(c, r, size, b.UnreadRune(), b.UnreadRune(), b.UnreadByte())
                fmt.Printf("%q %q\n", b.Next(4), b.Bytes())
                line, err := b.ReadString('\n')
                fmt.Printf("%q %v\n", line, err)
                line, err = b.ReadString('\n')
                fmt.Printf("%q %v %v\n", line, err, err == io.EOF)
                rest, err := b.ReadBytes('x')
                fmt.Println(rest == nil, err, b.Len(), b.Cap())
                n, err = b.Read(p)
                fmt.Println(n, err)
                n, err = b.Read(nil)
                fmt.Println(n, err)
                """#,
                imports: ["bytes", "fmt", "io"])
                == #"""
                0 0 true
                3 <nil> 16 64 héllo wörld世
                3 <nil> [104 195 169] 18
                108 108 1 <nil> bytes.Buffer: UnreadRune: previous operation was not a successful ReadRune bytes.Buffer: UnreadByte: previous operation was not a successful read
                "lo w" "örld世 7-x\n"
                "örld世 7-x\n" <nil>
                "" EOF true
                true EOF 0 64
                0 EOF
                0 <nil>

                """#)
    }

    /// `Cap` after each growth is Go's: 64 bytes at first, then twice the
    /// storage or what is needed, rounded up to a size class of Go's allocator;
    /// content of less than half the storage is slid down instead.
    @Test func aBufferGrowsAsGoDoes() throws {
        #expect(
            try runGoMain(
                #"""
                var b bytes.Buffer
                last := -1
                for i := 0; i < 400; i++ {
                    fmt.Fprintf(&b, "line %d\n", i)
                    if b.Cap() != last {
                        last = b.Cap()
                        fmt.Println(b.Len(), last)
                    }
                }
                b.Next(3000)
                b.Write(make([]byte, 600))
                fmt.Println(b.Len(), b.Cap())
                b.Reset()
                fmt.Println(b.Len(), b.Cap(), b.Available())
                var g bytes.Buffer
                g.Grow(100)
                fmt.Println(g.Len(), g.Cap())
                g.Grow(40000)
                fmt.Println(g.Len(), g.Cap())
                fixed := bytes.NewBuffer(make([]byte, 0, 10))
                fixed.WriteString("0123456789")
                fmt.Println(fixed.Cap(), fixed.Available())
                fixed.WriteByte('!')
                fmt.Println(fixed.Cap(), fixed.String())
                """#,
                imports: ["bytes", "fmt"])
                == """
                7 64
                70 128
                134 256
                262 512
                518 1024
                1033 2048
                2050 4096
                1090 4096
                0 4096 4096
                0 112
                0 40960
                10 0
                24 0123456789!

                """)
    }

    /// `Truncate` keeps the first unread bytes and panics out of range, `Grow`
    /// panics on a negative count, and a nil `*Buffer` prints as `<nil>`.
    @Test func truncateResetAndTheNilBuffer() throws {
        #expect(
            try runGoMain(
                """
                b := bytes.NewBufferString("0123456789")
                b.ReadByte()
                b.Truncate(4)
                fmt.Println(b.String(), b.Len())
                b.Truncate(0)
                fmt.Println(b.Len(), b.String() == "")
                var none *bytes.Buffer
                fmt.Println(none.String(), bytes.NewBuffer([]byte("abc")).Len(), bytes.MinRead, bytes.ErrTooLarge)
                func() {
                    defer func() { fmt.Println("recovered:", recover()) }()
                    b.Truncate(1)
                }()
                defer func() { fmt.Println("recovered:", recover()) }()
                b.Grow(-1)
                """,
                imports: ["bytes", "fmt"])
                == """
                1234 4
                0 true
                <nil> 3 512 bytes.Buffer: too large
                recovered: bytes.Buffer: truncation out of range
                recovered: bytes.Buffer.Grow: negative count

                """)
    }

    /// `ReadFrom` reads a source to its end, `WriteTo` empties the buffer into
    /// a destination in one write, and `io.Copy` goes through them. A `Buffer`
    /// is the source of a `bufio.Reader` and the destination of a
    /// `bufio.Writer`.
    @Test func aBufferCopiesFromAReaderAndToAWriter() throws {
        #expect(
            try runGoMain(
                #"""
                var b bytes.Buffer
                total, err := b.ReadFrom(strings.NewReader(strings.Repeat("0123456789", 120)))
                fmt.Println(total, err, b.Len(), b.Cap())
                b.Truncate(14)
                total, err = b.WriteTo(shout{&b})
                fmt.Println(total, err, b.String())
                copied, err := io.Copy(shout{&b}, bytes.NewBufferString("through io.Copy"))
                fmt.Println(copied, err, b.String())

                in := bytes.NewBufferString("GET /index.html HTTP/1.1\r\nHost: example\r\n\r\n")
                var out bytes.Buffer
                rd, wr := bufio.NewReader(in), bufio.NewWriter(&out)
                for {
                    header, err := rd.ReadBytes('\n')
                    header = bytes.TrimSpace(header)
                    if err != nil || len(header) == 0 {
                        break
                    }
                    if name, value, ok := bytes.Cut(header, []byte(": ")); ok {
                        fmt.Fprintf(wr, "%s=%s;", bytes.ToLower(name), value)
                    } else {
                        wr.Write(bytes.Fields(header)[1])
                        wr.WriteByte(';')
                    }
                }
                fmt.Println(out.Len(), wr.Flush(), out.String())
                """#,
                imports: ["bufio", "bytes", "fmt", "io", "strings"],
                declarations: """
                    type shout struct{ w io.Writer }

                    func (s shout) Write(p []byte) (int, error) {
                        fmt.Println("write of", len(p))
                        return s.w.Write(bytes.ToUpper(p))
                    }
                    """)
                == "1200 <nil> 1200 2048\nwrite of 14\n14 <nil> \nwrite of 15\n15 <nil> THROUGH IO.COPY\n0 <nil> /index.html;host=example;\n")
    }

    /// A `bytes.Reader` reads, steps back, seeks, and reads at an offset.
    @Test func aReaderReadsASlice() throws {
        #expect(
            try runGoMain(
                """
                r := bytes.NewReader([]byte("héllo"))
                fmt.Println(r.Len(), r.Size())
                r.ReadByte()
                ch, size, _ := r.ReadRune()
                fmt.Println(ch, size, r.UnreadRune(), r.UnreadRune(), r.UnreadByte(), r.Len())
                pos, err := r.Seek(-2, io.SeekEnd)
                at := make([]byte, 4)
                k, aerr := r.ReadAt(at, 3)
                fmt.Println(pos, err, k, aerr, at, r.Len())
                _, err = r.Seek(-1, io.SeekStart)
                fmt.Println(err)
                _, err = r.Seek(0, 7)
                fmt.Println(err)
                rest, err := io.ReadAll(r)
                fmt.Println(string(rest), err)
                r.Reset([]byte("again"))
                var b bytes.Buffer
                n, err := r.WriteTo(&b)
                fmt.Println(n, err, b.String(), r.Len())
                _, err = r.ReadByte()
                fmt.Println(err, r.UnreadByte(), bytes.NewReader(nil).UnreadByte())
                """,
                imports: ["bytes", "fmt", "io"])
                == """
                6 6
                233 2 <nil> bytes.Reader.UnreadRune: previous operation was not ReadRune <nil> 6
                4 <nil> 3 EOF [108 108 111 0] 2
                bytes.Reader.Seek: negative position
                bytes.Reader.Seek: invalid whence
                lo <nil>
                5 <nil> again 0
                EOF <nil> bytes.Reader.UnreadByte: at beginning of slice

                """)
    }

    /// `Equal`, `Compare`, `EqualFold`, and the searches.
    @Test func comparingAndSearching() throws {
        #expect(
            try runGoMain(
                #"""
                a, z := []byte("Hello, World"), []byte("hello, world")
                fmt.Println(bytes.Equal(a, z), bytes.EqualFold(a, z), bytes.Compare(a, z), bytes.Compare(z, a), bytes.Compare(a, a), bytes.Equal(nil, []byte{}), bytes.Compare(nil, a))
                fmt.Println(bytes.Contains(a, []byte("lo, ")), bytes.Index(a, []byte("o")), bytes.LastIndex(a, []byte("o")), bytes.IndexByte(a, 'W'), bytes.LastIndexByte(a, 'l'), bytes.Index(a, []byte("xyz")), bytes.Index(a, nil), bytes.LastIndex(a, nil))
                fmt.Println(bytes.Count(a, []byte("l")), bytes.Count([]byte("héllo"), nil), bytes.Count([]byte("aaaa"), []byte("aa")))
                fmt.Println(bytes.HasPrefix(a, []byte("Hell")), bytes.HasSuffix(a, []byte("World")), bytes.HasPrefix(a, z), bytes.HasPrefix(a, nil))
                // A part of a slice is searched and compared from its own start.
                s := []byte("xxabcabdxx")[2:8]
                fmt.Println(bytes.Index(s, []byte("abd")), bytes.Index(s, []byte("xx")), bytes.IndexByte(s, 'x'), bytes.IndexByte(s, 'd'), bytes.Index(s, s), bytes.Index(s[:2], s), bytes.Index(nil, nil), bytes.Index(s, []byte("d")), bytes.LastIndex(s, []byte("ab")), bytes.Contains(s, []byte("cab")))
                fmt.Println(bytes.Compare(s[:3], s[3:]), bytes.Compare([]byte{0xff}, []byte{0x01}), bytes.Compare(s[:2], s[:3]), bytes.Compare(s[:3], s[:2]), bytes.Equal(s[:2], s[3:5]), bytes.Equal(s[:3], s[3:]), bytes.Equal(nil, nil))
                fmt.Println(bytes.EqualFold([]byte("Straße"), []byte("STRASSE")), bytes.EqualFold([]byte("K"), []byte("\u212a")), bytes.EqualFold([]byte("σς"), []byte("ΣΣ")), bytes.EqualFold([]byte("i"), []byte("İ")), bytes.EqualFold([]byte("ǅ"), []byte("ǆ")))
                """#,
                imports: ["bytes", "fmt"])
                == """
                false true -1 1 0 true -1
                true 4 8 7 10 -1 0 12
                3 6 2
                true true false true
                3 -1 -1 5 0 -1 0 5 3 true
                -1 1 -1 1 true false true
                false true true false true

                """)
    }

    /// `Split`, `SplitN`, `Fields`, `Join`, `Cut`, and `Repeat`: the parts, and
    /// which results are nil.
    @Test func splittingAndJoining() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(show(bytes.Split([]byte("a,b,,c"), []byte(","))), show(bytes.Split([]byte("héy"), nil)), show(bytes.Split(nil, []byte(","))), show(bytes.Split(nil, nil)))
                fmt.Println(show(bytes.SplitN([]byte("a,b,c"), []byte(","), 2)), show(bytes.SplitN([]byte("a,b,c"), []byte(","), 0)), show(bytes.SplitN([]byte("abc"), nil, 2)))
                fmt.Println(show(bytes.Fields([]byte("  one\ttwo \u00a0 three\n"))), show(bytes.Fields([]byte("   "))))
                joined := bytes.Join([][]byte{[]byte("a"), []byte("b"), []byte("c")}, []byte(", "))
                fmt.Printf("%q %q %v %q\n", joined, bytes.Join(nil, []byte("x")), bytes.Join(nil, nil) == nil, bytes.Repeat([]byte("ab"), 3))
                before, after, found := bytes.Cut([]byte("key=value=x"), []byte("="))
                fmt.Printf("%q %q %v\n", before, after, found)
                before, after, found = bytes.Cut([]byte("key"), []byte("="))
                fmt.Printf("%q %v %v\n", before, after == nil, found)
                // The parts lie in the slice that was split.
                line := []byte("x y")
                parts := bytes.Fields(line)
                parts[1][0] = 'Z'
                fmt.Println(string(line))
                defer func() { fmt.Println("recovered:", recover()) }()
                bytes.Repeat([]byte("x"), -1)
                """#,
                imports: ["bytes", "fmt"],
                declarations: """
                    func show(parts [][]byte) string {
                        s := fmt.Sprint(len(parts), parts == nil, ":")
                        for _, p := range parts {
                            s += fmt.Sprintf("%q,", p)
                        }
                        return s
                    }
                    """)
                == """
                4 false:"a","b","","c", 3 false:"h","é","y", 1 false:"", 0 false:
                2 false:"a","b,c", 0 true: 2 false:"a","bc",
                3 false:"one","two","three", 0 false:
                "a, b, c" "" false "ababab"
                "key" "value=x" true
                "key" true false
                x Z
                recovered: bytes: negative Repeat count

                """)
    }

    /// `TrimSpace`, `Trim`, `TrimLeft`, `TrimRight`, `TrimPrefix`,
    /// `TrimSuffix`, `Replace`, `ReplaceAll`, and the letter cases.
    @Test func trimmingAndReplacing() throws {
        #expect(
            try runGoMain(
                #"""
                a := []byte("Hello, World")
                fmt.Printf("%q %q %q %q\n", bytes.TrimSpace([]byte(" \t padded \r\n")), bytes.Trim([]byte("xxhixyx"), "xy"), bytes.TrimPrefix(a, []byte("Hello, ")), bytes.TrimSuffix(a, []byte("World")))
                fmt.Printf("%q %q %q\n", bytes.TrimLeft([]byte("ééa é"), "é"), bytes.TrimRight([]byte("ééa é"), " é"), bytes.TrimSpace([]byte("\u2003wide\u00a0")))
                fmt.Println(bytes.TrimSpace([]byte("  ")) == nil, bytes.Trim([]byte("xx"), "x") == nil, bytes.TrimRight([]byte("xx"), "x") == nil, bytes.TrimLeft([]byte("xx"), "x") == nil)
                fmt.Printf("%s %s %s\n", bytes.ToUpper([]byte("straße é")), bytes.ToLower([]byte("ÀÉÎ Go")), bytes.ToUpper([]byte("already")))
                fmt.Printf("%s %s %s %s %s\n", bytes.Replace([]byte("banana"), []byte("a"), []byte("o"), 2), bytes.ReplaceAll([]byte("banana"), []byte("an"), nil), bytes.Replace([]byte("abc"), nil, []byte("-"), -1), bytes.Replace([]byte("abc"), []byte("x"), []byte("y"), -1), bytes.Replace([]byte("héé"), nil, []byte("."), 3))
                c := bytes.Clone(a)
                c[0] = 'J'
                fmt.Println(string(a), string(c), bytes.Clone(nil) == nil)
                """#,
                imports: ["bytes", "fmt"])
                == """
                "padded" "hi" "World" "Hello, "
                "a é" "ééa" "wide"
                true true false true
                STRAßE É àéî go ALREADY
                bonona ba -a-b-c- abc .h.é.é
                Hello, World Jello, World true

                """)
    }

    /// The functions work on any bytes. What is not UTF-8 is one byte to the
    /// searches and the trims, U+FFFD to the functions that read characters,
    /// and is written as U+FFFD by `ToUpper` and `ToLower`, all as in Go. Only
    /// `String` and `ReadString` differ from Go: a string of this dialect is
    /// valid UTF-8, so they give U+FFFD for such a byte where Go keeps it. See
    /// `docs/go-toolchain.md`, Known Gaps.
    @Test func bytesThatAreNoTextStayAsTheyAre() throws {
        #expect(
            try runGoMain(
                #"""
                raw := []byte{0xff, 'a', 0xc3, ' ', 0xe4, 0xb8}
                fmt.Println(bytes.ToUpper(raw), bytes.Count(raw, nil), bytes.IndexByte(raw, 0xc3), bytes.Fields(raw), bytes.Split(raw[:3], nil))
                fmt.Println(bytes.Equal(bytes.TrimSpace(raw), raw), bytes.EqualFold([]byte{0xff}, []byte{0xfe}), bytes.Trim(raw, "\ufffd"), bytes.Index(raw, []byte{0xb8}))
                b := bytes.NewBuffer(raw)
                r, size, _ := b.ReadRune()
                fmt.Println(r, size, b.Bytes(), b.Len())
                var w bytes.Buffer
                w.WriteRune(0xD800)
                w.WriteRune(-1)
                w.WriteByte(0x80)
                fmt.Println(w.Bytes())
                rd := bytes.NewReader(raw[4:])
                r, size, _ = rd.ReadRune()
                fmt.Println(r, size)
                """#,
                imports: ["bytes", "fmt"])
                == """
                [239 191 189 65 239 191 189 32 239 191 189 239 191 189] 7 2 [[255 97 195] [228 184]] [[255] [97] [195]]
                true true [97 195 32] 5
                65533 1 [97 195 32 228 184] 5
                [239 191 189 239 191 189 128]
                65533 1

                """)
    }

    /// The package under another name, a `Buffer` as a field, behind a pointer,
    /// in a slice, as an `io.Writer` and an `io.Reader`, and captured by a
    /// function literal.
    @Test func everyPassSeesThePackage() throws {
        #expect(
            try runGoMain(
                #"""
                var l logger
                l.printf("%d items", 3)
                l.printf("done")
                fmt.Print(l.buf.String())
                bufs := []*raw.Buffer{raw.NewBufferString("a"), new(raw.Buffer)}
                add := func(s string) {
                    for _, b := range bufs {
                        b.WriteString(s)
                    }
                }
                add("x")
                add("y")
                fmt.Println(bufs[0], bufs[1].Len())
                var w io.Writer = bufs[1]
                io.WriteString(w, "!")
                var r io.Reader = bufs[1]
                data, err := io.ReadAll(r)
                fmt.Println(string(data), err, raw.Equal(data, []byte("xy!")))
                fmt.Printf("%T %T %v\n", bufs[0], raw.NewReader(nil), l.buf.Len())
                """#,
                imports: ["fmt", "io"],
                declarations: #"""
                    import raw "bytes"

                    type logger struct {
                        buf   raw.Buffer
                        lines int
                    }

                    func (l *logger) printf(format string, args ...any) {
                        l.lines++
                        fmt.Fprintf(&l.buf, "%d: ", l.lines)
                        fmt.Fprintf(&l.buf, format, args...)
                        l.buf.WriteByte('\n')
                    }
                    """#)
                == """
                1: 3 items
                2: done
                axy 2
                xy! <nil> true
                *bytes.Buffer *bytes.Reader 19

                """)
    }

    /// A method an embedded field lends, with several results, is called as a
    /// statement, deferred, and started as a goroutine, as `w.WriteString(s)`
    /// is on a `*bufio.ReadWriter`. Where one value is wanted it is still
    /// refused.
    @Test func aPromotedCallOfSeveralResultsIsAStatement() throws {
        #expect(
            try runGoMain(
                """
                out := &tally{}
                both := &pair{tally: out}
                both.Write([]byte("ab"))
                both.count()
                func() {
                    defer both.Write([]byte("cd"))
                }()
                fmt.Println(out.n)
                """,
                imports: ["fmt"],
                declarations: """
                    type tally struct{ n int }

                    func (t *tally) Write(p []byte) (int, error) {
                        t.n += len(p)
                        return len(p), nil
                    }

                    type counter struct{}

                    func (c counter) count() (int, bool) { return 0, false }

                    type pair struct {
                        *tally
                        counter
                    }
                    """)
                == "4\n")
        #expect(
            firstError(
                """
                both := &pair{}
                n := both.count()
                fmt.Println(n)
                """,
                imports: ["fmt"],
                declarations: """
                    type counter struct{}

                    func (c counter) count() (int, bool) { return 0, false }

                    type pair struct {
                        counter
                    }
                    """)
                == "12:6: assignment mismatch: 1 variable but both.count returns 2 values")
    }

    /// A program is linked with the declarations of `bufio` and `bytes` it
    /// names and what those reach, and a program that names neither package
    /// gets nothing of them.
    @Test func onlyWhatAProgramUsesIsLinked() throws {
        func functionNames(_ body: String, imports: [String]) throws -> Set<String> {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(path: "main.go", text: goMainSource(body, imports: imports))
            ])
            return Set(executable.functions.map(\.name))
        }
        let none = try functionNames(
            "fmt.Println(strings.ToUpper(\"x\"))", imports: ["fmt", "strings"])
        #expect(none == ["main"])

        let equal = try functionNames(
            "fmt.Println(bytes.Equal([]byte(\"a\"), nil))", imports: ["bytes", "fmt"])
        #expect(equal == ["main", "bytes.Equal"])

        let buffer = try functionNames(
            """
            var b bytes.Buffer
            b.WriteString("x")
            fmt.Println(b.String())
            """, imports: ["bytes", "fmt"])
        #expect(buffer.contains("*bytes.Buffer.WriteString"))
        #expect(buffer.contains("bytes.IndexByte"))
        #expect(!buffer.contains { $0.contains("bytes.Reader") || $0.hasPrefix("bufio.") })
        #expect(!buffer.contains("bytes.Split") && !buffer.contains("bytes.EqualFold"))

        let scanner = try functionNames(
            """
            s := bufio.NewScanner(strings.NewReader("a b"))
            for s.Scan() {
                fmt.Println(s.Text())
            }
            """, imports: ["bufio", "fmt", "strings"])
        #expect(scanner.contains("*bufio.Scanner.Scan"))
        #expect(scanner.contains("bufio.ScanLines"))
        #expect(!scanner.contains("bufio.ScanWords"))
        #expect(!scanner.contains { $0.contains("bufio.Reader") || $0.contains("bufio.Writer") })
        #expect(!scanner.contains { $0.hasPrefix("bytes.") || $0.hasPrefix("*bytes.") })
    }
}
