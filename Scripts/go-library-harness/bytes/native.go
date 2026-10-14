package bytes

import std "bytes"

// The natives of the package, for running its text in real Go.
var native = struct {
	indexByte func(p []byte, c byte) int
	index     func(s, sep []byte) int
	equal     func(a, b []byte) bool
	compare   func(a, b []byte) int
}{
	indexByte: std.IndexByte,
	index:     std.Index,
	equal:     std.Equal,
	compare:   std.Compare,
}
