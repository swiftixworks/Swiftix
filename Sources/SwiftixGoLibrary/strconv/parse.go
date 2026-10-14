package strconv

import (
	"errors"
	"strings"
)

// The numbers are read by natives of the run-time library, which fail with
// the text of Go's error alone. These functions give the value a native
// read and, for its error, Go's *NumError: what follows the quoted input in
// the text is why. Itoa and the Format functions stay natives.

// numError is the *NumError of the function named fn on s, for failure,
// the error of the native; nil when there is none.
func numError(fn, s string, failure error) error {
	if failure == nil {
		return nil
	}
	why, ok := strings.CutPrefix(failure.Error(), "strconv."+fn+": parsing "+Quote(s)+": ")
	var err error
	switch {
	case ok && why == ErrSyntax.Error():
		err = ErrSyntax
	case ok && why == ErrRange.Error():
		err = ErrRange
	case ok:
		// An invalid base or bit size, which Go words so too.
		err = errors.New(why)
	default:
		err = failure
	}
	return &NumError{Func: fn, Num: s, Err: err}
}

// ParseInt reads s as an integer in base (2 to 36, or 0 for the base its
// prefix says) that fits in bitSize bits (0 for int). Out of range, the
// value is the nearest that fits, with ErrRange.
func ParseInt(s string, base int, bitSize int) (i int64, err error) {
	i, err = native.ParseInt(s, base, bitSize)
	return i, numError("ParseInt", s, err)
}

// ParseUint is ParseInt for an unsigned integer, which has no sign.
func ParseUint(s string, base int, bitSize int) (uint64, error) {
	u, err := native.ParseUint(s, base, bitSize)
	return u, numError("ParseUint", s, err)
}

// ParseFloat reads s as a floating-point number rounded to bitSize bits
// (32 or 64). Out of range, the value is an infinity, with ErrRange.
func ParseFloat(s string, bitSize int) (float64, error) {
	f, err := native.ParseFloat(s, bitSize)
	return f, numError("ParseFloat", s, err)
}

// Atoi is ParseInt(s, 10, 0) as an int, its error named for Atoi.
func Atoi(s string) (int, error) {
	i, err := ParseInt(s, 10, 0)
	if failure, ok := err.(*NumError); ok {
		failure.Func = "Atoi"
	}
	return int(i), err
}
