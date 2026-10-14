/// `json.Marshal` and `json.MarshalIndent`: a value written as JSON by the
/// type it travels with in an interface, as Go's encoder writes it.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go encoding/json: encoding")
struct GoJSONEncodeTests: GoTestHarness {

    /// Every kind: numbers of each size, strings with Go's escapes, nil
    /// pointers, slices, and maps, maps sorted by key, a `[]byte` in base64.
    @Test func scalarsAndCollections() throws {
        #expect(
            try runGoMain(
                #"""
                for _, v := range []any{nil, true, 0, -12, int8(-128), uint8(255), uint64(18446744073709551615), int64(-9223372036854775808),
                    "a\"b\\c\n\t\x01<>&  é", []int(nil), []int{}, [2]bool{true}, map[string]int(nil), map[string]int{"b": 2, "a": 1, "": 0},
                    map[int]string{10: "x", -1: "y", 2: "z"}, map[uint16]bool{65535: true}, []byte("hi"), []byte(nil), [3]byte{1, 2, 3}, (*int)(nil), new(int)} {
                    b, err := json.Marshal(v)
                    fmt.Println(string(b), err)
                }
                """#,
                imports: ["encoding/json", "fmt"])
                == #"""
                null <nil>
                true <nil>
                0 <nil>
                -12 <nil>
                -128 <nil>
                255 <nil>
                18446744073709551615 <nil>
                -9223372036854775808 <nil>
                "a\"b\\c\n\t\u0001\u003c\u003e\u0026\u2028\u2029é" <nil>
                null <nil>
                [] <nil>
                [true,false] <nil>
                null <nil>
                {"":0,"a":1,"b":2} <nil>
                {"-1":"y","10":"x","2":"z"} <nil>
                {"65535":true} <nil>
                "aGk=" <nil>
                null <nil>
                [1,2,3] <nil>
                null <nil>
                0 <nil>

                """#)
    }

    /// ES6 number text: no exponent between 1e-6 and 1e21, the shortest digits
    /// that read back, `float32` by its own digits; NaN and infinities refused.
    @Test func floatsAreWrittenAsGoWritesThem() throws {
        #expect(
            try runGoMain(
                #"""
                for _, f := range []float64{0, math.Copysign(0, -1), 1, 0.1, 1e20, 1e21, 1e-6, 1e-7, 123456789.125, 5e-324, 1.7976931348623157e308, 1.0 / 3} {
                    b, _ := json.Marshal(f)
                    c, _ := json.Marshal(float32(f))
                    fmt.Println(string(b), string(c))
                }
                for _, f := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
                    _, err := json.Marshal(f)
                    fmt.Printf("%T %v\n", err, err)
                }
                """#,
                imports: ["encoding/json", "fmt", "math"])
                == "0 0\n-0 -0\n1 1\n0.1 0.1\n100000000000000000000 100000000000000000000\n1e+21 1e+21\n0.000001 0.000001\n1e-7 1e-7\n123456789.125 123456790\n5e-324 0\n1.7976931348623157e+308 \n0.3333333333333333 0.33333334\n*json.UnsupportedValueError json: unsupported value: NaN\n*json.UnsupportedValueError json: unsupported value: +Inf\n*json.UnsupportedValueError json: unsupported value: -Inf\n")
    }

    /// Go's `typeFields`: tag names and options, unexported fields left out,
    /// embedded structs promoted with the shallower or tagged field winning and
    /// equal ones cancelling, nil embedded pointers skipped.
    @Test func structFieldsFollowTagsAndEmbedding() throws {
        #expect(
            try runGoMain(
                """
                b, err := json.Marshal(T{Name: "n", Embedded: Embedded{X: 1, Y: 2}, Other: &Other{X: 3, Z: 4}, Skip: 5, quiet: 6, Opt: 0, Str: 7})
                fmt.Println(string(b), err)
                b, _ = json.Marshal(T{})
                fmt.Println(string(b))
                b, _ = json.Marshal(Conflict{A{1, 2}, B{3, 4}})
                fmt.Println(string(b))
                b, _ = json.Marshal(struct {
                    inner
                    R int
                }{inner{1, 2}, 3})
                fmt.Println(string(b))
                b, _ = json.Marshal(struct {
                    *inner
                    S int
                }{nil, 3})
                fmt.Println(string(b))
                """,
                imports: ["encoding/json", "fmt"],
                declarations: """
                    type Embedded struct {
                        X int
                        Y int `json:"y"`
                    }

                    type Other struct {
                        X int
                        Z int
                    }

                    type T struct {
                        Name string `json:"name"`
                        Embedded
                        *Other
                        Skip  int `json:"-"`
                        quiet int
                        Opt   int     `json:"opt,omitempty"`
                        Str   int     `json:",string"`
                        Ptr   *int    `json:"ptr"`
                        Tags  []string `json:"tags,omitempty"`
                        Dash  int     `json:"-,"`
                    }

                    type A struct {
                        X int
                        Y int `json:"y"`
                    }

                    type B struct {
                        X int
                        Z int
                    }

                    type Conflict struct {
                        A
                        B
                    }

                    type inner struct {
                        P int
                        q int
                    }
                    """)
                == """
                {"name":"n","y":2,"Z":4,"Str":"7","ptr":null,"-":0} <nil>
                {"name":"","y":0,"Str":"0","ptr":null,"-":0}
                {"y":2,"Z":4}
                {"P":1,"R":3}
                {"S":3}

                """)
    }

    /// `omitempty` leaves out false, 0, nil, and empty strings, slices, and
    /// maps; `omitzero` leaves out the zero value, and asks `IsZero` where the
    /// type has it.
    @Test func omitemptyAndOmitzero() throws {
        #expect(
            try runGoMain(
                """
                type O struct {
                    B  bool           `json:"b,omitempty"`
                    F  float64        `json:"f,omitempty"`
                    S  string         `json:"s,omitempty"`
                    L  []int          `json:"l,omitempty"`
                    M  map[string]int `json:"m,omitempty"`
                    P  *int           `json:"p,omitempty"`
                    I  any            `json:"i,omitempty"`
                    St struct{}       `json:"st,omitempty"`
                    Z  [2]int         `json:"z,omitzero"`
                    Zs struct{ A int } `json:"zs,omitzero"`
                    T  time.Time      `json:"t,omitzero"`
                    C  Cap            `json:"c,omitzero"`
                }
                for _, o := range []O{{}, {F: math.Copysign(0, -1), L: []int{}, M: map[string]int{}, Z: [2]int{0, 1}, C: Cap{20}}, {C: Cap{5}, T: time.Unix(0, 0).UTC()}} {
                    b, _ := json.Marshal(o)
                    fmt.Println(string(b))
                }
                """,
                imports: ["encoding/json", "fmt", "math", "time"],
                declarations: """
                    type Cap struct{ N int }

                    func (c Cap) IsZero() bool { return c.N < 10 }
                    """)
                == """
                {"st":{}}
                {"st":{},"z":[0,1],"c":{"N":20}}
                {"st":{},"t":"1970-01-01T00:00:00Z"}

                """)
    }

    /// A value in an interface is written by its dynamic type; `<`, `>`, `&`,
    /// U+2028 and U+2029 are escaped; a pointer writes what it points to.
    @Test func interfacesPointersAndHTML() throws {
        #expect(
            try runGoMain(
                #"""
                x := 5
                v := map[string]any{"html": "<script>&", "ptr": &x, "list": []any{1, "two", 3.5, nil, []string{"a"}, map[string]any{"k": false}},
                    "struct": struct{ A, B any }{A: errors.New("e"), B: &struct{ C int }{7}}}
                b, err := json.Marshal(v)
                fmt.Println(string(b), err)
                b, err = json.MarshalIndent(v, "> ", "\t")
                fmt.Println(string(b), err)
                b, err = json.MarshalIndent([]int{}, "", "  ")
                fmt.Println(string(b), err)
                """#,
                imports: ["encoding/json", "errors", "fmt"])
                == #"""
                {"html":"\u003cscript\u003e\u0026","list":[1,"two",3.5,null,["a"],{"k":false}],"ptr":5,"struct":{"A":{},"B":{"C":7}}} <nil>
                {
                > 	"html": "\u003cscript\u003e\u0026",
                > 	"list": [
                > 		1,
                > 		"two",
                > 		3.5,
                > 		null,
                > 		[
                > 			"a"
                > 		],
                > 		{
                > 			"k": false
                > 		}
                > 	],
                > 	"ptr": 5,
                > 	"struct": {
                > 		"A": {},
                > 		"B": {
                > 			"C": 7
                > 		}
                > 	}
                > } <nil>
                [] <nil>

                """#)
    }

    /// A `time.Time` as RFC 3339 with nanoseconds, a `json.RawMessage` as its
    /// compacted text, a `json.Number` as its digits; each refusing what Go
    /// refuses.
    @Test func timeRawMessageAndNumber() throws {
        #expect(
            try runGoMain(
                #"""
                t := time.Date(2024, 2, 29, 23, 59, 58, 123456000, time.FixedZone("X", -5*3600))
                b, err := json.Marshal(struct {
                    T  time.Time
                    P  *time.Time
                    R  json.RawMessage
                    RN json.RawMessage
                    N  json.Number
                    NE json.Number
                    NS json.Number `json:",string"`
                }{T: t, R: json.RawMessage(" [1, { \"a\" : \"<\" }] "), N: "-1.5e3", NS: "7"})
                fmt.Println(string(b), err)
                _, err = json.Marshal(time.Date(-1, 1, 1, 0, 0, 0, 0, time.UTC))
                fmt.Printf("%T %v\n", err, err)
                _, err = json.Marshal(json.RawMessage("{"))
                fmt.Printf("%T %v\n", err, err)
                _, err = json.Marshal(json.Number("0x1"))
                fmt.Printf("%T %v\n", err, err)
                """#,
                imports: ["encoding/json", "fmt", "time"])
                == #"""
                {"T":"2024-02-29T23:59:58.123456-05:00","P":null,"R":[1,{"a":"\u003c"}],"RN":null,"N":-1.5e3,"NE":0,"NS":"7"} <nil>
                *json.MarshalerError json: error calling MarshalJSON for type time.Time: Time.MarshalJSON: year outside of range [0,9999]
                *json.MarshalerError json: error calling MarshalJSON for type json.RawMessage: unexpected end of JSON input
                *errors.errorString json: invalid number literal "0x1"

                """#)
    }

    /// Channels, functions, and maps whose keys JSON cannot name are refused by
    /// type; a value that points back to itself is found after Go's thousand
    /// levels and refused, while a deep but finite one is written.
    @Test func unsupportedTypesAndCycles() throws {
        #expect(
            try runGoMain(
                #"""
                for _, v := range []any{make(chan int), func() {}, map[bool]int{}, map[[1]int]int(nil), struct{ C chan int }{}} {
                    _, err := json.Marshal(v)
                    fmt.Printf("%T %v\n", err, err)
                }
                n := &Node{V: 1}
                n.Next = n
                _, err := json.Marshal(n)
                fmt.Printf("%T %v\n", err, err)
                m := map[string]any{}
                m["m"] = m
                _, err = json.Marshal(m)
                fmt.Println(err)
                deep := &Node{}
                for i := 0; i < 1500; i++ {
                    deep = &Node{V: i, Next: deep}
                }
                b, err := json.Marshal(deep)
                fmt.Println(len(b), err)
                """#,
                imports: ["encoding/json", "fmt"],
                declarations: """
                    type Node struct {
                        V    int
                        Next *Node
                    }
                    """)
                == """
                *json.UnsupportedTypeError json: unsupported type: chan int
                *json.UnsupportedTypeError json: unsupported type: func()
                *json.UnsupportedTypeError json: unsupported type: map[bool]int
                *json.UnsupportedTypeError json: unsupported type: map[[1]int]int
                *json.UnsupportedTypeError json: unsupported type: chan int
                *json.UnsupportedValueError json: unsupported value: encountered a cycle via *main.Node
                json: unsupported value: encountered a cycle via map[string]interface {}
                25909 <nil>

                """)
    }

    /// The walk keeps its work on a stack of its own, so depth costs no stack of
    /// the VM's thread.
    @Test func aValueNestedTenThousandDeepIsWritten() throws {
        #expect(
            try runGoMain(
                """
                var v any = []any{}
                for i := 0; i < 10000; i++ {
                    v = []any{v}
                }
                b, err := json.Marshal(v)
                fmt.Println(len(b), string(b[:5]), err)
                """,
                imports: ["encoding/json", "fmt"])
                == "20002 [[[[[ <nil>\n")
    }
}
