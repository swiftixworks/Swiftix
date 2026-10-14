// Package os is the part of os that is written in Go: its errors, and the
// functions of the file system, which give them. The files themselves, the
// standard streams, the environment, and the process belong to the run-time
// library, which this file imports under the same path.
package os

import (
	"errors"
	"io/fs"
	"syscall"
)

// The kinds of failure of the file system, which are those of io/fs.
var (
	ErrInvalid    = fs.ErrInvalid
	ErrPermission = fs.ErrPermission
	ErrExist      = fs.ErrExist
	ErrNotExist   = fs.ErrNotExist
	ErrClosed     = fs.ErrClosed
)

// PathError is the error of an operation on a path.
type PathError = fs.PathError

// A LinkError is a failed operation on two paths, such as a rename.
type LinkError struct {
	Op  string
	Old string
	New string
	Err error
}

func (e *LinkError) Error() string { return e.Op + " " + e.Old + " " + e.New + ": " + e.Err.Error() }

func (e *LinkError) Unwrap() error { return e.Err }

// IsExist reports whether err says that a file already exists. Unlike
// errors.Is, it looks only inside a *PathError or a *LinkError.
func IsExist(err error) bool { return underlyingErrorIs(err, ErrExist) }

// IsNotExist reports whether err says that a file does not exist.
func IsNotExist(err error) bool { return underlyingErrorIs(err, ErrNotExist) }

// IsPermission reports whether err says that permission was denied.
func IsPermission(err error) bool { return underlyingErrorIs(err, ErrPermission) }

// IsTimeout reports whether err says that an operation ran out of time.
func IsTimeout(err error) bool {
	t, ok := underlyingError(err).(interface{ Timeout() bool })
	return ok && t.Timeout()
}

func underlyingErrorIs(err, target error) bool {
	err = underlyingError(err)
	if err == target {
		return true
	}
	e, ok := err.(syscall.Errno)
	return ok && e.Is(target)
}

// underlyingError is the error a *PathError or a *LinkError holds, or err.
func underlyingError(err error) error {
	switch err := err.(type) {
	case *PathError:
		return err.Err
	case *LinkError:
		return err.Err
	}
	return err
}

// errno is the error whose text is why: the syscall.Errno that says it,
// ErrClosed for a file used after Close, or a new error.
func errno(why string) error {
	if why == ErrClosed.Error() {
		return ErrClosed
	}
	for e := syscall.Errno(1); e < 0x86; e++ {
		if e.Error() == why {
			return e
		}
	}
	return errors.New(why)
}
