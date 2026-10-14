package http

import (
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync"
)

// A ServeMux routes a request to the handler of the pattern that matches
// it. A pattern is
//
//	[METHOD ][HOST]/[PATH]
//
// where a path that ends in a slash matches every path below it, a segment
// "{name}" matches any one segment, "{name...}" at the end matches the
// rest of the path, and "{$}" at the end matches the slash alone. Of the
// patterns that match, the most specific one handles the request: one that
// names a host before one that does not, one that names the method before
// one that does not, and a literal segment before a wildcard. Two patterns
// of which neither is more specific cannot both be registered.
//
// A request for a path without the final slash of a registered subtree is
// redirected to the path with it, and so is one whose path has "." or ".."
// elements or doubled slashes, to the clean path.
type ServeMux struct {
	mu sync.Mutex
	// The patterns, by host and then by method, each list with a more
	// specific pattern before a more general one that it overlaps.
	hosts map[string]map[string][]*muxEntry
	all   []*muxEntry
}

type muxEntry struct {
	pat     *pattern
	handler Handler
}

// NewServeMux returns a ServeMux without patterns.
func NewServeMux() *ServeMux {
	return &ServeMux{hosts: map[string]map[string][]*muxEntry{}}
}

// DefaultServeMux is the ServeMux that Handle and HandleFunc register with
// and that a server without a handler serves.
var DefaultServeMux = NewServeMux()

// A pattern is a parsed ServeMux pattern.
type pattern struct {
	str      string
	method   string
	host     string
	segments []segment
}

func (p *pattern) lastSegment() segment {
	return p.segments[len(p.segments)-1]
}

// A segment is one element of a pattern's path: literal text, the name of
// a wildcard, or "/" for the "{$}" that ends a pattern.
type segment struct {
	s     string
	wild  bool
	multi bool
}

// parsePattern parses a pattern. An error says where in the pattern it is.
func parsePattern(s string) (*pattern, error) {
	if len(s) == 0 {
		return nil, errors.New("empty pattern")
	}
	off := 0
	fail := func(err error) (*pattern, error) {
		return nil, fmt.Errorf("at offset %d: %w", off, err)
	}

	method := ""
	rest := s
	found := false
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' || s[i] == '\t' {
			method = s[:i]
			rest = s[i+1:]
			for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
				rest = rest[1:]
			}
			found = true
			break
		}
	}
	if method != "" && !native.validToken(method) {
		return fail(fmt.Errorf("invalid method %q", method))
	}
	p := &pattern{str: s, method: method}

	if found {
		off = len(method) + 1
	}
	i := strings.Index(rest, "/")
	if i < 0 {
		return fail(errors.New("host/path missing /"))
	}
	p.host = rest[:i]
	rest = rest[i:]
	if j := strings.Index(p.host, "{"); j >= 0 {
		off += j
		return fail(errors.New("host contains '{' (missing initial '/'?)"))
	}
	off += i

	if method != "" && method != "CONNECT" && rest != cleanPath(rest) {
		return fail(errors.New("non-CONNECT pattern with unclean path can never match"))
	}

	seenNames := map[string]bool{}
	for len(rest) > 0 {
		// rest begins with the slash before the next segment.
		rest = rest[1:]
		off = len(s) - len(rest)
		if len(rest) == 0 {
			// A final slash matches everything below it.
			p.segments = append(p.segments, segment{s: "", wild: true, multi: true})
			break
		}
		i := strings.Index(rest, "/")
		if i < 0 {
			i = len(rest)
		}
		seg := rest[:i]
		rest = rest[i:]
		brace := strings.Index(seg, "{")
		if brace < 0 {
			p.segments = append(p.segments, segment{s: pathUnescape(seg), wild: false, multi: false})
			continue
		}
		if brace != 0 {
			return fail(errors.New("bad wildcard segment (must start with '{')"))
		}
		if seg[len(seg)-1] != '}' {
			return fail(errors.New("bad wildcard segment (must end with '}')"))
		}
		name := seg[1 : len(seg)-1]
		if name == "$" {
			if len(rest) != 0 {
				return fail(errors.New("{$} not at end"))
			}
			p.segments = append(p.segments, segment{s: "/", wild: false, multi: false})
			break
		}
		multi := strings.HasSuffix(name, "...")
		if multi {
			name = name[:len(name)-3]
		}
		if multi && len(rest) != 0 {
			return fail(errors.New("{...} wildcard not at end"))
		}
		if name == "" {
			return fail(errors.New("empty wildcard"))
		}
		if !isValidWildcardName(name) {
			return fail(fmt.Errorf("bad wildcard name %q", name))
		}
		if seenNames[name] {
			return fail(fmt.Errorf("duplicate wildcard name %q", name))
		}
		seenNames[name] = true
		p.segments = append(p.segments, segment{s: name, wild: true, multi: multi})
	}
	return p, nil
}

