package json

import (
	"encoding/base64"
	"errors"
	"strconv"
)

// Unmarshal parses the JSON-encoded data and stores the result in the value
// pointed to by v.
func Unmarshal(data []byte, v any) error {
	return unmarshal(data, v, decodeCheck)
}

// Unmarshaler is the interface implemented by types that can unmarshal a
// JSON description of themselves.
type Unmarshaler interface {
	UnmarshalJSON([]byte) error
}

// An UnmarshalTypeError describes a JSON value that was not appropriate for
// a value of a specific Go type.
type UnmarshalTypeError struct {
	Value  string // description of JSON value - "bool", "array", "number -5"
	typ    string
	Offset int64  // error occurred after reading Offset bytes
	Struct string // name of the struct type containing the field
	Field  string // the full path from root node to the field, include embedded struct
}

func (e *UnmarshalTypeError) Error() string {
	if e.Struct != "" || e.Field != "" {
		return "json: cannot unmarshal " + e.Value + " into Go struct field " + e.Struct + "." + e.Field + " of type " + e.typ
	}
	return "json: cannot unmarshal " + e.Value + " into Go value of type " + e.typ
}

// An InvalidUnmarshalError describes an invalid argument passed to
// Unmarshal: one that is not a non-nil pointer.
type InvalidUnmarshalError struct {
	what string
}

func (e *InvalidUnmarshalError) Error() string {
	return "json: Unmarshal(" + e.what + ")"
}

// A Number represents a JSON number literal.
type Number string

// String returns the literal text of the number.
func (n Number) String() string { return string(n) }

// Float64 returns the number as a float64.
func (n Number) Float64() (float64, error) {
	return strconv.ParseFloat(string(n), 64)
}

// Int64 returns the number as an int64.
func (n Number) Int64() (int64, error) {
	return strconv.ParseInt(string(n), 10, 64)
}

// How a decoding goes: whether the text is checked first, as Unmarshal does
// and a Decoder, which has read it, does not, and the options of a Decoder.
const (
	decodeCheck = 1 << iota
	decodeUseNumber
	decodeDisallowUnknownFields
)

// What the native of a decoding says when it stops.
const (
	decodeDone = iota
	decodeSyntax
	decodeInvalid
	decodeType
	decodeFailed
	decodeCorrupt
	decodeCallUnmarshalJSON
	decodeCallUnmarshalText
)

// unmarshal decodes data into v.
func unmarshal(data []byte, v any, flags int) error {
	h := native.decodeStart(data, v, flags)
	defer native.release(h)
	for {
		code, x, text := native.decodeRun(h)
		switch code {
		case decodeDone:
			return nil
		case decodeSyntax:
			msg, offset := native.failure(h)
			return &SyntaxError{msg, offset}
		case decodeInvalid:
			return &InvalidUnmarshalError{text}
		case decodeType:
			value, offset, strct, field := native.typeError(h)
			return &UnmarshalTypeError{value, text, offset, strct, field}
		case decodeFailed:
			return errors.New(text)
		case decodeCorrupt:
			_, offset := native.failure(h)
			return base64.CorruptInputError(offset)
		case decodeCallUnmarshalJSON:
			if err := x.(Unmarshaler).UnmarshalJSON(native.raw(h)); err != nil {
				return withContext(h, err)
			}
			native.resume(h, nil)
		case decodeCallUnmarshalText:
			if err := x.(textUnmarshaler).UnmarshalText(native.raw(h)); err != nil {
				return withContext(h, err)
			}
			native.resume(h, nil)
		}
	}
}

// textUnmarshaler is encoding.TextUnmarshaler.
type textUnmarshaler interface {
	UnmarshalText(text []byte) error
}

// withContext is err, an error of a method, with the struct and field the
// decoding was in when err is an *UnmarshalTypeError, as Go adds them.
func withContext(h int, err error) error {
	if e, ok := err.(*UnmarshalTypeError); ok {
		strct, field, ok := native.context(h, e.Field)
		if ok {
			e.Struct = strct
			e.Field = field
		}
	}
	return err
}
