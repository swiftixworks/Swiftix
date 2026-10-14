/// `encoding/json` in programs: a JSON API over HTTP and its client, and what
/// a program that uses the package is linked with.
///
/// The server decodes request bodies with a `json.Decoder` that refuses
/// unknown fields and answers with a `json.Encoder` on the
/// `http.ResponseWriter`; one type has `MarshalJSON` and `UnmarshalJSON`,
/// one field is a `time.Time`, others are `omitempty`. The expected text is
/// what the same program printed under Go 1.24.5.
///
/// Concurrency: every test builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import Testing

@testable import Swiftix
@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go encoding/json programs")
struct GoJSONProgramTests: GoTestHarness {

    /// Runs `source` as a process of a kernel that has a loopback interface,
    /// and returns what it printed on standard output.
    private func runServer(_ source: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        stack.configure(
            .addInterface(
                NetworkInterfaceConfiguration(
                    address: IPv4Address(127, 0, 0, 1),
                    mac: MACAddress("00:00:00:00:00:00")!,
                    prefixLength: 8)))
        let loopback = try #require(stack.interface(at: 0))
        loopback.onEgress = { [weak stack, weak loopback] frame in
            guard let stack, let loopback else { return }
            loop.schedule(after: 0) { stack.receive(frame, on: loopback) }
        }
        var output = ""
        var failure: (any Error)?
        kernel.spawn("server") { context in
            for path in ["/stdin", "/stdout", "/stderr"] {
                _ = context.open(path, create: true, truncate: true)
            }
            do {
                _ = try GoVirtualMachine(maximumInstructions: 50_000_000).run(
                    executable, eventLoop: loop, processContext: context,
                    arguments: ["server"]
                ) { output += $0 }
            } catch {
                failure = error
            }
            context.exit(0)
        }
        loop.runUntilIdle()
        if let failure { throw failure }
        return output
    }

    /// The names of the functions of the image `source` compiles to.
    private func functionNames(_ source: String) throws -> [String] {
        try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
            .functions.map(\.name)
    }

    /// `POST /items` and `GET /items/{id}` of a small store, with a request
    /// that has an unknown field, one with a value of the wrong type, one
    /// cut off, and lookups that fail.
    @Test func aJSONAPIAndItsClient() throws {
        #expect(try runServer(apiSource) == apiExpected + "\n")
    }

    /// A program that does not import the package is linked with none of
    /// it; one that only marshals gets the encoder's text and not the
    /// decoder's; a method of the program is linked where the walk may
    /// stop for it.
    @Test func aProgramIsLinkedWithWhatItUses() throws {
        let plain = try functionNames(
            """
            package main
            import "fmt"
            func main() { fmt.Println("x") }
            """)
        #expect(plain == ["main"])
        let marshal = try functionNames(
            """
            package main
            import (
                "encoding/json"
                "fmt"
            )
            func main() {
                b, err := json.Marshal(map[string]int{"a": 1})
                fmt.Println(string(b), err)
            }
            """)
        #expect(marshal.contains("encoding/json.Marshal"))
        #expect(!marshal.contains("encoding/json.Unmarshal"))
        #expect(!marshal.contains { $0.hasPrefix("encoding/json.(*Decoder)") || $0.contains("Decoder.") })
        let valid = try functionNames(
            """
            package main
            import (
                "encoding/json"
                "fmt"
            )
            func main() { fmt.Println(json.Valid([]byte("{}"))) }
            """)
        #expect(valid.contains("encoding/json.Valid"))
        #expect(!valid.contains("encoding/json.Marshal"))
    }
}

private let apiSource = #"""
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Price int64

// MarshalJSON writes cents as a decimal string.
func (p Price) MarshalJSON() ([]byte, error) {
	return []byte(fmt.Sprintf(`"%d.%02d"`, p/100, p%100)), nil
}

func (p *Price) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	whole, frac, _ := strings.Cut(s, ".")
	w, err := strconv.Atoi(whole)
	if err != nil {
		return err
	}
	f, _ := strconv.Atoi(frac)
	*p = Price(w*100 + f)
	return nil
}

type Item struct {
	ID      int       `json:"id"`
	Name    string    `json:"name"`
	Price   Price     `json:"price"`
	Tags    []string  `json:"tags,omitempty"`
	Created time.Time `json:"created"`
	Note    *string   `json:"note,omitempty"`
}

