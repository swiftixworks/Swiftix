package sort

import "reflect"

// The natives of the package, for running its text in real Go.
var native = struct {
	length func(x any, caller string) int
	swap   func(x any, i, j int)
}{
	length: func(x any, _ string) int { return reflect.ValueOf(x).Len() },
	swap:   func(x any, i, j int) { reflect.Swapper(x)(i, j) },
}
