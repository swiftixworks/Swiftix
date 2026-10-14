/// Go's `flag`, written in Go for the library: flag sets, every kind of
/// flag, values of the program's types, `Func` and `BoolFunc`, the usage
/// text with its defaults, and what parsing does with a bad flag under
/// `ContinueOnError` and `ExitOnError`.
///
/// What each program prints is what Go 1.24.5 printed for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go flag")
struct GoFlagTests: GoTestHarness {

    /// Every kind of flag in a set that continues on an error, its errors
    /// and usage text, and the command line after `os.Args` is assigned.
    @Test func flagSetsParseAndReportAsGosDo() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: flagSetsSource)
        ])
        var output = ""
        try GoVirtualMachine().run(executable, arguments: ["flags"]) { output += $0 }
        #expect(output == flagSetsExpected)
    }

    /// `TextVar`, a usage function of the program, and a bad flag on the
    /// command line: the usage goes to standard error and `go run` reports
    /// the program's status 2.
    @Test func theCommandLineExitsOnAnError() {
        let output = runShell(
            ["cd /flags", "GOCACHE=off go run .", "echo status=$?"],
            seed: { context in
                _ = context.mkdir("/flags")
                Self.write(context, path: "/flags/go.mod", contents: "module example/flags\n\ngo 1.24\n")
                Self.write(context, path: "/flags/main.go", contents: commandLineSource)
            })
        #expect(output.contains(commandLineExpected))
        #expect(output.contains("status=1"))
    }
}

private let flagSetsSource = #"""
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

type listValue []string

func (l *listValue) String() string { return strings.Join(*l, ",") }
func (l *listValue) Set(s string) error {
	if s == "" {
		return errors.New("empty item")
	}
	*l = append(*l, s)
	return nil
}

type level int

func (l *level) String() string { return fmt.Sprint(int(*l)) }
func (l *level) Set(s string) error {
	switch s {
	case "debug":
		*l = 0
	case "info":
		*l = 1
	default:
		return fmt.Errorf("unknown level %q", s)
	}
	return nil
}