type apiError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type store struct {
	mu    sync.Mutex
	items map[int]Item
	next  int
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (s *store) create(w http.ResponseWriter, r *http.Request) {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var it Item
	if err := dec.Decode(&it); err != nil {
		writeJSON(w, http.StatusBadRequest, apiError{400, err.Error()})
		return
	}
	s.mu.Lock()
	s.next++
	it.ID = s.next
	it.Created = time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
	s.items[it.ID] = it
	s.mu.Unlock()
	writeJSON(w, http.StatusCreated, it)
}

func (s *store) get(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, apiError{400, "bad id"})
		return
	}
	s.mu.Lock()
	it, ok := s.items[id]
	s.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, apiError{404, "no item " + strconv.Itoa(id)})
		return
	}
	writeJSON(w, http.StatusOK, it)
}

func call(base, method, path, body string) {
	var resp *http.Response
	var err error
	if method == "POST" {
		resp, err = http.Post(base+path, "application/json", strings.NewReader(body))
	} else {
		resp, err = http.Get(base + path)
	}
	if err != nil {
		fmt.Println("error:", err)
		return
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	fmt.Printf("%s %s -> %d %s %s", method, path, resp.StatusCode, resp.Header.Get("Content-Type"), raw)
	if resp.StatusCode >= 400 {
		var e apiError
		json.Unmarshal(raw, &e)
		fmt.Printf("  error %d: %s\n", e.Code, e.Message)
		return
	}
	var it Item
	if err := json.NewDecoder(bytes.NewReader(raw)).Decode(&it); err != nil {
		fmt.Println("  decode:", err)
		return
	}
	fmt.Printf("  item %d %q %d %v %s\n", it.ID, it.Name, it.Price, it.Tags, it.Created.Format(time.RFC1123))
}

func main() {
	s := &store{items: map[int]Item{}}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /items", s.create)
	mux.HandleFunc("GET /items/{id}", s.get)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Println(err)
		return
	}
	go http.Serve(ln, mux)
	base := "http://" + ln.Addr().String()
	call(base, "POST", "/items", `{"name":"lamp","price":"12.50","tags":["home","<light>"]}`)
	call(base, "POST", "/items", `{"name":"desk","price":"99.99"}`)
	call(base, "POST", "/items", `{"name":"bad","colour":"red"}`)
	call(base, "POST", "/items", `{"name":"bad","price":12}`)
	call(base, "POST", "/items", `{"name":`)
	call(base, "GET", "/items/1", "")
	call(base, "GET", "/items/2", "")
	call(base, "GET", "/items/7", "")
	call(base, "GET", "/items/x", "")
}
"""#

private let apiExpected = #"""
POST /items -> 201 application/json {"id":1,"name":"lamp","price":"12.50","tags":["home","\u003clight\u003e"],"created":"2024-01-02T03:04:05Z"}
  item 1 "lamp" 1250 [home <light>] Tue, 02 Jan 2024 03:04:05 UTC
POST /items -> 201 application/json {"id":2,"name":"desk","price":"99.99","created":"2024-01-02T03:04:05Z"}
  item 2 "desk" 9999 [] Tue, 02 Jan 2024 03:04:05 UTC
POST /items -> 400 application/json {"code":400,"message":"json: unknown field \"colour\""}
  error 400: json: unknown field "colour"
POST /items -> 400 application/json {"code":400,"message":"json: cannot unmarshal number into Go struct field Item.price of type string"}
  error 400: json: cannot unmarshal number into Go struct field Item.price of type string
POST /items -> 400 application/json {"code":400,"message":"unexpected EOF"}
  error 400: unexpected EOF
GET /items/1 -> 200 application/json {"id":1,"name":"lamp","price":"12.50","tags":["home","\u003clight\u003e"],"created":"2024-01-02T03:04:05Z"}
  item 1 "lamp" 1250 [home <light>] Tue, 02 Jan 2024 03:04:05 UTC
GET /items/2 -> 200 application/json {"id":2,"name":"desk","price":"99.99","created":"2024-01-02T03:04:05Z"}
  item 2 "desk" 9999 [] Tue, 02 Jan 2024 03:04:05 UTC
GET /items/7 -> 404 application/json {"code":404,"message":"no item 7"}
  error 404: no item 7
GET /items/x -> 400 application/json {"code":400,"message":"bad id"}
  error 400: bad id
"""#
