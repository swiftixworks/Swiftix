/// `os/signal`, `os.Signal`, `os.Process`, and `syscall`'s signals: a
/// program that asks for a signal receives it on its channel, never
/// blocking the delivery; `Ignore`, `Ignored`, `Stop`, `Reset`, and
/// `NotifyContext` are Go's; and a signal the program does not handle ends
/// it as it ends a process of Go's, which `go run` reports and a shell
/// sees in the status of the image run as a process.
///
/// The program sends its signals to itself. What it prints is what Go
/// 1.24.5 printed for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go os/signal")
struct GoSignalTests: GoTestHarness {
    @Test func aProgramReceivesIgnoresAndDiesOfSignals() {
        let output = runShell(
            [
                "cd /signals", "GOCACHE=off go run .", "echo status=$?", "go build -o app .", "./app",
                "echo app=$?",
            ],
            advancing: 2,
            seed: { context in
                _ = context.mkdir("/signals")
                Self.write(context, path: "/signals/go.mod", contents: "module example/signals\n\ngo 1.24\n")
                Self.write(context, path: "/signals/main.go", contents: signalsSource)
            })
        #expect(output.contains(signalsExpected))
        #expect(output.contains("status=1"))
        // Run as a process of its own, the image dies of the signal, and the
        // shell sees 128 plus its number, as for a binary of Go's.
        #expect(output.contains("app=143"))
    }
}

private let signalsSource = #"""
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

func main() {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, os.Interrupt)
	fmt.Println(os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGKILL, os.Kill)
	fmt.Println(signal.Ignored(syscall.SIGHUP))

	var wg sync.WaitGroup
	done := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-done:
				fmt.Println("worker: stopping")
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}()

	p, _ := os.FindProcess(os.Getpid())
	time.Sleep(25 * time.Millisecond)
	p.Signal(syscall.SIGTERM)
	s := <-sigs
	fmt.Println("got", s, s == syscall.SIGTERM)
	close(done)
	wg.Wait()

	syscall.Kill(syscall.Getpid(), syscall.SIGINT)
	fmt.Println("got", <-sigs)

	signal.Ignore(syscall.SIGHUP)
	fmt.Println(signal.Ignored(syscall.SIGHUP))
	syscall.Kill(os.Getpid(), syscall.SIGHUP)
	time.Sleep(10 * time.Millisecond)
	select {
	case s := <-sigs:
		fmt.Println("unexpected", s)
	default:
		fmt.Println("hangup ignored")
	}

	all := make(chan os.Signal, 4)
	signal.Notify(all)
	syscall.Kill(os.Getpid(), syscall.SIGUSR1)
	fmt.Println("all got", <-all)
	signal.Stop(all)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGUSR2)
	fmt.Println(ctx)
	syscall.Kill(os.Getpid(), syscall.SIGUSR2)
	<-ctx.Done()
	fmt.Println("ctx:", ctx.Err())
	stop()

	signal.Reset(syscall.SIGTERM)
	defer fmt.Println("never printed")
	syscall.Kill(os.Getpid(), syscall.SIGTERM)
	time.Sleep(time.Second)
	fmt.Println("not reached")
}
"""#

private let signalsExpected = #"""
interrupt terminated hangup killed killed
false
got terminated true
worker: stopping
got interrupt
true
hangup ignored
all got user defined signal 1
signal.NotifyContext(context.Background, [user defined signal 2])
ctx: context canceled
signal: terminated
"""#
