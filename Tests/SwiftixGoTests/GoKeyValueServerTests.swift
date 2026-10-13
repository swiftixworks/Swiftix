/// A small key-value server written in Swiftix Go, run end to end over
/// loopback TCP: a map-backed store with expiry, an append-only log replayed
/// at start, and one goroutine per connection.
///
/// This is the consumer that the map, `os` file, wall-clock, and `error`
/// surfaces exist for; it fails when any of them stops fitting the others.
///
/// Concurrency: the fixture builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor. Expiry advances logical time only.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go key-value server")
struct GoKeyValueServerTests {

    static let server = """
        package main
        import "fmt"
        import "io"
        import "net"
        import "os"
        import "strconv"
        import "strings"
        import "time"

        type database struct {
            values  map[string]string
            expires map[string]time.Time
            log     *os.File
        }

        func (db *database) record(fields []string, replaying bool) {
            if replaying || db.log == nil {
                return
            }
            db.log.WriteString(strings.Join(fields, " ") + "\\n")
        }

        func (db *database) expire(key string) {
            deadline, ok := db.expires[key]
            if ok && !time.Now().Before(deadline) {
                delete(db.values, key)
                delete(db.expires, key)
                db.record([]string{"DEL", key}, false)
            }
        }

        func (db *database) apply(fields []string, replaying bool) string {
            command := fields[0]
            if command == "DBSIZE" && len(fields) == 1 {
                return ":" + strconv.Itoa(len(db.values))
            }
            if len(fields) < 2 {
                return "-ERR unknown command '" + command + "'"
            }
            key := fields[1]
            switch command {
            case "SET":
                if len(fields) != 3 {
                    return "-ERR wrong number of arguments"
                }
                db.values[key] = fields[2]
                delete(db.expires, key)
                db.record(fields, replaying)
                return "+OK"
            case "GET":
                db.expire(key)
                value, ok := db.values[key]
                if !ok {
                    return "(nil)"
                }
                return value
            case "DEL":
                _, ok := db.values[key]
                if !ok {
                    return ":0"
                }
                delete(db.values, key)
                delete(db.expires, key)
                db.record(fields, replaying)
                return ":1"
            case "PEXPIRE":
                if len(fields) != 3 {
                    return "-ERR wrong number of arguments"
                }
                milliseconds, err := strconv.Atoi(fields[2])
                if err != nil {
                    return "-ERR value is not an integer"
                }
                _, ok := db.values[key]
                if !ok {
                    return ":0"
                }
                db.expires[key] = time.Now().Add(time.Duration(milliseconds) * time.Millisecond)
                return ":1"
            }
            return "-ERR unknown command '" + command + "'"
        }

        func (db *database) replay(path string) error {
            f, err := os.Open(path)
            if err != nil {
                return nil
            }
            pending := ""
            buffer := make([]byte, 16)
            for {
                n, err := f.Read(buffer)
                pending += string(buffer[:n])
                for {
                    end := strings.Index(pending, "\\n")
                    if end < 0 {
                        break
                    }
                    db.apply(strings.Split(pending[:end], " "), true)
                    pending = pending[end+1:]
                }
                if err == io.EOF {
                    break
                }
                if err != nil {
                    f.Close()
                    return err
                }
            }
            return f.Close()
        }

        func serve(conn net.Conn, db *database, done chan bool) {
            pending := ""
            buffer := make([]byte, 32)
            for {
                n, err := conn.Read(buffer)
                if err != nil {
                    break
                }
                pending += string(buffer[:n])
                for {
                    end := strings.Index(pending, "\\n")
                    if end < 0 {
                        break
                    }
                    line := strings.TrimSpace(pending[:end])
                    pending = pending[end+1:]
                    if line == "QUIT" {
                        conn.Close()
                        return
                    }
                    if line == "SHUTDOWN" {
                        conn.Write([]byte("+BYE\\n"))
                        conn.Close()
                        done <- true
                        return
                    }
                    conn.Write([]byte(db.apply(strings.Split(line, " "), false) + "\\n"))
                }
            }
            conn.Close()
        }

        func accept(listener net.Listener, db *database, done chan bool) {
            for {
                conn, err := listener.Accept()
                if err != nil {
                    return
                }
                go serve(conn, db, done)
            }
        }

        func fail(err error) {
            fmt.Fprintln(os.Stderr, "kvd:", err.Error())
            os.Exit(1)
        }

        func main() {
            var db database
            db.values = map[string]string{}
            db.expires = map[string]time.Time{}
            os.Mkdir("/data", 0o755)
            err := db.replay("/data/kv.aof")
            if err != nil {
                fail(err)
            }
            log, err := os.OpenFile("/data/kv.aof", os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
            if err != nil {
                fail(err)
            }
            db.log = log
            listener, err := net.Listen("tcp", ":6379")
            if err != nil {
                fail(err)
            }
            done := make(chan bool)
            go accept(listener, &db, done)
            <-done
            listener.Close()
            err = log.Close()
            if err != nil {
                fail(err)
            }
        }
        """

