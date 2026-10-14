/// `sync.RWMutex`, `sync.Locker`, `sync.Cond`, and `sync.Mutex.TryLock`.
///
/// A `sync.RWMutex` is the struct Go has and its methods are native calls
/// that take a pointer to it, so the lock is where the variable is. What each
/// program prints is what Go 1.24.5 prints for it, and each error pinned with
/// its place is the first one its compiler reports, copied without change.
/// The programs wait with `time.Sleep` where an order has to be certain, on
/// the VM's logical clock.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go sync.RWMutex, sync.Locker, and sync.Cond")
struct GoSyncLockTests: GoTestHarness {

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

    /// Readers share the lock and a writer has it alone; `TryLock` and
    /// `TryRLock` say which without waiting.
    @Test func aReadWriteMutexAdmitsManyReadersOrOneWriter() throws {
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                mu.RLock()
                mu.RLock()
                fmt.Println(mu.TryLock(), mu.TryRLock())
                mu.RUnlock()
                mu.RUnlock()
                mu.RUnlock()
                fmt.Println(mu.TryLock(), mu.TryRLock(), mu.TryLock())
                mu.Unlock()
                mu.Lock()
                mu.Unlock()
                fmt.Println(mu.TryRLock())
                """,
                imports: ["fmt", "sync", "time"])
                == "false true\ntrue false false\ntrue\n")
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                var wg sync.WaitGroup
                inside := make(chan int, 3)
                release := make(chan bool)
                for i := 0; i < 3; i++ {
                    wg.Add(1)
                    go func(i int) {
                        defer wg.Done()
                        mu.RLock()
                        inside <- i
                        <-release
                        mu.RUnlock()
                    }(i)
                }
                sum := 0
                for i := 0; i < 3; i++ {
                    sum += <-inside
                }
                fmt.Println("three readers inside:", sum, mu.TryLock(), mu.TryRLock())
                mu.RUnlock()
                close(release)
                wg.Wait()
                fmt.Println("all out:", mu.TryLock())
                """,
                imports: ["fmt", "sync", "time"])
                == "three readers inside: 3 false true\nall out: true\n")
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                var wg sync.WaitGroup
                n := 0
                for i := 0; i < 40; i++ {
                    wg.Add(2)
                    go func() {
                        defer wg.Done()
                        mu.Lock()
                        n++
                        mu.Unlock()
                    }()
                    go func() {
                        defer wg.Done()
                        mu.RLock()
                        _ = n
                        mu.RUnlock()
                    }()
                }
                wg.Wait()
                fmt.Println(n)
                """,
                imports: ["fmt", "sync", "time"])
                == "40\n")
    }

    /// Go's rule: once a writer waits, a reader that comes waits behind it,
    /// and when the writer unlocks every such reader goes on at once. Writers get
    /// the lock in the order they came.
    @Test func aWaitingWriterKeepsNewReadersOut() throws {
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                mu.RLock()
                done := make(chan string, 4)
                go func() {
                    mu.Lock()
                    done <- "writer"
                    mu.Unlock()
                }()
                time.Sleep(10 * time.Millisecond)
                fmt.Println("while the writer waits:", mu.TryRLock(), mu.TryLock())
                for _, name := range []string{"reader2", "reader3"} {
                    go func() {
                        mu.RLock()
                        done <- name
                        mu.RUnlock()
                    }()
                }
                time.Sleep(10 * time.Millisecond)
                fmt.Println("nobody is through:", len(done))
                mu.RUnlock()
                first := <-done
                a, b := <-done, <-done
                if a > b {
                    a, b = b, a
                }
                fmt.Println(first, a, b)
                """,
                imports: ["fmt", "sync", "time"])
                == """
                while the writer waits: false false
                nobody is through: 0
                writer reader2 reader3

                """)
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                var wg sync.WaitGroup
                order := []int{}
                mu.Lock()
                for i := 0; i < 4; i++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        mu.Lock()
                        order = append(order, i)
                        mu.Unlock()
                    }()
                    time.Sleep(time.Millisecond)
                }
                mu.Unlock()
                wg.Wait()
                fmt.Println(order, mu.TryLock())
                """,
                imports: ["fmt", "sync", "time"])
                == "[0 1 2 3] true\n")
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                mu.Lock()
                got := make(chan string, 3)
                go func() {
                    mu.RLock()
                    got <- "reader"
                    time.Sleep(5 * time.Millisecond)
                    mu.RUnlock()
                }()
                time.Sleep(time.Millisecond)
                go func() {
                    mu.Lock()
                    got <- "second writer"
                    mu.Unlock()
                }()
                time.Sleep(time.Millisecond)
                mu.Unlock()
                fmt.Println(<-got)
                fmt.Println(<-got)
                """,
                imports: ["fmt", "sync", "time"])
                == "reader\nsecond writer\n")
    }

    /// A variable, a field, an embedded field, an element of a slice `make`
    /// made, and what a pointer points to are each a lock of their own; a copy is
    /// the lock as it was when it was copied.
    @Test func theLockIsWhereTheVariableIs() throws {
        #expect(
            try runGoMain(
                """
                s := &store{m: map[string]string{}}
                s.Set("a", "1")
                fmt.Println(s.Get("a"))
                fmt.Println(s.Get("b"))
                var value store
                value.m = map[string]string{"x": "y"}
                fmt.Println(value.Get("x"))
                value.Lock()
                fmt.Println(value.TryRLock(), s.TryRLock())
                value.Unlock()
                """,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type store struct {
                        sync.RWMutex
                        m map[string]string
                    }

                    func (s *store) Get(k string) (string, bool) {
                        s.RLock()
                        defer s.RUnlock()
                        v, ok := s.m[k]
                        return v, ok
                    }

                    func (s *store) Set(k, v string) {
                        s.Lock()
                        defer s.Unlock()
                        s.m[k] = v
                    }

                    type shard struct {
                        mu sync.RWMutex
                        n  int
                    }

                    type gate struct {
                        sync.Mutex
                        open bool
                    }

                    type tally struct{ log []string }

                    func (t *tally) Lock()   { t.log = append(t.log, "lock") }
                    func (t *tally) Unlock() { t.log = append(t.log, "unlock") }

                    func locked(l sync.Locker, f func()) {
                        l.Lock()
                        defer l.Unlock()
                        f()
                    }
                    """)
                == "1 true\n false\ny true\nfalse true\n")
        #expect(
            try runGoMain(
                """
                shards := make([]shard, 4)
                for i := range shards {
                    shards[i].mu.Lock()
                    shards[i].n = i
                }
                fmt.Println(shards[3].mu.TryRLock())
                for i := range shards {
                    shards[i].mu.Unlock()
                }
                fmt.Println(shards[0].mu.TryLock(), shards[1].mu.TryLock(), shards[0].mu.TryLock())
                var pair [2]shard
                pair[0].mu.Lock()
                fmt.Println(pair[1].mu.TryLock())
                byName := map[string]*sync.RWMutex{"a": {}, "b": new(sync.RWMutex)}
                byName["a"].Lock()
                fmt.Println(byName["a"].TryLock(), byName["b"].TryLock())
                """,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type store struct {
                        sync.RWMutex
                        m map[string]string
                    }

                    func (s *store) Get(k string) (string, bool) {
                        s.RLock()
                        defer s.RUnlock()
                        v, ok := s.m[k]
                        return v, ok
                    }

                    func (s *store) Set(k, v string) {
                        s.Lock()
                        defer s.Unlock()
                        s.m[k] = v
                    }

                    type shard struct {
                        mu sync.RWMutex
                        n  int
                    }

                    type gate struct {
                        sync.Mutex
                        open bool
                    }

                    type tally struct{ log []string }

                    func (t *tally) Lock()   { t.log = append(t.log, "lock") }
                    func (t *tally) Unlock() { t.log = append(t.log, "unlock") }

                    func locked(l sync.Locker, f func()) {
                        l.Lock()
                        defer l.Unlock()
                        f()
                    }
                    """)
                == "false\ntrue true false\ntrue\nfalse true\n")
        #expect(
            try runGoMain(
                """
                var rw sync.RWMutex
                p := &rw
                p.Lock()
                fmt.Println(p.TryRLock(), rw.TryRLock())
                p.Unlock()
                literal := sync.RWMutex{}
                literal.Lock()
                copied := literal
                fmt.Println(copied.TryRLock(), literal.TryRLock())
                literal.Unlock()
                fmt.Println(literal == sync.RWMutex{}, copied == sync.RWMutex{})
                var none *sync.RWMutex
                defer func() { fmt.Println(recover()) }()
                none.RLock()
                """,
                imports: ["fmt", "sync", "time"])
                == """
                false false
                false false
                true false
                runtime error: invalid memory address or nil pointer dereference

                """)
    }

    /// A method of a lock that is not called is a function that has its
    /// lock, and `go` and `defer` take the methods as they take any other.
    @Test func theMethodsAreValuesAndStartGoroutinesAndDeferredCalls() throws {
        #expect(
            try runGoMain(
                #"""
                var mu sync.RWMutex
                fns := []func(){mu.Lock, mu.Unlock, mu.RLock, mu.RUnlock}
                for _, f := range fns {
                    f()
                }
                tries := map[string]func() bool{"w": mu.TryLock, "r": mu.TryRLock}
                fmt.Println(tries["w"](), tries["r"](), tries["w"]())
                unlock := mu.Unlock
                unlock()
                read, done, reader := mu.RLock, mu.RUnlock, mu.RLocker
                fmt.Printf("%T %T %T %T %T\n", unlock, read, mu.TryLock, reader, reader())
                read()
                fmt.Println(mu.TryLock())
                done()
                p := &mu
                viaPointer := p.TryLock
                fmt.Println(viaPointer(), viaPointer())
                """#,
                imports: ["fmt", "sync", "time"])
                == """
                true false false
                func() func() func() bool func() sync.Locker *sync.rlocker
                false
                true false

                """)
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                total := 0
                var wg sync.WaitGroup
                for i := 1; i <= 10; i++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        defer mu.Unlock()
                        mu.Lock()
                        total += i
                    }()
                }
                wg.Wait()
                fmt.Println(total)
                go mu.Lock()
                time.Sleep(time.Millisecond)
                fmt.Println(mu.TryRLock())
                func() {
                    defer mu.RLock()
                    defer mu.Unlock()
                }()
                fmt.Println(mu.TryLock(), mu.TryRLock())
                """,
                imports: ["fmt", "sync", "time"])
                == "55\nfalse\nfalse true\n")
    }

    /// `sync.Locker` is the interface of `Lock` and `Unlock`. A pointer to a
    /// `sync.Mutex` or a `sync.RWMutex`, what `RLocker` gives, a struct that embeds
    /// a lock, and a type of the program are all one; the value of a lock is not.
    @Test func aPointerToALockIsALocker() throws {
        #expect(
            try runGoMain(
                #"""
                var rw sync.RWMutex
                var mu sync.Mutex
                own := &tally{}
                s := &store{m: map[string]string{}}
                g := &gate{}
                lockers := []sync.Locker{&rw, &mu, rw.RLocker(), own, s, g}
                for _, l := range lockers {
                    l.Lock()
                    fmt.Printf("%T\n", l)
                    l.Unlock()
                }
                fmt.Println(own.log, s.TryLock(), g.TryLock(), rw.TryRLock(), mu.TryLock())
                rw.RUnlock()
                locked(&rw, func() { fmt.Println("writing:", rw.TryRLock()) })
                locked(rw.RLocker(), func() { fmt.Println("reading:", rw.TryRLock(), rw.TryLock()) })
                var l sync.Locker
                fmt.Println(l == nil)
                l = &rw
                fmt.Println(l == sync.Locker(&rw), l != nil)
                """#,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type store struct {
                        sync.RWMutex
                        m map[string]string
                    }

                    func (s *store) Get(k string) (string, bool) {
                        s.RLock()
                        defer s.RUnlock()
                        v, ok := s.m[k]
                        return v, ok
                    }

                    func (s *store) Set(k, v string) {
                        s.Lock()
                        defer s.Unlock()
                        s.m[k] = v
                    }

                    type shard struct {
                        mu sync.RWMutex
                        n  int
                    }

                    type gate struct {
                        sync.Mutex
                        open bool
                    }

                    type tally struct{ log []string }

                    func (t *tally) Lock()   { t.log = append(t.log, "lock") }
                    func (t *tally) Unlock() { t.log = append(t.log, "unlock") }

                    func locked(l sync.Locker, f func()) {
                        l.Lock()
                        defer l.Unlock()
                        f()
                    }
                    """)
                == """
                *sync.RWMutex
                *sync.Mutex
                *sync.rlocker
                *main.tally
                *main.store
                *main.gate
                [lock unlock] true true true true
                writing: false
                reading: true false
                true
                true true

                """)
        #expect(
            try runGoMain(
                """
                var rw sync.RWMutex
                var mu sync.Mutex
                for _, a := range []any{&rw, &mu, rw.RLocker(), rw, 5} {
                    _, isLocker := a.(sync.Locker)
                    _, reads := a.(interface{ RLock() })
                    _, tries := a.(interface{ TryLock() bool })
                    _, wrong := a.(interface{ Lock() error })
                    _, other := a.(interface{ TryLock() int })
                    switch a.(type) {
                    case *sync.RWMutex:
                        fmt.Print("rwmutex ")
                    case *sync.Mutex:
                        fmt.Print("mutex ")
                    case sync.Locker:
                        fmt.Print("locker ")
                    default:
                        fmt.Print("other ")
                    }
                    fmt.Println(isLocker, reads, tries, wrong, other)
                }
                """,
                imports: ["fmt", "sync", "time"])
                == """
                rwmutex true true true false false
                mutex true false true false false
                locker true false false false false
                other false false false false false
                other false false false false false

                """)
        #expect(
            try runGoMain(
                #"""
                type guarded struct {
                    sync.Locker
                    n int
                }
                var rw sync.RWMutex
                g := guarded{Locker: &rw}
                g.Lock()
                g.n++
                fmt.Println(rw.TryRLock(), g.n)
                g.Unlock()
                var l sync.Locker = g
                l.Lock()
                fmt.Printf("%T %v\n", l, rw.TryLock())
                """#,
                imports: ["fmt", "sync", "time"])
                == "false 1\nmain.guarded false\n")
    }

    /// `sync.Mutex.TryLock`, on a variable, through a pointer, as a value, and
    /// on a struct that embeds the mutex.
    @Test func aMutexCanBeTried() throws {
        #expect(
            try runGoMain(
                #"""
                var mu sync.Mutex
                fmt.Println(mu.TryLock(), mu.TryLock())
                mu.Unlock()
                p := &mu
                fmt.Println(p.TryLock(), mu.TryLock())
                try := mu.TryLock
                p.Unlock()
                fmt.Printf("%T %v %v\n", try, try(), try())
                g := &gate{}
                fmt.Println(g.TryLock(), g.TryLock())
                g.Unlock()
                g.Lock()
                tryGate := g.TryLock
                fmt.Println(tryGate())
                held := make(chan bool)
                go func() { held <- mu.TryLock() }()
                fmt.Println(<-held)
                """#,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type store struct {
                        sync.RWMutex
                        m map[string]string
                    }

                    func (s *store) Get(k string) (string, bool) {
                        s.RLock()
                        defer s.RUnlock()
                        v, ok := s.m[k]
                        return v, ok
                    }

                    func (s *store) Set(k, v string) {
                        s.Lock()
                        defer s.Unlock()
                        s.m[k] = v
                    }

                    type shard struct {
                        mu sync.RWMutex
                        n  int
                    }

                    type gate struct {
                        sync.Mutex
                        open bool
                    }

                    type tally struct{ log []string }

                    func (t *tally) Lock()   { t.log = append(t.log, "lock") }
                    func (t *tally) Unlock() { t.log = append(t.log, "unlock") }

                    func locked(l sync.Locker, f func()) {
                        l.Lock()
                        defer l.Unlock()
                        f()
                    }
                    """)
                == "true false\ntrue false\nfunc() bool true false\ntrue false\nfalse\nfalse\n")
    }

    /// The fields are Go's, so `%v`, `%+v`, and `%T` print what Go prints for
    /// a lock that nobody waits on.
    @Test func aLockPrintsAsGosStructDoes() throws {
        #expect(
            try runGoMain(
                #"""
                type both struct {
                    rw sync.RWMutex
                    n  int
                }
                var b both
                fmt.Printf("%v\n%+v\n", b, b)
                fmt.Printf("%T %T %T\n", b, b.rw, &b.rw)
                b.rw.RLock()
                b.rw.RLock()
                fmt.Printf("%v\n", b.rw)
                b.rw.RUnlock()
                b.rw.RUnlock()
                b.rw.Lock()
                fmt.Printf("%v\n", b)
                var l sync.Locker = &b.rw
                fmt.Printf("%T %T\n", l, b.rw.RLocker())
                fmt.Println(fmt.Sprint(b.rw.RLocker()) == fmt.Sprint(&b.rw))
                """#,
                imports: ["fmt", "sync", "time"])
                == """
                {{{{} {0 0}} 0 0 {{} 0} {{} 0}} 0}
                {rw:{w:{_:{} mu:{state:0 sema:0}} writerSem:0 readerSem:0 readerCount:{_:{} v:0} readerWait:{_:{} v:0}} n:0}
                main.both sync.RWMutex *sync.RWMutex
                {{{} {0 0}} 0 0 {{} 2} {{} 0}}
                {{{{} {1 0}} 0 0 {{} -1073741824} {{} 0}} 0}
                *sync.RWMutex *sync.rlocker
                true

                """)
    }

    /// `sync.Cond`: `Wait` unlocks, waits, and locks again; `Signal` wakes
    /// one waiter and `Broadcast` all; a signal nobody waits for is not kept. The
    /// locker is whatever the program gives, a method of its own included.
    @Test func aConditionVariableWakesThoseThatWait() throws {
        #expect(
            try runGoMain(
                """
                q := newQueue()
                results := make(chan int, 10)
                for i := 0; i < 3; i++ {
                    go func() { results <- q.get() }()
                }
                time.Sleep(time.Millisecond)
                q.put(1)
                q.put(2)
                q.put(3)
                sum := 0
                for i := 0; i < 3; i++ {
                    sum += <-results
                }
                fmt.Println(sum)
                """,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type queue struct {
                        mu    sync.Mutex
                        cond  *sync.Cond
                        items []int
                    }

                    func newQueue() *queue {
                        q := &queue{}
                        q.cond = sync.NewCond(&q.mu)
                        return q
                    }

                    func (q *queue) put(v int) {
                        q.mu.Lock()
                        q.items = append(q.items, v)
                        q.mu.Unlock()
                        q.cond.Signal()
                    }

                    func (q *queue) get() int {
                        q.mu.Lock()
                        defer q.mu.Unlock()
                        for len(q.items) == 0 {
                            q.cond.Wait()
                        }
                        v := q.items[0]
                        q.items = q.items[1:]
                        return v
                    }
                    """)
                == "6\n")
        #expect(
            try runGoMain(
                """
                var mu sync.RWMutex
                c := sync.NewCond(&mu)
                ready := false
                var wg sync.WaitGroup
                for i := 0; i < 4; i++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        c.L.Lock()
                        for !ready {
                            c.Wait()
                        }
                        c.L.Unlock()
                    }()
                }
                time.Sleep(time.Millisecond)
                c.L.Lock()
                ready = true
                c.L.Unlock()
                c.Broadcast()
                wg.Wait()
                fmt.Println("all woke")
                c.Signal()
                c.Broadcast()
                woke := make(chan bool, 1)
                go func() {
                    mu.Lock()
                    c.Wait()
                    mu.Unlock()
                    woke <- true
                }()
                time.Sleep(time.Millisecond)
                select {
                case <-woke:
                    fmt.Println("woke early")
                default:
                    fmt.Println("still waiting")
                }
                c.Signal()
                fmt.Println(<-woke)
                """,
                imports: ["fmt", "sync", "time"])
                == "all woke\nstill waiting\ntrue\n")
        #expect(
            try runGoMain(
                #"""
                own := &tally{}
                oc := sync.NewCond(own)
                done := make(chan bool)
                go func() {
                    oc.L.Lock()
                    oc.Wait()
                    oc.L.Unlock()
                    done <- true
                }()
                time.Sleep(time.Millisecond)
                oc.Signal()
                <-done
                fmt.Println(own.log)
                var mu sync.RWMutex
                var zero sync.Cond
                zero.L = mu.RLocker()
                go func() {
                    zero.L.Lock()
                    zero.Wait()
                    zero.L.Unlock()
                    done <- true
                }()
                time.Sleep(time.Millisecond)
                fmt.Println(mu.TryLock())
                mu.Unlock()
                signal := zero.Signal
                signal()
                <-done
                fmt.Printf("%T %T %T %T\n", oc, zero.L, zero.Wait, sync.NewCond)
                defer zero.Broadcast()
                go zero.Signal()
                """#,
                imports: ["fmt", "sync", "time"],
                declarations: """
                    type store struct {
                        sync.RWMutex
                        m map[string]string
                    }

                    func (s *store) Get(k string) (string, bool) {
                        s.RLock()
                        defer s.RUnlock()
                        v, ok := s.m[k]
                        return v, ok
                    }

                    func (s *store) Set(k, v string) {
                        s.Lock()
                        defer s.Unlock()
                        s.m[k] = v
                    }

                    type shard struct {
                        mu sync.RWMutex
                        n  int
                    }

                    type gate struct {
                        sync.Mutex
                        open bool
                    }

                    type tally struct{ log []string }

                    func (t *tally) Lock()   { t.log = append(t.log, "lock") }
                    func (t *tally) Unlock() { t.log = append(t.log, "unlock") }

                    func locked(l sync.Locker, f func()) {
                        l.Lock()
                        defer l.Unlock()
                        f()
                    }
                    """)
                == """
                [lock unlock lock unlock]
                true
                *sync.Cond *sync.rlocker func() func(sync.Locker) *sync.Cond

                """)
    }

    /// The first error of Go's compiler for a call that does not fit, a value
    /// where a pointer is wanted, and a field the library keeps to itself.
    @Test func misuseAndWrongCallsAreReportedAsGoReportsThem() {
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                mu.RLock(1)
                """,
                imports: ["fmt", "sync", "time"])
                == "8:10: too many arguments in call to mu.RLock\n\thave (number)\n\twant ()")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                x := mu.Lock()
                _ = x
                """,
                imports: ["fmt", "sync", "time"])
                == "8:6: mu.Lock() (no value) used as value")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                var b int = mu.TryLock()
                _ = b
                """,
                imports: ["fmt", "sync", "time"])
                == "8:13: cannot use mu.TryLock() (value of type bool) as int value in variable declaration")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                var l sync.Locker = mu
                _ = l
                """,
                imports: ["fmt", "sync", "time"])
                == "8:21: cannot use mu (variable of struct type \"sync\".RWMutex) as \"sync\".Locker value in variable declaration: \"sync\".RWMutex does not implement \"sync\".Locker (method Lock has pointer receiver)")
        #expect(
            firstError(
                """
                var mu sync.Mutex
                var l sync.Locker = mu
                _ = l
                """,
                imports: ["fmt", "sync", "time"])
                == "8:21: cannot use mu (variable of struct type \"sync\".Mutex) as \"sync\".Locker value in variable declaration: \"sync\".Mutex does not implement \"sync\".Locker (method Lock has pointer receiver)")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                mu.Foo()
                """,
                imports: ["fmt", "sync", "time"])
                == "8:4: mu.Foo undefined (type \"sync\".RWMutex has no field or method Foo)")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                _ = mu.w
                """,
                imports: ["fmt", "sync", "time"])
                == "8:8: mu.w undefined (cannot refer to unexported field w)")
        #expect(
            firstError("_ = sync.RWMutex{w: 1}", imports: ["fmt", "sync", "time"])
                == "7:18: cannot refer to unexported field w in struct literal of type \"sync\".RWMutex")
        #expect(
            firstError(
                """
                m := map[string]sync.RWMutex{}
                m["a"].Lock()
                """,
                imports: ["fmt", "sync", "time"])
                == "8:8: cannot call pointer method Lock on \"sync\".RWMutex")
        #expect(
            firstError(
                """
                var mu sync.Mutex
                mu.TryLock(1)
                """,
                imports: ["fmt", "sync", "time"])
                == "8:12: too many arguments in call to mu.TryLock\n\thave (number)\n\twant ()")
        #expect(
            firstError(
                """
                var mu sync.Mutex
                var s string = mu.TryLock()
                _ = s
                """,
                imports: ["fmt", "sync", "time"])
                == "8:16: cannot use mu.TryLock() (value of type bool) as string value in variable declaration")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                var l sync.Locker = &mu
                l.RLock()
                """,
                imports: ["fmt", "sync", "time"])
                == "9:3: l.RLock undefined (type \"sync\".Locker has no field or method RLock)")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                x := sync.RWMutex
                _, _ = x, mu
                """,
                imports: ["fmt", "sync", "time"])
                == "8:6: sync.RWMutex (type) is not an expression")
        #expect(
            firstError(
                """
                var c sync.Cond
                c.Wait(1)
                """,
                imports: ["fmt", "sync", "time"])
                == "8:8: too many arguments in call to c.Wait\n\thave (number)\n\twant ()")
        #expect(
            firstError(
                """
                c := sync.NewCond()
                _ = c
                """,
                imports: ["fmt", "sync", "time"])
                == "7:6: not enough arguments in call to sync.NewCond\n\thave ()\n\twant (\"sync\".Locker)")
        #expect(
            firstError(
                """
                c := sync.NewCond(1)
                _ = c
                """,
                imports: ["fmt", "sync", "time"])
                == "7:19: cannot use 1 (constant of type int) as \"sync\".Locker value in argument to sync.NewCond: int does not implement \"sync\".Locker (missing method Lock)")
        #expect(
            firstError(
                """
                var mu sync.RWMutex
                c := sync.NewCond(mu)
                _ = c
                """,
                imports: ["fmt", "sync", "time"])
                == "8:19: cannot use mu (variable of struct type \"sync\".RWMutex) as \"sync\".Locker value in argument to sync.NewCond: \"sync\".RWMutex does not implement \"sync\".Locker (method Lock has pointer receiver)")
    }

    /// Go's runtime ends the program with `fatal error:` and the name of the
    /// mistake. No deferred call runs and `recover` does not see it. A lock the one
    /// goroutine there is takes twice waits for ever.
    @Test func unlockingALockThatIsNotLockedEndsTheProgram() {
        func outcome(_ body: String) -> String {
            do {
                return try runGoMain(body, imports: ["fmt", "sync"])
            } catch {
                return String(describing: error)
            }
        }
        #expect(
            outcome(
                "var mu sync.RWMutex\nmu.RUnlock()")
                == "fatal error: sync: RUnlock of unlocked RWMutex")
        #expect(
            outcome(
                "var mu sync.RWMutex\nmu.Unlock()")
                == "fatal error: sync: Unlock of unlocked RWMutex")
        #expect(
            outcome(
                "var mu sync.RWMutex\nmu.RLock()\nmu.Unlock()")
                == "fatal error: sync: Unlock of unlocked RWMutex")
        #expect(
            outcome(
                "var mu sync.RWMutex\nmu.Lock()\nmu.RUnlock()")
                == "fatal error: sync: RUnlock of unlocked RWMutex")
        #expect(
            outcome(
                "var mu sync.RWMutex\ndefer func() { fmt.Println(recover()) }()\nmu.Unlock()")
                == "fatal error: sync: Unlock of unlocked RWMutex")
        #expect(
            outcome(
                "var mu sync.RWMutex\nmu.Lock()\nmu.RLock()")
                == "fatal error: all goroutines are asleep - deadlock!")
    }

    /// An aliased import and a dot import of `sync`, alias declarations, types
    /// declared in a function, two packages of one module, package-level variables,
    /// and literals that capture a lock: what Go prints for the module.
    @Test func everyPassSeesTheLocks() throws {
        let file0 = #"""
            package main

            import (
                "fmt"
                sy "sync"
                . "sync"

                "example/m/lib"
            )

            type RW = sy.RWMutex
            type Lk = sy.Locker

            type table struct {
                RW
                rows []string
            }

            var global RWMutex
            var lockers = []Locker{&global, global.RLocker(), new(Mutex)}

            func main() {
                st := lib.New()
                fmt.Println(st.Add("a", 2), st.Add("a", 3))
                st.RLock()
                fmt.Println(st.TryLock(), st.TryRLock(), len(st.M))
                st.RUnlock()
                st.RUnlock()

                var g lib.Guard
                g.P = &g.V
                g.L = g.P
                g.P.Lock()
                fmt.Println(g.V.TryRLock(), g.Try(), g.Try())
                g.L.Unlock()
                lib.Locked(&g.V, func() { fmt.Println("in", g.V.TryLock()) })
                lib.Locked(lib.Reader(), func() { fmt.Println("reading", lib.Global.TryLock(), lib.Global.TryRLock()) })
                lib.Global.RUnlock()
                fmt.Printf("%T %T %v\n", g, g.L, lib.Global)

                type local struct {
                    mu RW
                    n  int
                }
                type localRW RWMutex
                var x local
                x.mu.Lock()
                inc := func() {
                    x.n++
                    x.mu.Unlock()
                }
                inc()
                fmt.Println(x.n, x.mu.TryLock())
                fmt.Printf("%T %v\n", x, x)
                var y localRW
                fmt.Printf("%T %v\n", y, y)

                t := &table{}
                var l Lk = t
                l.Lock()
                t.rows = append(t.rows, "r")
                l.Unlock()
                fmt.Printf("%T %d %v\n", l, len(t.rows), t.TryLock())

                for i, l := range lockers {
                    l.Lock()
                    fmt.Printf("%d %T\n", i, l)
                    l.Unlock()
                }
                var wg WaitGroup
                var mu RW
                total := 0
                for i := 1; i <= 10; i++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        defer mu.Unlock()
                        mu.Lock()
                        total += i
                    }()
                }
                wg.Wait()
                fmt.Println(total)
                fns := []func(){mu.Lock, mu.Unlock, mu.RLock, mu.RUnlock}
                for _, f := range fns {
                    f()
                }
                tries := map[string]func() bool{"w": mu.TryLock, "r": mu.TryRLock}
                fmt.Println(tries["w"](), tries["r"](), tries["w"]())
                mu.Unlock()
                rl := mu.RLocker
                fmt.Printf("%T %T\n", rl, rl())
                started := make(chan bool)
                go func() {
                    defer close(started)
                    mu.RLock()
                }()
                <-started
                defer fmt.Println("released")
                defer mu.RUnlock()
            }
            """#
        let file1 = """
            package lib

            import (
                s "sync"
            )

            // Store is a map guarded by a lock it embeds.
            type Store struct {
                s.RWMutex
                M map[string]int
            }

            // Guard holds a lock by pointer and by value.
            type Guard struct {
                P *s.RWMutex
                V s.RWMutex
                L s.Locker
                m s.Mutex
            }

            func New() *Store { return &Store{M: map[string]int{}} }

            func (st *Store) Add(k string, n int) int {
                st.Lock()
                defer st.Unlock()
                st.M[k] += n
                return st.M[k]
            }

            func (g *Guard) Try() bool { return g.m.TryLock() }

            func Locked(l s.Locker, f func()) {
                l.Lock()
                defer l.Unlock()
                f()
            }

            var Global s.RWMutex

            func Reader() s.Locker { return Global.RLocker() }
            """
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m",
                    sources: [GoSourceFile(path: "/m/main.go", text: file0 + "\n")]),
                GoPackageSource(
                    importPath: "example/m/lib",
                    sources: [GoSourceFile(path: "/m/lib/lib.go", text: file1 + "\n")]),
            ], root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(
            output
                == """
                2 5
                false true 1
                false true false
                in false
                reading false true
                lib.Guard *sync.RWMutex {{{} {0 0}} 0 0 {{} 0} {{} 0}}
                1 true
                main.local {{{{} {1 0}} 0 0 {{} -1073741824} {{} 0}} 1}
                main.localRW {{{} {0 0}} 0 0 {{} 0} {{} 0}}
                *main.table 1 true
                0 *sync.RWMutex
                1 *sync.rlocker
                2 *sync.Mutex
                55
                true false false
                func() sync.Locker *sync.rlocker
                released

                """)
    }

    /// The methods of the struct types are functions of the VM and no part of
    /// an image, and a struct that embeds a `sync.Mutex` is lent no function for
    /// `TryLock`: the image of a program that calls none of them names none.
    @Test func aProgramThatTriesNoLockIsTheImageItWas() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    "g := &gate{}\ng.Lock()\ndefer g.Unlock()\nfmt.Println(g.open)",
                    imports: ["fmt", "sync"],
                    declarations: "type gate struct {\n    sync.Mutex\n    open bool\n}"))
        ])
        let names = executable.functions.map(\.name)
        #expect(names.contains("*gate.Lock"))
        #expect(!names.contains { $0.hasSuffix("TryLock") })
        #expect(GoStandardLibrary.isNativeCallName("$sync.RWMutex.RLock"))
        #expect(!GoStandardLibrary.isNativeCallName("$sync.RWMutex.Close"))
    }
}
