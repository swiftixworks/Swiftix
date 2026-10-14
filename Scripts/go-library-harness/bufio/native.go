package bufio

import "bytes"

// The native of the package, for running its text in real Go.
var native = struct {
	indexByte func(p []byte, c byte) int
}{
	indexByte: bytes.IndexByte,
}
