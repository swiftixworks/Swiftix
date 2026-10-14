// Package errors is the part of errors that is written in Go. New, Is, As,
// Unwrap, and Join belong to the run-time library, which this file imports
// under the same path.
package errors

import "errors"

// ErrUnsupported indicates that a requested operation cannot be performed,
// because it is unsupported. For example, a call to [os.Link] when using a
// file system that does not support hard links.
//
// Functions and methods should not return this error but should instead
// return an error including appropriate context that satisfies
//
//	errors.Is(err, errors.ErrUnsupported)
//
// either by directly wrapping ErrUnsupported or by implementing an [Is] method.
//
// Functions and methods should document the cases in which an error
// wrapping this will be returned.
var ErrUnsupported = errors.New("unsupported operation")
