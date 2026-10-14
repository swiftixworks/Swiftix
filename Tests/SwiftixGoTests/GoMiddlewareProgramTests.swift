/// Two programs of the kind this toolchain is for, written with the
/// standard library as a Go programmer would write them: what each prints
/// is what Go 1.24.5 printed for it, the ports the system chose printed as
/// names.

import Testing

@testable import Swiftix
@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go middleware programs")
struct GoMiddlewareProgramTests {
    /// Runs `source` as a process of a kernel that has a loopback
    /// interface, and returns what it printed on standard output.
    private func run(_ source: String) throws -> String {
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
                    executable, eventLoop: loop, processContext: context, arguments: ["server"]
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

    /// A small redis: RESP over TCP, an LRU of three keys, a key that expires, an append-only file of checksummed records replayed at the next start, its configuration from flags, and a shutdown on SIGTERM through `signal.NotifyContext` that flushes the file.
    @Test func aSmallRedisRunsAsGoRunsIt() throws {
        #expect(try run(redisSource) == redisExpected)
    }

    /// A small nginx: static files from `http.FileServer`, an API proxied by `httputil.ReverseProxy` to two backends chosen by weighted round robin, a health check, and an access log written by a middleware.
    @Test func aSmallNginxRunsAsGoRunsIt() throws {
        #expect(try run(nginxSource) == nginxExpected)
    }
}

private let redisSource = #"""
// A small redis: RESP over TCP, an LRU of a fixed size, keys that expire,
// an append-only file of checksummed records replayed at start, its
// configuration from flags, and a shutdown on SIGTERM that flushes the
// file. Clients in the same program drive it.
package main

import (
	"bufio"
	"container/list"
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"hash/crc32"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type config struct {
	addr     string
	maxKeys  int
	aofPath  string
	logLevel string
}

func parseConfig(args []string) (config, error) {
	var c config
	fs := flag.NewFlagSet("miniredis", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&c.addr, "addr", "127.0.0.1:0", "listen address")
	fs.IntVar(&c.maxKeys, "max-keys", 3, "keys kept before the least recently used goes")
	fs.StringVar(&c.aofPath, "aof", "data/appendonly.aof", "append-only file")
	fs.StringVar(&c.logLevel, "log", "info", "log level")
	err := fs.Parse(args)
	return c, err
}

type entry struct {
	key      string
	value    string
	expireAt time.Time
}

type store struct {
	mu    sync.Mutex
	max   int
	order *list.List
	items map[string]*list.Element
	aof   *aofWriter
	now   func() time.Time
}

func newStore(max int, aof *aofWriter, now func() time.Time) *store {
	return &store{max: max, order: list.New(), items: map[string]*list.Element{}, aof: aof, now: now}
}

func (s *store) get(key string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	el, ok := s.items[key]
	if !ok {
		return "", false
	}
	e := el.Value.(*entry)
	if !e.expireAt.IsZero() && !s.now().Before(e.expireAt) {
		s.order.Remove(el)
		delete(s.items, key)
		return "", false
	}
	s.order.MoveToFront(el)
	return e.value, true
}

func (s *store) set(key, value string, ttl time.Duration, replay bool) (evicted string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var expire time.Time
	if ttl > 0 {
		expire = s.now().Add(ttl)
	}
	if el, ok := s.items[key]; ok {
		e := el.Value.(*entry)
		e.value, e.expireAt = value, expire
		s.order.MoveToFront(el)
	} else {
		s.items[key] = s.order.PushFront(&entry{key, value, expire})
		if s.order.Len() > s.max {
			last := s.order.Back()
			s.order.Remove(last)
			evicted = last.Value.(*entry).key
			delete(s.items, evicted)
		}
	}
	if !replay && s.aof != nil {
		s.aof.append("SET", key, value, strconv.FormatInt(int64(ttl/time.Millisecond), 10))
	}
	return evicted
}

func (s *store) del(keys []string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, k := range keys {
		if el, ok := s.items[k]; ok {
			s.order.Remove(el)
			delete(s.items, k)
			n++
			if s.aof != nil {
				s.aof.append("DEL", k)
			}
		}
	}
	return n
}

func (s *store) keys() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for el := s.order.Front(); el != nil; el = el.Next() {
		out = append(out, el.Value.(*entry).key)
	}
	return out
}

// aofWriter writes each command as a record: length, crc32, payload.
type aofWriter struct {
	mu  sync.Mutex
	f   *os.File
	buf *bufio.Writer
	n   int
}

func openAOF(path string) (*aofWriter, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	return &aofWriter{f: f, buf: bufio.NewWriter(f)}, nil
}

func (w *aofWriter) append(fields ...string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	payload := []byte(strings.Join(fields, "\x00"))
	var head [8]byte
	binary.BigEndian.PutUint32(head[:4], uint32(len(payload)))
	binary.BigEndian.PutUint32(head[4:], crc32.ChecksumIEEE(payload))
	w.buf.Write(head[:])
	w.buf.Write(payload)
	w.n++
}

func (w *aofWriter) close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.buf.Flush(); err != nil {
		return err
	}
	return w.f.Close()
}

