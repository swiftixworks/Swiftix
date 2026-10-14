package syscall

// A Signal is a number of a signal the kernel delivers, as Linux numbers
// them.
type Signal int

// The signals, with Linux's numbers.
const (
	SIGHUP  = Signal(0x1)
	SIGINT  = Signal(0x2)
	SIGQUIT = Signal(0x3)
	SIGKILL = Signal(0x9)
	SIGUSR1 = Signal(0xa)
	SIGUSR2 = Signal(0xc)
	SIGPIPE = Signal(0xd)
	SIGALRM = Signal(0xe)
	SIGTERM = Signal(0xf)
	SIGCHLD = Signal(0x11)
	SIGCONT = Signal(0x12)
	SIGSTOP = Signal(0x13)
	SIGTSTP = Signal(0x14)
)

// Signal makes a Signal an os.Signal.
func (s Signal) Signal() {}

func (s Signal) String() string {
	switch s {
	case SIGHUP:
		return "hangup"
	case SIGINT:
		return "interrupt"
	case SIGQUIT:
		return "quit"
	case SIGKILL:
		return "killed"
	case SIGUSR1:
		return "user defined signal 1"
	case SIGUSR2:
		return "user defined signal 2"
	case SIGPIPE:
		return "broken pipe"
	case SIGALRM:
		return "alarm clock"
	case SIGTERM:
		return "terminated"
	case SIGCHLD:
		return "child exited"
	case SIGCONT:
		return "continued"
	case SIGSTOP:
		return "stopped (signal)"
	case SIGTSTP:
		return "stopped"
	}
	return "signal " + itoa(int(s))
}

// Kill sends the signal sig to the process pid.
func Kill(pid int, sig Signal) error {
	native.kill(pid, int(sig))
	return nil
}

// Getpid returns the number of the calling process.
func Getpid() int { return native.getpid() }
