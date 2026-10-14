// Package url parses URLs and escapes their parts, for the URLs of HTTP: a
// scheme, an authority, a path, a query, and a fragment. Its results are
// those of Go's net/url. Escaping goes over a string byte by byte, so the
// run-time library does it; this file reaches it by importing its own path.
package url

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Error is a failed operation on a URL, with the error that stopped it.
type Error struct {
	Op  string
	URL string
	Err error
}

func (e *Error) Unwrap() error { return e.Err }

func (e *Error) Error() string { return fmt.Sprintf("%s %q: %s", e.Op, e.URL, e.Err) }

// The part of a URL a string belongs to, which decides what is escaped in
// it. The run-time library knows the parts by these numbers.
const (
	encodePath = 1 + iota
	encodePathSegment
	encodeHost
	encodeZone
	encodeUserPassword
	encodeQueryComponent
	encodeFragment
)

// EscapeError is a percent sign that two hexadecimal digits do not follow.
type EscapeError string

func (e EscapeError) Error() string {
	return "invalid URL escape " + fmt.Sprintf("%q", string(e))
}

// InvalidHostError is a byte that no host name has.
type InvalidHostError string

func (e InvalidHostError) Error() string {
	return "invalid character " + fmt.Sprintf("%q", string(e)) + " in host name"
}

// unescape replaces each %XX of s by its byte, and in a query component
// each plus sign by a space. A path without a percent sign is itself.
func unescape(s string, mode int) (string, error) {
	if !strings.Contains(s, "%") && mode == encodePath {
		return s, nil
	}
	out, bad, kind := native.unescape(s, mode)
	switch kind {
	case 1:
		return "", EscapeError(bad)
	case 2:
		return "", InvalidHostError(bad)
	}
	return out, nil
}

// QueryUnescape is the inverse of QueryEscape.
func QueryUnescape(s string) (string, error) {
	return unescape(s, encodeQueryComponent)
}

// PathUnescape is the inverse of PathEscape: a plus sign stays one.
func PathUnescape(s string) (string, error) {
	return unescape(s, encodePathSegment)
}

// QueryEscape escapes s for use as a key or a value of a query.
func QueryEscape(s string) string {
	return native.escape(s, encodeQueryComponent)
}

// PathEscape escapes s for use as one segment of a path.
func PathEscape(s string) string {
	return native.escape(s, encodePathSegment)
}

// A URL is a parsed URL:
//
//	[scheme:][//[userinfo@]host][/]path[?query][#fragment]
//
// Path holds the path unescaped; RawPath is set only where the source
// escaped it in a way EscapedPath would not, and RawFragment likewise.
type URL struct {
	Scheme      string
	Opaque      string
	User        *Userinfo
	Host        string
	Path        string
	RawPath     string
	OmitHost    bool
	ForceQuery  bool
	RawQuery    string
	Fragment    string
	RawFragment string
}

// Userinfo is the user name and the password of a URL.
type Userinfo struct {
	username    string
	password    string
	passwordSet bool
}

// User returns the Userinfo of a user name without a password.
func User(username string) *Userinfo {
	return &Userinfo{username: username, password: "", passwordSet: false}
}

// UserPassword returns the Userinfo of a user name and a password.
func UserPassword(username, password string) *Userinfo {
	return &Userinfo{username: username, password: password, passwordSet: true}
}

// Username returns the user name.
func (u *Userinfo) Username() string {
	if u == nil {
		return ""
	}
	return u.username
}

// Password returns the password and whether there is one.
func (u *Userinfo) Password() (string, bool) {
	if u == nil {
		return "", false
	}
	return u.password, u.passwordSet
}

// String returns the user information as a URL writes it.
func (u *Userinfo) String() string {
	if u == nil {
		return ""
	}
	s := native.escape(u.username, encodeUserPassword)
	if u.passwordSet {
		s += ":" + native.escape(u.password, encodeUserPassword)
	}
	return s
}