var errCorrupt = errors.New("aof: checksum mismatch")

func replay(path string, s *store) (int, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	defer f.Close()
	r := bufio.NewReader(f)
	n := 0
	for {
		var head [8]byte
		if _, err := io.ReadFull(r, head[:]); err == io.EOF {
			return n, nil
		} else if err != nil {
			return n, err
		}
		payload := make([]byte, binary.BigEndian.Uint32(head[:4]))
		if _, err := io.ReadFull(r, payload); err != nil {
			return n, err
		}
		if crc32.ChecksumIEEE(payload) != binary.BigEndian.Uint32(head[4:]) {
			return n, errCorrupt
		}
		fields := strings.Split(string(payload), "\x00")
		switch fields[0] {
		case "SET":
			ms, _ := strconv.ParseInt(fields[3], 10, 64)
			s.set(fields[1], fields[2], time.Duration(ms)*time.Millisecond, true)
		case "DEL":
			s.del(fields[1:2])
		}
		n++
	}
}

func readCommand(r *bufio.Reader) ([]string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	line = strings.TrimRight(line, "\r\n")
	if !strings.HasPrefix(line, "*") {
		return strings.Fields(line), nil
	}
	count, err := strconv.Atoi(line[1:])
	if err != nil {
		return nil, fmt.Errorf("bad array header %q: %w", line, err)
	}
	args := make([]string, 0, count)
	for i := 0; i < count; i++ {
		head, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		size, err := strconv.Atoi(strings.TrimRight(head, "\r\n")[1:])
		if err != nil {
			return nil, err
		}
		buf := make([]byte, size+2)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, err
		}
		args = append(args, string(buf[:size]))
	}
	return args, nil
}

func reply(w *bufio.Writer, v any) {
	switch v := v.(type) {
	case nil:
		w.WriteString("$-1\r\n")
	case string:
		fmt.Fprintf(w, "$%d\r\n%s\r\n", len(v), v)
	case int:
		fmt.Fprintf(w, ":%d\r\n", v)
	case error:
		fmt.Fprintf(w, "-ERR %s\r\n", v)
	case []string:
		fmt.Fprintf(w, "*%d\r\n", len(v))
		for _, s := range v {
			fmt.Fprintf(w, "$%d\r\n%s\r\n", len(s), s)
		}
	}
}

