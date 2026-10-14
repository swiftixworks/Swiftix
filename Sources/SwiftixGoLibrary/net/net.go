// Package net is the part of Go's net that a TCP server and its clients
// need, written for this run-time library: the interfaces Conn, Listener,
// Addr, and Error, the types TCPConn, TCPListener, TCPAddr, and OpError,
// Dial and Listen, and deadlines. A connection is a descriptor of the
// kernel the VM serves through the natives of this package; everything
// else is Go, so a program's own type can be a Conn, a struct that embeds
// one is one, and an error is the value Go returns.
package net

import (
	"errors"
	"io"
	"os"
	"time"
)

// An Addr is the address of an end of a network connection.
type Addr interface {
	Network() string // name of the network (for example, "tcp", "udp")
	String() string  // string form of address (for example, "192.0.2.1:25", "[2001:db8::1]:80")
}

// A Conn is a generic stream-oriented network connection. Its methods may
// be called by several goroutines at once.
type Conn interface {
	// Read reads data from the connection. It fails with an error whose
	// Timeout is true once a deadline set by SetDeadline or
	// SetReadDeadline has passed.
	Read(b []byte) (n int, err error)

	// Write writes data to the connection.
	Write(b []byte) (n int, err error)

	// Close closes the connection. A Read or Write that waits is woken and
	// fails.
	Close() error

	// LocalAddr returns the local network address.
	LocalAddr() Addr

	// RemoteAddr returns the remote network address.
	RemoteAddr() Addr

	// SetDeadline sets the read and write deadlines. A zero time means no
	// deadline.
	SetDeadline(t time.Time) error

	// SetReadDeadline sets the deadline for Read calls, those that wait
	// now included. A zero time means no deadline.
	SetReadDeadline(t time.Time) error

	// SetWriteDeadline sets the deadline for Write calls. A zero time
	// means no deadline.
	SetWriteDeadline(t time.Time) error
}

// A Listener is a generic network listener for stream-oriented protocols.
type Listener interface {
	// Accept waits for and returns the next connection to the listener.
	Accept() (Conn, error)

	// Close closes the listener. An Accept that waits is woken and fails.
	Close() error

	// Addr returns the listener's network address.
	Addr() Addr
}

// An Error represents a network error.
type Error interface {
	error
	Timeout() bool // Is the error a timeout?

	// Deprecated: Temporary errors are not well-defined.
	Temporary() bool
}

// ErrClosed is the error returned by an I/O call on a network connection
// that has already been closed, or that is closed by another goroutine
// before the I/O is completed.
var ErrClosed error = errNetClosing{}

// errNetClosing is the type of ErrClosed, as Go's internal/poll has it.
type errNetClosing struct{}

func (e errNetClosing) Error() string   { return "use of closed network connection" }
func (e errNetClosing) Timeout() bool   { return false }
func (e errNetClosing) Temporary() bool { return false }

// OpError is the error type usually returned by functions in the net
// package. It describes the operation, network type, and address of an
// error.
type OpError struct {
	// Op is the operation which caused the error, such as
	// "read" or "write".
	Op string

	// Net is the network type on which this error occurred,
	// such as "tcp" or "udp6".
	Net string

	// For operations involving a remote network connection, like
	// Dial, Read, or Write, Source is the corresponding local
	// network address.
	Source Addr

	// Addr is the network address for which this error occurred.
	// For local operations, like Listen or SetDeadline, Addr is
	// the address of the local endpoint being manipulated.
	// For operations involving a remote network connection, like
	// Dial, Read, or Write, Addr is the remote address of that
	// connection.
	Addr Addr

	// Err is the error that occurred during the operation.
	// The Error method panics if the error is nil.
	Err error
}

func (e *OpError) Unwrap() error { return e.Err }

func (e *OpError) Error() string {
	if e == nil {
		return "<nil>"
	}
	s := e.Op
	if e.Net != "" {
		s += " " + e.Net
	}
	if e.Source != nil {
		s += " " + e.Source.String()
	}
	if e.Addr != nil {
		if e.Source != nil {
			s += "->"
		} else {
			s += " "
		}
		s += e.Addr.String()
	}
	s += ": " + e.Err.Error()
	return s
}

type timeout interface {
	Timeout() bool
}

func (e *OpError) Timeout() bool {
	if ne, ok := e.Err.(*os.SyscallError); ok {
		t, ok := ne.Err.(timeout)
		return ok && t.Timeout()
	}
	t, ok := e.Err.(timeout)
	return ok && t.Timeout()
}

