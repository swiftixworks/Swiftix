/// `encoding/base64` as Go writes it: the four encodings, padding and
/// strictness, and `CorruptInputError` at Go's offset.
///
/// What each program prints is what Go 1.24.5 prints for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go encoding/base64")
struct GoBase64Tests: GoTestHarness {

    /// Each encoding's text and lengths.
    @Test func encodings() throws {
        #expect(
            try runGoMain(
                """
                for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.RawURLEncoding} {
                    fmt.Println(enc.EncodeToString([]byte("hi?")), enc.EncodeToString([]byte{0xfb, 0xff}), enc.EncodeToString(nil), enc.EncodedLen(5), enc.DecodedLen(7))
                }
                buf := make([]byte, base64.StdEncoding.EncodedLen(4))
                base64.StdEncoding.Encode(buf, []byte{1, 2, 3, 4})
                fmt.Println(string(buf), string(base64.StdEncoding.AppendEncode([]byte("x:"), []byte("y"))))
                fmt.Println(base64.StdEncoding.WithPadding('*').EncodeToString([]byte("a")))
                """,
                imports: ["encoding/base64", "fmt"])
                == """
                aGk/ +/8=  8 3
                aGk_ -_8=  8 3
                aGk/ +/8  7 5
                aGk_ -_8  7 5
                AQIDBA== x:eQ==
                YQ**

                """)
    }

    /// Line breaks are skipped; anything else out of place is a
    /// `CorruptInputError`.
    @Test func decodingAndItsErrors() throws {
        #expect(
            try runGoMain(
                #"""
                for _, in := range []string{"aGk/", "aGk", "aGk=", "a===", "aG\nk/", "aGk/x", "@@@@", "", "aGk=\n", "aGl="} {
                    out, err := base64.StdEncoding.DecodeString(in)
                    out2, err2 := base64.RawStdEncoding.DecodeString(in)
                    _, err3 := base64.StdEncoding.Strict().DecodeString(in)
                    fmt.Printf("%q %q %v %q %v %v\n", in, out, err, out2, err2, err3)
                }
                dst := make([]byte, 8)
                n, err := base64.URLEncoding.Decode(dst, []byte("-_-_"))
                fmt.Println(n, err, dst[:n])
                _, err = base64.StdEncoding.DecodeString("ab!d")
                var corrupt base64.CorruptInputError
                fmt.Printf("%T %v %v %d\n", err, err, errors.As(err, &corrupt), corrupt)
                b, err := base64.StdEncoding.AppendDecode([]byte("x"), []byte("aGk="))
                fmt.Println(string(b), err)
                """#,
                imports: ["encoding/base64", "errors", "fmt"])
                == #"""
                "aGk/" "hi?" <nil> "hi?" <nil> <nil>
                "aGk" "" illegal base64 data at input byte 0 "hi" <nil> illegal base64 data at input byte 0
                "aGk=" "hi" <nil> "" illegal base64 data at input byte 3 <nil>
                "a===" "" illegal base64 data at input byte 1 "" illegal base64 data at input byte 1 illegal base64 data at input byte 1
                "aG\nk/" "hi?" <nil> "hi?" <nil> <nil>
                "aGk/x" "hi?" illegal base64 data at input byte 4 "hi?" illegal base64 data at input byte 4 illegal base64 data at input byte 4
                "@@@@" "" illegal base64 data at input byte 0 "" illegal base64 data at input byte 0 illegal base64 data at input byte 0
                "" "" <nil> "" <nil> <nil>
                "aGk=\n" "hi" <nil> "" illegal base64 data at input byte 3 <nil>
                "aGl=" "hi" <nil> "" illegal base64 data at input byte 3 illegal base64 data at input byte 3
                3 <nil> [251 255 191]
                base64.CorruptInputError illegal base64 data at input byte 2 true 2
                xhi <nil>

                """#)
    }
}