func serveConn(conn net.Conn, s *store, logger *log.Logger) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	w := bufio.NewWriter(conn)
	for {
		args, err := readCommand(r)
		if err != nil {
			if err != io.EOF {
				logger.Printf("read: %v", err)
			}
			return
		}
		switch strings.ToUpper(args[0]) {
		case "PING":
			w.WriteString("+PONG\r\n")
		case "SET":
			var ttl time.Duration
			if len(args) == 5 && strings.EqualFold(args[3], "PX") {
				ms, err := strconv.Atoi(args[4])
				if err != nil {
					reply(w, err)
					break
				}
				ttl = time.Duration(ms) * time.Millisecond
			}
			if gone := s.set(args[1], args[2], ttl, false); gone != "" {
				logger.Printf("evicted %s", gone)
			}
			w.WriteString("+OK\r\n")
		case "GET":
			if v, ok := s.get(args[1]); ok {
				reply(w, v)
			} else {
				reply(w, nil)
			}
		case "DEL":
			reply(w, s.del(args[1:]))
		case "KEYS":
			reply(w, s.keys())
		default:
			reply(w, fmt.Errorf("unknown command '%s'", args[0]))
		}
		w.Flush()
	}
}

func run(args []string, now func() time.Time, out io.Writer) error {
	cfg, err := parseConfig(args)
	if err != nil {
		return err
	}
	logger := log.New(out, "["+cfg.logLevel+"] ", 0)
	aof, err := openAOF(cfg.aofPath)
	if err != nil {
		return err
	}
	s := newStore(cfg.maxKeys, nil, now)
	n, err := replay(cfg.aofPath, s)
	if err != nil {
		return err
	}
	s.aof = aof
	logger.Printf("replayed %d records, keys %v", n, s.keys())

	ln, err := net.Listen("tcp", cfg.addr)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer stop()
	var wg sync.WaitGroup
	go func() {
		<-ctx.Done()
		logger.Printf("shutting down: %v", context.Cause(ctx))
		ln.Close()
	}()

	clientsDone := make(chan struct{})
	go func() {
		defer close(clientsDone)
		clientSession(ln.Addr().String(), out)
		syscall.Kill(syscall.Getpid(), syscall.SIGTERM)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				break
			}
			return err
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			serveConn(conn, s, logger)
		}()
	}
	wg.Wait()
	<-clientsDone
	logger.Printf("flushed %d records", aof.n)
	return aof.close()
}

func send(conn net.Conn, r *bufio.Reader, args ...string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(&b, "$%d\r\n%s\r\n", len(a), a)
	}
	conn.Write([]byte(b.String()))
	line, _ := r.ReadString('\n')
	line = strings.TrimRight(line, "\r\n")
	switch line[0] {
	case '$':
		n, _ := strconv.Atoi(line[1:])
		if n < 0 {
			return "(nil)"
		}
		buf := make([]byte, n+2)
		io.ReadFull(r, buf)
		return strconv.Quote(string(buf[:n]))
	case '*':
		n, _ := strconv.Atoi(line[1:])
		var items []string
		for i := 0; i < n; i++ {
			head, _ := r.ReadString('\n')
			size, _ := strconv.Atoi(strings.TrimRight(head, "\r\n")[1:])
			buf := make([]byte, size+2)
			io.ReadFull(r, buf)
			items = append(items, string(buf[:size]))
		}
		return fmt.Sprint(items)
	}
	return line
}

func clientSession(addr string, out io.Writer) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Fprintln(out, "dial:", err)
		return
	}
	defer conn.Close()
	r := bufio.NewReader(conn)
	steps := [][]string{
		{"PING"},
		{"SET", "a", "1"},
		{"SET", "b", "2"},
		{"SET", "session", "xyz", "PX", "100"},
		{"GET", "a"},
		{"SET", "c", "3"},
		{"KEYS"},
		{"GET", "b"},
		{"DEL", "a", "zzz"},
		{"GET", "session"},
		{"FLY"},
	}
	for _, step := range steps {
		fmt.Fprintf(out, "> %s\n%s\n", strings.Join(step, " "), send(conn, r, step...))
	}
}