// isValidWildcardName reports whether s is an identifier of ASCII letters,
// digits, and underscores. Go also takes letters and digits beyond ASCII.
func isValidWildcardName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		isLetter := 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || c >= 0x80
		isDigit := '0' <= c && c <= '9'
		if !isLetter && c != '_' && (i == 0 || !isDigit) {
			return false
		}
	}
	return true
}

func pathUnescape(path string) string {
	if !strings.Contains(path, "%") {
		return path
	}
	u, err := url.PathUnescape(path)
	if err != nil {
		// What is no escape stands for itself.
		return path
	}
	return u
}

// How the requests two patterns match relate.
type relationship int

const (
	equivalent   relationship = iota // both match the same requests
	moreGeneral                      // the first matches all the second does, and more
	moreSpecific                     // the second matches all the first does, and more
	disjoint                         // no request matches both
	overlaps                         // some request matches both, and neither is more specific
)

// conflictsWith reports whether p1 and p2 cannot both be registered: some
// request matches both and neither is the more specific.
func (p1 *pattern) conflictsWith(p2 *pattern) bool {
	if p1.host != p2.host {
		// A pattern with a host comes before one without, and two hosts
		// share no request.
		return false
	}
	rel := p1.comparePathsAndMethods(p2)
	return rel == equivalent || rel == overlaps
}

func (p1 *pattern) comparePathsAndMethods(p2 *pattern) relationship {
	mrel := p1.compareMethods(p2)
	if mrel == disjoint {
		return disjoint
	}
	return combineRelationships(mrel, p1.comparePaths(p2))
}

// compareMethods relates the methods of two patterns. No method is every
// method, and GET is HEAD as well.
func (p1 *pattern) compareMethods(p2 *pattern) relationship {
	if p1.method == p2.method {
		return equivalent
	}
	if p1.method == "" {
		return moreGeneral
	}
	if p2.method == "" {
		return moreSpecific
	}
	if p1.method == "GET" && p2.method == "HEAD" {
		return moreGeneral
	}
	if p2.method == "GET" && p1.method == "HEAD" {
		return moreSpecific
	}
	return disjoint
}

// comparePaths relates the paths of two patterns, segment by segment.
func (p1 *pattern) comparePaths(p2 *pattern) relationship {
	// Paths of different lengths share a path only when the shorter one
	// ends in a wildcard for the rest.
	if len(p1.segments) != len(p2.segments) && !p1.lastSegment().multi && !p2.lastSegment().multi {
		return disjoint
	}
	segs1 := p1.segments
	segs2 := p2.segments
	rel := equivalent
	for len(segs1) > 0 && len(segs2) > 0 {
		rel = combineRelationships(rel, compareSegments(segs1[0], segs2[0]))
		if rel == disjoint {
			return rel
		}
		segs1 = segs1[1:]
		segs2 = segs2[1:]
	}
	if len(segs1) == 0 && len(segs2) == 0 {
		return rel
	}
	// One pattern has segments left, which the other's final wildcard
	// takes in.
	if len(segs1) < len(segs2) && p1.lastSegment().multi {
		return combineRelationships(rel, moreGeneral)
	}
	if len(segs2) < len(segs1) && p2.lastSegment().multi {
		return combineRelationships(rel, moreSpecific)
	}
	return disjoint
}

func compareSegments(s1, s2 segment) relationship {
	if s1.multi && s2.multi {
		return equivalent
	}
	if s1.multi {
		return moreGeneral
	}
	if s2.multi {
		return moreSpecific
	}
	if s1.wild && s2.wild {
		return equivalent
	}
	if s1.wild {
		if s2.s == "/" {
			// A wildcard matches a segment, and "{$}" the lack of one.
			return disjoint
		}
		return moreGeneral
	}
	if s2.wild {
		if s1.s == "/" {
			return disjoint
		}
		return moreSpecific
	}
	if s1.s == s2.s {
		return equivalent
	}
	return disjoint
}