type temporary interface {
	Temporary() bool
}

func (e *OpError) Temporary() bool {
	// Treat ECONNRESET and ECONNABORTED as temporary errors when
	// they come from calling accept. See issue 6163.
	if e.Op == "accept" && isConnError(e.Err) {
		return true
	}

	if ne, ok := e.Err.(*os.SyscallError); ok {
		t, ok := ne.Err.(temporary)
		return ok && t.Temporary()
	}
	t, ok := e.Err.(temporary)
	return ok && t.Temporary()
}

func isConnError(err error) bool {
	if se, ok := err.(*os.SyscallError); ok {
		return se.Err == errConnReset
	}
	return false
}

// An AddrError reports an address that cannot be used.
type AddrError struct {
	Err  string
	Addr string
}

func (e *AddrError) Error() string {
	if e == nil {
		return "<nil>"
	}
	s := e.Err
	if e.Addr != "" {
		s = "address " + e.Addr + ": " + s
	}
	return s
}

func (e *AddrError) Timeout() bool   { return false }
func (e *AddrError) Temporary() bool { return false }

// An UnknownNetworkError names a network Dial or Listen does not know.
type UnknownNetworkError string

func (e UnknownNetworkError) Error() string   { return "unknown network " + string(e) }
func (e UnknownNetworkError) Timeout() bool   { return false }
func (e UnknownNetworkError) Temporary() bool { return false }

// DNSError represents a failure to look a name up. Only literal addresses
// and localhost are known here, and the ports by number.
type DNSError struct {
	UnwrapErr   error  // error returned by the [DNSError.Unwrap] method, might be nil
	Err         string // description of the error
	Name        string // name looked for
	Server      string // server used
	IsTimeout   bool   // if true, timed out; not all timeouts set this
	IsTemporary bool   // if true, error is temporary; not all errors set this

	// IsNotFound is set to true when the requested name does not
	// contain any records of the requested type (data not found),
	// or the name itself was not found (NXDOMAIN).
	IsNotFound bool
}

func (e *DNSError) Unwrap() error { return e.UnwrapErr }

func (e *DNSError) Error() string {
	if e == nil {
		return "<nil>"
	}
	s := "lookup " + e.Name
	if e.Server != "" {
		s += " on " + e.Server
	}
	s += ": " + e.Err
	return s
}

func (e *DNSError) Timeout() bool   { return e.IsTimeout }
func (e *DNSError) Temporary() bool { return e.IsTimeout || e.IsTemporary }

// What the natives report besides success, and the errors Go has for each.
const (
	codeEOF         = 1
	codeTimeout     = 2
	codeClosed      = 3
	codeRefused     = 4
	codeAddrInUse   = 5
	codeUnavailable = 6
	codeReset       = 7
	codeTimedOut    = 8
	codeNoAddress   = 9
)

var (
	errConnRefused  = errors.New("connection refused")
	errAddrInUse    = errors.New("address already in use")
	errUnavailable  = errors.New("network is unreachable")
	errConnReset    = errors.New("connection reset by peer")
	errConnTimedOut = errors.New("connection timed out")
	errInvalid      = errors.New("invalid argument")
	errNoAddress    = errors.New("can't assign requested address")
)

// codeError is the error the natives' code stands for, from the system
// call `call` when it is one.
func codeError(call string, code int) error {
	switch code {
	case codeTimeout:
		return os.ErrDeadlineExceeded
	case codeClosed:
		return ErrClosed
	case codeRefused:
		return os.NewSyscallError(call, errConnRefused)
	case codeAddrInUse:
		return os.NewSyscallError(call, errAddrInUse)
	case codeReset:
		return os.NewSyscallError(call, errConnReset)
	case codeTimedOut:
		return os.NewSyscallError(call, errConnTimedOut)
	case codeNoAddress:
		return os.NewSyscallError(call, errNoAddress)
	}
	return os.NewSyscallError(call, errUnavailable)
}

// A netFD is a descriptor of the kernel with the addresses of its ends.
type netFD struct {
	sysfd  int
	net    string
	laddr  Addr
	raddr  Addr
	closed bool
}

// conn is what TCPConn embeds in Go; the methods are on TCPConn here.
type conn struct {
	fd *netFD
}

// TCPConn is an implementation of the Conn interface for TCP network
// connections.
type TCPConn struct {
	conn
}

