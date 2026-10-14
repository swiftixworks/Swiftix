package http

import (
	"sort"
	"strings"
)

// A Header holds the fields of an HTTP header. Keys are in canonical form:
// the first letter and each letter after a hyphen in upper case.
type Header map[string][]string

// Add adds value to the values of key.
func (h Header) Add(key, value string) {
	key = native.CanonicalHeaderKey(key)
	h[key] = append(h[key], value)
}

// Set makes value the only value of key.
func (h Header) Set(key, value string) {
	h[native.CanonicalHeaderKey(key)] = []string{value}
}

// Get returns the first value of key, or "". The key may be in any case.
func (h Header) Get(key string) string {
	if h == nil {
		return ""
	}
	v := h[native.CanonicalHeaderKey(key)]
	if len(v) == 0 {
		return ""
	}
	return v[0]
}

// Values returns every value of key. The slice is the header's own.
func (h Header) Values(key string) []string {
	if h == nil {
		return nil
	}
	return h[native.CanonicalHeaderKey(key)]
}

// get is Get for a key that is canonical already.
func (h Header) get(key string) string {
	if v := h[key]; len(v) > 0 {
		return v[0]
	}
	return ""
}

// has reports whether the header has the canonical key.
func (h Header) has(key string) bool {
	_, ok := h[key]
	return ok
}

// Del removes key.
func (h Header) Del(key string) {
	delete(h, native.CanonicalHeaderKey(key))
}

// Clone returns a copy of h that shares nothing with it.
func (h Header) Clone() Header {
	if h == nil {
		return nil
	}
	h2 := Header{}
	for k, vv := range h {
		vv2 := make([]string, len(vv))
		copy(vv2, vv)
		h2[k] = vv2
	}
	return h2
}

// text returns the fields as they are written in a message, one per line
// and sorted by key. A line break inside a value becomes a space, and a
// key that is no token is left out.
func (h Header) text() string {
	if len(h) == 0 {
		return ""
	}
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	if len(keys) > 1 {
		sort.Strings(keys)
	}
	text := ""
	for _, k := range keys {
		if !native.validToken(k) {
			continue
		}
		for _, v := range h[k] {
			if strings.Contains(v, "\n") {
				v = strings.Join(strings.Split(v, "\n"), " ")
			}
			if strings.Contains(v, "\r") {
				v = strings.Join(strings.Split(v, "\r"), " ")
			}
			text += k + ": " + trimString(v) + "\r\n"
		}
	}
	return text
}

// CanonicalHeaderKey returns the canonical form of a header key:
// "accept-encoding" becomes "Accept-Encoding". A key with a space or a byte
// no key has is returned as it is.
func CanonicalHeaderKey(s string) string { return native.CanonicalHeaderKey(s) }

// isSpace reports whether b is white space of a header: a space, a tab, or
// a line break.
func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// trimString returns s without leading and trailing white space.
func trimString(s string) string {
	for len(s) > 0 && isSpace(s[0]) {
		s = s[1:]
	}
	for len(s) > 0 && isSpace(s[len(s)-1]) {
		s = s[:len(s)-1]
	}
	return s
}

// hasToken reports whether token is one of the elements of the header
// value v, which commas and spaces separate. The token is in lower case;
// the value may be in any case.
func hasToken(v, token string) bool {
	if v == "" {
		return false
	}
	if v == token {
		return true
	}
	v = strings.ToLower(v)
	if !strings.Contains(v, token) {
		return false
	}
	for start := 0; start+len(token) <= len(v); start++ {
		if v[start:start+len(token)] != token {
			continue
		}
		if start > 0 && !isTokenBoundary(v[start-1]) {
			continue
		}
		if end := start + len(token); end != len(v) && !isTokenBoundary(v[end]) {
			continue
		}
		return true
	}
	return false
}

func isTokenBoundary(b byte) bool {
	return b == ' ' || b == ',' || b == '\t'
}

// valuesContainToken reports whether a comma-separated element of any of
// the values is token, in any case.
func valuesContainToken(values []string, token string) bool {
	for _, v := range values {
		if !strings.Contains(strings.ToLower(v), token) {
			continue
		}
		for _, element := range strings.Split(v, ",") {
			if strings.ToLower(trimOWS(element)) == token {
				return true
			}
		}
	}
	return false
}

// trimOWS returns s without the spaces and tabs around it.
func trimOWS(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

// DetectContentType returns the content type of data that begins with
// these bytes, from at most the first 512 of them, by the algorithm of
// https://mimesniff.spec.whatwg.org/. Data it does not recognize is
// "application/octet-stream".
func DetectContentType(data []byte) string { return native.DetectContentType(data) }
