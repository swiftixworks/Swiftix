// Package runtime is the part of runtime that is written in Go: the
// interface of its errors. The errors themselves are made by the VM, which
// gives them both methods; GC and the like belong to the run-time library.
package runtime

// An Error is a run-time error: an index out of range, a nil dereference, a
// failed type assertion, and the like. RuntimeError does nothing; it tells
// these errors from others.
type Error interface {
	error
	RuntimeError()
}
