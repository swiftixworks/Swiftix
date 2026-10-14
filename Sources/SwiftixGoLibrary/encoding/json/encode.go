// Package json is encoding/json. The walk over a value, which Go makes with
// reflect, is a native of the run-time library: it reads the value by the
// type it travels with in an interface and writes the text, or reads the
// text and builds the value. What only the program can do, calling its
// MarshalJSON, MarshalText, UnmarshalJSON, or UnmarshalText methods, this
// text does when the native stops and asks for it, after which the native
// goes on where it stopped. The error types are Go's, without the fields of
// type reflect.Type and reflect.Value, whose text they keep for Error.
package json

import (
	"errors"
	"strconv"
)

// Marshal returns the JSON encoding of v.
func Marshal(v any) ([]byte, error) {
	return marshal(v, true)
}

// MarshalIndent is like Marshal but applies Indent to format the output.
func MarshalIndent(v any, prefix, indent string) ([]byte, error) {
	b, err := Marshal(v)
	if err != nil {
		return nil, err
	}
	b2, err := appendIndent(make([]byte, 0, 2*len(b)), b, prefix, indent)
	if err != nil {
		return nil, err
	}
	return b2, nil
}

// Marshaler is the interface implemented by types that can marshal
// themselves into valid JSON.
type Marshaler interface {
	MarshalJSON() ([]byte, error)
}

// An UnsupportedTypeError is returned by Marshal when attempting to encode
// an unsupported value type.
type UnsupportedTypeError struct {
	typ string
}

func (e *UnsupportedTypeError) Error() string {
	return "json: unsupported type: " + e.typ
}

// An UnsupportedValueError is returned by Marshal when attempting to encode
// an unsupported value.
type UnsupportedValueError struct {
	Str string
}

func (e *UnsupportedValueError) Error() string {
	return "json: unsupported value: " + e.Str
}

// A MarshalerError represents an error from calling a MarshalJSON or
// MarshalText method.
type MarshalerError struct {
	typ        string
	Err        error
	sourceFunc string
}

func (e *MarshalerError) Error() string {
	srcFunc := e.sourceFunc
	if srcFunc == "" {
		srcFunc = "MarshalJSON"
	}
	return "json: error calling " + srcFunc +
		" for type " + e.typ +
		": " + e.Err.Error()
}

// Unwrap returns the underlying error.
func (e *MarshalerError) Unwrap() error { return e.Err }

// What the native of an encoding says when it stops: the text is done, the
// value it gives must be asked for its text, or the encoding failed.
const (
	encodeDone = iota
	encodeUnsupportedType
	encodeUnsupportedValue
	encodeFailed
	encodeMarshalerSyntax
	encodeMarshalerFailed
	encodeCallMarshalJSON
	encodeCallMarshalText
	encodeCallKeyText
	encodeCallIsZero
)

// marshal encodes v, escaping <, >, and & in strings when escapeHTML.
func marshal(v any, escapeHTML bool) ([]byte, error) {
	flags := 0
	if escapeHTML {
		flags = 1
	}
	h := native.encodeStart(v, flags)
	defer native.release(h)
	for {
		code, x, text := native.encodeRun(h)
		switch code {
		case encodeDone:
			return native.encoded(h), nil
		case encodeUnsupportedType:
			return nil, &UnsupportedTypeError{typ: text}
		case encodeUnsupportedValue:
			return nil, &UnsupportedValueError{Str: text}
		case encodeFailed:
			return nil, errors.New(text)
		case encodeMarshalerSyntax:
			msg, offset := native.failure(h)
			return nil, &MarshalerError{text, &SyntaxError{msg, offset}, "MarshalJSON"}
		case encodeMarshalerFailed:
			msg, _ := native.failure(h)
			return nil, &MarshalerError{text, errors.New(msg), "MarshalJSON"}
		case encodeCallMarshalJSON:
			b, err := x.(Marshaler).MarshalJSON()
			if err != nil {
				return nil, &MarshalerError{text, err, "MarshalJSON"}
			}
			native.resume(h, b)
		case encodeCallMarshalText:
			b, err := x.(textMarshaler).MarshalText()
			if err != nil {
				return nil, &MarshalerError{text, err, "MarshalText"}
			}
			native.resume(h, b)
		case encodeCallKeyText:
			b, err := x.(textMarshaler).MarshalText()
			if err != nil {
				return nil, errors.New("json: encoding error for type " + strconv.Quote(text) + ": " + strconv.Quote(err.Error()))
			}
			native.resume(h, b)
		case encodeCallIsZero:
			if x.(isZeroer).IsZero() {
				native.resume(h, nil)
			} else {
				native.resume(h, []byte{1})
			}
		}
	}
}

// textMarshaler is encoding.TextMarshaler, which a program implements
// without importing encoding.
type textMarshaler interface {
	MarshalText() (text []byte, err error)
}

// isZeroer is what the omitzero option asks a value.
type isZeroer interface {
	IsZero() bool
}
