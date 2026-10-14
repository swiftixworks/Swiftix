// Package syscall is the part of syscall that the errors of the file
// system need: Errno, the number of a failed system call, with Linux's
// numbers and texts, which the run-time library reports.
package syscall

import "io/fs"

// An Errno is the error number of a failed system call.
type Errno uintptr

// The error numbers the run-time library reports, as Linux numbers them.
const (
	EPERM         Errno = 0x1
	ENOENT        Errno = 0x2
	EINTR         Errno = 0x4
	EIO           Errno = 0x5
	ECHILD        Errno = 0xa
	EAGAIN        Errno = 0xb
	EBADF         Errno = 0x9
	EACCES        Errno = 0xd
	EEXIST        Errno = 0x11
	ENODEV        Errno = 0x13
	ENOTDIR       Errno = 0x14
	EISDIR        Errno = 0x15
	EINVAL        Errno = 0x16
	EMFILE        Errno = 0x18
	ENOSPC        Errno = 0x1c
	EROFS         Errno = 0x1e
	EPIPE         Errno = 0x20
	ENOSYS        Errno = 0x26
	ENOTEMPTY     Errno = 0x27
	ENOTSUP       Errno = 0x5f
	EADDRINUSE    Errno = 0x62
	EADDRNOTAVAIL Errno = 0x63
	ENETUNREACH   Errno = 0x65
	ECONNRESET    Errno = 0x68
	ENOTCONN      Errno = 0x6b
	ETIMEDOUT     Errno = 0x6e
	ECONNREFUSED  Errno = 0x6f
)

// EWOULDBLOCK is EAGAIN, and EOPNOTSUPP ENOTSUP, as on Linux.
const (
	EWOULDBLOCK Errno = EAGAIN
	EOPNOTSUPP  Errno = ENOTSUP
)

func (e Errno) Error() string {
	switch e {
	case EPERM:
		return "operation not permitted"
	case ENOENT:
		return "no such file or directory"
	case EINTR:
		return "interrupted system call"
	case EIO:
		return "input/output error"
	case EBADF:
		return "bad file descriptor"
	case ECHILD:
		return "no child processes"
	case EAGAIN:
		return "resource temporarily unavailable"
	case EACCES:
		return "permission denied"
	case EEXIST:
		return "file exists"
	case ENODEV:
		return "no such device"
	case ENOTDIR:
		return "not a directory"
	case EISDIR:
		return "is a directory"
	case EINVAL:
		return "invalid argument"
	case EMFILE:
		return "too many open files"
	case ENOSPC:
		return "no space left on device"
	case EROFS:
		return "read-only file system"
	case EPIPE:
		return "broken pipe"
	case ENOSYS:
		return "function not implemented"
	case ENOTEMPTY:
		return "directory not empty"
	case ENOTSUP:
		return "operation not supported"
	case EADDRINUSE:
		return "address already in use"
	case EADDRNOTAVAIL:
		// The text Go reports for a bind to an address no interface has.
		return "can't assign requested address"
	case ENETUNREACH:
		return "network is unreachable"
	case ECONNREFUSED:
		return "connection refused"
	case ECONNRESET:
		return "connection reset by peer"
	case ENOTCONN:
		return "transport endpoint is not connected"
	case ETIMEDOUT:
		return "connection timed out"
	}
	return "errno " + itoa(int(e))
}

// itoa is the decimal text of n.
func itoa(n int) string {
	if n < 0 {
		return "-" + itoa(-n)
	}
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}

// Is answers errors.Is for the kinds of failure of io/fs.
func (e Errno) Is(target error) bool {
	switch target {
	case fs.ErrPermission:
		return e == EACCES || e == EPERM
	case fs.ErrExist:
		return e == EEXIST || e == ENOTEMPTY
	case fs.ErrNotExist:
		return e == ENOENT
	}
	return false
}

// Temporary reports whether a later try may succeed.
func (e Errno) Temporary() bool {
	return e == EINTR || e == EMFILE || e == ECONNRESET || e.Timeout()
}

// Timeout reports whether the call ran out of time.
func (e Errno) Timeout() bool {
	return e == EAGAIN || e == ETIMEDOUT
}
