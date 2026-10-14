// Holds the text of log to Go's log: the header of a line at random
// instants against time's own formatting, and every function of a Logger
// against Go's Logger on one writer each, with the date and time off.
package main

import (
	"bytes"
	"fmt"
	golog "log"
	"math/rand"
	"os"
	"strings"
	"time"

	"example/harness/log"
)

var failures int

func fail(format string, args ...any) {
	failures++
	if failures <= 20 {
		fmt.Printf(format+"\n", args...)
	}
}

func recovered(f func()) (r any) {
	defer func() { r = recover() }()
	f()
	return nil
}

func main() {
	random := rand.New(rand.NewSource(1))
	// Dates from year 1 to 9999, and every flag combination.
	for i := 0; i < 400000; i++ {
		sec := random.Int63n(253402300800+62135596800) - 62135596800
		if i < 2000 {
			sec = int64(i-1000) * 43201
		}
		nsec := random.Int63n(1000000000)
		flag := random.Intn(128) &^ (golog.Lshortfile | golog.Llongfile)
		at := time.Unix(sec, nsec).UTC()
		want := ""
		if flag&golog.Lmsgprefix == 0 {
			want = "pre "
		}
		if flag&golog.Ldate != 0 {
			want += at.Format("2006/01/02 ")
		}
		if flag&golog.Lmicroseconds != 0 {
			want += at.Format("15:04:05.000000 ")
		} else if flag&golog.Ltime != 0 {
			want += at.Format("15:04:05 ")
		}
		if flag&golog.Lmsgprefix != 0 {
			want += "pre "
		}
		if got := log.Header("pre ", flag, sec, nsec); got != want {
			fail("header(%d, %d, %d) = %q, want %q", flag, sec, nsec, got, want)
		}
	}
	// Go's own header at this instant, in UTC, is the one the text makes.
	var line bytes.Buffer
	real := golog.New(&line, "p ", golog.LstdFlags|golog.Lmicroseconds|golog.LUTC)
	before := time.Now()
	real.Print("x")
	stamp, err := time.Parse("2006/01/02 15:04:05.000000", strings.TrimSuffix(strings.TrimPrefix(line.String(), "p "), " x\n"))
	if err != nil || stamp.Before(before.Add(-time.Second)) || stamp.After(before.Add(time.Second)) {
		fail("Go's line %q is not in the layout the text is held to", line.String())
	} else if got := log.Header("p ", golog.LstdFlags|golog.Lmicroseconds|golog.LUTC, stamp.Unix(), int64(stamp.Nanosecond())) + "x\n"; got != line.String() {
		fail("header at Go's instant: %q, Go wrote %q", got, line.String())
	}

	// The same calls on both loggers.
	var mine, gos bytes.Buffer
	a, b := log.New(&mine, "", 0), golog.New(&gos, "", 0)
	words := []any{"a", "b\n", "", 1, 2, 3.5, true, nil, []int{1}, "%d"}
	for i := 0; i < 20000; i++ {
		args := make([]any, random.Intn(4))
		for j := range args {
			args[j] = words[random.Intn(len(words))]
		}
		format := []string{"%v %v", "x\n", "", "%d|%s", "%q\n\n"}[random.Intn(5)]
		var ra, rb any
		switch random.Intn(12) {
		case 0:
			a.Print(args...)
			b.Print(args...)
		case 1:
			a.Println(args...)
			b.Println(args...)
		case 2:
			a.Printf(format, args...)
			b.Printf(format, args...)
		case 3:
			ra, rb = recovered(func() { a.Panic(args...) }), recovered(func() { b.Panic(args...) })
		case 4:
			ra, rb = recovered(func() { a.Panicln(args...) }), recovered(func() { b.Panicln(args...) })
		case 5:
			ra, rb = recovered(func() { a.Panicf(format, args...) }), recovered(func() { b.Panicf(format, args...) })
		case 6:
			prefix := []string{"", "p: ", "[x] "}[random.Intn(3)]
			a.SetPrefix(prefix)
			b.SetPrefix(prefix)
		case 7:
			flag := []int{0, golog.Lmsgprefix, golog.LUTC}[random.Intn(3)]
			a.SetFlags(flag)
			b.SetFlags(flag)
		case 8:
			ra, rb = a.Output(1, format), b.Output(1, format)
		case 9:
			ra, rb = a.Prefix(), b.Prefix()
		case 10:
			ra, rb = a.Flags(), b.Flags()
		case 11:
			ra, rb = a.Writer() == &mine, b.Writer() == &gos
		}
		if ra != rb {
			fail("step %d: %v, Go %v", i, ra, rb)
		}
		if mine.String() != gos.String() {
			fail("step %d wrote %q, Go %q", i, mine.String(), gos.String())
		}
		mine.Reset()
		gos.Reset()
	}
	for name, pair := range map[string][2]int{
		"Ldate": {log.Ldate, golog.Ldate}, "Ltime": {log.Ltime, golog.Ltime},
		"Lmicroseconds": {log.Lmicroseconds, golog.Lmicroseconds}, "Llongfile": {log.Llongfile, golog.Llongfile},
		"Lshortfile": {log.Lshortfile, golog.Lshortfile}, "LUTC": {log.LUTC, golog.LUTC},
		"Lmsgprefix": {log.Lmsgprefix, golog.Lmsgprefix}, "LstdFlags": {log.LstdFlags, golog.LstdFlags},
	} {
		if pair[0] != pair[1] {
			fail("%s = %d, Go %d", name, pair[0], pair[1])
		}
	}
	// The functions of the package, through the standard logger.
	log.SetOutput(&mine)
	golog.SetOutput(&gos)
	log.SetFlags(log.Lmsgprefix)
	golog.SetFlags(golog.Lmsgprefix)
	log.SetPrefix("std ")
	golog.SetPrefix("std ")
	log.Print("a", 1)
	golog.Print("a", 1)
	log.Println("b", 2)
	golog.Println("b", 2)
	log.Printf("c%d", 3)
	golog.Printf("c%d", 3)
	log.Output(1, "d")
	golog.Output(1, "d")
	for _, f := range [][2]func(){
		{func() { log.Panic("e") }, func() { golog.Panic("e") }},
		{func() { log.Panicln("f") }, func() { golog.Panicln("f") }},
		{func() { log.Panicf("g%d", 1) }, func() { golog.Panicf("g%d", 1) }},
	} {
		if ra, rb := recovered(f[0]), recovered(f[1]); ra != rb {
			fail("panic value %q, Go %q", ra, rb)
		}
	}
	if mine.String() != gos.String() || log.Flags() != golog.Flags() || log.Prefix() != golog.Prefix() ||
		log.Writer() != &mine || log.Default().Prefix() != "std " {
		fail("standard logger wrote %q, Go %q", mine.String(), gos.String())
	}
	if failures > 0 {
		fmt.Println(failures, "differences")
		os.Exit(1)
	}
	fmt.Println("log: the text and Go agree")
}