// cut splits s around the first sep, as strings.Cut does.
func cut(s, sep string) (before, after string, found bool) {
	i := strings.Index(s, sep)
	if i >= 0 {
		return s[:i], s[i+len(sep):], true
	}
	return s, "", false
}

// getScheme splits "http:" off a URL. A URL that does not begin with a
// scheme has none.
func getScheme(rawURL string) (scheme, path string, err error) {
	for i := 0; i < len(rawURL); i++ {
		c := rawURL[i]
		switch {
		case 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z':
		case '0' <= c && c <= '9' || c == '+' || c == '-' || c == '.':
			if i == 0 {
				return "", rawURL, nil
			}
		case c == ':':
			if i == 0 {
				return "", "", errors.New("missing protocol scheme")
			}
			return rawURL[:i], rawURL[i+1:], nil
		default:
			return "", rawURL, nil
		}
	}
	return "", rawURL, nil
}

// Parse parses a URL, which may be relative.
func Parse(rawURL string) (*URL, error) {
	u, frag, _ := cut(rawURL, "#")
	url, err := parse(u, false)
	if err != nil {
		return nil, &Error{Op: "parse", URL: u, Err: err}
	}
	if frag == "" {
		return url, nil
	}
	if err = url.setFragment(frag); err != nil {
		return nil, &Error{Op: "parse", URL: rawURL, Err: err}
	}
	return url, nil
}

// ParseRequestURI parses the URL of an HTTP request line, which is an
// absolute URL or a path that begins with a slash, and has no fragment.
func ParseRequestURI(rawURL string) (*URL, error) {
	url, err := parse(rawURL, true)
	if err != nil {
		return nil, &Error{Op: "parse", URL: rawURL, Err: err}
	}
	return url, nil
}

// parse parses a URL without a fragment. One that arrived in a request may
// not be a relative path.
func parse(rawURL string, viaRequest bool) (*URL, error) {
	if native.hasControlByte(rawURL) {
		return nil, errors.New("net/url: invalid control character in URL")
	}

	if rawURL == "" && viaRequest {
		return nil, errors.New("empty url")
	}
	url := &URL{}

	if rawURL == "*" {
		url.Path = "*"
		return url, nil
	}

	scheme, rest, err := getScheme(rawURL)
	if err != nil {
		return nil, err
	}
	url.Scheme = strings.ToLower(scheme)

	if strings.HasSuffix(rest, "?") && strings.Count(rest, "?") == 1 {
		url.ForceQuery = true
		rest = rest[:len(rest)-1]
	} else {
		rest, url.RawQuery, _ = cut(rest, "?")
	}

	if !strings.HasPrefix(rest, "/") {
		if url.Scheme != "" {
			url.Opaque = rest
			return url, nil
		}
		if viaRequest {
			return nil, errors.New("invalid URI for request")
		}

		if segment, _, _ := cut(rest, "/"); strings.Contains(segment, ":") {
			return nil, errors.New("first path segment in URL cannot contain colon")
		}
	}

	if (url.Scheme != "" || !viaRequest && !strings.HasPrefix(rest, "///")) && strings.HasPrefix(rest, "//") {
		authority := rest[2:]
		rest = ""
		if i := strings.Index(authority, "/"); i >= 0 {
			rest = authority[i:]
			authority = authority[:i]
		}
		url.User, url.Host, err = parseAuthority(authority)
		if err != nil {
			return nil, err
		}
	} else if url.Scheme != "" && strings.HasPrefix(rest, "/") {
		url.OmitHost = true
	}
	if err := url.setPath(rest); err != nil {
		return nil, err
	}
	return url, nil
}

