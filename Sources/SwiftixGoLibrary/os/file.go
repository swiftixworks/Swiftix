package os

import (
	"os"
	"strings"
)

// The files are opened, read, and changed by natives of the run-time
// library, which fail with the text of Go's error alone: the operation, the
// path, and why. These functions give what a native gave and, for its
// error, Go's *PathError or *LinkError, holding the syscall.Errno that the
// text names.

// pathError is the *PathError of a failure on name that a native reported
// as failure; nil when there is none.
func pathError(name string, failure error) error {
	if failure == nil {
		return nil
	}
	op, rest, ok := strings.Cut(failure.Error(), " ")
	why, found := strings.CutPrefix(rest, name+": ")
	if !ok || !found {
		return failure
	}
	return &PathError{Op: op, Path: name, Err: errno(why)}
}

// Open opens the named file for reading.
func Open(name string) (*os.File, error) {
	f, err := native.Open(name)
	return f, pathError(name, err)
}

// Create creates or truncates the named file, open for reading and writing.
func Create(name string) (*os.File, error) {
	f, err := native.Create(name)
	return f, pathError(name, err)
}

// OpenFile opens the named file with the flags (O_RDONLY and the like) and,
// when it creates the file, the permissions perm.
func OpenFile(name string, flag int, perm int) (*os.File, error) {
	f, err := native.OpenFile(name, flag, perm)
	return f, pathError(name, err)
}

// ReadFile reads the named file and returns what it holds.
func ReadFile(name string) ([]byte, error) {
	data, err := native.ReadFile(name)
	return data, pathError(name, err)
}

// WriteFile writes data to the named file, creating it with perm if
// needed and truncating it otherwise.
func WriteFile(name string, data []byte, perm int) error {
	return pathError(name, native.WriteFile(name, data, perm))
}

// Remove removes the named file or empty directory.
func Remove(name string) error {
	return pathError(name, native.Remove(name))
}

// Mkdir creates a directory with the permissions perm.
func Mkdir(name string, perm int) error {
	return pathError(name, native.Mkdir(name, perm))
}

// Rename renames oldpath to newpath, replacing a file there.
func Rename(oldpath, newpath string) error {
	failure := native.Rename(oldpath, newpath)
	if failure == nil {
		return nil
	}
	why, ok := strings.CutPrefix(failure.Error(), "rename "+oldpath+" "+newpath+": ")
	if !ok {
		return failure
	}
	return &LinkError{Op: "rename", Old: oldpath, New: newpath, Err: errno(why)}
}
