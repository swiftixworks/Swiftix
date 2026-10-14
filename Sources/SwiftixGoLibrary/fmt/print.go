// Package fmt is the part of fmt that is written in Go: the interfaces a
// value implements to choose how it prints. The printing functions belong to
// the run-time library, which calls String, GoString, and Format of the
// program's types as Go's fmt does. The State it gives Format is a value of
// its own, *fmt.pp.
package fmt

// State is what a Format method writes to, and how it learns the flags,
// width, and precision of the verb it formats for.
type State interface {
	// Write is how Format prints.
	Write(b []byte) (n int, err error)
	// Width returns the width and whether one was given.
	Width() (wid int, ok bool)
	// Precision returns the precision and whether one was given.
	Precision() (prec int, ok bool)
	// Flag reports whether the flag c, a character, was given.
	Flag(c int) bool
}

// Formatter is implemented by a value that formats itself under every verb.
type Formatter interface {
	Format(f State, verb rune)
}

// Stringer is implemented by a value that has a String method, which
// prints it under the verbs for text and in Print.
type Stringer interface {
	String() string
}

// GoStringer is implemented by a value that has a GoString method, which
// prints it under %#v.
type GoStringer interface {
	GoString() string
}