func main() {
	os.RemoveAll("data")
	clock := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	var clockMu sync.Mutex
	now := func() time.Time {
		clockMu.Lock()
		defer clockMu.Unlock()
		clock = clock.Add(10 * time.Millisecond)
		return clock
	}
	for round := 1; round <= 2; round++ {
		fmt.Printf("== round %d\n", round)
		if err := run([]string{"-max-keys", "3", "-log", "debug"}, now, os.Stdout); err != nil {
			fmt.Println("run:", err)
		}
	}
	data, _ := os.ReadFile("data/appendonly.aof")
	fmt.Println("aof bytes:", len(data), "crc:", crc32.ChecksumIEEE(data))
	_, err := parseConfig([]string{"-max-keys", "lots"})
	fmt.Println(err)
	os.RemoveAll("data")
}
"""#

private let redisExpected = #"""
== round 1
[debug] replayed 0 records, keys []
> PING
+PONG
> SET a 1
+OK
> SET b 2
+OK
> SET session xyz PX 100
+OK
> GET a
"1"
[debug] evicted b
> SET c 3
+OK
> KEYS
[c a session]
> GET b
(nil)
> DEL a zzz
:1
> GET session
"xyz"
> FLY
-ERR unknown command 'FLY'
[debug] shutting down: context canceled
[debug] flushed 5 records
== round 2
[debug] replayed 5 records, keys [c session b]
> PING
+PONG
[debug] evicted b
> SET a 1
+OK
[debug] evicted session
> SET b 2
+OK
[debug] evicted c
> SET session xyz PX 100
+OK
> GET a
"1"
[debug] evicted b
> SET c 3
+OK
> KEYS
[c a session]
> GET b
(nil)
> DEL a zzz
:1
> GET session
"xyz"
> FLY
-ERR unknown command 'FLY'
[debug] shutting down: context canceled
[debug] flushed 5 records
aof bytes: 182 crc: 3309853734
invalid value "lots" for flag -max-keys: parse error

"""#

private let nginxSource = #"""
// A small nginx: static files under /static/, everything under /api/
// proxied to backends chosen by weighted round robin, an access log, a
// health check, and configuration from flags.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type upstream struct {
	name   string
	url    *url.URL
	weight int
	proxy  *httputil.ReverseProxy
	served int
}

type balancer struct {
	mu        sync.Mutex
	upstreams []*upstream
	sequence  []int
	next      int
}

func newBalancer(ups []*upstream) *balancer {
	b := &balancer{upstreams: ups}
	for i, u := range ups {
		for w := 0; w < u.weight; w++ {
			b.sequence = append(b.sequence, i)
		}
	}
	return b
}

func (b *balancer) pick() *upstream {
	b.mu.Lock()
	defer b.mu.Unlock()
	u := b.upstreams[b.sequence[b.next%len(b.sequence)]]
	b.next++
	u.served++
	return u
}

func (b *balancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	u := b.pick()
	w.Header().Set("X-Upstream", u.name)
	u.proxy.ServeHTTP(w, r)
}

type recorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (r *recorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(p []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	n, err := r.ResponseWriter.Write(p)
	r.bytes += n
	return n, err
}

func accessLog(logger *log.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &recorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		logger.Printf("%s %s %d %d upstream=%q", r.Method, r.URL.RequestURI(), rec.status, rec.bytes, w.Header().Get("X-Upstream"))
	})
}

