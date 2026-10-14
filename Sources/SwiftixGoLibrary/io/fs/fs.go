// Package fs is the part of io/fs that the errors of the file system need:
// the errors that say what kind of failure one is, and PathError, which
// says on what path it happened.
package fs

import "errors"

// The kinds of failure of the file system. errors.Is(err, ErrNotExist)
// asks whether err is one: a *PathError holds a syscall.Errno, whose Is
// method answers for these.
var (
	ErrInvalid    = errors.New("invalid argument")
	ErrPermission = errors.New("permission denied")
	ErrExist      = errors.New("file already exists")
	ErrNotExist   = errors.New("file does not exist")
	ErrClosed     = errors.New("file already closed")
)

// A PathError is a failed operation on a path: what was done, to which
// path, and why.
type PathError struct {
	Op   string
	Path string
	Err  error
}

func (e *PathError) Error() string { return e.Op + " " + e.Path + ": " + e.Err.Error() }

func (e *PathError) Unwrap() error { return e.Err }

// Timeout reports whether the error is a timeout, as its Err says.
func (e *PathError) Timeout() bool {
	t, ok := e.Err.(interface{ Timeout() bool })
	return ok && t.Timeout()
}
