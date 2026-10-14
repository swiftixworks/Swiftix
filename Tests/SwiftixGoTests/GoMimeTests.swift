/// `mime` and the streams of `encoding/base64`, Go's text.
///
/// What each program prints is what Go 1.24.5 printed for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go mime and base64 streams")
struct GoMimeTests {
    private func run(_ source: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        var output = ""
        try GoVirtualMachine(maximumInstructions: 50_000_000).run(executable) { output += $0 }
        return output
    }

    /// `mime`: `TypeByExtension` from Go's built-in table (and `mime.types` files where the system has them, which this one does not), `ExtensionsByType`, `AddExtensionType`, `ParseMediaType`, `FormatMediaType`, and encoded words.
    @Test func mediaTypesAndExtensionsAreGos() throws {
        #expect(try run(mimesSource) == mimesExpected)
    }

    /// `encoding/base64`'s `NewEncoder` and `NewDecoder`, which write and read in pieces, skipping line breaks.
    @Test func base64StreamsAreGos() throws {
        #expect(try run(streamsSource) == streamsExpected)
    }
}

private let mimesSource = #"""
package main

import (
	"fmt"
	"mime"
)

func main() {
	for _, e := range []string{".html", ".css", ".js", ".json", ".png", ".svg", ".wasm", ".JPG", ".pdf", ".avif", ".webp", ".mjs", ".gif"} {
		fmt.Printf("%s=%q ", e, mime.TypeByExtension(e))
	}
	fmt.Println()
	exts, err := mime.ExtensionsByType("text/html")
	fmt.Println(exts, err)
	fmt.Println(mime.AddExtensionType(".swx", "application/x-swiftix"), mime.TypeByExtension(".swx"))
	mt, params, err := mime.ParseMediaType(`text/html; charset="utf-8"; q=0.5`)
	fmt.Println(mt, params, err)
	mt, params, err = mime.ParseMediaType("multipart/form-data; boundary=xyz")
	fmt.Println(mt, params["boundary"], err)
	_, _, err = mime.ParseMediaType("bad type ;")
	fmt.Println(err)
	fmt.Println(mime.FormatMediaType("text/plain", map[string]string{"charset": "utf-8", "a": "b c"}))
	fmt.Println(mime.QEncoding.Encode("utf-8", "¡Hola, señor!"), mime.BEncoding.Encode("UTF-8", "hello"))
	var d mime.WordDecoder
	s, err := d.DecodeHeader("=?utf-8?q?caf=C3=A9?= ok")
	fmt.Println(s, err)
}
"""#

private let mimesExpected = #"""
.html="text/html; charset=utf-8" .css="text/css; charset=utf-8" .js="text/javascript; charset=utf-8" .json="application/json" .png="image/png" .svg="image/svg+xml" .wasm="application/wasm" .JPG="image/jpeg" .pdf="application/pdf" .avif="image/avif" .webp="image/webp" .mjs="text/javascript; charset=utf-8" .gif="image/gif" 
[.htm .html] <nil>
<nil> application/x-swiftix
text/html map[charset:utf-8 q:0.5] <nil>
multipart/form-data xyz <nil>
mime: expected slash after first token
text/plain; a="b c"; charset=utf-8
=?utf-8?q?=C2=A1Hola,_se=C3=B1or!?= hello
café ok <nil>

"""#

private let streamsSource = #"""
package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"strings"
)

func main() {
	var buf bytes.Buffer
	w := base64.NewEncoder(base64.StdEncoding, &buf)
	for _, part := range []string{"he", "llo, ", "wor", "ld!"} {
		w.Write([]byte(part))
	}
	fmt.Println(buf.String())
	w.Close()
	fmt.Println(buf.String())
	r := base64.NewDecoder(base64.StdEncoding, strings.NewReader("aGVs\nbG8s\r\nIHdvcmxkIQ=="))
	out, err := io.ReadAll(r)
	fmt.Printf("%q %v\n", out, err)
	raw := base64.NewEncoder(base64.RawURLEncoding, &buf)
	raw.Write([]byte{0xfb, 0xff})
	raw.Close()
	fmt.Println(buf.String())
	_, err = io.ReadAll(base64.NewDecoder(base64.StdEncoding, strings.NewReader("ab!d")))
	fmt.Println(err)
}
"""#

private let streamsExpected = #"""
aGVsbG8sIHdvcmxk
aGVsbG8sIHdvcmxkIQ==
"hello, world!" <nil>
aGVsbG8sIHdvcmxkIQ==-_8
illegal base64 data at input byte 2

"""#