// combineRelationships relates two patterns of which one part relates as
// r1 and another as r2.
func combineRelationships(r1, r2 relationship) relationship {
	switch r1 {
	case equivalent:
		return r2
	case disjoint:
		return disjoint
	case overlaps:
		if r2 == disjoint {
			return disjoint
		}
		return overlaps
	}
	// r1 is moreGeneral or moreSpecific.
	switch r2 {
	case equivalent:
		return r1
	case inverseRelationship(r1):
		return overlaps
	}
	return r2
}

func inverseRelationship(r relationship) relationship {
	switch r {
	case moreSpecific:
		return moreGeneral
	case moreGeneral:
		return moreSpecific
	}
	return r
}

// describeConflict says why two patterns cannot both be registered.
func describeConflict(p1, p2 *pattern) string {
	mrel := p1.compareMethods(p2)
	prel := p1.comparePaths(p2)
	rel := combineRelationships(mrel, prel)
	if rel == equivalent {
		return fmt.Sprintf("%s matches the same requests as %s", p1.str, p2.str)
	}
	if rel != overlaps {
		panic("describeConflict called with non-conflicting patterns")
	}
	if prel == overlaps {
		return fmt.Sprintf("%[1]s and %[2]s both match some paths, like %[3]q.\nBut neither is more specific than the other.\n%[1]s matches %[4]q, but %[2]s doesn't.\n%[2]s matches %[5]q, but %[1]s doesn't.",
			p1.str, p2.str, commonPath(p1, p2), differencePath(p1, p2), differencePath(p2, p1))
	}
	if mrel == moreGeneral && prel == moreSpecific {
		return fmt.Sprintf("%s matches more methods than %s, but has a more specific path pattern", p1.str, p2.str)
	}
	if mrel == moreSpecific && prel == moreGeneral {
		return fmt.Sprintf("%s matches fewer methods than %s, but has a more general path pattern", p1.str, p2.str)
	}
	return fmt.Sprintf("bug: unexpected way for two patterns %s and %s to conflict", p1.str, p2.str)
}

// matchingSegment is a path segment that s matches.
func matchingSegment(s segment) string {
	if !s.multi && s.s != "/" {
		return "/" + s.s
	}
	return "/"
}

func matchingPath(segs []segment) string {
	path := ""
	for _, s := range segs {
		path += matchingSegment(s)
	}
	return path
}

// commonPath is a path that both of two overlapping patterns match.
func commonPath(p1, p2 *pattern) string {
	path := ""
	segs1 := p1.segments
	segs2 := p2.segments
	for len(segs1) > 0 && len(segs2) > 0 {
		if s1 := segs1[0]; s1.wild {
			path += matchingSegment(segs2[0])
		} else {
			path += matchingSegment(s1)
		}
		segs1 = segs1[1:]
		segs2 = segs2[1:]
	}
	if len(segs1) > 0 {
		path += matchingPath(segs1)
	} else if len(segs2) > 0 {
		path += matchingPath(segs2)
	}
	return path
}

// differencePath is a path that p1 matches and p2, which overlaps it,
// does not.
func differencePath(p1, p2 *pattern) string {
	path := ""
	segs1 := p1.segments
	segs2 := p2.segments
	for len(segs1) > 0 && len(segs2) > 0 {
		s1 := segs1[0]
		s2 := segs2[0]
		if s1.multi && s2.multi {
			// Both end here, so the difference lies before.
			return path + "/"
		}
		if s1.multi && !s2.multi {
			// s1 takes the rest, where s2 takes one segment or the lack
			// of one: the other of the two is the difference.
			path += "/"
			if s2.s == "/" {
				if s1.s != "" {
					path += s1.s
				} else {
					path += "x"
				}
			}
			return path
		}
		if !s1.multi && s2.multi {
			path += matchingSegment(s1)
		} else if s1.wild && s2.wild {
			path += matchingSegment(s1)
		} else if s1.wild && !s2.wild {
			// Any segment but the literal of s2.
			if s1.s != s2.s {
				path += matchingSegment(s1)
			} else {
				path += "/" + s2.s + "x"
			}
		} else if !s1.wild && s2.wild {
			path += matchingSegment(s1)
		} else {
			if s1.s != s2.s {
				panic(fmt.Sprintf("literals differ: %q and %q", s1.s, s2.s))
			}
			path += matchingSegment(s1)
		}
		segs1 = segs1[1:]
		segs2 = segs2[1:]
	}
	if len(segs1) > 0 {
		path += matchingPath(segs1)
	} else if len(segs2) > 0 {
		path += matchingPath(segs2)
	}
	return path
}

