// The text of log calls no native. This file gives the harness the one
// unexported function it holds to Go: the header of a line at an instant.
package log

// Header is header.
func Header(prefix string, flag int, sec, nsec int64) string {
	return header(prefix, flag, sec, nsec)
}
