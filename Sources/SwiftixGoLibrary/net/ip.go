package net

import "strconv"

// IP address lengths (bytes).
const (
	IPv4len = 4
	IPv6len = 16
)

// An IP is a single IP address, a slice of bytes: 4 bytes for IPv4, 16 for
// IPv6, with an IPv4 address in IPv6 form as well.
type IP []byte

// Well-known IPv6 addresses.
var (
	IPv6zero        = IP{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	IPv6unspecified = IP{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	IPv6loopback    = IP{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
)

// IPv4 returns the IP address (in 16-byte form) of the IPv4 address
// a.b.c.d.
func IPv4(a, b, c, d byte) IP {
	return IP{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, a, b, c, d}
}

func isZeros(p IP) bool {
	for i := 0; i < len(p); i++ {
		if p[i] != 0 {
			return false
		}
	}
	return true
}

// To4 converts the IPv4 address ip to a 4-byte representation. If ip is
// not an IPv4 address, To4 returns nil.
func (ip IP) To4() IP {
	if len(ip) == IPv4len {
		return ip
	}
	if len(ip) == IPv6len && isZeros(ip[0:10]) && ip[10] == 0xff && ip[11] == 0xff {
		return ip[12:16]
	}
	return nil
}

// To16 converts the IP address ip to a 16-byte representation. If ip is
// not an IP address (it is the wrong length), To16 returns nil.
func (ip IP) To16() IP {
	if len(ip) == IPv4len {
		return IPv4(ip[0], ip[1], ip[2], ip[3])
	}
	if len(ip) == IPv6len {
		return ip
	}
	return nil
}

// IsUnspecified reports whether ip is an unspecified address, either the
// IPv4 address "0.0.0.0" or the IPv6 address "::".
func (ip IP) IsUnspecified() bool {
	return ip.Equal(IPv4(0, 0, 0, 0)) || ip.Equal(IPv6unspecified)
}

// IsLoopback reports whether ip is a loopback address.
func (ip IP) IsLoopback() bool {
	if ip4 := ip.To4(); ip4 != nil {
		return ip4[0] == 127
	}
	return ip.Equal(IPv6loopback)
}

// Equal reports whether ip and x are the same IP address. An IPv4 address
// and that same address in IPv6 form are considered to be equal.
func (ip IP) Equal(x IP) bool {
	if len(ip) == len(x) {
		return string(ip) == string(x)
	}
	if len(ip) == IPv4len && len(x) == IPv6len {
		return string(x[0:12]) == string(IPv4(0, 0, 0, 0)[0:12]) && string(ip) == string(x[12:])
	}
	if len(ip) == IPv6len && len(x) == IPv4len {
		return string(ip[0:12]) == string(IPv4(0, 0, 0, 0)[0:12]) && string(ip[12:]) == string(x)
	}
	return false
}

const hexDigit = "0123456789abcdef"

// String returns the string form of the IP address ip: "<nil>" for an
// address of length zero, dotted decimal ("192.0.2.1") for an IPv4
// address, and RFC 5952 form ("2001:db8::1") for another.
func (ip IP) String() string {
	if len(ip) == 0 {
		return "<nil>"
	}
	if len(ip) != IPv4len && len(ip) != IPv6len {
		s := make([]byte, 0, 1+len(ip)*2)
		s = append(s, '?')
		for _, b := range ip {
			s = append(s, hexDigit[b>>4], hexDigit[b&0xf])
		}
		return string(s)
	}
	if p4 := ip.To4(); len(p4) == IPv4len {
		return strconv.Itoa(int(p4[0])) + "." + strconv.Itoa(int(p4[1])) + "." +
			strconv.Itoa(int(p4[2])) + "." + strconv.Itoa(int(p4[3]))
	}
	// The longest run of two or more zero groups, the first of the
	// longest, is written "::".
	start, length := -1, 0
	for i := 0; i < 8; {
		j := i
		for j < 8 && ip[2*j] == 0 && ip[2*j+1] == 0 {
			j++
		}
		if j-i >= 2 && j-i > length {
			start, length = i, j-i
		}
		if j == i {
			j++
		}
		i = j
	}
	s := ""
	for i := 0; i < 8; i++ {
		if i == start {
			s += "::"
			i += length - 1
			continue
		}
		if i > 0 && i != start+length {
			s += ":"
		}
		group := int(ip[2*i])<<8 | int(ip[2*i+1])
		s += strconv.FormatInt(int64(group), 16)
	}
	return s
}

// ParseIP parses s as an IP address, in IPv4 dotted decimal ("192.0.2.1")
// or IPv6 ("2001:db8::68") form, and returns it in 16-byte form, or nil
// when s is no valid address.
func ParseIP(s string) IP {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '.':
			return parseIPv4(s)
		case ':':
			return parseIPv6(s)
		}
	}
	return nil
}

func parseIPv4(s string) IP {
	var p [IPv4len]byte
	for i := 0; i < IPv4len; i++ {
		if i > 0 {
			if len(s) == 0 || s[0] != '.' {
				return nil
			}
			s = s[1:]
		}
		n, digits := 0, 0
		for digits < len(s) && '0' <= s[digits] && s[digits] <= '9' {
			if digits > 0 && n == 0 {
				return nil // a leading zero
			}
			n = n*10 + int(s[digits]-'0')
			digits++
			if n > 0xff {
				return nil
			}
		}
		if digits == 0 {
			return nil
		}
		s = s[digits:]
		p[i] = byte(n)
	}
	if len(s) != 0 {
		return nil
	}
	return IPv4(p[0], p[1], p[2], p[3])
}

func parseIPv6(s string) IP {
	ip := make(IP, IPv6len)
	ellipsis := -1 // position of ellipsis in ip
	if len(s) >= 2 && s[0] == ':' && s[1] == ':' {
		ellipsis = 0
		s = s[2:]
		if len(s) == 0 {
			return ip
		}
	}
	i := 0
	for i < IPv6len {
		n, digits := 0, 0
		for digits < len(s) && digits < 4 {
			v := hexValue(s[digits])
			if v < 0 {
				break
			}
			n = n*16 + v
			digits++
		}
		if digits == 0 {
			return nil
		}
		if digits < len(s) && s[digits] == '.' {
			// An IPv4 address ends it.
			if ellipsis < 0 && i != IPv6len-IPv4len {
				return nil
			}
			if i+IPv4len > IPv6len {
				return nil
			}
			v4 := parseIPv4(s)
			if v4 == nil {
				return nil
			}
			copy(ip[i:], v4[12:])
			i += IPv4len
			s = ""
			break
		}
		ip[i] = byte(n >> 8)
		ip[i+1] = byte(n)
		i += 2
		s = s[digits:]
		if len(s) == 0 {
			break
		}
		if s[0] != ':' || len(s) == 1 {
			return nil
		}
		s = s[1:]
		if s[0] == ':' {
			if ellipsis >= 0 {
				return nil // a second ellipsis
			}
			ellipsis = i
			s = s[1:]
			if len(s) == 0 {
				break
			}
		}
	}
	if len(s) != 0 {
		return nil
	}
	if i < IPv6len {
		if ellipsis < 0 {
			return nil
		}
		n := IPv6len - i
		for j := i - 1; j >= ellipsis; j-- {
			ip[j+n] = ip[j]
		}
		for j := ellipsis + n - 1; j >= ellipsis; j-- {
			ip[j] = 0
		}
	} else if ellipsis >= 0 {
		return nil // an ellipsis must stand for at least one group
	}
	return ip
}

// hexValue is the value of the hexadecimal digit c, or -1.
func hexValue(c byte) int {
	switch {
	case '0' <= c && c <= '9':
		return int(c - '0')
	case 'a' <= c && c <= 'f':
		return int(c-'a') + 10
	case 'A' <= c && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// TCPAddr represents the address of a TCP end point.
type TCPAddr struct {
	IP   IP
	Port int
	Zone string // IPv6 scoped addressing zone
}

// Network returns the address's network name, "tcp".
func (a *TCPAddr) Network() string { return "tcp" }

func (a *TCPAddr) String() string {
	if a == nil {
		return "<nil>"
	}
	ip := ""
	if len(a.IP) != 0 {
		ip = a.IP.String()
	}
	if a.Zone != "" {
		return JoinHostPort(ip+"%"+a.Zone, strconv.Itoa(a.Port))
	}
	return JoinHostPort(ip, strconv.Itoa(a.Port))
}

// ResolveTCPAddr returns an address of TCP end point. The host must be an
// IP literal, localhost, or empty; the port a number.
func ResolveTCPAddr(network, address string) (*TCPAddr, error) {
	switch network {
	case "tcp", "tcp4", "tcp6":
	case "":
		network = "tcp"
	default:
		return nil, UnknownNetworkError(network)
	}
	return resolveTCPAddr(address)
}

func resolveTCPAddr(address string) (*TCPAddr, error) {
	host, service, err := SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, needsLookup := parsePort(service)
	if needsLookup {
		return nil, &DNSError{Err: "unknown port", Name: "tcp/" + service, IsNotFound: true}
	}
	if port < 0 || port > 0xFFFF {
		return nil, &AddrError{Err: "invalid port", Addr: service}
	}
	if host == "" {
		return &TCPAddr{Port: port}, nil
	}
	if host == "localhost" {
		return &TCPAddr{IP: IPv4(127, 0, 0, 1), Port: port}, nil
	}
	ip := ParseIP(host)
	if ip == nil {
		return nil, &DNSError{Err: "no such host", Name: host, IsNotFound: true}
	}
	return &TCPAddr{IP: ip, Port: port}, nil
}

// parsePort parses service as a decimal integer and returns the
// corresponding value as port. It is the caller's responsibility to
// parse service as a non-decimal integer when needsLookup is true.
func parsePort(service string) (port int, needsLookup bool) {
	if service == "" {
		// Lock in the legacy behavior that an empty string
		// means port 0. See golang.org/issue/13610.
		return 0, false
	}
	const (
		max    = uint32(1<<32 - 1)
		cutoff = uint32(1 << 30)
	)
	neg := false
	if service[0] == '+' {
		service = service[1:]
	} else if service[0] == '-' {
		neg = true
		service = service[1:]
	}
	var n uint32
	for i := 0; i < len(service); i++ {
		d := service[i]
		if '0' <= d && d <= '9' {
			d -= '0'
		} else {
			return 0, true
		}
		if n >= cutoff {
			n = max
			break
		}
		n *= 10
		nn := n + uint32(d)
		if nn < n || nn > max {
			n = max
			break
		}
		n = nn
	}
	if !neg && n >= cutoff {
		port = int(cutoff - 1)
	} else if neg && n > cutoff {
		port = int(cutoff)
	} else {
		port = int(n)
	}
	if neg {
		port = -port
	}
	return port, false
}

// SplitHostPort splits a network address of the form "host:port",
// "host%zone:port", "[host]:port" or "[host%zone]:port" into host or
// host%zone and port.
func SplitHostPort(hostport string) (host, port string, err error) {
	const (
		missingPort   = "missing port in address"
		tooManyColons = "too many colons in address"
	)
	addrErr := func(addr, why string) (host, port string, err error) {
		return "", "", &AddrError{Err: why, Addr: addr}
	}
	j, k := 0, 0

	// The port starts after the last colon.
	i := lastIndexByte(hostport, ':')
	if i < 0 {
		return addrErr(hostport, missingPort)
	}

	if hostport[0] == '[' {
		// Expect the first ']' just before the last ':'.
		end := indexByte(hostport, ']')
		if end < 0 {
			return addrErr(hostport, "missing ']' in address")
		}
		switch end + 1 {
		case len(hostport):
			// There can't be a ':' behind the ']' now.
			return addrErr(hostport, missingPort)
		case i:
			// The expected result.
		default:
			// Either ']' isn't followed by a colon, or it is
			// followed by a colon that is not the last one.
			if hostport[end+1] == ':' {
				return addrErr(hostport, tooManyColons)
			}
			return addrErr(hostport, missingPort)
		}
		host = hostport[1:end]
		j, k = 1, end+1 // there can't be a '[' resp. ']' before these positions
	} else {
		host = hostport[:i]
		if indexByte(host, ':') >= 0 {
			return addrErr(hostport, tooManyColons)
		}
	}
	if indexByte(hostport[j:], '[') >= 0 {
		return addrErr(hostport, "unexpected '[' in address")
	}
	if indexByte(hostport[k:], ']') >= 0 {
		return addrErr(hostport, "unexpected ']' in address")
	}

	port = hostport[i+1:]
	return host, port, nil
}

// JoinHostPort combines host and port into a network address of the form
// "host:port". If host contains a colon, as found in literal IPv6
// addresses, then JoinHostPort returns "[host]:port".
func JoinHostPort(host, port string) string {
	// We assume that host is a literal IPv6 address if host has
	// colons.
	if indexByte(host, ':') >= 0 {
		return "[" + host + "]:" + port
	}
	return host + ":" + port
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func lastIndexByte(s string, c byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == c {
			return i
		}
	}
	return -1
}
