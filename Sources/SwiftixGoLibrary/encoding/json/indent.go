package json

import "bytes"

// A SyntaxError is a description of a JSON syntax error.
type SyntaxError struct {
	msg    string // description of error
	Offset int64  // error occurred after reading Offset bytes
}

func (e *SyntaxError) Error() string { return e.msg }

// Valid reports whether data is a valid JSON encoding.
func Valid(data []byte) bool {
	msg, _ := native.valid(data)
	return msg == ""
}

// HTMLEscape appends to dst the JSON-encoded src with <, >, &, U+2028 and
// U+2029 characters inside string literals changed to <, >,
// &,  ,  .
func HTMLEscape(dst *bytes.Buffer, src []byte) {
	dst.Grow(len(src))
	dst.Write(appendHTMLEscape(nil, src))
}

const hex = "0123456789abcdef"

func appendHTMLEscape(dst, src []byte) []byte {
	start := 0
	for i, c := range src {
		if c == '<' || c == '>' || c == '&' {
			dst = append(dst, src[start:i]...)
			dst = append(dst, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xF])
			start = i + 1
		}
		// Convert U+2028 and U+2029 (E2 80 A8 and E2 80 A9).
		if c == 0xE2 && i+2 < len(src) && src[i+1] == 0x80 && src[i+2]&^1 == 0xA8 {
			dst = append(dst, src[start:i]...)
			dst = append(dst, '\\', 'u', '2', '0', '2', hex[src[i+2]&0xF])
			start = i + len(" ")
		}
	}
	return append(dst, src[start:]...)
}

// Compact appends to dst the JSON-encoded src with insignificant space
// characters elided.
func Compact(dst *bytes.Buffer, src []byte) error {
	dst.Grow(len(src))
	b, msg, offset := native.compact(nil, src, false)
	if msg != "" {
		return &SyntaxError{msg, offset}
	}
	dst.Write(b)
	return nil
}

// Indent appends to dst an indented form of the JSON-encoded src.
func Indent(dst *bytes.Buffer, src []byte, prefix, indent string) error {
	dst.Grow(2 * len(src))
	b, err := appendIndent(nil, src, prefix, indent)
	dst.Write(b)
	return err
}

func appendIndent(dst, src []byte, prefix, indent string) ([]byte, error) {
	b, msg, offset := native.indent(dst, src, prefix, indent)
	if msg != "" {
		return b, &SyntaxError{msg, offset}
	}
	return b, nil
}
