#!/bin/sh
# Runs the Go text of a package of the run-time library in real Go, against
# Go's own package.
#
#     Scripts/go-library-harness/run.sh sort
#
# A scratch module is made of three things: the package's files from
# Sources/SwiftixGoLibrary/<package>, unchanged; <package>/native.go from
# here, which declares the variable `native` the text calls its natives
# through; and <package>/main.go from here, which drives both packages and
# prints what differs. It then says which statements of the text the inputs
# did not reach. Real Go is $GO, or the `go` on the path.
#
# To hold another package to Go this way, add a directory with those two
# files. See the guide at the top of Sources/SwiftixGo/SourceLibrary.swift.
set -eu
package=${1:?usage: run.sh <package>}
here=$(cd "$(dirname "$0")" && pwd)
library=$here/../../Sources/SwiftixGoLibrary/$package
go=${GO:-go}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$package" "$work/coverage"
printf 'module example/harness\n\ngo 1.24\n' > "$work/go.mod"
cp "$library"/*.go "$here/$package/native.go" "$work/$package/"
cp "$here/$package/main.go" "$work/main.go"
cd "$work"
"$go" vet ./...
"$go" build -cover -coverpkg=./... -o harness .
GOCOVERDIR=$work/coverage ./harness
"$go" tool covdata textfmt -i=coverage -o coverage.txt
echo "functions of the text with statements the inputs did not reach:"
"$go" tool cover -func=coverage.txt | grep "example/harness/$package/" | grep -v '/native.go:' | awk '$3 != "100.0%"'
