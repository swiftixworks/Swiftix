// Package encoding defines interfaces shared by other packages that convert
// data to and from byte-level and textual representations.
package encoding

// BinaryMarshaler is the interface implemented by an object that can
// marshal itself into a binary form.
type BinaryMarshaler interface {
	MarshalBinary() (data []byte, err error)
}

// BinaryUnmarshaler is the interface implemented by an object that can
// unmarshal a binary representation of itself.
type BinaryUnmarshaler interface {
	UnmarshalBinary(data []byte) error
}

// TextMarshaler is the interface implemented by an object that can marshal
// itself into a textual form.
type TextMarshaler interface {
	MarshalText() (text []byte, err error)
}

// TextUnmarshaler is the interface implemented by an object that can
// unmarshal a textual representation of itself.
type TextUnmarshaler interface {
	UnmarshalText(text []byte) error
}
