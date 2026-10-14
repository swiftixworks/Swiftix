// The natives the Go text of strconv calls, as Go's own functions: they
// fail with an error whose text is Go's, as those of the run-time library
// do. What else the text needs it reaches by importing "strconv", which
// here is Go's.
package strconv

import "strconv"

var native = struct {
	ParseInt   func(s string, base, bitSize int) (int64, error)
	ParseUint  func(s string, base, bitSize int) (uint64, error)
	ParseFloat func(s string, bitSize int) (float64, error)
}{
	ParseInt:   strconv.ParseInt,
	ParseUint:  strconv.ParseUint,
	ParseFloat: strconv.ParseFloat,
}