// parseAuthority splits [userinfo@]host.
func parseAuthority(authority string) (user *Userinfo, host string, err error) {
	i := strings.LastIndex(authority, "@")
	if i < 0 {
		host, err = parseHost(authority)
	} else {
		host, err = parseHost(authority[i+1:])
	}
	if err != nil {
		return nil, "", err
	}
	if i < 0 {
		return nil, host, nil
	}
	userinfo := authority[:i]
	if !validUserinfo(userinfo) {
		return nil, "", errors.New("net/url: invalid userinfo")
	}
	if !strings.Contains(userinfo, ":") {
		if userinfo, err = unescape(userinfo, encodeUserPassword); err != nil {
			return nil, "", err
		}
		user = User(userinfo)
	} else {
		username, password, _ := cut(userinfo, ":")
		if username, err = unescape(username, encodeUserPassword); err != nil {
			return nil, "", err
		}
		if password, err = unescape(password, encodeUserPassword); err != nil {
			return nil, "", err
		}
		user = UserPassword(username, password)
	}
	return user, host, nil
}

// parseHost checks host[:port], where the host may be an address in
// brackets with a zone.
func parseHost(host string) (string, error) {
	if strings.HasPrefix(host, "[") {
		i := strings.LastIndex(host, "]")
		if i < 0 {
			return "", errors.New("missing ']' in host")
		}
		colonPort := host[i+1:]
		if !validOptionalPort(colonPort) {
			return "", fmt.Errorf("invalid port %q after host", colonPort)
		}

		zone := strings.Index(host[:i], "%25")
		if zone >= 0 {
			host1, err := unescape(host[:zone], encodeHost)
			if err != nil {
				return "", err
			}
			host2, err := unescape(host[zone:i], encodeZone)
			if err != nil {
				return "", err
			}
			host3, err := unescape(host[i:], encodeHost)
			if err != nil {
				return "", err
			}
			return host1 + host2 + host3, nil
		}
	} else if i := strings.LastIndex(host, ":"); i != -1 {
		colonPort := host[i:]
		if !validOptionalPort(colonPort) {
			return "", fmt.Errorf("invalid port %q after host", colonPort)
		}
	}

	return unescape(host, encodeHost)
}

// setPath sets Path from the escaped p, and RawPath where the two say
// different things.
func (u *URL) setPath(p string) error {
	path, err := unescape(p, encodePath)
	if err != nil {
		return err
	}
	u.Path = path
	if escp := native.escape(path, encodePath); p == escp {
		u.RawPath = ""
	} else {
		u.RawPath = p
	}
	return nil
}

// EscapedPath returns the path as the URL writes it: RawPath when that is
// a valid escaping of Path, and Path escaped otherwise.
func (u *URL) EscapedPath() string {
	if u.RawPath != "" && native.validEncoded(u.RawPath, encodePath) {
		p, err := unescape(u.RawPath, encodePath)
		if err == nil && p == u.Path {
			return u.RawPath
		}
	}
	if u.Path == "*" {
		return "*" // don't escape (Issue 11202)
	}
	return native.escape(u.Path, encodePath)
}

// setFragment is setPath for the fragment.
func (u *URL) setFragment(f string) error {
	frag, err := unescape(f, encodeFragment)
	if err != nil {
		return err
	}
	u.Fragment = frag
	if escf := native.escape(frag, encodeFragment); f == escf {
		u.RawFragment = ""
	} else {
		u.RawFragment = f
	}
	return nil
}

// EscapedFragment is EscapedPath for the fragment.
func (u *URL) EscapedFragment() string {
	if u.RawFragment != "" && native.validEncoded(u.RawFragment, encodeFragment) {
		f, err := unescape(u.RawFragment, encodeFragment)
		if err == nil && f == u.Fragment {
			return u.RawFragment
		}
	}
	return native.escape(u.Fragment, encodeFragment)
}

// validOptionalPort reports whether port is empty or a colon and digits.
func validOptionalPort(port string) bool {
	if port == "" {
		return true
	}
	if port[0] != ':' {
		return false
	}
	for i := 1; i < len(port); i++ {
		if port[i] < '0' || port[i] > '9' {
			return false
		}
	}
	return true
}

