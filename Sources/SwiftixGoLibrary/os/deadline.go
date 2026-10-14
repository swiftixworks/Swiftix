package os

// ErrDeadlineExceeded is returned for an expired deadline: by a Read or a
// Write of a network connection whose deadline has passed. Its Timeout
// method reports true.
var ErrDeadlineExceeded error = &deadlineExceededError{}

// deadlineExceededError is the type of ErrDeadlineExceeded, which Go
// declares in internal/poll as DeadlineExceededError.
type deadlineExceededError struct{}

func (e *deadlineExceededError) Error() string   { return "i/o timeout" }
func (e *deadlineExceededError) Timeout() bool   { return true }
func (e *deadlineExceededError) Temporary() bool { return true }