    static let client = """
        package main
        import "fmt"
        import "net"
        import "os"

        func main() {
            conn, err := net.Dial("tcp", "127.0.0.1:6379")
            if err != nil {
                fmt.Println("kvc:", err.Error())
                os.Exit(1)
            }
            request := ""
            for i := 1; i < len(os.Args); i++ {
                request += os.Args[i] + "\\n"
            }
            conn.Write([]byte(request + "QUIT\\n"))
            buffer := make([]byte, 32)
            for {
                n, err := conn.Read(buffer)
                if n > 0 {
                    fmt.Print(string(buffer[:n]))
                }
                if err != nil {
                    break
                }
            }
            conn.Close()
        }
        """

    /// A session whose kernel has a loopback interface.
    private func makeSession() throws -> GoProcessSession {
        let session = try GoProcessSession(["/kvd": Self.server, "/kvc": Self.client])
        let kernel = session.kernel
        let loop = session.loop
        kernel.netns.stack.configure(
            .addInterface(
                NetworkInterfaceConfiguration(
                    address: IPv4Address(127, 0, 0, 1),
                    mac: MACAddress("00:00:00:00:00:00")!,
                    prefixLength: 8)))
        let loopback = try #require(kernel.netns.stack.interface(at: 0))
        loopback.onEgress = { [weak kernel, weak loopback] frame in
            guard let kernel, let loopback else { return }
            loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: loopback) }
        }
        return session
    }

    /// What the client printed for `commands`, without the shell's job
    /// notices for the background server.
    private func replies(_ session: GoProcessSession, _ commands: String) -> [String] {
        let output = session.run("/kvc " + commands)
        return output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("[") }
    }

    @Test func servesCommandsExpiresKeysAndReplaysItsLog() throws {
        let session = try makeSession()

        _ = session.run("/kvd &")
        #expect(
            replies(session, "'SET a 1' 'SET b two' 'GET a' 'DEL b' 'GET b' 'PEXPIRE a 500' 'GET a'")
                == ["+OK", "+OK", "1", ":1", "(nil)", ":1", "1"])
        #expect(
            replies(session, "'PEXPIRE a soon' 'PEXPIRE zz 5' 'NOPE x' 'DBSIZE'")
                == ["-ERR value is not an integer", ":0", "-ERR unknown command 'NOPE'", ":1"])

        session.advance(by: 1)
        #expect(
            replies(session, "'GET a' 'SET c 3' 'DBSIZE' 'SHUTDOWN'")
                == ["(nil)", "+OK", ":1", "+BYE"])
        session.advance(by: 1)
        #expect(session.fileText("/data/kv.aof") == "SET a 1\nSET b two\nDEL b\nDEL a\nSET c 3\n")
        #expect(session.fileMode("/data/kv.aof") == 0o600)

        // A second server rebuilds the same state from the log.
        _ = session.run("/kvd &")
        #expect(
            replies(session, "'GET a' 'GET b' 'GET c' 'DBSIZE' 'SET d 4' 'SHUTDOWN'")
                == ["(nil)", "(nil)", "3", ":1", "+OK", "+BYE"])
        session.advance(by: 1)
        #expect(
            session.fileText("/data/kv.aof")
                == "SET a 1\nSET b two\nDEL b\nDEL a\nSET c 3\nSET d 4\n")
    }

    @Test func aClientWithoutAServerIsRefused() throws {
        let session = try makeSession()

        #expect(
            replies(session, "'GET a'")
                == ["kvc: dial tcp 127.0.0.1:6379: connect: connection refused"])
    }
}