// validUserinfo reports whether s has only bytes that user information
// may have. An at sign is tolerated, as browsers tolerate it.
func validUserinfo(s string) bool {
	for i := 0; i < len(s); i++ {
		r := s[i]
		if 'A' <= r && r <= 'Z' {
			continue
		}
		if 'a' <= r && r <= 'z' {
			continue
		}
		if '0' <= r && r <= '9' {
			continue
		}
		switch r {
		case '-', '.', '_', ':', '~', '!', '$', '&', '\'',
			'(', ')', '*', '+', ',', ';', '=', '%':
			continue
		case '@':
			continue
		default:
			return false
		}
	}
	return true
}

// String returns the URL as text.
func (u *URL) String() string {
	buf := ""
	if u.Scheme != "" {
		buf += u.Scheme + ":"
	}
	if u.Opaque != "" {
		buf += u.Opaque
	} else {
		if u.Scheme != "" || u.Host != "" || u.User != nil {
			if u.OmitHost && u.Host == "" && u.User == nil {
			} else {
				if u.Host != "" || u.Path != "" || u.User != nil {
					buf += "//"
				}
				if ui := u.User; ui != nil {
					buf += ui.String() + "@"
				}
				if h := u.Host; h != "" {
					buf += native.escape(h, encodeHost)
				}
			}
		}
		path := u.EscapedPath()
		if path != "" && path[0] != '/' && u.Host != "" {
			buf += "/"
		}
		if buf == "" {
			if segment, _, _ := cut(path, "/"); strings.Contains(segment, ":") {
				buf += "./"
			}
		}
		buf += path
	}
	if u.ForceQuery || u.RawQuery != "" {
		buf += "?" + u.RawQuery
	}
	if u.Fragment != "" {
		buf += "#" + u.EscapedFragment()
	}
	return buf
}

// Redacted is String with any password replaced by "xxxxx".
func (u *URL) Redacted() string {
	if u == nil {
		return ""
	}

	ru := *u
	if _, has := ru.User.Password(); has {
		ru.User = UserPassword(ru.User.Username(), "xxxxx")
	}
	return ru.String()
}

// IsAbs reports whether the URL has a scheme.
func (u *URL) IsAbs() bool {
	return u.Scheme != ""
}

// Query parses RawQuery, leaving out what is malformed.
func (u *URL) Query() Values {
	v, _ := ParseQuery(u.RawQuery)
	return v
}

// RequestURI returns what a request line has for the URL: the escaped
// path and the query.
func (u *URL) RequestURI() string {
	result := u.Opaque
	if result == "" {
		result = u.EscapedPath()
		if result == "" {
			result = "/"
		}
	} else {
		if strings.HasPrefix(result, "//") {
			result = u.Scheme + ":" + result
		}
	}
	if u.ForceQuery || u.RawQuery != "" {
		result += "?" + u.RawQuery
	}
	return result
}

// Parse parses ref as a URL relative to u: an absolute ref stays as it is,
// and a relative one is resolved against u.
func (u *URL) Parse(ref string) (*URL, error) {
	refURL, err := Parse(ref)
	if err != nil {
		return nil, err
	}
	return u.ResolveReference(refURL), nil
}

// ResolveReference resolves ref against u, which is absolute, as RFC 3986
// says: what ref lacks from the left it takes from u, and the path of a
// relative ref replaces the last element of u's.
func (u *URL) ResolveReference(ref *URL) *URL {
	url := *ref
	if ref.Scheme == "" {
		url.Scheme = u.Scheme
	}
	if ref.Scheme != "" || ref.Host != "" || ref.User != nil {
		// The reference names its own host: only the path is cleaned.
		url.setPath(resolvePath(ref.EscapedPath(), ""))
		return &url
	}
	if ref.Opaque != "" {
		url.User = nil
		url.Host = ""
		url.Path = ""
		return &url
	}
	if ref.Path == "" && !ref.ForceQuery && ref.RawQuery == "" {
		url.RawQuery = u.RawQuery
		if ref.Fragment == "" {
			url.Fragment = u.Fragment
			url.RawFragment = u.RawFragment
		}
	}
	if ref.Path == "" && u.Opaque != "" {
		url.Opaque = u.Opaque
		url.User = nil
		url.Host = ""
		url.Path = ""
		return &url
	}
	// A path, absolute or relative to u's.
	url.Host = u.Host
	url.User = u.User
	url.setPath(resolvePath(u.EscapedPath(), ref.EscapedPath()))
	return &url
}