// Handle registers the handler for the pattern. It panics when the pattern
// is malformed or conflicts with one that is registered.
func (mux *ServeMux) Handle(pattern string, handler Handler) {
	if err := mux.register(pattern, handler); err != nil {
		panic(err)
	}
}

// HandleFunc registers the function as the handler for the pattern.
func (mux *ServeMux) HandleFunc(pattern string, handler func(ResponseWriter, *Request)) {
	if handler == nil {
		panic(errors.New("http: nil handler"))
	}
	if err := mux.register(pattern, HandlerFunc(handler)); err != nil {
		panic(err)
	}
}

// Handle registers the handler for the pattern in DefaultServeMux.
func Handle(pattern string, handler Handler) {
	DefaultServeMux.Handle(pattern, handler)
}

// HandleFunc registers the function as the handler for the pattern in
// DefaultServeMux.
func HandleFunc(pattern string, handler func(ResponseWriter, *Request)) {
	DefaultServeMux.HandleFunc(pattern, handler)
}

func (mux *ServeMux) register(patstr string, handler Handler) error {
	if patstr == "" {
		return errors.New("http: invalid pattern")
	}
	if handler == nil {
		return errors.New("http: nil handler")
	}
	if f, ok := handler.(HandlerFunc); ok && f == nil {
		return errors.New("http: nil handler")
	}

	pat, err := parsePattern(patstr)
	if err != nil {
		return fmt.Errorf("parsing %q: %w", patstr, err)
	}

	mux.mu.Lock()
	defer mux.mu.Unlock()
	if mux.hosts == nil {
		mux.hosts = map[string]map[string][]*muxEntry{}
	}
	for _, e := range mux.all {
		if pat.conflictsWith(e.pat) {
			// Go names the lines of the two registrations here, which a
			// program of this toolchain cannot ask for.
			return fmt.Errorf("pattern %q (registered at %s) conflicts with pattern %q (registered at %s):\n%s",
				pat.str, "unknown location", e.pat.str, "unknown location", describeConflict(pat, e.pat))
		}
	}
	entry := &muxEntry{pat: pat, handler: handler}
	mux.all = append(mux.all, entry)
	methods := mux.hosts[pat.host]
	if methods == nil {
		methods = map[string][]*muxEntry{}
		mux.hosts[pat.host] = methods
	}
	// Before the first pattern it is more specific than: every pattern
	// more specific than this one is more specific than that one too, and
	// so stands before it already.
	list := methods[pat.method]
	at := len(list)
	for i, e := range list {
		if pat.comparePaths(e.pat) == moreSpecific {
			at = i
			break
		}
	}
	list = append(list, entry)
	copy(list[at+1:], list[at:len(list)-1])
	list[at] = entry
	methods[pat.method] = list
	return nil
}

// requestPath is the path of a request in the pieces patterns match: its
// segments unescaped, with "/" last for a path that ends in a slash, and
// where each segment begins in the path.
type requestPath struct {
	path     string
	segments []string
	starts   []int
}

func splitPath(path string) *requestPath {
	rp := &requestPath{path: path}
	parts := strings.Split(path[1:], "/")
	offset := 0
	for i, part := range parts {
		rp.starts = append(rp.starts, offset)
		if i == len(parts)-1 && part == "" {
			rp.segments = append(rp.segments, "/")
		} else {
			rp.segments = append(rp.segments, pathUnescape(part))
		}
		offset += len(part) + 1
	}
	return rp
}

// match reports whether the pattern's path matches rp, and what its
// wildcards stand for.
func (p *pattern) match(rp *requestPath) (bool, []string) {
	var matches []string
	n := len(rp.segments)
	for i, seg := range p.segments {
		if seg.multi {
			// The rest of the path, which is at least a slash.
			if i >= n {
				return false, nil
			}
			if seg.s != "" {
				matches = append(matches, pathUnescape(rp.path[rp.starts[i]+1:]))
			}
			return true, matches
		}
		if i >= n {
			return false, nil
		}
		if seg.wild {
			if rp.segments[i] == "/" {
				return false, nil
			}
			matches = append(matches, rp.segments[i])
		} else if seg.s != rp.segments[i] {
			return false, nil
		}
	}
	return len(p.segments) == n, matches
}

