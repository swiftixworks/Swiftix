package os

import (
	"errors"
	"syscall"
)

// A Signal represents an operating system signal.
type Signal interface {
	String() string
	Signal() // to distinguish from other Stringers
}

// The only signal values guaranteed to be present in the os package on all
// systems are os.Interrupt (send the process an interrupt) and os.Kill
// (force the process to exit).
var (
	Interrupt Signal = syscall.SIGINT
	Kill      Signal = syscall.SIGKILL
)

// A Process is a process of the kernel the program runs on.
type Process struct {
	Pid int
}

// FindProcess looks for a running process by its pid. It always succeeds,
// as on Unix: a process that does not exist is found when it is signalled.
func FindProcess(pid int) (*Process, error) {
	return &Process{Pid: pid}, nil
}

// Signal sends a signal to the Process.
func (p *Process) Signal(sig Signal) error {
	s, ok := sig.(syscall.Signal)
	if !ok {
		return errors.New("os: unsupported signal type")
	}
	return syscall.Kill(p.Pid, s)
}

// Kill causes the Process to exit immediately.
func (p *Process) Kill() error {
	return p.Signal(Kill)
}