// resolvePath applies the path ref to the path base: ref replaces what
// follows the last slash of base, and "." and ".." elements are resolved.
// The result begins with a slash.
func resolvePath(base, ref string) string {
	full := ""
	if ref == "" {
		full = base
	} else if ref[0] != '/' {
		full = base[:strings.LastIndex(base, "/")+1] + ref
	} else {
		full = ref
	}
	if full == "" {
		return ""
	}
	var out []string
	elements := strings.Split(full, "/")
	last := elements[len(elements)-1]
	for i, element := range elements {
		switch element {
		case ".":
		case "..":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
		default:
			// The empty element before the first slash is the root.
			if element != "" || i > 0 {
				out = append(out, element)
			}
		}
	}
	path := "/" + strings.Join(out, "/")
	if last == "." || last == ".." {
		// A directory, so a slash ends it.
		if path != "/" {
			path += "/"
		}
	}
	return path
}

// Hostname returns Host without a port, and without the brackets of an
// address.
func (u *URL) Hostname() string {
	host, _ := splitHostPort(u.Host)
	return host
}

// Port returns the port of Host, or "" when it has none.
func (u *URL) Port() string {
	_, port := splitHostPort(u.Host)
	return port
}

// splitHostPort splits host:port where the port is digits.
func splitHostPort(hostPort string) (host, port string) {
	host = hostPort

	colon := strings.LastIndex(host, ":")
	if colon != -1 && validOptionalPort(host[colon:]) {
		port = host[colon+1:]
		host = host[:colon]
	}

	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = host[1 : len(host)-1]
	}

	return host, port
}

// Values maps the keys of a query or a form to their values. Keys are case
// sensitive.
type Values map[string][]string

// Get returns the first value of key, or "".
func (v Values) Get(key string) string {
	vs := v[key]
	if len(vs) == 0 {
		return ""
	}
	return vs[0]
}

// Set makes value the only value of key.
func (v Values) Set(key, value string) {
	v[key] = []string{value}
}

// Add adds value to the values of key.
func (v Values) Add(key, value string) {
	v[key] = append(v[key], value)
}

// Del removes key.
func (v Values) Del(key string) {
	delete(v, key)
}

// Has reports whether key has a value.
func (v Values) Has(key string) bool {
	_, ok := v[key]
	return ok
}

// ParseQuery parses key=value settings separated by ampersands. The map
// holds every setting that is well formed; the error is the first that is
// not.
func ParseQuery(query string) (Values, error) {
	m := Values{}
	err := parseQuery(m, query)
	return m, err
}

func parseQuery(m Values, query string) (err error) {
	if query == "" {
		return nil
	}
	for _, key := range strings.Split(query, "&") {
		if strings.Contains(key, ";") {
			err = fmt.Errorf("invalid semicolon separator in query")
			continue
		}
		if key == "" {
			continue
		}
		key, value, _ := cut(key, "=")
		key, err1 := QueryUnescape(key)
		if err1 != nil {
			if err == nil {
				err = err1
			}
			continue
		}
		value, err1 = QueryUnescape(value)
		if err1 != nil {
			if err == nil {
				err = err1
			}
			continue
		}
		m[key] = append(m[key], value)
	}
	return err
}

// Encode writes the values as a query, sorted by key.
func (v Values) Encode() string {
	if len(v) == 0 {
		return ""
	}
	buf := ""
	keys := make([]string, 0, len(v))
	for k := range v {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		vs := v[k]
		keyEscaped := QueryEscape(k)
		for _, v := range vs {
			if len(buf) > 0 {
				buf += "&"
			}
			buf += keyEscaped + "=" + QueryEscape(v)
		}
	}
	return buf
}