func newTCPConn(sysfd int, network string, laddr, raddr *TCPAddr) *TCPConn {
	return &TCPConn{conn{&netFD{sysfd: sysfd, net: network, laddr: laddr, raddr: raddr}}}
}

func (c *TCPConn) ok() bool { return c != nil && c.fd != nil }

// opError is the error of `op` on the connection.
func (c *TCPConn) opError(op string, err error) error {
	return &OpError{Op: op, Net: c.fd.net, Source: c.fd.laddr, Addr: c.fd.raddr, Err: err}
}

// Read implements the Conn Read method.
func (c *TCPConn) Read(b []byte) (int, error) {
	if !c.ok() {
		return 0, errInvalid
	}
	if c.fd.closed {
		return 0, c.opError("read", ErrClosed)
	}
	n, code := native.read(c.fd.sysfd, b)
	switch code {
	case 0:
		return n, nil
	case codeEOF:
		return n, io.EOF
	}
	return n, c.opError("read", codeError("read", code))
}

// Write implements the Conn Write method.
func (c *TCPConn) Write(b []byte) (int, error) {
	if !c.ok() {
		return 0, errInvalid
	}
	if c.fd.closed {
		return 0, c.opError("write", ErrClosed)
	}
	n, code := native.write(c.fd.sysfd, b)
	if code != 0 {
		return n, c.opError("write", codeError("write", code))
	}
	return n, nil
}

// Close closes the connection.
func (c *TCPConn) Close() error {
	if !c.ok() {
		return errInvalid
	}
	if c.fd.closed {
		return c.opError("close", ErrClosed)
	}
	c.fd.closed = true
	native.close(c.fd.sysfd)
	return nil
}

// LocalAddr returns the local network address.
func (c *TCPConn) LocalAddr() Addr {
	if !c.ok() {
		return nil
	}
	return c.fd.laddr
}

// RemoteAddr returns the remote network address.
func (c *TCPConn) RemoteAddr() Addr {
	if !c.ok() {
		return nil
	}
	return c.fd.raddr
}

// The deadlines a call of the native sets.
const (
	readDeadline  = 1
	writeDeadline = 2
)

// SetDeadline implements the Conn SetDeadline method.
func (c *TCPConn) SetDeadline(t time.Time) error {
	return c.setDeadline(readDeadline|writeDeadline, t)
}

// SetReadDeadline implements the Conn SetReadDeadline method.
func (c *TCPConn) SetReadDeadline(t time.Time) error {
	return c.setDeadline(readDeadline, t)
}

// SetWriteDeadline implements the Conn SetWriteDeadline method.
func (c *TCPConn) SetWriteDeadline(t time.Time) error {
	return c.setDeadline(writeDeadline, t)
}

func (c *TCPConn) setDeadline(which int, t time.Time) error {
	if !c.ok() {
		return errInvalid
	}
	if c.fd.closed {
		return c.opError("set", ErrClosed)
	}
	// The earliest instant stands for no deadline: a zero time.
	at := int64(-1 << 63)
	if !t.IsZero() {
		at = t.UnixNano()
	}
	native.deadline(c.fd.sysfd, which, at)
	return nil
}

// TCPListener is a TCP network listener.
type TCPListener struct {
	fd *netFD
}

func (l *TCPListener) ok() bool { return l != nil && l.fd != nil }

func (l *TCPListener) opError(op string, err error) error {
	return &OpError{Op: op, Net: l.fd.net, Source: nil, Addr: l.fd.laddr, Err: err}
}

// AcceptTCP accepts the next incoming call and returns the new connection.
func (l *TCPListener) AcceptTCP() (*TCPConn, error) {
	if !l.ok() {
		return nil, errInvalid
	}
	if l.fd.closed {
		return nil, l.opError("accept", ErrClosed)
	}
	sysfd, local, remote, port, code := native.accept(l.fd.sysfd)
	if code != 0 {
		return nil, l.opError("accept", codeError("accept", code))
	}
	laddr := &TCPAddr{IP: ParseIP(local).To4(), Port: l.fd.laddr.(*TCPAddr).Port}
	raddr := &TCPAddr{IP: ParseIP(remote).To4(), Port: port}
	return newTCPConn(sysfd, l.fd.net, laddr, raddr), nil
}

