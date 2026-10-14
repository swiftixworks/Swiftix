/// `json.Unmarshal` and `json.Valid`: JSON read into a value through the
/// pointer given, with Go's merge into what is there and every error Go
/// reports, at Go's offset.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go encoding/json: decoding")
struct GoJSONDecodeTests: GoTestHarness {

    /// Into an `any`: objects as `map[string]any`, arrays as `[]any`, numbers as
    /// `float64`, and strings, booleans, and null as themselves.
    @Test func intoAnInterface() throws {
        #expect(
            try runGoMain(
                #"""
                var v any
                err := json.Unmarshal([]byte(` {"a": [1, -2.5e3, "xé😀", true, null, {}], "b": {"c": []}, "": 0} `), &v)
                fmt.Printf("%v %v\n", v, err)
                m := v.(map[string]any)
                fmt.Printf("%T %T %T\n", m["a"], m["a"].([]any)[0], m["b"])
                for _, in := range []string{`"s"`, `12`, `true`, `null`, `[]`, `{}`} {
                    var x any = 99
                    err := json.Unmarshal([]byte(in), &x)
                    fmt.Printf("%T %v %v\n", x, x, err)
                }
                """#,
                imports: ["encoding/json", "errors", "fmt"])
                == """
                map[:0 a:[1 -2500 xé😀 true <nil> map[]] b:map[c:[]]] <nil>
                []interface {} float64 map[string]interface {}
                string s <nil>
                float64 12 <nil>
                bool true <nil>
                <nil> <nil> <nil>
                []interface {} [] <nil>
                map[string]interface {} map[] <nil>

                """)
    }

    /// Keys match field names exactly or else without regard to case; a map
    /// keeps its entries; a slice is cut to the elements read and an array
    /// zeroed after them; pointers are allocated where nil and decoded through
    /// where not.
    @Test func intoStructsMapsSlicesAndArrays() throws {
        #expect(
            try runGoMain(
                """
                x := 1
                t := T{Name: "keep", Count: 7, M: map[string]int{"old": 1}, P: &x, Arr: [3]int{9, 9, 9}, List: []int{5, 6, 7}}
                err := json.Unmarshal([]byte(`{"NAME":"n","m":{"new":2},"p":3,"arr":[1],"list":[8],"Ignored":1,"inner":{"z":true},"pp":{"z":false}}`), &t)
                fmt.Println(t.Name, t.Count, t.M, *t.P, x, t.Arr, t.List, t.Inner, t.PP.Z, err)
                var mi map[int]string
                fmt.Println(json.Unmarshal([]byte(`{"1":"a","-2":"b"}`), &mi), mi)
                var arr [2]string
                fmt.Println(json.Unmarshal([]byte(`["a","b","c"]`), &arr), arr)
                var pp **int
                fmt.Println(json.Unmarshal([]byte(`4`), &pp), **pp)
                fmt.Println(json.Unmarshal([]byte(`null`), &pp), pp == nil)
                var bs []byte
                fmt.Println(json.Unmarshal([]byte(`"aGVsbG8="`), &bs), string(bs))
                """,
                imports: ["encoding/json", "errors", "fmt"],
                declarations: """
                    type Inner struct{ Z bool `json:"z"` }

                    type T struct {
                        Name  string
                        Count int
                        M     map[string]int `json:"m"`
                        P     *int           `json:"p"`
                        Arr   [3]int         `json:"arr"`
                        List  []int          `json:"list"`
                        Inner Inner          `json:"inner"`
                        PP    *Inner         `json:"pp"`
                    }
                    """)
                == """
                n 7 map[new:2 old:1] 3 3 [1 0 0] [8] {true} false <nil>
                <nil> map[-2:b 1:a]
                <nil> [a b]
                <nil> 4
                <nil> true
                <nil> hello

                """)
    }

    /// A value of the wrong type is an `*UnmarshalTypeError` with the struct
    /// and the path of fields to it; the first is returned after the rest of the
    /// input is read.
    @Test func typeErrorsAreSavedAndDecodingGoesOn() throws {
        #expect(
            try runGoMain(
                """
                var t T
                for _, in := range []string{
                    `{"a":"x","b":{"c":[{"d":1},{"d":"y"}]},"e":5}`,
                    `{"b":{"c":[{"d":true}]}}`,
                    `{"a":1.5}`, `{"a":1e3}`, `{"a":99999999999999999999}`, `{"small":300}`, `{"u":-1}`,
                    `{"a":[1]}`, `{"a":{}}`, `{"m":{"x":1}}`, `{"f":1e400}`, `{"e":"s"}`,
                } {
                    err := json.Unmarshal([]byte(in), &t)
                    fmt.Println(describe(err), t.E)
                }
                var f float64
                var s string
                fmt.Println(describe(json.Unmarshal([]byte(`"x"`), &f)), describe(json.Unmarshal([]byte(`[1]`), &s)))
                var v any
                fmt.Println(describe(json.Unmarshal([]byte(`[1e400]`), &v)))
                """,
                imports: ["encoding/json", "errors", "fmt"],
                declarations: """
                    type T struct {
                        A     int `json:"a"`
                        B     struct {
                            C []struct {
                                D int `json:"d"`
                            } `json:"c"`
                        } `json:"b"`
                        E     int            `json:"e"`
                        Small int8           `json:"small"`
                        U     uint           `json:"u"`
                        M     map[int]int    `json:"m"`
                        F     float32        `json:"f"`
                    }
                    func describe(err error) string {
                        var se *json.SyntaxError
                        var te *json.UnmarshalTypeError
                        switch {
                        case err == nil:
                            return "ok"
                        case errors.As(err, &se):
                            return fmt.Sprintf("%T %v @%d", err, err, se.Offset)
                        case errors.As(err, &te):
                            return fmt.Sprintf("%T %v [%s @%d %q %q]", err, err, te.Value, te.Offset, te.Struct, te.Field)
                        }
                        return fmt.Sprintf("%T %v", err, err)
                    }
                    """)
                == """
                *json.UnmarshalTypeError json: cannot unmarshal string into Go struct field T.a of type int [string @8 "T" "a"] 5
                *json.UnmarshalTypeError json: cannot unmarshal bool into Go struct field .b.c.d of type int [bool @20 "" "b.c.d"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number 1.5 into Go struct field T.a of type int [number 1.5 @8 "T" "a"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number 1e3 into Go struct field T.a of type int [number 1e3 @8 "T" "a"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number 99999999999999999999 into Go struct field T.a of type int [number 99999999999999999999 @25 "T" "a"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number 300 into Go struct field T.small of type int8 [number 300 @12 "T" "small"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number -1 into Go struct field T.u of type uint [number -1 @7 "T" "u"] 5
                *json.UnmarshalTypeError json: cannot unmarshal array into Go struct field T.a of type int [array @6 "T" "a"] 5
                *json.UnmarshalTypeError json: cannot unmarshal object into Go struct field T.a of type int [object @6 "T" "a"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number x into Go struct field T.m of type int [number x @7 "T" "m"] 5
                *json.UnmarshalTypeError json: cannot unmarshal number 1e400 into Go struct field T.f of type float32 [number 1e400 @10 "T" "f"] 5
                *json.UnmarshalTypeError json: cannot unmarshal string into Go struct field T.e of type int [string @8 "T" "e"] 5
                *json.UnmarshalTypeError json: cannot unmarshal string into Go value of type float64 [string @3 "" ""] *json.UnmarshalTypeError json: cannot unmarshal array into Go value of type string [array @1 "" ""]
                *json.UnmarshalTypeError json: cannot unmarshal number 1e400 into Go value of type float64 [number 1e400 @7 "" ""]

                """)
    }

    /// The text is checked before anything is decoded: a `*SyntaxError` with
    /// Go's message and offset, and nothing changed.
    @Test func syntaxErrorsAreGosWithTheirOffsets() throws {
        #expect(
            try runGoMain(
                #"""
                for _, in := range []string{``, ` `, `{`, `[1,]`, `{"a" 1}`, `{"a":1,}`, `nul`, `tru`, `"\x"`, `"\u12G4"`, `01`, `-`, `1.`, `1e+`,
                    `[1 2]`, `{} x`, `{"a":1}}`, "\"a\tb\"", `{1:2}`, `{"a":}`, `[}`} {
                    v := 7
                    err := json.Unmarshal([]byte(in), &v)
                    fmt.Printf("%q %v %s\n", in, json.Valid([]byte(in)), describe(err))
                }
                fmt.Println(describe(json.Unmarshal([]byte{'"', 0xff, '"', 0xff}, new(any))))
                fmt.Println(describe(json.Unmarshal([]byte(strings.Repeat("[", 10001)), new(any))))
                var deep any
                in := strings.Repeat("[", 10000) + strings.Repeat("]", 10000)
                fmt.Println(describe(json.Unmarshal([]byte(in), &deep)))
                """#,
                imports: ["encoding/json", "errors", "fmt", "strings"],
                declarations: """
                    func describe(err error) string {
                        var se *json.SyntaxError
                        var te *json.UnmarshalTypeError
                        switch {
                        case err == nil:
                            return "ok"
                        case errors.As(err, &se):
                            return fmt.Sprintf("%T %v @%d", err, err, se.Offset)
                        case errors.As(err, &te):
                            return fmt.Sprintf("%T %v [%s @%d %q %q]", err, err, te.Value, te.Offset, te.Struct, te.Field)
                        }
                        return fmt.Sprintf("%T %v", err, err)
                    }
                    """)
                == #"""
                "" false *json.SyntaxError unexpected end of JSON input @0
                " " false *json.SyntaxError unexpected end of JSON input @1
                "{" false *json.SyntaxError unexpected end of JSON input @1
                "[1,]" false *json.SyntaxError invalid character ']' looking for beginning of value @4
                "{\"a\" 1}" false *json.SyntaxError invalid character '1' after object key @6
                "{\"a\":1,}" false *json.SyntaxError invalid character '}' looking for beginning of object key string @8
                "nul" false *json.SyntaxError invalid character ' ' in literal null (expecting 'l') @3
                "tru" false *json.SyntaxError invalid character ' ' in literal true (expecting 'e') @3
                "\"\\x\"" false *json.SyntaxError invalid character 'x' in string escape code @3
                "\"\\u12G4\"" false *json.SyntaxError invalid character 'G' in \u hexadecimal character escape @6
                "01" false *json.SyntaxError invalid character '1' after top-level value @2
                "-" false *json.SyntaxError invalid character ' ' in numeric literal @1
                "1." false *json.SyntaxError invalid character ' ' after decimal point in numeric literal @2
                "1e+" false *json.SyntaxError invalid character ' ' in exponent of numeric literal @3
                "[1 2]" false *json.SyntaxError invalid character '2' after array element @4
                "{} x" false *json.SyntaxError invalid character 'x' after top-level value @4
                "{\"a\":1}}" false *json.SyntaxError invalid character '}' after top-level value @8
                "\"a\tb\"" false *json.SyntaxError invalid character '\t' in string literal @3
                "{1:2}" false *json.SyntaxError invalid character '1' looking for beginning of object key string @2
                "{\"a\":}" false *json.SyntaxError invalid character '}' looking for beginning of value @6
                "[}" false *json.SyntaxError invalid character '}' looking for beginning of value @2
                *json.SyntaxError invalid character 'ÿ' after top-level value @4
                *json.SyntaxError invalid character '[' exceeded max depth @10001
                ok

                """#)
    }

    /// `Unmarshal` wants a non-nil pointer; a field with `,string` reads its value
    /// from inside a string, as Go does and with Go's errors.
    @Test func invalidTargetsAndStringOption() throws {
        #expect(
            try runGoMain(
                #"""
                var np *T
                fmt.Println(json.Unmarshal([]byte(`1`), nil), json.Unmarshal([]byte(`1`), np), json.Unmarshal([]byte(`1`), T{}))
                fmt.Println(describe(json.Unmarshal([]byte(`{`), nil)))
                var t T
                for _, in := range []string{`{"i":"12"}`, `{"i":12}`, `{"i":"x"}`, `{"i":""}`, `{"s":"\"q\""}`, `{"s":"q"}`,
                    `{"b":"true"}`, `{"b":"1"}`, `{"i":null}`, `{"i":"null"}`, `{"i":[1]}`, `{"f":"2.5"}`} {
                    err := json.Unmarshal([]byte(in), &t)
                    fmt.Printf("%s -> %+v %s\n", in, t, describe(err))
                }
                """#,
                imports: ["encoding/json", "errors", "fmt"],
                declarations: """
                    type T struct {
                        I int     `json:"i,string"`
                        S string  `json:"s,string"`
                        B bool    `json:"b,string"`
                        F float64 `json:"f,string"`
                    }
                    func describe(err error) string {
                        var se *json.SyntaxError
                        var te *json.UnmarshalTypeError
                        switch {
                        case err == nil:
                            return "ok"
                        case errors.As(err, &se):
                            return fmt.Sprintf("%T %v @%d", err, err, se.Offset)
                        case errors.As(err, &te):
                            return fmt.Sprintf("%T %v [%s @%d %q %q]", err, err, te.Value, te.Offset, te.Struct, te.Field)
                        }
                        return fmt.Sprintf("%T %v", err, err)
                    }
                    """)
                == #"""
                json: Unmarshal(nil) json: Unmarshal(nil *main.T) json: Unmarshal(non-pointer main.T)
                *json.SyntaxError unexpected end of JSON input @1
                {"i":"12"} -> {I:12 S: B:false F:0} ok
                {"i":12} -> {I:12 S: B:false F:0} *errors.errorString json: invalid use of ,string struct tag, trying to unmarshal unquoted value into int
                {"i":"x"} -> {I:12 S: B:false F:0} *errors.errorString json: invalid use of ,string struct tag, trying to unmarshal "x" into int
                {"i":""} -> {I:12 S: B:false F:0} *errors.errorString json: invalid use of ,string struct tag, trying to unmarshal "" into int
                {"s":"\"q\""} -> {I:12 S:q B:false F:0} ok
                {"s":"q"} -> {I:12 S:q B:false F:0} *errors.errorString json: invalid use of ,string struct tag, trying to unmarshal "q" into string
                {"b":"true"} -> {I:12 S:q B:true F:0} ok
                {"b":"1"} -> {I:12 S:q B:true F:0} *errors.errorString json: invalid use of ,string struct tag, trying to unmarshal "1" into bool
                {"i":null} -> {I:12 S:q B:true F:0} ok
                {"i":"null"} -> {I:12 S:q B:true F:0} ok
                {"i":[1]} -> {I:12 S:q B:true F:0} *errors.errorString json: invalid use of ,string struct tag, trying to unmarshal unquoted value into int
                {"f":"2.5"} -> {I:12 S:q B:true F:2.5} ok

                """#)
    }

    /// Fields of embedded structs are set through embedded pointers, which are
    /// allocated, except where their type is unexported.
    @Test func embeddedFieldsAndUnknownKeys() throws {
        #expect(
            try runGoMain(
                """
                var o Outer
                fmt.Println(json.Unmarshal([]byte(`{"X":1,"Y":2,"Z":3,"P":4,"Q":5}`), &o), o.X, o.Y, o.B.Z, o.Q)
                var h Hidden
                fmt.Println(describe(json.Unmarshal([]byte(`{"P":1,"S":2}`), &h)), h.S)
                """,
                imports: ["encoding/json", "errors", "fmt"],
                declarations: """
                    type A struct{ X, Y int }

                    type B struct{ Z int }

                    type inner struct{ P int }

                    type Outer struct {
                        A
                        *B
                        Q int
                    }

                    type Hidden struct {
                        *inner
                        S int
                    }
                    func describe(err error) string {
                        var se *json.SyntaxError
                        var te *json.UnmarshalTypeError
                        switch {
                        case err == nil:
                            return "ok"
                        case errors.As(err, &se):
                            return fmt.Sprintf("%T %v @%d", err, err, se.Offset)
                        case errors.As(err, &te):
                            return fmt.Sprintf("%T %v [%s @%d %q %q]", err, err, te.Value, te.Offset, te.Struct, te.Field)
                        }
                        return fmt.Sprintf("%T %v", err, err)
                    }
                    """)
                == """
                <nil> 1 2 3 5
                *errors.errorString json: cannot set embedded pointer to unexported struct: main.inner 2

                """)
    }

    /// `json.Number` keeps a number's text, and is a valid number or an error.
    @Test func numbersCanStayText() throws {
        #expect(
            try runGoMain(
                """
                var v struct {
                    N json.Number
                    M json.Number
                    A any
                }
                fmt.Println(json.Unmarshal([]byte(`{"N":12.50,"M":"7","A":1}`), &v), v.N, v.M, v.A)
                f, err := v.N.Float64()
                i, err2 := v.N.Int64()
                fmt.Println(f, err, i, err2, v.N.String())
                fmt.Println(json.Unmarshal([]byte(`{"M":"x"}`), &v))
                """,
                imports: ["encoding/json", "fmt"])
                == #"""
                <nil> 12.50 7 1
                12.5 <nil> 0 strconv.ParseInt: parsing "12.50": invalid syntax 12.50
                json: invalid number literal, trying to unmarshal "\"x\"" into Number

                """#)
    }
}
