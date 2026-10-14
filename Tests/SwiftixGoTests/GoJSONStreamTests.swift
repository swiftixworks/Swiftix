/// `json.Encoder` and `json.Decoder` over any `io.Writer` and `io.Reader`,
/// and `Valid`, `Compact`, `Indent`, `HTMLEscape`, and `Decoder.Token`.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go encoding/json: streams")
struct GoJSONStreamTests: GoTestHarness {

    /// `SetEscapeHTML` and `SetIndent` apply to the values encoded after them;
    /// an error writes nothing.
    @Test func anEncoderWritesEachValueAndANewline() throws {
        #expect(
            try runGoMain(
                """
                enc := json.NewEncoder(os.Stdout)
                enc.Encode(map[string]string{"k": "<v>"})
                enc.SetEscapeHTML(false)
                enc.Encode(map[string]string{"k": "<v>"})
                enc.SetIndent("#", "  ")
                enc.Encode(map[string]any{"x": []int{1, 2}, "y": struct{}{}})
                enc.SetIndent("", "")
                fmt.Println(enc.Encode(make(chan int)))
                enc.Encode(nil)
                """,
                imports: ["encoding/json", "fmt", "os"])
                == #"""
                {"k":"\u003cv\u003e"}
                {"k":"<v>"}
                {
                #  "x": [
                #    1,
                #    2
                #  ],
                #  "y": {}
                #}
                json: unsupported type: chan int
                null

                """#)
    }

    /// One value at a time from a reader that gives a few bytes per call: a
    /// number at the end of the input ends there, a value cut off is
    /// `io.ErrUnexpectedEOF`, space alone is `io.EOF`, and syntax errors are at
    /// their offset in the whole stream.
    @Test func aDecoderReadsAStreamOfValues() throws {
        #expect(
            try runGoMain(
                #"""
                for _, in := range []string{` {"id":1} [1,2] "s" 12 true null 3.5e1 `, `{"a":1} {"b":`, `[1,2`, `1 2 33`, `{"a":1} {"b" 2}`, "  \n\t ", ``, `[1] [2] [3,,]`} {
                    dec := json.NewDecoder(&slow{data: []byte(in), n: 3})
                    for {
                        var v any
                        err := dec.Decode(&v)
                        if err != nil {
                            fmt.Printf("  %T %v at %d\n", err, err, dec.InputOffset())
                            break
                        }
                        fmt.Printf("%T %v more=%v off=%d\n", v, v, dec.More(), dec.InputOffset())
                    }
                }
                """#,
                imports: ["encoding/json", "fmt", "io"],
                declarations: """
                    type slow struct {
                        data []byte
                        n    int
                    }

                    func (r *slow) Read(p []byte) (int, error) {
                        if len(r.data) == 0 {
                            return 0, io.EOF
                        }
                        k := min(r.n, len(p), len(r.data))
                        copy(p, r.data[:k])
                        r.data = r.data[k:]
                        return k, nil
                    }
                    """)
                == """
                map[string]interface {} map[id:1] more=true off=10
                []interface {} [1 2] more=true off=16
                string s more=true off=20
                float64 12 more=true off=23
                bool true more=true off=28
                <nil> <nil> more=true off=33
                float64 35 more=false off=38
                  *errors.errorString EOF at 38
                map[string]interface {} map[a:1] more=true off=8
                  *errors.errorString unexpected EOF at 8
                  *errors.errorString unexpected EOF at 0
                float64 1 more=true off=2
                float64 2 more=true off=4
                float64 33 more=false off=6
                  *errors.errorString EOF at 6
                map[string]interface {} map[a:1] more=true off=8
                  *json.SyntaxError invalid character '2' after object key at 8
                  *errors.errorString EOF at 0
                  *errors.errorString EOF at 0
                []interface {} [1] more=true off=4
                []interface {} [2] more=true off=8
                  *json.SyntaxError invalid character ',' looking for beginning of value at 8

                """)
    }

    /// `UseNumber`, `DisallowUnknownFields`, and what `Buffered` has left.
    @Test func decoderOptionsAndBufferedText() throws {
        #expect(
            try runGoMain(
                #"""
                dec := json.NewDecoder(strings.NewReader(`{"id":1,"name":"x","extra":true} {"id":2} 1.50 tail`))
                dec.DisallowUnknownFields()
                dec.UseNumber()
                var it Item
                fmt.Println(dec.Decode(&it), it)
                fmt.Println(dec.Decode(&it), it)
                var n any
                fmt.Println(dec.Decode(&n), n)
                fmt.Printf("%T\n", n)
                rest, _ := io.ReadAll(dec.Buffered())
                fmt.Printf("%q\n", rest)
                """#,
                imports: ["encoding/json", "fmt", "io", "strings"],
                declarations: """
                    type Item struct {
                        ID   int    `json:"id"`
                        Name string `json:"name"`
                    }
                    """)
                == """
                json: unknown field "extra" {1 x}
                <nil> {2 x}
                <nil> 1.50
                json.Number
                " tail"

                """)
    }

    /// `Token` gives delimiters, keys, and values one at a time, and `Decode`
    /// reads a whole element in the middle of an array.
    @Test func tokens() throws {
        #expect(
            try runGoMain(
                #"""
                dec := json.NewDecoder(strings.NewReader(`[{"id":1},{"id":2}] {"a": [1, "two", {"three": null}], "b": true} ]`))
                tok, err := dec.Token()
                fmt.Printf("%T %v %v\n", tok, tok, err)
                for dec.More() {
                    var x struct{ ID int }
                    fmt.Println(dec.Decode(&x), x, dec.InputOffset())
                }
                for {
                    tok, err := dec.Token()
                    if err != nil {
                        fmt.Println("end:", err)
                        break
                    }
                    fmt.Printf("%T:%v ", tok, tok)
                }
                """#,
                imports: ["encoding/json", "fmt", "strings"])
                == """
                json.Delim [ <nil>
                <nil> {1} 9
                <nil> {2} 18
                json.Delim:] json.Delim:{ string:a json.Delim:[ float64:1 string:two json.Delim:{ string:three <nil>:<nil> json.Delim:} json.Delim:] string:b bool:true json.Delim:} end: invalid character ']' looking for beginning of value

                """)
    }

    /// The functions on JSON text alone.
    @Test func validCompactIndentAndHTMLEscape() throws {
        #expect(
            try runGoMain(
                #"""
                var out bytes.Buffer
                fmt.Println(json.Indent(&out, []byte(` {"a":[1,2,{}],"b":{}, "c":[ ]}`), "", ". "), out.String())
                out.Reset()
                fmt.Println(json.Compact(&out, []byte(" { \"a\" : [ 1 , \"<\" ] } ")), out.String())
                out.Reset()
                fmt.Println(json.Compact(&out, []byte(`{"a":}`)), out.Len())
                out.Reset()
                json.HTMLEscape(&out, []byte(`{"x":"<a href=\"y\">&amp;</a>`+" "+`"}`))
                fmt.Println(out.String())
                fmt.Println(json.Valid([]byte(`{"a":[true,false,null,-1.5e-3]}`)), json.Valid([]byte(`{"a"}`)), json.Valid(nil))
                """#,
                imports: ["bytes", "encoding/json", "fmt"])
                == #"""
                <nil> {
                . "a": [
                . . 1,
                . . 2,
                . . {}
                . ],
                . "b": {},
                . "c": []
                }
                <nil> {"a":[1,"<"]}
                invalid character '}' looking for beginning of value 0
                {"x":"\u003ca href=\"y\"\u003e\u0026amp;\u003c/a\u003e\u2028"}
                true false false

                """#)
    }
}