// match finds the entry for a host, a method, and a path: among the
// patterns for the host before those for any host, and among those for the
// method before those for any method, the first that matches the path.
func (mux *ServeMux) match(host, method, path string) (*muxEntry, []string) {
	if len(path) == 0 || path[0] != '/' {
		return nil, nil
	}
	rp := splitPath(path)
	if host != "" {
		if e, m := matchMethodAndPath(mux.hosts[host], method, rp); e != nil {
			return e, m
		}
	}
	return matchMethodAndPath(mux.hosts[""], method, rp)
}

func matchMethodAndPath(methods map[string][]*muxEntry, method string, rp *requestPath) (*muxEntry, []string) {
	if methods == nil {
		return nil, nil
	}
	if e, m := matchPath(methods[method], rp); e != nil {
		return e, m
	}
	if method == "HEAD" {
		// A pattern for GET takes HEAD as well.
		if e, m := matchPath(methods["GET"], rp); e != nil {
			return e, m
		}
	}
	if method == "" {
		return nil, nil
	}
	return matchPath(methods[""], rp)
}

func matchPath(entries []*muxEntry, rp *requestPath) (*muxEntry, []string) {
	for _, e := range entries {
		if ok, m := e.pat.match(rp); ok {
			return e, m
		}
	}
	return nil, nil
}

// exactMatch reports whether the entry matches the path as such, and not
// as a path below the slash its pattern ends in.
func exactMatch(e *muxEntry, path string) bool {
	if e == nil {
		return false
	}
	if !e.pat.lastSegment().multi {
		return true
	}
	// A pattern that ends in a slash matches the path exactly when the
	// path ends there too.
	if len(path) > 0 && path[len(path)-1] != '/' {
		return false
	}
	return len(e.pat.segments) == strings.Count(path, "/")
}

// matchOrRedirect matches the path, and when nothing matches it exactly
// and a pattern does match it with a slash added, says to redirect there.
func (mux *ServeMux) matchOrRedirect(host, method, path string, u *url.URL) (*muxEntry, []string, *url.URL) {
	mux.mu.Lock()
	defer mux.mu.Unlock()

	e, matches := mux.match(host, method, path)
	if !exactMatch(e, path) && u != nil && !strings.HasSuffix(path, "/") {
		path += "/"
		e2, _ := mux.match(host, method, path)
		if exactMatch(e2, path) {
			return nil, nil, &url.URL{Path: cleanPath(u.Path) + "/", RawQuery: u.RawQuery}
		}
	}
	return e, matches, nil
}

// matchingMethods returns the methods of the patterns that match the host
// and the path, or the path with a slash added, sorted.
func (mux *ServeMux) matchingMethods(host, path string) []string {
	mux.mu.Lock()
	defer mux.mu.Unlock()
	set := map[string]bool{}
	paths := []string{path}
	if !strings.HasSuffix(path, "/") {
		paths = append(paths, path+"/")
	}
	hosts := []string{""}
	if host != "" {
		hosts = []string{host, ""}
	}
	for _, p := range paths {
		if len(p) == 0 || p[0] != '/' {
			continue
		}
		rp := splitPath(p)
		for _, h := range hosts {
			for method, entries := range mux.hosts[h] {
				if method == "" {
					continue
				}
				if e, _ := matchPath(entries, rp); e != nil {
					set[method] = true
				}
			}
		}
		if set["GET"] {
			set["HEAD"] = true
		}
	}
	methods := make([]string, 0, len(set))
	for m := range set {
		methods = append(methods, m)
	}
	sort.Strings(methods)
	return methods
}

// Handler returns the handler for the request and the pattern that
// matched: a redirect for a path that is not clean or lacks the slash of a
// subtree, and a "page not found" handler with the pattern "" when nothing
// matches.
func (mux *ServeMux) Handler(r *Request) (h Handler, pattern string) {
	h, p, _, _ := mux.findHandler(r)
	return h, p
}

