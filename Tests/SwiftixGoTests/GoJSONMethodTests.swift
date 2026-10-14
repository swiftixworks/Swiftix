/// `json.Marshaler`, `json.Unmarshaler`, `encoding.TextMarshaler`, and
/// `encoding.TextUnmarshaler` of the program, which the walks stop for and
/// the library's text calls: in Go's order, on Go's receivers (a value that
/// can be addressed by its pointer), on map keys too, with Go's errors.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go encoding/json: methods")
struct GoJSONMethodTests: GoTestHarness {

    /// A pointer method only where the value can be addressed: through a
    /// pointer, in a slice; a map key by its `MarshalText`, sorted by its text.
    @Test func marshalMethodsAreCalledInOrder() throws {
        #expect(
            try runGoMain(
                """
                c := Celsius(3.5)
                d := Doc{Temp: 21.5, PTemp: &c, Lvl: 3, Lvls: map[Level]string{2: "b", 1: "a", 10: "j"}, PPtr: &PtrOnly{1}, Arr: []Level{1, 2}}
                b, err := json.Marshal(d)
                fmt.Println(string(b), err)
                b, err = json.Marshal(&d)
                fmt.Println(string(b), err)
                b, err = json.Marshal([]PtrOnly{{1}})
                fmt.Println(string(b), err)
                var tm encoding.TextMarshaler = Level(4)
                b, err = json.Marshal(tm)
                fmt.Println(string(b), err)
                """,
                imports: ["encoding/json", "errors", "fmt", "strconv", "strings", "encoding"],
                declarations: """
                    type Celsius float64

                    func (c Celsius) MarshalJSON() ([]byte, error) {
                        fmt.Println("  MarshalJSON", float64(c))
                        return []byte(fmt.Sprintf(`{"c": %g}`, float64(c))), nil
                    }

                    func (c *Celsius) UnmarshalJSON(b []byte) error {
                        fmt.Println("  UnmarshalJSON", string(b))
                        var m map[string]float64
                        if err := json.Unmarshal(b, &m); err != nil {
                            return err
                        }
                        *c = Celsius(m["c"])
                        return nil
                    }

                    type Level int

                    func (l Level) MarshalText() ([]byte, error) {
                        if l < 0 {
                            return nil, errors.New("negative level")
                        }
                        return []byte("L" + strconv.Itoa(int(l))), nil
                    }

                    func (l *Level) UnmarshalText(b []byte) error {
                        s := string(b)
                        if !strings.HasPrefix(s, "L") {
                            return fmt.Errorf("bad level %q", s)
                        }
                        n, err := strconv.Atoi(s[1:])
                        *l = Level(n)
                        return err
                    }

                    type PtrOnly struct{ V int }

                    func (p *PtrOnly) MarshalJSON() ([]byte, error) { return []byte(`"ptr"`), nil }

                    type Bad struct{}

                    func (Bad) MarshalJSON() ([]byte, error) { return []byte(`{bad`), nil }

                    type Fails struct{}

                    func (Fails) MarshalJSON() ([]byte, error) { return nil, errors.New("boom") }

                    type Doc struct {
                        Temp  Celsius          `json:"temp"`
                        PTemp *Celsius         `json:"ptemp"`
                        Lvl   Level            `json:"lvl"`
                        Lvls  map[Level]string `json:"lvls"`
                        Ptr   PtrOnly          `json:"ptr"`
                        PPtr  *PtrOnly         `json:"pptr"`
                        Arr   []Level          `json:"arr"`
                    }
                    """)
                == """
                  MarshalJSON 21.5
                  MarshalJSON 3.5
                {"temp":{"c":21.5},"ptemp":{"c":3.5},"lvl":"L3","lvls":{"L1":"a","L10":"j","L2":"b"},"ptr":{"V":0},"pptr":"ptr","arr":["L1","L2"]} <nil>
                  MarshalJSON 21.5
                  MarshalJSON 3.5
                {"temp":{"c":21.5},"ptemp":{"c":3.5},"lvl":"L3","lvls":{"L1":"a","L10":"j","L2":"b"},"ptr":"ptr","pptr":"ptr","arr":["L1","L2"]} <nil>
                ["ptr"] <nil>
                "L4" <nil>

                """)
    }

    /// A method's error, or text that is no JSON, is a `*MarshalerError`; a map
    /// key's is Go's plain error.
    @Test func marshalErrors() throws {
        #expect(
            try runGoMain(
                #"""
                _, err := json.Marshal(Bad{})
                var me *json.MarshalerError
                fmt.Printf("%T %v %v\n", err, err, errors.As(err, &me))
                _, err = json.Marshal(map[string]any{"f": Fails{}})
                fmt.Println(err, errors.Unwrap(err))
                _, err = json.Marshal(Level(-1))
                fmt.Println(err)
                _, err = json.Marshal(map[Level]int{-1: 1})
                fmt.Printf("%T %v\n", err, err)
                """#,
                imports: ["encoding/json", "errors", "fmt", "strconv", "strings"],
                declarations: """
                    type Celsius float64

                    func (c Celsius) MarshalJSON() ([]byte, error) {
                        fmt.Println("  MarshalJSON", float64(c))
                        return []byte(fmt.Sprintf(`{"c": %g}`, float64(c))), nil
                    }

                    func (c *Celsius) UnmarshalJSON(b []byte) error {
                        fmt.Println("  UnmarshalJSON", string(b))
                        var m map[string]float64
                        if err := json.Unmarshal(b, &m); err != nil {
                            return err
                        }
                        *c = Celsius(m["c"])
                        return nil
                    }

                    type Level int

                    func (l Level) MarshalText() ([]byte, error) {
                        if l < 0 {
                            return nil, errors.New("negative level")
                        }
                        return []byte("L" + strconv.Itoa(int(l))), nil
                    }

                    func (l *Level) UnmarshalText(b []byte) error {
                        s := string(b)
                        if !strings.HasPrefix(s, "L") {
                            return fmt.Errorf("bad level %q", s)
                        }
                        n, err := strconv.Atoi(s[1:])
                        *l = Level(n)
                        return err
                    }

                    type PtrOnly struct{ V int }

                    func (p *PtrOnly) MarshalJSON() ([]byte, error) { return []byte(`"ptr"`), nil }

                    type Bad struct{}

                    func (Bad) MarshalJSON() ([]byte, error) { return []byte(`{bad`), nil }

                    type Fails struct{}

                    func (Fails) MarshalJSON() ([]byte, error) { return nil, errors.New("boom") }

                    type Doc struct {
                        Temp  Celsius          `json:"temp"`
                        PTemp *Celsius         `json:"ptemp"`
                        Lvl   Level            `json:"lvl"`
                        Lvls  map[Level]string `json:"lvls"`
                        Ptr   PtrOnly          `json:"ptr"`
                        PPtr  *PtrOnly         `json:"pptr"`
                        Arr   []Level          `json:"arr"`
                    }
                    """)
                == """
                *json.MarshalerError json: error calling MarshalJSON for type main.Bad: invalid character 'b' looking for beginning of object key string true
                json: error calling MarshalJSON for type main.Fails: boom boom
                json: error calling MarshalText for type main.Level: negative level
                *errors.errorString json: encoding error for type "map[main.Level]int": "negative level"

                """)
    }

    /// `UnmarshalJSON` gets the value's text, `UnmarshalText` a string's
    /// contents, a key's too; their errors stop the decoding, and a type error
    /// inside one gets the field it was in.
    @Test func unmarshalMethods() throws {
        #expect(
            try runGoMain(
                """
                var d Doc
                err := json.Unmarshal([]byte(`{"temp":{"c":21.5},"ptemp":{"c":3},"lvl":"L3","lvls":{"L1":"a","L2":"b"},"arr":["L1","L2"],"ptr":{"V":1}}`), &d)
                fmt.Println(err, d.Temp, *d.PTemp, d.Lvl, d.Lvls, d.Arr)
                fmt.Println(json.Unmarshal([]byte(`{"lvl":"X3"}`), &d))
                fmt.Println(json.Unmarshal([]byte(`{"lvl":3}`), &d))
                fmt.Println(json.Unmarshal([]byte(`{"temp":{"c":"x"}}`), &d))
                fmt.Println(json.Unmarshal([]byte(`{"lvls":{"Lx":"q"}}`), &d))
                var cp *Celsius
                fmt.Println(json.Unmarshal([]byte(`{"c":9}`), &cp), *cp)
                var raws []json.RawMessage
                fmt.Println(json.Unmarshal([]byte(`[ {"a" : 1}, [ 2 ], "x" ]`), &raws), len(raws), string(raws[0]), string(raws[1]))
                """,
                imports: ["encoding/json", "errors", "fmt", "strconv", "strings"],
                declarations: """
                    type Celsius float64

                    func (c Celsius) MarshalJSON() ([]byte, error) {
                        fmt.Println("  MarshalJSON", float64(c))
                        return []byte(fmt.Sprintf(`{"c": %g}`, float64(c))), nil
                    }

                    func (c *Celsius) UnmarshalJSON(b []byte) error {
                        fmt.Println("  UnmarshalJSON", string(b))
                        var m map[string]float64
                        if err := json.Unmarshal(b, &m); err != nil {
                            return err
                        }
                        *c = Celsius(m["c"])
                        return nil
                    }

                    type Level int

                    func (l Level) MarshalText() ([]byte, error) {
                        if l < 0 {
                            return nil, errors.New("negative level")
                        }
                        return []byte("L" + strconv.Itoa(int(l))), nil
                    }

                    func (l *Level) UnmarshalText(b []byte) error {
                        s := string(b)
                        if !strings.HasPrefix(s, "L") {
                            return fmt.Errorf("bad level %q", s)
                        }
                        n, err := strconv.Atoi(s[1:])
                        *l = Level(n)
                        return err
                    }

                    type PtrOnly struct{ V int }

                    func (p *PtrOnly) MarshalJSON() ([]byte, error) { return []byte(`"ptr"`), nil }

                    type Bad struct{}

                    func (Bad) MarshalJSON() ([]byte, error) { return []byte(`{bad`), nil }

                    type Fails struct{}

                    func (Fails) MarshalJSON() ([]byte, error) { return nil, errors.New("boom") }

                    type Doc struct {
                        Temp  Celsius          `json:"temp"`
                        PTemp *Celsius         `json:"ptemp"`
                        Lvl   Level            `json:"lvl"`
                        Lvls  map[Level]string `json:"lvls"`
                        Ptr   PtrOnly          `json:"ptr"`
                        PPtr  *PtrOnly         `json:"pptr"`
                        Arr   []Level          `json:"arr"`
                    }
                    """)
                == """
                  UnmarshalJSON {"c":21.5}
                  UnmarshalJSON {"c":3}
                <nil> 21.5 3 3 map[1:a 2:b] [1 2]
                bad level "X3"
                json: cannot unmarshal number into Go struct field Doc.lvl of type main.Level
                  UnmarshalJSON {"c":"x"}
                json: cannot unmarshal string into Go struct field Doc.temp of type float64
                strconv.Atoi: parsing "x": invalid syntax
                  UnmarshalJSON {"c":9}
                <nil> 9
                <nil> 3 {"a" : 1} [ 2 ]

                """)
    }

    /// `time.Time` is written and read as RFC 3339, as a value, a pointer, and
    /// a map key.
    @Test func timesByTheirMethods() throws {
        #expect(
            try runGoMain(
                """
                type E struct {
                    When time.Time            `json:"when"`
                    P    *time.Time           `json:"p"`
                    ByT  map[time.Time]string `json:"byt"`
                }
                t := time.Date(2024, 5, 6, 7, 8, 9, 10, time.UTC)
                b, err := json.Marshal(E{When: t, P: &t, ByT: map[time.Time]string{t: "x"}})
                fmt.Println(string(b), err)
                var e E
                fmt.Println(json.Unmarshal(b, &e), e.When, *e.P, e.ByT)
                fmt.Println(json.Unmarshal([]byte(`{"when":"yesterday"}`), &e))
                fmt.Println(json.Unmarshal([]byte(`{"when":5}`), &e))
                _, err = json.Marshal(time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC))
                fmt.Println(err)
                """,
                imports: ["encoding/json", "fmt", "time"])
                == """
                {"when":"2024-05-06T07:08:09.00000001Z","p":"2024-05-06T07:08:09.00000001Z","byt":{"2024-05-06T07:08:09.00000001Z":"x"}} <nil>
                <nil> 2024-05-06 07:08:09.00000001 +0000 UTC 2024-05-06 07:08:09.00000001 +0000 UTC map[2024-05-06 07:08:09.00000001 +0000 UTC:x]
                parsing time "yesterday" as "2006-01-02T15:04:05Z07:00": cannot parse "yesterday" as "2006"
                Time.UnmarshalJSON: input is not a JSON string
                json: error calling MarshalJSON for type time.Time: Time.MarshalJSON: year outside of range [0,9999]

                """)
    }
}