func backend(name string) *httptest {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/echo", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		fmt.Fprintf(w, "%s echo %s %q fwd=%s", name, r.Method, body, r.Header.Get("X-Forwarded-For"))
	})
	mux.HandleFunc("GET /api/items/{id}", func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.Atoi(r.PathValue("id"))
		if err != nil {
			http.Error(w, "bad id", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":%d,"from":%q}`, id, name)
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	return &httptest{url: "http://" + ln.Addr().String(), srv: srv}
}

type httptest struct {
	url string
	srv *http.Server
}

func main() {
	fs := flag.NewFlagSet("mininginx", flag.ContinueOnError)
	root := fs.String("root", "public", "static root")
	weights := fs.String("weights", "2,1", "weights of the two backends")
	if err := fs.Parse([]string{"-root", "public", "-weights", "3,1"}); err != nil {
		panic(err)
	}
	os.MkdirAll(filepath.Join(*root, "img"), 0o755)
	os.WriteFile(filepath.Join(*root, "index.html"), []byte("<title>mini</title>\n"), 0o644)
	os.WriteFile(filepath.Join(*root, "img", "logo.svg"), []byte("<svg/>"), 0o644)

	var ups []*upstream
	for i, w := range strings.Split(*weights, ",") {
		weight, _ := strconv.Atoi(w)
		name := fmt.Sprintf("b%d", i+1)
		be := backend(name)
		target, _ := url.Parse(be.url)
		ups = append(ups, &upstream{name: name, url: target, weight: weight, proxy: httputil.NewSingleHostReverseProxy(target)})
	}
	var logBuf bytes.Buffer
	logger := log.New(&logBuf, "access ", 0)

	mux := http.NewServeMux()
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir(*root))))
	mux.Handle("/api/", newBalancer(ups))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	front := &http.Server{Handler: accessLog(logger, mux), ReadHeaderTimeout: 2 * time.Second}
	go front.Serve(ln)
	base := "http://" + ln.Addr().String()

	do := func(method, path, body string) {
		req, _ := http.NewRequest(method, base+path, strings.NewReader(body))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			fmt.Println(method, path, "error:", err)
			return
		}
		data, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		fmt.Printf("%s %s -> %d %s %q %s\n", method, path, resp.StatusCode, resp.Header.Get("Content-Type"), resp.Header.Get("X-Upstream"), data)
	}
	do("GET", "/healthz", "")
	do("GET", "/static/", "")
	do("GET", "/static/img/logo.svg", "")
	do("GET", "/static/nope.css", "")
	for i := 1; i <= 5; i++ {
		do("GET", "/api/items/"+strconv.Itoa(i), "")
	}
	do("GET", "/api/items/x", "")
	do("POST", "/api/echo", "ping")
	do("DELETE", "/healthz", "")

	front.Close()
	var served []string
	for _, u := range ups {
		served = append(served, fmt.Sprintf("%s=%d", u.name, u.served))
	}
	sort.Strings(served)
	fmt.Println("served:", served)
	fmt.Print(strings.ReplaceAll(logBuf.String(), "127.0.0.1", "LOCAL"))
	os.RemoveAll(*root)
}
"""#

private let nginxExpected = #"""
GET /healthz -> 200 text/plain; charset=utf-8 "" ok

GET /static/ -> 200 text/html; charset=utf-8 "" <title>mini</title>

GET /static/img/logo.svg -> 200 image/svg+xml "" <svg/>
GET /static/nope.css -> 404 text/plain; charset=utf-8 "" 404 page not found

GET /api/items/1 -> 200 application/json "b1" {"id":1,"from":"b1"}
GET /api/items/2 -> 200 application/json "b1" {"id":2,"from":"b1"}
GET /api/items/3 -> 200 application/json "b1" {"id":3,"from":"b1"}
GET /api/items/4 -> 200 application/json "b2" {"id":4,"from":"b2"}
GET /api/items/5 -> 200 application/json "b1" {"id":5,"from":"b1"}
GET /api/items/x -> 400 text/plain; charset=utf-8 "b1" bad id

POST /api/echo -> 200 text/plain; charset=utf-8 "b1" b1 echo POST "ping" fwd=127.0.0.1
DELETE /healthz -> 405 text/plain; charset=utf-8 "" Method Not Allowed

served: [b1=6 b2=1]
access GET /healthz 200 3 upstream=""
access GET /static/ 200 20 upstream=""
access GET /static/img/logo.svg 200 6 upstream=""
access GET /static/nope.css 404 19 upstream=""
access GET /api/items/1 200 20 upstream="b1"
access GET /api/items/2 200 20 upstream="b1"
access GET /api/items/3 200 20 upstream="b1"
access GET /api/items/4 200 20 upstream="b2"
access GET /api/items/5 200 20 upstream="b1"
access GET /api/items/x 400 7 upstream="b1"
access POST /api/echo 200 33 upstream="b1"
access DELETE /healthz 405 19 upstream=""

"""#
