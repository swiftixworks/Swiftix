/// A struct that embeds `context.Context` or a type of `net/http` is lent
/// its methods, and implements the interfaces they make up, as in Go: the
/// middleware that wraps an `http.ResponseWriter` to keep the status, a
/// context that answers one key itself, a router around a `*http.ServeMux`.
///
/// `context` and `net/http` are Go text of the library, so their types are
/// embedded like any of the program's. Every expected output here was taken
/// from Go 1.24.5.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go embedded context and net/http types")
struct GoLibraryEmbeddingTests: GoTestHarness {

    /// A context that embeds another is one, with the methods it does not
    /// declare promoted, and a parent of the contexts made from it.
    @Test func anEmbeddedContextLendsItsMethods() throws {
        #expect(
            try runGoMain(
                """
                vc := valueCtx{context.Background(), "t1"}
                fmt.Println(vc.Value("tag"), vc.Value("x"), vc.Err(), vc.Done() == nil)
                _, has := vc.Deadline()
                fmt.Println(has)
                var c context.Context = vc
                ctx, cancel := context.WithTimeout(c, 10*time.Millisecond)
                defer cancel()
                <-ctx.Done()
                fmt.Println(ctx.Err(), ctx.Value("tag"))
                p := &valueCtx{context.TODO(), "t2"}
                use(p)
                cc, stop := context.WithCancel(p)
                stop()
                <-cc.Done()
                fmt.Println(cc.Err(), cc.Value("tag"))
                err := vc.Err
                fmt.Println(err())
                """,
                imports: ["context", "fmt", "time"],
                declarations: """
                    type valueCtx struct {
                        context.Context
                        tag string
                    }

                    func (v valueCtx) Value(key any) any {
                        if k, ok := key.(string); ok && k == "tag" {
                            return v.tag
                        }
                        return v.Context.Value(key)
                    }

                    func use(c context.Context) { fmt.Println(c.Err(), c.Value("tag")) }
                    """)
                == """
                t1 <nil> <nil> true
                false
                context deadline exceeded t1
                <nil> t2
                context canceled t2
                <nil>

                """)
    }

    /// The middleware pattern: a writer that keeps the status around the one it
    /// is given, which it is wherever an `http.ResponseWriter` is wanted, without
    /// writing `s.ResponseWriter.Header()`; a request embedded by pointer; a
    /// router that embeds a `*http.ServeMux` and is an `http.Handler`.
    @Test func anEmbeddedResponseWriterLendsItsMethods() throws {
        #expect(
            try runGoMain(
                """
                mux := router{http.NewServeMux(), "r"}
                mux.HandleFunc("/a", func(w http.ResponseWriter, r *http.Request) {
                    w.WriteHeader(http.StatusTeapot)
                    io.WriteString(w, "hi")
                })
                var h http.Handler = logged{middleware(mux), "outer"}
                rec := &recorder{header: http.Header{}}
                r, _ := http.NewRequest("GET", "http://example.com/a?q=1", nil)
                h.ServeHTTP(rec, r)
                fmt.Println(rec.status, rec.body, rec.header.Get("X-Mid"))
                q := wrappedReq{r, 1}
                fmt.Println(q.Method, q.URL.Query().Get("q"), q.FormValue("q"), q.Context().Err())
                fmt.Println(q.WithContext(context.Background()).URL.Path)
                hd := headers{http.Header{}}
                hd.Set("k", "v")
                hd.Add("k", "w")
                fmt.Println(hd.Get("k"), hd.Values("k"))
                """,
                imports: ["context", "fmt", "io", "net/http"],
                declarations: """
                    type statusWriter struct {
                        http.ResponseWriter
                        status int
                    }

                    func (s *statusWriter) WriteHeader(code int) {
                        s.status = code
                        s.ResponseWriter.WriteHeader(code)
                    }

                    type logged struct {
                        http.Handler
                        name string
                    }

                    type router struct {
                        *http.ServeMux
                        name string
                    }

                    type wrappedReq struct {
                        *http.Request
                        extra int
                    }

                    type headers struct {
                        http.Header
                    }

                    type recorder struct {
                        header http.Header
                        status int
                        body   string
                    }

                    func (r *recorder) Header() http.Header         { return r.header }
                    func (r *recorder) Write(b []byte) (int, error) { r.body += string(b); return len(b), nil }
                    func (r *recorder) WriteHeader(code int)        { r.status = code }

                    func middleware(next http.Handler) http.Handler {
                        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                            sw := &statusWriter{ResponseWriter: w, status: 200}
                            sw.Header().Set("X-Mid", "1")
                            next.ServeHTTP(sw, r)
                            fmt.Println("served", r.Method, r.URL.Path, sw.status)
                        })
                    }
                    """)
                == "served GET /a 418\n418 hi 1\nGET 1 1 <nil>\n/a\nv [v w]\n")
    }
}
