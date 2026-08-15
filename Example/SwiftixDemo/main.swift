// A tiny consumer of the Swiftix library — it plays the "topology + UI" role
// that lives outside the core. It imports Swiftix normally (no @testable), so
// it also serves as a compile-time check that the public API is sufficient to
// build and drive a host from another module.

import Foundation
import Swiftix
import SwiftixGoTool

print("Swiftix demo — version \(Swiftix.version)\n")

// MARK: - Demo 1: wire two hosts together and ping across the link.

func pingDemo() {
    let loop = EventLoop()
    let kernelA = Kernel(loop: loop)
    let kernelB = Kernel(loop: loop)

    kernelA.netns.stack.configure(
        .addInterface(
            NetworkInterfaceConfiguration(
                address: IPv4Address(10, 0, 0, 1),
                mac: MACAddress("02:00:00:00:00:0a")!)))
    kernelB.netns.stack.configure(
        .addInterface(
            NetworkInterfaceConfiguration(
                address: IPv4Address(10, 0, 0, 2),
                mac: MACAddress("02:00:00:00:00:0b")!)))
    guard let ifA = kernelA.netns.stack.interface(at: 0),
        let ifB = kernelB.netns.stack.interface(at: 0)
    else {
        fatalError("demo network interfaces were not configured")
    }

    // The topology role: connect the two interfaces with a one-way latency by
    // scheduling delivery of each egress frame onto the shared event loop.
    let latency = 0.005
    ifA.onEgress = { frame in loop.schedule(after: latency) { kernelB.netns.stack.receive(frame, on: ifB) } }
    ifB.onEgress = { frame in loop.schedule(after: latency) { kernelA.netns.stack.receive(frame, on: ifA) } }

    let target = IPv4Address(10, 0, 0, 2)
    print("PING \(target) (\(target)) 56(84) bytes of data.")
    kernelA.spawn(
        "ping",
        Programs.ping(
            to: target, count: 3,
            onFinish: { stats in
                let loss = stats.transmitted == 0 ? 0 : Double(stats.lost) / Double(stats.transmitted) * 100
                print("")
                print("--- \(target) ping statistics ---")
                print(
                    String(
                        format: "%d packets transmitted, %d received, %.0f%% packet loss, time %dms",
                        stats.transmitted, stats.received, loss, Int(stats.elapsedSeconds * 1000)))
                if let low = stats.minSeconds, let avg = stats.averageSeconds,
                    let high = stats.maxSeconds, let dev = stats.deviationSeconds
                {
                    print(
                        String(
                            format: "rtt min/avg/max/mdev = %.3f/%.3f/%.3f/%.3f ms",
                            low * 1000, avg * 1000, high * 1000, dev * 1000))
                }
            }
        ) { outcome in
            switch outcome {
            case let .reply(from, sequence, ttl, bytes, rtt):
                print(
                    String(
                        format: "%d bytes from %@: icmp_seq=%d ttl=%d time=%.3f ms",
                        bytes, "\(from)", Int(sequence), Int(ttl), rtt * 1000))
            case let .timeout(sequence):
                print("Request timeout for icmp_seq \(sequence)")
            }
        })

    // Three echoes are paced ~1s apart, so the third goes out around t≈2s; drive
    // the loop past that plus the final reply and the statistics summary.
    loop.advance(by: 4.0)
}

// MARK: - Demo 2: run the shell on a pseudo-terminal.

func shellDemo() {
    let loop = EventLoop()
    let kernel = Kernel(loop: loop)
    let pty = PseudoTerminal()

    kernel.spawn("seed-go-demo") { ctx in
        _ = ctx.mkdir("/go-demo")
        let module = ctx.open("/go-demo/go.mod", create: true, truncate: true)!
        ctx.write(module, Array("module example/hello\n\ngo 1.24\n".utf8))
        ctx.close(module)
        let source = ctx.open("/go-demo/main.go", create: true, truncate: true)!
        ctx.write(
            source,
            Array(
                """
                package main
                import "fmt"

                var startup = 1

                type Counter struct { Value int }

                func init() { startup++ }

                func (counter *Counter) Add(delta int) {
                    counter.Value = counter.Value + delta
                }

                func main() {
                    counter := Counter{Value: startup}
                    counter.Add(40)
                    values := []int{1, 2, 3}
                    fmt.Println("Swiftix Go", counter.Value, values[1:len(values)])
                }

                """.utf8))
        ctx.close(source)
        ctx.exit(0)
    }
    loop.runUntilIdle()

    pty.onOutput = { [weak pty] in
        guard let pty else { return }
        FileHandle.standardOutput.write(Data(pty.readForApp(max: 65535)))
    }

    let commands = CommandRegistry.builtins
    GoToolchain.register(in: commands)
    kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: commands))
    loop.runUntilIdle()  // prompt, block on read

    for line in [
        "echo hello from swiftix",
        "which echo",
        "seq 3 | cat",
        "cd /go-demo",
        "go version",
        "go env GOOS GOARCH GOCACHE",
        "gofmt -l .",
        "gofmt -s -w .",
        "go fmt ./...",
        "go run .",
        "go build -o hello .",
        "./hello",
        "go install .",
        "go clean -cache",
        "/home/user/go/bin/go-demo",
        "echo piped through cat | cat",
        "mkdir /data",
        "echo saved > /data/note",
        "echo appended >> /data/note",
        "cat /data/note",
        "head -n 1 /data/note",
        "tail -n 1 /data/note",
        "wc < /data/note",
        "cat /data/note | sort | uniq | nl",
        "stat /data/note",
        "cd /data",
        "pwd",
        "sleep 0 &",
        "jobs",
        "export NAME=swiftix",
        "echo hi $NAME",
        "false",
        "echo status=$?",
        "help",
        "nope",
    ] {
        pty.writeFromApp(Array((line + "\n").utf8))
        loop.runUntilIdle()
    }
}

print("== ping demo ==")
pingDemo()
print("\n== shell demo ==")
shellDemo()

print("\ndone.")