func (mux *ServeMux) findHandler(r *Request) (h Handler, patStr string, pat *pattern, matches []string) {
	var e *muxEntry
	host := r.URL.Host
	escapedPath := r.URL.EscapedPath()
	path := escapedPath
	// The path of CONNECT is taken as it is.
	if r.Method == "CONNECT" {
		_, _, u := mux.matchOrRedirect(host, r.Method, path, r.URL)
		if u != nil {
			return RedirectHandler(u.String(), StatusMovedPermanently), u.Path, nil, nil
		}
		// With the request's host this time, and no redirect.
		e, matches, _ = mux.matchOrRedirect(r.Host, r.Method, path, nil)
	} else {
		// The host without its port, and the path clean.
		host = stripHostPort(r.Host)
		path = cleanPath(path)

		var u *url.URL
		e, matches, u = mux.matchOrRedirect(host, r.Method, path, r.URL)
		if u != nil {
			return RedirectHandler(u.String(), StatusMovedPermanently), u.Path, nil, nil
		}
		if path != escapedPath {
			// To the clean path.
			patStr := ""
			if e != nil {
				patStr = e.pat.str
			}
			u := &url.URL{Path: path, RawQuery: r.URL.RawQuery}
			return RedirectHandler(u.String(), StatusMovedPermanently), patStr, nil, nil
		}
	}
	if e == nil {
		// Nothing for the method: when a pattern matches but for the
		// method, the answer is that the method is not allowed.
		allowedMethods := mux.matchingMethods(host, path)
		if len(allowedMethods) > 0 {
			return HandlerFunc(func(w ResponseWriter, r *Request) {
				w.Header().Set("Allow", strings.Join(allowedMethods, ", "))
				Error(w, StatusText(StatusMethodNotAllowed), StatusMethodNotAllowed)
			}), "", nil, nil
		}
		return NotFoundHandler(), "", nil, nil
	}
	return e.handler, e.pat.str, e.pat, matches
}

// ServeHTTP passes the request to the handler whose pattern matches it.
func (mux *ServeMux) ServeHTTP(w ResponseWriter, r *Request) {
	if r.RequestURI == "*" {
		if r.ProtoAtLeast(1, 1) {
			w.Header().Set("Connection", "close")
		}
		w.WriteHeader(StatusBadRequest)
		return
	}
	var h Handler
	h, r.Pattern, r.pat, r.matches = mux.findHandler(r)
	h.ServeHTTP(w, r)
}

// cleanPath returns the canonical form of a path: rooted, without "." and
// ".." elements and doubled slashes, and with the final slash it had.
func cleanPath(p string) string {
	if p == "" {
		return "/"
	}
	if p[0] != '/' {
		p = "/" + p
	}
	if !strings.Contains(p, "//") && !strings.Contains(p, "/.") {
		// Clean already.
		return p
	}
	np := pathClean(p)
	// Cleaning takes the final slash away, except from the root.
	if p[len(p)-1] == '/' && np != "/" {
		if len(p) == len(np)+1 && strings.HasPrefix(p, np) {
			np = p
		} else {
			np += "/"
		}
	}
	return np
}

// pathClean returns the shortest path that names what p names, as Go's
// path.Clean does: no doubled slash, no "." element, and no ".." element
// that an element before it cancels.
func pathClean(p string) string {
	if p == "" {
		return "."
	}
	rooted := p[0] == '/'
	var out []string
	for _, element := range strings.Split(p, "/") {
		switch element {
		case "", ".":
		case "..":
			if len(out) > 0 && out[len(out)-1] != ".." {
				out = out[:len(out)-1]
			} else if !rooted {
				out = append(out, "..")
			}
		default:
			out = append(out, element)
		}
	}
	cleaned := strings.Join(out, "/")
	if rooted {
		return "/" + cleaned
	}
	if cleaned == "" {
		return "."
	}
	return cleaned
}

// stripHostPort returns h without a port.
func stripHostPort(h string) string {
	if !strings.Contains(h, ":") {
		return h
	}
	host, _, ok := splitHostPort(h)
	if !ok {
		// What cannot be split is left as it is.
		return h
	}
	return host
}

// splitHostPort splits "host:port" and "[host]:port", as net.SplitHostPort
// does, and reports whether the address has that form.
func splitHostPort(hostport string) (host, port string, ok bool) {
	i := strings.LastIndex(hostport, ":")
	if i < 0 {
		return "", "", false
	}
	if len(hostport) > 0 && hostport[0] == '[' {
		end := strings.Index(hostport, "]")
		if end < 0 || end+1 != i {
			return "", "", false
		}
		host = hostport[1:end]
		if strings.Contains(host, "[") || strings.Contains(host, "]") {
			return "", "", false
		}
	} else {
		host = hostport[:i]
		if strings.Contains(host, ":") || strings.Contains(host, "[") || strings.Contains(host, "]") {
			return "", "", false
		}
	}
	port = hostport[i+1:]
	if strings.Contains(port, "[") || strings.Contains(port, "]") {
		return "", "", false
	}
	return host, port, true
}