func parse(args ...string) {
	fs := flag.NewFlagSet("server", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	port := fs.Int("port", 6379, "the `port` to listen on")
	host := fs.String("host", "127.0.0.1", "address to bind")
	verbose := fs.Bool("v", false, "verbose output")
	timeout := fs.Duration("timeout", 30*time.Second, "idle timeout")
	ratio := fs.Float64("ratio", 0.5, "sample ratio")
	big := fs.Uint64("max", 1<<20, "max bytes")
	var peers listValue
	fs.Var(&peers, "peer", "a peer (repeatable)")
	var lvl level = 1
	fs.Var(&lvl, "level", "log level")
	var seen []string
	fs.Func("tag", "add a tag", func(s string) error {
		seen = append(seen, s)
		return nil
	})
	fs.BoolFunc("trace", "turn tracing on", func(s string) error {
		seen = append(seen, "trace="+s)
		return nil
	})
	err := fs.Parse(args)
	fmt.Printf("err=%v port=%d host=%s v=%v timeout=%v ratio=%v max=%d peers=%v level=%v seen=%v\n",
		err, *port, *host, *verbose, *timeout, *ratio, *big, peers, lvl, seen)
	fmt.Println("args:", fs.Args(), fs.NArg(), fs.Arg(0), fs.NFlag(), fs.Parsed())
	fs.Visit(func(f *flag.Flag) { fmt.Print(f.Name, "=", f.Value, " ") })
	fmt.Println()
	if f := fs.Lookup("port"); f != nil {
		fmt.Println(f.Name, f.DefValue, f.Usage, f.Value.(flag.Getter).Get())
	}
}

func main() {
	parse("-port=7000", "--host", "0.0.0.0", "-v", "-timeout", "1m30s", "-peer", "a", "-peer=b", "-level", "debug", "-tag", "x", "-trace", "rest", "-port", "1")
	parse("-ratio", "abc")
	parse("-nope")
	parse("-port", "99999999999999999999")
	parse("-level", "loud")
	parse("-peer", "")
	parse("-v=maybe")
	parse("-h")
	parse("--", "-port", "5")
	parse("-max", "-1")
	parse("-port")
	fs := flag.NewFlagSet("demo", flag.ContinueOnError)
	fs.SetOutput(os.Stdout)
	fs.String("name", "", "your `name`")
	fs.Int("n", 0, "count")
	fs.Bool("quiet", true, "be quiet")
	fs.Duration("d", 0, "a duration")
	fs.PrintDefaults()
	fmt.Println(fs.Set("n", "3"), fs.Set("zzz", "1"), fs.Lookup("n").Value)
	os.Args = []string{"prog", "-k", "5", "tail"}
	k := flag.Int("k", 1, "k value")
	flag.Parse()
	fmt.Println(*k, flag.Args(), flag.CommandLine.Name() != "", os.Args[1:])
}
"""#

private let flagSetsExpected = #"""
err=<nil> port=7000 host=0.0.0.0 v=true timeout=1m30s ratio=0.5 max=1048576 peers=[a b] level=0 seen=[x trace=true]
args: [rest -port 1] 3 rest 8 true
host=0.0.0.0 level=0 peer=a,b port=7000 tag= timeout=1m30s trace= v=true\#u{20}
port 6379 the `port` to listen on 7000
invalid value "abc" for flag -ratio: parse error
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=invalid value "abc" for flag -ratio: parse error port=6379 host=127.0.0.1 v=false timeout=30s ratio=0 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
flag provided but not defined: -nope
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=flag provided but not defined: -nope port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
invalid value "99999999999999999999" for flag -port: value out of range
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=invalid value "99999999999999999999" for flag -port: value out of range port=9223372036854775807 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 9223372036854775807
invalid value "loud" for flag -level: unknown level "loud"
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=invalid value "loud" for flag -level: unknown level "loud" port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
invalid value "" for flag -peer: empty item
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=invalid value "" for flag -peer: empty item port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
invalid boolean value "maybe" for -v: parse error
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=invalid boolean value "maybe" for -v: parse error port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=flag: help requested port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
err=<nil> port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [-port 5] 2 -port 0 true

port 6379 the `port` to listen on 6379
invalid value "-1" for flag -max: parse error
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=invalid value "-1" for flag -max: parse error port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=0 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
flag needs an argument: -port
Usage of server:
  -host string
    \#taddress to bind (default "127.0.0.1")
  -level value
    \#tlog level (default 1)
  -max uint
    \#tmax bytes (default 1048576)
  -peer value
    \#ta peer (repeatable)
  -port port
    \#tthe port to listen on (default 6379)
  -ratio float
    \#tsample ratio (default 0.5)
  -tag value
    \#tadd a tag
  -timeout duration
    \#tidle timeout (default 30s)
  -trace
    \#tturn tracing on
  -v	verbose output
err=flag needs an argument: -port port=6379 host=127.0.0.1 v=false timeout=30s ratio=0.5 max=1048576 peers=[] level=1 seen=[]
args: [] 0  0 true

port 6379 the `port` to listen on 6379
  -d duration
    \#ta duration
  -n int
    \#tcount
  -name name
    \#tyour name
  -quiet
    \#tbe quiet (default true)
<nil> no such flag -zzz 3
5 [tail] true [-k 5 tail]

"""#

private let commandLineSource = #"""
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

type mode struct{ name string }

func (m mode) MarshalText() ([]byte, error) { return []byte(m.name), nil }
func (m *mode) UnmarshalText(b []byte) error {
	s := string(b)
	if s != "fast" && s != "safe" {
		return fmt.Errorf("bad mode %q", s)
	}
	m.name = s
	return nil
}

func main() {
	var m mode
	flag.TextVar(&m, "mode", mode{"safe"}, "run `mode`")
	n := flag.Int("n", 1, "count")
	flag.Usage = func() {
		fmt.Fprintln(flag.CommandLine.Output(), "usage: tool [flags]")
		flag.PrintDefaults()
	}
	fmt.Println(m.name, *n)
	fs := flag.NewFlagSet("sub", flag.ContinueOnError)
	var out strings.Builder
	fs.SetOutput(&out)
	fs.TextVar(&m, "mode", mode{"safe"}, "run mode")
	fmt.Println(fs.Parse([]string{"-mode", "fast"}), m.name)
	fmt.Println(fs.Parse([]string{"-mode", "slow"}), m.name)
	fmt.Print(out.String())
	os.Args = []string{"tool", "-n", "x"}
	flag.Parse()
	fmt.Println("not reached")
}
"""#

private let commandLineExpected = #"""
safe 1
<nil> fast
invalid value "slow" for flag -mode: bad mode "slow" fast
invalid value "slow" for flag -mode: bad mode "slow"
Usage of sub:
  -mode value
    \#trun mode (default safe)
invalid value "x" for flag -n: parse error
usage: tool [flags]
  -mode mode
    \#trun mode (default safe)
  -n int
    \#tcount (default 1)
exit status 2
"""#
