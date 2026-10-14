// Package log is Go's log, written in Go: a Logger formats a line, with the
// prefix and the date and time its flags ask for, and passes it to its
// writer in one Write. The functions of the package are the methods of the
// standard logger, which writes to standard error.
//
// Two things differ from Go. The run-time knows no time zone, so the local
// time a line shows is UTC, with or without LUTC. And it cannot say where a
// function was called from, so Lshortfile and Llongfile print what Go
// prints when it cannot say either: ???:0.
package log

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// The flags say what a Logger writes before each message.
const (
	Ldate         = 1  // the date: 2009/01/23
	Ltime         = 2  // the time: 01:23:23
	Lmicroseconds = 4  // microseconds after the time: 01:23:23.123123
	Llongfile     = 8  // full file name and line number
	Lshortfile    = 16 // final file name element and line number
	LUTC          = 32 // the date and time in UTC rather than local time
	Lmsgprefix    = 64 // the prefix before the message, not before the line
	LstdFlags     = 3  // what the standard logger starts with: Ldate | Ltime
)

// A Logger writes lines to a writer. Each call makes one Write, and calls
// from several goroutines do not interleave.
type Logger struct {
	mu     sync.Mutex // held while a line is written, and while out changes
	prefix string
	flag   int
	out    io.Writer
}

// standardError is the writer of the standard logger. The *os.File of the
// run-time is no io.Writer, so this type gives standard error the method.
type standardError struct{}

func (standardError) Write(p []byte) (int, error) { return os.Stderr.Write(p) }

var std = New(standardError{}, "", LstdFlags)

// New returns a Logger that writes to out, with prefix before each line,
// or before each message under Lmsgprefix, and with the flags of flag.
func New(out io.Writer, prefix string, flag int) *Logger {
	return &Logger{prefix: prefix, flag: flag, out: out}
}

// Default returns the standard logger, which the functions of the package
// write through.
func Default() *Logger { return std }

// header is what comes before the message of a line written at now.
func header(prefix string, flag int, now time.Time) string {
	h := ""
	if flag&Lmsgprefix == 0 {
		h = prefix
	}
	if flag&Ldate != 0 {
		h += now.Format("2006/01/02 ")
	}
	if flag&(Ltime|Lmicroseconds) != 0 {
		if flag&Lmicroseconds != 0 {
			h += now.Format("15:04:05.000000 ")
		} else {
			h += now.Format("15:04:05 ")
		}
	}
	if flag&(Lshortfile|Llongfile) != 0 {
		h += "???:0: "
	}
	if flag&Lmsgprefix != 0 {
		h += prefix
	}
	return h
}

// Output writes s as one line of the log, with a newline after it if it
// does not end in one. calldepth would say whose file and line to print.
func (l *Logger) Output(calldepth int, s string) error {
	var now time.Time
	// The time is read before the lock is waited for, as in Go.
	if l.flag&(Ldate|Ltime|Lmicroseconds) != 0 {
		now = time.Now()
	}
	line := header(l.prefix, l.flag, now) + s
	if len(s) == 0 || s[len(s)-1] != '\n' {
		line += "\n"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	_, err := l.out.Write([]byte(line))
	return err
}

// Print writes its operands as fmt.Print does.
func (l *Logger) Print(v ...any) { l.Output(2, fmt.Sprint(v...)) }

// Printf writes its operands as fmt.Printf does.
func (l *Logger) Printf(format string, v ...any) { l.Output(2, fmt.Sprintf(format, v...)) }

// Println writes its operands as fmt.Println does.
func (l *Logger) Println(v ...any) { l.Output(2, fmt.Sprintln(v...)) }

// Fatal is Print and then os.Exit(1).
func (l *Logger) Fatal(v ...any) {
	l.Output(2, fmt.Sprint(v...))
	os.Exit(1)
}

// Fatalf is Printf and then os.Exit(1).
func (l *Logger) Fatalf(format string, v ...any) {
	l.Output(2, fmt.Sprintf(format, v...))
	os.Exit(1)
}

// Fatalln is Println and then os.Exit(1).
func (l *Logger) Fatalln(v ...any) {
	l.Output(2, fmt.Sprintln(v...))
	os.Exit(1)
}

// Panic is Print and then a panic with the message.
func (l *Logger) Panic(v ...any) {
	s := fmt.Sprint(v...)
	l.Output(2, s)
	panic(s)
}

// Panicf is Printf and then a panic with the message.
func (l *Logger) Panicf(format string, v ...any) {
	s := fmt.Sprintf(format, v...)
	l.Output(2, s)
	panic(s)
}

// Panicln is Println and then a panic with the message.
func (l *Logger) Panicln(v ...any) {
	s := fmt.Sprintln(v...)
	l.Output(2, s)
	panic(s)
}

// Flags returns the flags of the logger.
func (l *Logger) Flags() int { return l.flag }

// SetFlags sets the flags of the logger.
func (l *Logger) SetFlags(flag int) { l.flag = flag }

// Prefix returns the prefix of the logger.
func (l *Logger) Prefix() string { return l.prefix }

// SetPrefix sets the prefix of the logger.
func (l *Logger) SetPrefix(prefix string) { l.prefix = prefix }

// Writer returns what the logger writes to.
func (l *Logger) Writer() io.Writer {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.out
}

// SetOutput sets what the logger writes to.
func (l *Logger) SetOutput(w io.Writer) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.out = w
}

// SetOutput sets what the standard logger writes to.
func SetOutput(w io.Writer) { std.SetOutput(w) }

// Flags returns the flags of the standard logger.
func Flags() int { return std.Flags() }

// SetFlags sets the flags of the standard logger.
func SetFlags(flag int) { std.SetFlags(flag) }

// Prefix returns the prefix of the standard logger.
func Prefix() string { return std.Prefix() }

// SetPrefix sets the prefix of the standard logger.
func SetPrefix(prefix string) { std.SetPrefix(prefix) }

// Writer returns what the standard logger writes to.
func Writer() io.Writer { return std.Writer() }

// Output writes s as one line of the standard logger.
func Output(calldepth int, s string) error { return std.Output(calldepth+1, s) }

// Print writes to the standard logger as fmt.Print does.
func Print(v ...any) { std.Output(2, fmt.Sprint(v...)) }

// Printf writes to the standard logger as fmt.Printf does.
func Printf(format string, v ...any) { std.Output(2, fmt.Sprintf(format, v...)) }

// Println writes to the standard logger as fmt.Println does.
func Println(v ...any) { std.Output(2, fmt.Sprintln(v...)) }

// Fatal is Print and then os.Exit(1).
func Fatal(v ...any) {
	std.Output(2, fmt.Sprint(v...))
	os.Exit(1)
}

// Fatalf is Printf and then os.Exit(1).
func Fatalf(format string, v ...any) {
	std.Output(2, fmt.Sprintf(format, v...))
	os.Exit(1)
}

// Fatalln is Println and then os.Exit(1).
func Fatalln(v ...any) {
	std.Output(2, fmt.Sprintln(v...))
	os.Exit(1)
}

// Panic is Print and then a panic with the message.
func Panic(v ...any) {
	s := fmt.Sprint(v...)
	std.Output(2, s)
	panic(s)
}

// Panicf is Printf and then a panic with the message.
func Panicf(format string, v ...any) {
	s := fmt.Sprintf(format, v...)
	std.Output(2, s)
	panic(s)
}

// Panicln is Println and then a panic with the message.
func Panicln(v ...any) {
	s := fmt.Sprintln(v...)
	std.Output(2, s)
	panic(s)
}