// Accept implements the Accept method in the Listener interface; it waits
// for the next call and returns a generic Conn.
func (l *TCPListener) Accept() (Conn, error) {
	c, err := l.AcceptTCP()
	if err != nil {
		return nil, err
	}
	return c, nil
}

// Close stops listening on the TCP address.
func (l *TCPListener) Close() error {
	if !l.ok() {
		return errInvalid
	}
	if l.fd.closed {
		return l.opError("close", ErrClosed)
	}
	l.fd.closed = true
	native.close(l.fd.sysfd)
	return nil
}

// Addr returns the listener's network address, a *TCPAddr.
func (l *TCPListener) Addr() Addr { return l.fd.laddr }

// checkNetwork is nil for a network of TCP, and the error Dial and Listen
// return for another.
func checkNetwork(op, network string) error {
	switch network {
	case "tcp", "tcp4":
		return nil
	case "tcp6", "udp", "udp4", "udp6", "ip", "ip4", "ip6", "unix", "unixgram", "unixpacket":
		return &OpError{Op: op, Net: network, Err: errors.New("protocol not supported")}
	}
	return &OpError{Op: op, Net: network, Err: UnknownNetworkError(network)}
}

// Dial connects to the address on the named network. Only "tcp" and
// "tcp4" are served, to an address that is an IPv4 literal, localhost, or
// a port alone.
func Dial(network, address string) (Conn, error) {
	c, err := dialTCP(network, address)
	if err != nil {
		return nil, err
	}
	return c, nil
}

// DialTimeout acts like Dial but takes a timeout. A connection over the
// loopback interface is made or refused at once, so it is Dial.
func DialTimeout(network, address string, timeout time.Duration) (Conn, error) {
	return Dial(network, address)
}

func dialTCP(network, address string) (*TCPConn, error) {
	if err := checkNetwork("dial", network); err != nil {
		return nil, err
	}
	raddr, err := resolveTCPAddr(address)
	if err != nil {
		return nil, &OpError{Op: "dial", Net: network, Err: err}
	}
	ip, ok := hostIPv4(raddr.IP)
	if !ok {
		return nil, &OpError{Op: "dial", Net: network, Addr: raddr, Err: codeError("connect", codeUnavailable)}
	}
	sysfd, local, port, code := native.dial(ip, raddr.Port)
	if code != 0 {
		return nil, &OpError{Op: "dial", Net: network, Addr: raddr, Err: codeError("connect", code)}
	}
	laddr := &TCPAddr{IP: ParseIP(local).To4(), Port: port}
	peer := &TCPAddr{IP: ParseIP(ip).To4(), Port: raddr.Port}
	return newTCPConn(sysfd, network, laddr, peer), nil
}

// Listen announces on the local network address. Only "tcp" and "tcp4"
// are served; a port of 0 chooses one.
func Listen(network, address string) (Listener, error) {
	l, err := listenTCP(network, address)
	if err != nil {
		return nil, err
	}
	return l, nil
}

func listenTCP(network, address string) (*TCPListener, error) {
	if err := checkNetwork("listen", network); err != nil {
		return nil, err
	}
	addr, err := resolveTCPAddr(address)
	if err != nil {
		return nil, &OpError{Op: "listen", Net: network, Err: err}
	}
	ip := ""
	listening := IPv6unspecified
	if len(addr.IP) != 0 && !addr.IP.IsUnspecified() {
		v4, ok := hostIPv4(addr.IP)
		if !ok {
			return nil, &OpError{Op: "listen", Net: network, Addr: addr, Err: os.NewSyscallError("bind", errNoAddress)}
		}
		ip = v4
		listening = ParseIP(v4).To4()
	}
	sysfd, port, code := native.listen(ip, addr.Port)
	if code != 0 {
		return nil, &OpError{Op: "listen", Net: network, Addr: addr, Err: codeError("bind", code)}
	}
	laddr := &TCPAddr{IP: listening, Port: port}
	return &TCPListener{fd: &netFD{sysfd: sysfd, net: network, laddr: laddr}}, nil
}

// hostIPv4 is the IPv4 address in dotted form that the kernel reaches for
// ip: itself, or the loopback address for no address, the unspecified
// one, and ::1. ok is false for any other IPv6 address.
func hostIPv4(ip IP) (string, bool) {
	if len(ip) == 0 || ip.IsUnspecified() || ip.Equal(IPv6loopback) {
		return "127.0.0.1", true
	}
	v4 := ip.To4()
	if v4 == nil {
		return "", false
	}
	return v4.String(), true
}
