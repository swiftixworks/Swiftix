# Changelog

Swiftix follows [Semantic Versioning](https://semver.org/). User-visible API,
format, behavior and platform changes are recorded here.

## Unreleased

### Added

- Swiftix Go files: `os.Open`, `os.Create`, and `os.OpenFile` with the
  `os.O_*` flags; `(*os.File).Close`, `Seek`, `ReadAt`, `WriteAt`, and `Sync`;
  `os.Remove`, `os.Rename`, and `os.Mkdir`; `io.EOF` and the `io.Seek*`
  constants. A program can keep an append-only log, replay it, and address a
  file in fixed-size pages.
- Swiftix Go wall-clock time: `time.Now`, `time.Since`, `time.Unix`, and the
  `time.Time` methods `Unix`, `UnixMilli`, `UnixNano`, `Sub`, `Add`, `Before`,
  `After`, and `Equal`.
- Swiftix Go `errors.New`, `errors.Unwrap`, `errors.Is`, and `errors.As`, and
  the builtin `copy`, which runs natively. `fmt.Errorf` wraps the operands of
  one or several `%w`, and a program type's `Unwrap` and `Is` methods are
  honored.
- Swiftix Go `fmt.Sprintf`, `fmt.Sprint`, `fmt.Sprintln`, `fmt.Errorf`,
  `fmt.Printf`, and `fmt.Fprintf` with Go's verbs (including `%T`, `%#v`, and
  `%p`), flags, width, precision, argument indexes (`%[2]d`, `%[1]*d`), and
  markers for a mistake. The output functions (`fmt.Print`, `Println`,
  `Printf`, `Fprint`, `Fprintln`, `Fprintf`) can be used as expressions that
  return `(n, err)`. See "Formatting" in `docs/go-toolchain.md`.
- `fmt` prints a value by its `Error()` or `String()` method, as an operand
  and inside slices, maps, and exported struct fields. A method is called on
  a nil pointer as well, and one that panics prints Go's
  `%!v(PANIC=String method: ...)`.
- Variadic functions and methods (`func f(prefix string, values ...int)`),
  called with any number of arguments or one `slice...`, within a package,
  across packages, and through an interface. `gofmt` prints `...` in both
  positions as Go does.
- Type assertions to an interface type (`value.(sizer)`, with or without
  `, ok`). The compiler lists the program's types that implement the
  interface from exact method signatures.
- Interface methods with several results can be called in a multi-value
  context (`value, ok := store.Get(key)`, `return store.Get(key)`).
- A function with results may end in a call to `panic` instead of a `return`.
- Declaration groups: `import ( ... )`, `var ( ... )`, `const ( ... )`, and
  `type ( ... )`, at package level and, for `var`, `const`, and `type`, in
  functions.
- Import names: `import f "fmt"` calls the package `f` in that file,
  `import _ "pkg"` imports it for its initialization alone, and
  `import . "pkg"` brings its exported names into the file. They work for
  packages of the run-time library and of the module, so two packages of one
  name can be imported side by side (`stderrors "errors"` beside a local
  `errors`), and a file that renames a package may use the package's own
  name for a variable, a function, or a type.
- Types declared in functions, alone or in a `type ( ... )` group. A local
  type reaches from its declaration to the end of its block, hides an outer
  type of that name, may refer to itself, and is distinct from a type of the
  same name in another function; `%T` prints both as Go does (`main.pair`).
  A failed assertion between two such types ends in Go's
  `(types from different scopes)`, and between types of one name in two
  packages in `(types from different packages)`.
- Struct fields that share a type, `X, Y int`; a block as a statement of its
  own, `{ ... }`, with its own scope; and alias declarations,
  `type Name = T`, at package level, in functions, and across packages. An
  alias and its type are one type. `gofmt` lays all three out as Go's does.
- Interface methods may name their parameters and results:
  `Get(key string) (value string, ok bool)`, `Put(key, value string)`.
- `go test` finds `func TestX(t *tt.T)` in a file that says
  `import tt "testing"`, by the shape of the parameter as Go's does.
- `gofmt` prints an import's name before its path and sorts the imports of a
  group by path and then by name, as Go's does.
- `iota`, the index of a specification in its `const` declaration, and the
  implicit repetition of the previous specification's type and expression:
  `const ( red color = iota; green; blue )`,
  `const ( _ = iota; KB = 1 << (10 * iota); MB )`.
- `gofmt` lays out declaration groups as Go's does: a specification on each
  line, the imports of a group sorted by path and without duplicates, and
  the names, types, values, and comments of a `var` or `const` group in
  columns.
- The address of a composite literal, `&T{...}`: a pointer to a new variable
  each time it is evaluated, for structs, arrays, slices, and maps. A
  constructor can `return &Server{...}`, and a loop that appends `&node{...}`
  appends distinct nodes.
- The empty struct literal `T{}`, the zero value of `T`.
- Several names on the left of `:=`, `=`, and `var` with a value for each:
  `a, b := x, y`, `a, b = b, a`, `var a, b T`, `var a, b = x, y`,
  `var n, err = f()`, `const a, b = 1, 2`, at package level and in
  functions, and in the clauses of a `for`. Go's order holds: the operands on
  the left and every value on the right are read before anything is stored.
- The blank identifier in an assignment and a `var`: `_ = x`, `n, _ = f()`.
- `if` and `switch` initializer statements (`if err := f(); err != nil { }`,
  `switch n := len(s); n { }`, `switch x := f(); { }`). The variables last
  for the statement and its `else` branches, and `gofmt` keeps the header on
  one line.
- Swiftix Go run-time errors are panics that `recover` can catch, with Go's
  messages and types: a nil pointer dereference, an index or slice bound out
  of range (`runtime error: index out of range [5] with length 3`), an
  integer division by zero, an assignment to a nil map, a failed type
  assertion, a negative shift count, `make` with a negative length, and a
  misuse of a closed or nil channel. Deferred calls run while the panic
  unwinds, the recovered value is an `error`, and a server can keep one
  failing goroutine from ending the program. See "Panics" in
  `docs/go-toolchain.md`.
- Swiftix Go `strings.ToUpper`, `strings.ToLower`, `strings.Fields`,
  `strings.TrimPrefix`, and `strings.TrimSuffix`. Case mapping and the
  printable test of `%q` use Go 1.24's Unicode 15.0.0 tables
  (`Scripts/generate-go-unicode-tables.go`), so they do not vary with the
  host's Unicode version.
- `append(slice, values...)`: a slice, or a string for a `[]byte`, as the
  final argument of `append`, appended natively. `gofmt` and `gofmt -r` print
  and match the spread.
- A multi-value `:=` may reuse variables of the same block when one name is
  new (`n, err := f()` after an earlier `err`).
- `GoMapStorage.count`.
- Swiftix Go function values. Function types (`func(int, string) (bool,
  error)`, variadic ones included) are types of variables, parameters,
  results, fields, elements, map values, and channels, and the underlying type
  of a named type, which may have methods (`type HandlerFunc func(string)
  string`). A function of the program, a function literal, a method value
  (`c.Inc`, of a concrete type or of an interface value), and a method
  expression (`T.Get`, `(*T).Inc`) are values: assigned, passed, returned,
  stored, held by an interface and asserted back, compared with `nil`, printed
  by `%v` and `%T` as Go prints them, and called through whatever holds them,
  by `go` and `defer` as well, inside one package and across packages. A call
  through a nil function panics as a nil pointer dereference.
- Swiftix Go closures. A function literal is an expression anywhere, called
  where it is written or kept, and uses the variables of the functions around
  it, parameters, receivers, and named results among them: it reads what they
  hold when it runs, what it assigns is seen outside, and they live as long as
  a literal that uses them. A literal made in a loop keeps the variable of its
  iteration. A variable that a literal only assigns is still `declared and not
  used`.
- Swiftix Go rune literals: `'a'`, `'世'`, and the escapes `\a \b \f \n \r \t
  \v \\ \'`, `\x41`, `\101`, `\u4e16`, and `\U0001F600`, as untyped integer
  constants. Malformed ones are reported with Go's messages at Go's positions.
- `(*T)(x)`, the conversion to a pointer type, and the conversion of `nil` to
  a slice, map, or pointer type (`[]int(nil)`, `map[string]int(nil)`,
  `(*T)(nil)`).
- Swiftix Go `time.Duration`: the named integer type of Go, in declarations,
  fields, parameters, results, maps, slices, and channels, with `String` in
  Go's format (`1.5s`, `2m0s`, `1h0m0s`, `150ms`, `1.5µs`, `0s`),
  `Nanoseconds`, `Microseconds`, `Milliseconds`, `Round`, `Truncate`, and
  `Abs`, on a value or a pointer and as method values. `var d time.Duration`
  was `undefined: time.Duration`.
- `time.Minute` and `time.Hour`, `time.Until`, and `time.ParseDuration` with
  Go's errors.
- A duration held by an interface keeps its type: it asserts as
  `time.Duration`, implements the interfaces its methods satisfy, and a panic
  with one prints its text.
- The results of a call are the arguments of another, `f(g())`, where `g()`
  is the only argument: for a function, a method, a method of an interface
  value, a function value, a literal called in place, a method value and a
  method expression, a variadic parameter, the `fmt` printers
  (`fmt.Printf(format())`), the other functions of the library, and `append`,
  `copy`, and `delete`; in `go`, `defer`, declarations, `return`, and nested.
  The inner call runs once, in Go's order. `g(f())` was refused with `not
  enough arguments in call to g`.
- A package may declare any number of blank variables, functions, methods,
  and types (`var _ I = (*T)(nil)`, `var _ = register()`, `func _() {}`), in
  several files and packages; each is checked and each initializer runs in
  its place. A second one was `_ redeclared in this block`.
- Several package-level variables from one expression: `var a, b = f()`,
  `var v, ok = m[k]`, `x.(T)`, `<-ch`. Was `assignment mismatch: 2 variables
  but 1 value`.
- Receivers, parameters, and results without names: `func (T) m()`,
  `func f(int, string)`, `func(_ int, ...string)`, `(_ int, _ error)`. Was
  `expected type`.
- Pointer types with a name, `type ptr *T`: field selection and assignment,
  `*p`, nil comparison, conversion to and from `*T`. Was `ptr has no field or
  method n`.
- Composite literals leave out what their type says: the type of an element
  or key at any depth (`[]point{{1, 2}}`, `map[point]string{{1, 2}: "a"}`;
  was `expected expression`), `&T` for pointer elements, and the length in
  `[...]T`. Elements of arrays and slices take constant indexes
  (`[]int{2: 5, 7}`; was `keyed slice literals are not supported yet`).
- Struct types written in expressions: `struct{ a int }{1}`, tables
  `[]struct{ ... }{{...}}`, `struct{}{}` (was `expected expression`). Struct
  types of the same fields are one type; a value of one is assigned to,
  compared with, and converted to a named type of that structure.
- `new(T)`, `min` and `max` over integers and strings, `clear` for maps and
  slices, and `make` of a named type (`make(names, 2)`). Each was `undefined`
  or `invalid make call`.
- Conversions to types in parentheses and to more types: `(func())(nil)`,
  `(<-chan int)(ch)`, `any(5)`, `error(nil)`, a conversion to a named
  interface, and between struct or array types of one structure.
- A pointer to an array is followed by `p[i]`, `&p[i]`, `p[a:b]`, `len(p)`,
  `cap(p)`, and `range p` (was `cannot index expression`).
- Type switches: `switch v := x.(type) { case T: ... }`, with or without the
  name and an initializer, over any interface value; cases of any type, of
  several types, `nil`, and `default`. Duplicate and impossible cases, an
  unused name, and `fallthrough` are refused as Go refuses them. Was
  `expected type`.
- Labels with `break L`, `continue L`, and `goto L`, on loops, `switch`,
  `select`, and blocks, with Go's errors for a label that is unused, unknown,
  defined twice, or no statement the jump can leave, and for a `goto` into a
  block or over a variable declaration. Was `expected semicolon or newline`.
- `fallthrough` in expression switches (was `expression evaluated but not
  used`), and `for i := range n` and `for range n` over an integer (was
  `cannot range over int`).
- A function of the run-time library is a value of its Go type:
  `f := strings.ToUpper`, `apply(strings.TrimSpace, s)`, the variadic
  `fmt.Println` and `fmt.Sprintf`, and the several results of `strconv.Atoi`.
  A method of a library type is a method value: `done := wg.Done`,
  `unlock := mu.Unlock`, `write := file.WriteString`. `errors.As` and the
  functions of `net/http` still can only be called.
- `sort.Slice`, `SliceStable`, `SliceIsSorted`, `Sort`, `Stable`, `IsSorted`,
  `Reverse`, `Interface`, `IntSlice`, `StringSlice`, `Search`, `SearchInts`,
  `SearchStrings`, `Find`, `IntsAreSorted`, and `StringsAreSorted`. The order
  of equal elements under the unstable sorts and the sequence of `Less` and
  `Swap` calls are Go's. They are Go text compiled with the program that
  uses them, linked like a package of the module; a program that names none
  compiles to the image it had.
- `sync.Once`: `once.Do(f)` calls `f` once, also when it panics, and a call
  from another goroutine waits for the first to end.
- Struct embedding: `type derived struct { base; name string }` gives
  `derived` a field `base` and the fields and methods of `base`, by value, by
  pointer, and for a type of another package, with Go's rules: the shallowest
  name wins, two at one depth are `ambiguous selector` where used, and the
  method sets of `S` and `*S` decide which interfaces the struct implements.
  A struct may embed an interface or `error`; `sync.Mutex`, `sync.WaitGroup`,
  `time.Time`, and `*os.File` are embedded with their methods (`c.Lock()`).
  Was `expected type`.
- Interfaces embed interfaces (`type ReadWriter interface { Reader; Writer }`),
  `error` included, and a value of one interface type is assigned to another
  whose methods it has.
- Raw string literals (`` `...` ``), over several lines and without escapes,
  and struct tags (``Name string `json:"name"` ``), which are part of the
  struct type and have no other effect.
- Sized integers: `int8`, `int16`, `int32`, `int64`, `uint`, `uint16`,
  `uint32`, `uint64`, `uintptr`, and `rune` (another name for `int32`), with
  Go's wraparound, unsigned division, remainder, comparison, and right shift
  for the 64-bit unsigned types, shift counts of any integer type, and
  conversions between all of them. `[]rune(s)` and `string(runes)` convert,
  and `fmt` prints each type under every integer verb. Each was rejected by
  name.
- Exact constants: an untyped integer constant has any size (`1 << 100`,
  `14695981039346656037`) and takes the type of what it meets. A literal past
  64 bits was `integer literal overflows int64`.
- Library: the integer bounds of `math` (`MaxInt8` to `MaxUint64`, `MinInt8`
  to `MinInt64`, `MaxInt`, `MinInt`, `MaxUint`); `strconv.ParseInt`,
  `ParseUint`, `FormatInt`, `FormatUint`; `unicode.IsLetter`, `IsDigit`,
  `IsSpace`, `IsUpper`, `IsLower`, `ToUpper`, `ToLower`; `utf8.RuneCountInString`, `RuneLen`, `DecodeRuneInString`, `EncodeRune`,
  `ValidString`; `strings.ContainsRune`, `IndexRune`, `IndexByte`.
- `gofmt` lays out elided and nested literals, struct types written in
  expressions, labels (on a line of their own, one level out), type switches,
  embedded fields, tags in a column of their own, and raw strings as Go's
  does; `gofmt -r` renames labels and rewrites the operand and the case types
  of a type switch.
- `net/http` serves requests with the program's handlers: `http.HandleFunc`,
  `http.Handle`, `http.ListenAndServe`, `http.Serve`, `http.Server`,
  `http.ServeMux` with Go 1.22 method, host, and wildcard patterns
  (`GET /items/{id}`, `r.PathValue`), `http.Handler`, `http.HandlerFunc`,
  `http.Error`, `http.NotFound`, `http.Redirect`, `http.StripPrefix`, and the
  status and method constants. A handler is any function value, each
  connection runs in its own goroutine, a panic ends its request alone, and
  responses match Go's byte for byte apart from `Date`. The server used to
  answer `200 OK` without calling the handler, and `w.Write` in a handler was
  `http.ResponseWriter has no field or method Write`.
- `http.Get`, `Head`, `Post`, `PostForm`, `NewRequest`, and `Client.Do` with
  redirects; the response has `Status`, `StatusCode`, `Header`, `Body`, and
  `ContentLength`.
- `net/url`: `Parse`, `URL`, `Values`, `QueryEscape`, `PathEscape`, and their
  inverses. Was `package net/url is not available`.
- `io.Reader`, `io.Writer`, `io.Closer`, `io.ReadCloser`, `io.ReadAll`,
  `io.WriteString`, `io.Copy`, `io.NopCloser`, `io.Discard`,
  `io.ErrUnexpectedEOF`, and `strings.NewReader`.
- `defer` and `go` of a method of an interface value (`defer
  resp.Body.Close()`, was `unsupported defer expression`) and of the builtin
  `close` (`defer close(done)` ended the run with `missing function: close`).
- `swiftix-go run` gives the program a loopback interface, so a program can
  reach a server it started; a connection from `listener.Accept` knows its
  peer address. `ProcessContext.tcpPeer` is public.
- Floating point: `float64` and `float32`, floating-point literals in every
  form, exact untyped constants, IEEE arithmetic and comparison, conversions
  to and from the integer types, and `fmt`'s `%v %g %f %e %G %E %x %b` with
  Go's shortest text. `var f float64` was `type float64 is not supported`,
  and `x := 1.5` was `expected selector name`.
- Library for floats: `strconv.ParseFloat` and `FormatFloat`; `math.Sqrt`,
  `Floor`, `Ceil`, `Trunc`, `Round`, `RoundToEven`, `Abs`, `Max`, `Min`,
  `Pow`, `Mod`, `Inf`, `NaN`, `IsNaN`, `IsInf`, `Signbit`, `Copysign`, the
  `Float64bits` family, and the constants of `math`; `sort.Float64s`; `min`
  and `max` of floats; `time.Duration`'s `Seconds`, `Minutes`, and `Hours`.
- Array lengths that are constant expressions: `[n]T`, `[2 * n]T`,
  `[len("abc")]T`. `var a [n]int` was `expected array length`.

### Changed

- Swiftix Go interface values carry their dynamic type wherever a value is
  converted to an interface (assignment, argument, return, composite literal,
  `append`, channel send), not only in call arguments. A `byte` stored in an
  interface is no longer an `int`, a named type no longer asserts as its
  underlying type, and calling a pointer-receiver method through an `error`
  no longer fails with a bytecode type mismatch.
- Errors made by `errors.New` and `fmt.Errorf` compare by identity, as in Go:
  two errors with the same message are different values. The errors of failed
  library calls still compare by message; see "Known Gaps" in
  `docs/go-toolchain.md`.
- `fmt` output now matches Go where it did not: a map prints sorted by key
  (was insertion order), a nil slice prints `[]` and a nil map `map[]` (was
  `<nil>`), a pointer to a struct prints `&{...}` and other pointers their
  address (was `&<pointer>`), a bad-verb marker names a byte `uint8`, a
  `[]byte` stored in an interface is still text for `%s`, and `fmt.Print`
  puts a space between two operands only when neither is a string (was
  never).
- A type assertion to an interface type used to compile and always fail; it
  now tests the method set.
- A `const` without a value is reported as `missing init expr for x`, Go's
  wording (was `missing value in const declaration`).
- A variable that a function declares and never reads is an error, as in
  Go: `declared and not used: x`, at the variable's name. Being assigned is
  no read (`x := 1; x = 2`), while `x++`, `x += 1`, `x.f = 1`, `x[i] = 1`,
  and `&x` are; parameters, results, and constants need not be read. Source
  that compiled with an unused variable no longer does: remove the variable
  or write `_ = x`.
- An import of a run-time library package that the file never names is an
  error, as an unused local package already was:
  `"os" imported and not used`. Remove the import, or write
  `import _ "os"`.
- A type prints by the name of its package, as in Go, where that is not the
  last element of the import path: `api.Request` for `package api` in
  `example/m/v2`, in `%T`, `%#v`, and a failed assertion. The linker keeps
  the name in the package's symbols (`example/m/v2@api.Request`); a package
  named after its directory has the symbols it had.
- An unrecovered panic prints its value as Go does: a value of a named type
  as `main.code(4)`, an error by its `Error` method and a value with a
  `String` method by that, and anything else by its type and address,
  `(main.failure) 0xc000012000` (was the value alone, `{3}`). A panic that
  begins while another is not over is printed after it, with `[recovered]`
  on one a deferred call had recovered:
  `panic: first [recovered]`, then `panic: second` on the next line.
- A diagnostic names a member of a package the way the file does:
  `undefined: t.Nope` after `import t "time"`. A member a package does not
  have is `undefined: os.Nope` (was `undefined: os`).
- `gofmt -r` reads a rule as Go's does. An identifier of a pattern stands
  for any expression only when it is one lower-case letter; a longer name
  now matches itself, so `total(first, second) -> ...` matches that call and
  no other. The operands of an expression are rewritten before it is
  matched, so a rule applies at every depth (`f(f(1))` under `f(1) -> 1` is
  `1`), also inside function literals. A rule from one identifier to another
  renames it wherever the file has it, declarations included
  (`total -> sum`). Parentheses in a pattern match parentheses, so
  `gofmt -r '(a) -> a'` removes every pair, and those in a replacement are
  written.
- A type declaration is reported at its name (`main.go:3:6`), where Go
  reports it, not at the `type` keyword. So is a function, where it used to
  be reported at `func`; `missing return` is reported where the body ends;
  a repeated result at its name; and a selection `x.f` at `f`, not at the
  `.`. A method declared twice is reported in Go's words,
  `method T.M already declared at main.go:3:12`.
- A diagnostic about an import is reported where Go reports it, at the
  import's name or else its path (`main.go:3:8`), not at the `import` keyword
  (`main.go:3:1`). A package named where a value is expected is
  `use of package os not in selector` (was `undefined: os`), and an unused
  local package whose name is not the last element of its path is
  `"path" imported as name and not used`.
- Diagnostics reworded to Go's: a multi-value `:=` without a new name is
  `no new variables on left side of :=` (was `x redeclared in this block`),
  a count that does not match is `assignment mismatch: 2 variables but 1
  value` (was `multiple-value context requires function call`), and struct
  literal errors name the type (`too few values in struct literal of type
  point`, `unknown field Z in struct literal of type point`).
- `gofmt` spaces binary operators as Go's printer does, by precedence and
  nesting, instead of putting blanks around every one: `x*2 + y`,
  `f(a+1, b)`, `s[i+1]`, `a, b = b+1, a*2`, `s[lo : hi+1]`, `a - -b`. It
  drops parentheses that say nothing (`((x))`, `if (a > b) {`), and no longer
  adds an empty line between two top-level declarations of one kind
  (`func`/`func`, `type`/`type`) where the source has none. Source formatted
  by Go's `gofmt` now comes back unchanged apart from the cases listed under
  "Known Gaps" in `docs/go-toolchain.md`; formatting existing Swiftix Go
  source again will change its operator spacing once.
- `gofmt` lays out lines and columns as Go's printer does. It aligns the
  names and types of struct fields, comments at the ends of consecutive
  lines, the bodies of consecutive one-line functions, and the values of
  composite literal elements that each begin a line. It keeps a function on
  one line when the source has it there and it is short (`func main() {}`,
  `func (s *stack) empty() bool { return len(s.items) == 0 }`), and a
  `struct` or `interface` with one short field or method
  (`interface{ Area() int }`). It keeps the line breaks the source has
  after a binary operator, between the elements of a list, after `=`, and
  after a `.`, and indents what follows. Until now it printed every body on
  lines of its own, left fields and comments unaligned, and joined a
  statement into one line. Source formatted by Go's `gofmt` comes back
  unchanged; source formatted by an earlier Swiftix `gofmt` will change once.
- A Swiftix Go program that ends on a run-time error fails with
  `GoRuntimeError.panicError("runtime error: ...")`, the text Go prints,
  instead of `.divisionByZero`, `.indexOutOfRange`, `.invalidSliceBounds`, or
  `.invalidPointer`. Those cases stay in the enum for faults of an image.
  The program's deferred calls now run first.
- A file-backed Go program that panics exits with status 2, as a Go program
  does (was 1).
- The value a failed type assertion or a closed-channel operation panics with
  is an `error` with the same text (was a string).
- Swiftix Go maps are hash-indexed and updated in place: lookup, insertion,
  and `delete` are O(1) amortized instead of O(entries). Iteration order is
  unchanged (insertion order). `GoMapStorage.entries` is now computed, and
  `GoMapStorage(entries:)` keeps the last value of a repeated key.
- The errors returned by `strconv.Atoi`, `net.Dial`, `net.Listen`,
  `net.LookupHost`, `http.Get`, `http.ListenAndServe`, `conn.Read`,
  `conn.Write`, `conn.Close`, `listener.Accept`, `listener.Close`, and
  `ctx.Err` have the type `error` instead of `interface{}`, so they can be
  returned as an `error`, compared with `io.EOF`, and read with `Error()`.
- `time.After` and `time.Tick` deliver instants on the kernel wall clock
  instead of logical nanoseconds. The two agree unless the host anchored the
  clock with `Kernel.setWallClock`.
- Errors in string literals are Go's, at Go's positions: `unknown escape`
  (was `unknown escape sequence`), `invalid character 'z' in hexadecimal
  escape` (was `invalid character in escape sequence`), `octal escape value
  256 > 255`, and `escape is invalid Unicode code point U+D800`, reported
  after the escape instead of at its `u`; `newline in string` is reported at
  the end of the line instead of at the opening quote.
- A call of a value that is no function says `invalid operation: cannot call
  non-function x (variable of type int)` (was `undefined: x`), `==` between
  two slices, maps, or functions says `invalid operation: slice can only be
  compared to nil` (was `values are not comparable`), and `invalid map key
  type` is reported at the key type instead of at `map`.
- `http.HandleFunc` checks its handler, which must be a
  `func(http.ResponseWriter, *http.Request)`; any second argument used to be
  accepted.
- `fmt.Println`, `strings.ToUpper`, and the other functions of the run-time
  library named without a call are refused with a message that says to wrap
  the call in a function literal.
- The compiler checks and lowers each kind of statement and expression in a
  function of its own, and lowers a function literal after the function it is
  written in. An unoptimized build used more than a tenth of a 512 KB thread's
  stack for every nested statement; twenty nested statements and twelve nested
  literals now compile there.
- The units of `time`, `time.Since`, and `t.Sub` are durations, and
  `time.Sleep`, `time.After`, `time.Tick`, `t.Add`, and `context.WithTimeout`
  take one. An untyped constant still becomes a duration (`time.Sleep(100)`,
  `d * 2`); an `int` does not, as in Go. `n := 3; time.Sleep(n)` compiled and
  ran and is now `cannot use int as time.Duration value in argument to
  time.Sleep`; `var timeout int = 5 * time.Second` is now `cannot use
  time.Duration as int value`; `time.Sleep(n * time.Millisecond)` is now
  `mismatched types int and time.Duration`. Write `time.Duration(n) *
  time.Millisecond`, which compiles to the same instructions.
- `fmt` prints a duration as Go does: `fmt.Printf("%T %v %d\n", time.Second,
  time.Second, time.Second)` printed `int 1000000000 1000000000` and prints
  `time.Duration 1s 1000000000`. A program that prints a duration or converts
  one to an interface compiles to a different image; every other program
  compiles to the image it had. An interface value holding `time.Second` no
  longer asserts as an `int`.
- Results that do not fit the parameters of the call they are passed to are
  reported at the inner call, where Go reports them. `g(f())` with `func g(n
  int)` and a `f` of two results compiled and printed with the first.
- Package-level variables are initialized in Go's order: each time the first
  that reads no variable still to be initialized. A variable that waited for
  a later one was initialized before the independent ones between them
  (`init 40`, `init 1` where Go prints `init 1`, `init 40`). Such a program
  compiles to a different `$package.init`.
- The value of a constant must be constant. `var v = 3; const c = v` printed
  `3`; it is now `v (variable of type int) is not constant`.
- An unexported field or method of another package's type cannot be selected,
  called, or given in a struct literal; `v.secret`, `v.hidden()`, and
  `lib.T{secret: 7}` compiled.
- A rune literal's default type is `rune`, and a `range` over a string yields
  `rune`, as in Go; both were `int` (`%T` printed `int`). A program that used
  either as an `int` needs a conversion.
- Literal diagnostics are Go's, at Go's positions: `mixture of field:value
  and value elements in struct literal` at the offending element, `too few
  values` at the closing brace, `index 3 is out of bounds (>= 3)`, and
  `cannot use string as int value in struct literal`. A literal element that
  ends a line needs its comma, and `len(s)` alone is `len(s) is not used`;
  both were accepted.
- A second `default` is reported as `multiple defaults (first at
  main.go:9:1)`; a duplicate constant case is `duplicate case in expression
  switch` and is found through constant expressions and named untyped
  constants (`case 1: case 2 - 1:` compiled); an interface that declares a
  method twice is `duplicate method M` (it was accepted).
- The message for an unsupported numeric type is `type float64 is not
  supported; the numeric types are the integer types`.
- `fmt.Fprint`, `Fprintln`, and `Fprintf` write to any value with a `Write`
  method (was `cannot use *buf as *os.File value`). A first argument that is
  no writer is `cannot use int as io.Writer value in argument to
  fmt.Fprintln`.
- `time.Duration` is defined over `int64`, and `t.Unix()`, `t.UnixMilli()`,
  `t.UnixNano()`, `d.Nanoseconds()`, `d.Microseconds()`, `d.Milliseconds()`,
  the arguments of `time.Unix`, and `ContentLength` of an HTTP request and
  response are `int64`, as in Go; `t.Unix()` was an `int`.
- `gofmt` writes the letter of a base prefix and of an exponent in lower case
  (`0X1F` to `0x1F`, `1E6` to `1e6`), as Go's does.
- A compile error is reported in Go's words and at Go's place. A value of
  the wrong type names the operand and where it was used: `cannot use 1
  (untyped int constant) as string value in variable declaration` (was
  `cannot use int as string value`), with the reason for an interface (`T
  does not implement I (method M has pointer receiver)`). An invalid
  operation is written out where it begins: `invalid operation: a + b
  (mismatched types int and string)` (was `mismatched types int and string`
  at the operator). A selection of what a type lacks is `t.b undefined (type
  T has no field or method b)`. A call with the wrong number of arguments
  gives `have (number)` and `want (int, string)`, for library functions and
  builtins too. `x := f()` of a two-result `f` is `assignment mismatch: 1
  variable but f returns 2 values`; `x redeclared in this block` is followed
  by `other declaration of x`. Messages may hold continuation lines, each
  after a tab, as Go prints them.
- `GoType.description` prints `error`, `any`, and an interface type with its
  methods (was `interface{...}` and `interface{}`).
- The library packages written in Go are linked by one mechanism, and only
  what a program reaches of `net/http`, `net/url`, `io`, `strings`, `sort`,
  and `sync` is linked, variables and their initializers included: a program
  that uses `net/http` for its status constants alone is linked with no
  function of it. Their Go text is the files under `Sources/SwiftixGoLibrary`;
  `Scripts/generate-go-library.py` writes the Swift file the build reads.

### Fixed

- Results that share a type, `func divide(a, b int) (q, r int)`, were
  refused with `expected type`.
- `recover` returned a panic's value without its type when the type was a
  named one: `%T` of a recovered `code(4)` said `int`, and it did not assert
  as `code`. The argument of `panic` now keeps its type like any value
  converted to an interface.
- `gofmt -r` broke the file when an operand of a matched expression was in
  parentheses (`a * c -> c * a` on `(x + y) * c`), and when a rule named one
  identifier (`total -> sum` replaced whole expressions by `sum`).
- Importing a package of the run-time library twice in one file is reported
  by that package's name (`os redeclared in this block`); the message used to
  say `fmt` whatever the package was.
- A variable declared in a loop body, and the variable of a `for` or `range`
  clause, was one variable for all iterations, so pointers taken in
  different iterations named the same storage: after
  `for i := 0; i < 3; i++ { x := i; list = append(list, &x) }` every element
  of `list` pointed at `2`. Each iteration now has its own variable, as in
  Go. The same held for a pointer-receiver method that kept its receiver and
  for a slice of a loop-local array. Programs that take no such pointer
  compile to the same instructions as before.
- A composite literal with a literal type was rejected in the header of a
  `for`, `if`, or `switch` (`for _, v := range []int{1, 2} { }`).
- A value read from a map had no static type in the compiler, so
  `p := m[k]` followed by `p.field` failed with `bytecode operand type
  mismatch` when the map held pointers, and a map value stored in an
  interface lost its type.
- `gofmt` joined the statements of a function literal that is an argument
  of a call onto one line (`t.Run("name", func(t *testing.T) {` followed by
  `a := 1 b := 2`), which no longer compiled. It also moved a comment after
  the `{` of a block or after a `case` to the next line, and kept a final
  comma before a closing delimiter on the same line (`f(a, b,)`).
- `gofmt` broke `interface{}` and `struct{}` in a function signature over
  two lines (`func f(v interface {` / `}) int{...}`), which no longer read as
  the declaration it was. It also printed `[]interface{}{x}` as a block,
  `type grid[2]point` and `type link * node` without their spacing, a
  function literal as `func () {`, and the `:` of a slice inside a composite
  literal as a key's (`[]string{s[1: 2]}`).
- `gofmt` printed a pointer element type in an expression as a
  multiplication (`[] * node{}`, `make([] * node, 0)`), a pointer field of a
  struct as `next * node`, a slice field as `lines[]string`, `map [K]V` in a
  declaration, an interface with methods on one line, `if(x)` and
  `return[]T{}` without their space, and `var x = a *b`. Each now matches
  Go's `gofmt`.
- `nil` could not be passed or assigned to a named interface type
  (`cannot use nil as namer value`); only `error` and literal interface types
  took it.
- Indexing or slicing a nil slice failed with `bytecode operand type
  mismatch`. It now panics with Go's bounds error, and `s[0:0]` of a nil
  slice is nil.
- Calling a method on a nil interface value failed with `bytecode operand
  type mismatch`; it is now Go's nil pointer dereference panic.
- `net.Dial` returned a connection and a nil error when the peer refused the
  connection or the handshake was abandoned. It now returns
  `dial tcp <address>: connect: connection refused` or `connection timed out`
  and closes the socket.
- A function with several results that recovered a panic returned its first
  result alone correctly: `n, s = 5, "five"` before the panic gave the caller
  `5` and `0`, and unnamed `(int, string)` results gave a second value that
  was not `""`.
- A deferred call that changed a named result through a pointer (`defer
  reset(&n)` before `return 5`) was not seen by the caller. A function that
  defers now returns what its result variables hold once its deferred calls
  have run, as in Go, whether a pointer or a closure changed them.
- A value of a slice or map type was refused where a named type with that
  underlying type was wanted, and the reverse: `var a ints = []int{1, 2}`
  with `type ints []int` was `cannot use []int as ints value`. Named channel
  and function types are assignable the same way.
- `[]int(nil)` was `cannot convert nil to type []int`, and `(*T)(x)` was
  `unsupported function call`.
- `fmt.Println(f())` prints every result of `f`: it printed `1` where Go
  prints `1 a`, `fmt.Printf(two())` printed `%!d(MISSING)`, `sum(f())` with
  `func sum(xs ...int)` summed the first result alone, and
  `fmt.Println(strconv.Atoi("12"))` printed `12` without the error.
- A call of several results where one value is wanted is refused with
  `multiple-value f() (value of type (int, string)) in single-value context`,
  as Go refuses it. It compiled with the first result: `f() + 1`, `[]int{f()}`,
  `m[f()]`, `if f() == 1`, `return f(), 1`, `n = f()`, a package-level `var n
  = f()`, and `strconv.Atoi("5") + 1` all ran. `return f()` in a function of
  one result is `too many return values`, and `v(f()...)` is `cannot use ...
  with 2-valued f()`.
- A library type named where a value is wanted says `time.Time (type) is not
  an expression`, as Go does, instead of calling it a function of the run-time
  library.
- `x := v` that declares nothing is `no new variables on left side of :=` at
  the `:=`. Was `x redeclared in this block` at the name.
- A name of the program called `iota` hides the constant generator:
  `iota := 5; const c = iota` gave `c` the value `0`.
- A name declared twice at package level is reported at the second name;
  `var _ = undefined` is `undefined: undefined` (was `initialization cycle
  for package variable`); `var init = 1` is `cannot declare init - must be
  func`; a method named like a field of its type is `field and method with
  the same name`; a method on a pointer or interface type is `invalid
  receiver type`. The last three were accepted.
- A type alias in a package-level value (`type Num = int; var h = func(n Num)
  Num {...}`) is resolved. Was `unsupported zero value type`.
- `gofmt`: a variadic type that begins a list has no blank before it,
  `func(...int)` (was `func( ...int)`).
- A literal of a named map type read an identifier or integer key as its
  spelling: `m{k: 1}` printed `map[k:1]`, and `mi{1: "a"}[1]` was empty.
  Duplicate constant keys in a map literal were accepted.
- `var t T = x` with `x` of `struct{ a int }` gave `t == T{1}` false;
  `x := 5; t := T{x: 1}` did not report `declared and not used: x`;
  `defer len(s)` was `missing function: len`; `%T` of a function with a
  struct parameter printed `func(struct)`.
- `nil` is a case of a switch on a pointer, an interface, or a channel (was
  `invalid case nil in switch on *T`); a slice, a map, or a function may be
  switched on with `nil` as its only case; `true` may be a case twice;
  `switch x := 1 {` and `switch nil {}` are refused, as in Go.
- A function may end in a `select` whose clauses all return, in `select {}`,
  in a `goto`, or in a clause that falls through. Was `missing return`.
- A call `p.F(...)` where a variable `p` hides a package of that name calls
  the variable's method. It called the package's function `F` when the
  program linked one.
- In a shift that is no constant, an untyped constant on the left takes the
  type the shift is used at: `var u uint8 = 1 << n` was `cannot use int as
  byte value`. A typed constant expression that leaves its type is reported:
  `const c byte = 200; d := c + 100` compiled and printed `44`. An untyped
  constant expression is computed exactly: `x := 1 << 62 * 4` printed `0`.
- `gofmt`: `func fn(s struct { a int }) {` is written as Go writes it;
  `gofmt -r` rewrites inside `[]interface{}{1, 2}`; a comment after the
  closing brace of a field whose type is a struct of several lines follows
  the brace after one blank.
- An untyped string constant takes a named string type and an untyped
  boolean a named bool type: `type S string; var s S = "a"` was `cannot use
  string as S value`, and so were `const GET Method = "GET"`, a `Method` map
  key or argument written as a string, and `type Flag bool; var f Flag =
  true`.

## 0.13.1 — 2026-10-08

### Added

- `ProcessContext.yield(resume:)`: a CPU-bound process gives up the processor
  and continues in a later step without holding logical time, unlike
  `sleep(0)`.
- `ProcessContext.yield()`: the `async` form, for process bodies that loop
  through `await`. It throws `.interrupted` if the process is terminated while
  it is waiting for its turn.

### Changed

- `EventLoop.advance(by:stepBudget:)` no longer lets yielded CPU-bound work
  freeze the clock. A timer due inside the interval runs at its deadline after
  at most 8 consecutive yields, and when the budget runs out with only yields
  left, `now` still reaches the target (the result stays `.budgetExceeded`).
  Timers, executor jobs, and ordinary zero-delay work hold the clock as
  before, and `runUntilIdle()`/`runNext()` are unchanged. Hosts should keep
  advancing toward their own frame target when a call stops short of it; see
  "Real-Time Driving" in `docs/architecture.md`.
- `EventLoop.advance(by:stepBudget:)` treats the executor jobs that resume an
  `async` task after `yield()` as yields: they keep their FIFO place, and the
  clock reaches the target when the budget runs out with only such jobs and
  yields left. Every other job holds the clock as before.
- `awk` and `bc` yield instead of taking a zero-length sleep, and `bc` also
  yields on the first iteration of a loop instead of only every 256th.
- A read from `/dev/zero`, `/dev/full`, `/dev/random`, or `/dev/urandom`
  through the blocking or async frontend resumes as a yield.
- A shell `while`/`until` loop yields on its first iteration and then every
  256 iterations.
- `ps`, `top`, and `/proc/<pid>/stat` report an `async` process that is
  yielding (`awk`, `bc`, `cat /dev/zero`, a custom body calling `yield()`) as
  running (`R`) until it next waits. It was shown as sleeping (`S`) for most
  of each turn.
- A yielding process that is stopped and continued is yielded work again at
  once: a step held back while it was stopped is replayed as a yield if it
  was one, so the process is reported as running (`R`) and does not hold
  logical time for the first turn after `SIGCONT`.
- A process step queued by yielded work (a wake-up through a pipe, a child
  being started, an exit being reported) is queued as a yield, and `yes`
  yields each time a full pipe makes it wait.
- A file-backed Go program yields at each instruction quantum instead of taking
  a zero-length sleep, and `ps` reports a spinning program as running (`R`).

### Fixed

- A CPU-bound Go program no longer stops logical time for its kernel: a
  `sleep` in another process, TCP retransmission, ARP, and `ping` timeouts now
  fire while it runs. Previously each quantum re-queued itself at the current
  instant, `advance(by:)` never reached its target, and it returned
  `.budgetExceeded` with the clock unmoved for as long as the program ran.
- An `async` process body no longer takes a loop step for every `async` call
  and return. Its jobs were run as jobs of the loop's serial executor although
  the task only has a task-executor preference, so the Swift runtime re-posted
  the task at each call boundary. A 5,000-iteration `bc` loop took about
  155,000 steps, more than the default step budget of one `runUntilIdle()`,
  and now takes about 50; the loop now has a separate task executor and runs
  those jobs on it. Fewer steps per process means a given step budget does
  more work, and async processes interleave at their suspensions only.
- `awk`, `bc`, and commands that copy from an endless device (`cat /dev/zero`,
  `dd if=/dev/urandom`) no longer stop logical time for their kernel while
  they run under a real-time host; a `sleep` in another process now wakes on
  time. The same holds for endless pipelines such as `yes | cat > /dev/null`.
- A shell loop made only of builtins (`while :; do :; done`, also in the
  background) no longer runs as a single step that never ends. The call that
  drove it (`advance(by:)`, `runUntilIdle()`) never returned, so the host
  hung and Ctrl-C could not be delivered.
- `mkdir`, `mv`, `rm`, `rmdir`, and every other command that goes through the
  capability-scoped file calls now stamp what they change. A new directory or
  file created that way was left at the epoch (1970 with an injected clock), a
  directory's mtime/ctime did not follow entries added, removed, or renamed
  through those calls, and a renamed node kept its old ctime.
- `rm` of one of several hard links now gives the link count back and updates
  the inode's ctime.
- `symlink` no longer restamps the existing directories that lead to the link.
- A tmpfs mount root, `/dev` and `/proc` files, and computed nodes such as
  `/proc/<pid>` and `/dev/pts/<n>` no longer show the epoch: kernel-provided
  nodes are dated at boot on the injected clock and computed ones at lookup.
  Restored snapshots and images keep their stored times.

## 0.13.0 — 2026-10-07

A userland baseline: the shell is a POSIX-style interpreter, the built-in
command set covers everyday coreutils use, and time, identity, devices, and
signals behave the way a Linux user expects. Public API changes are additive.

### Added

- Shell language: `if`/`for`/`while`/`until`/`case`, functions with `local`
  and `return`, here-documents and here-strings, `$(...)`, `$((...))`,
  `${v:-d}`-style parameter expansion, brace and tilde expansion, subshells
  and groups, `trap`, `set -eux`, aliases, and job control. `sh` runs a script
  file, `sh -c STRING`, or a nested interactive shell, and an executable
  script (`./x.sh a b`, or by name through `$PATH`) runs as a program.
- Shell builtins `umask [-S] [MODE]` (octal and symbolic) and `$RANDOM`, plus
  `BUILTIN --help` for every builtin.
- Commands: `awk` (patterns, arrays, user functions, `printf`, `getline`,
  `system()`, and `|` pipes through `sh -c`), `tar`, `bc`, `dd`, `od`,
  `hexdump`, `xxd`, `base64`, `tr`, `comm`, `join`, `paste`, `column`,
  `expand`, `fold`, `split`, `tac`, `cmp`, `strings`, `file`, `tree`,
  `realpath`, `mktemp`, `truncate`, `rmdir`, `sync`, `yes`, `less`, `time`,
  `watch`, `nproc`, `printenv`, `pgrep`, `pkill`, `pidof`, `killall`, `date`,
  `cal`, `id`, `groups`, `who`, `w`, `logname`, `tty`, `stty`, `shutdown`,
  `reboot`, `poweroff`, `halt`, `dig`, `ss`, and `telnet`.
- Every registered command answers `--help` with `Usage: …` and exits 0, and
  `man COMMAND` renders the same text. `Command` gains an optional `usage`
  string for consumer-registered commands.
- Wall clock: `Kernel.setWallClock` injects the epoch and zone; `date`,
  `ls -l`, `stat`, `tar tv`, `touch -d`/`-t`, and `find -newer`/`-mmin`/
  `-mtime` use it. Without an injected clock, logical zero is the Unix epoch.
- Identity: users and groups come from `/etc/passwd` and `/etc/group` (with a
  synthetic `root`/`userN` fallback) in `ls -l`, `stat`, `chown`,
  `find -user`, `ps`, `id`, `whoami`, the prompt, and `su`. `su` accepts a
  name or uid and the forms `su`, `su -`, `su - USER`, `su USER -c COMMAND`,
  and `su USER COMMAND ARG...`.
- Devices and procfs: `/dev/zero`, `/dev/full`, `/dev/random`, `/dev/urandom`,
  `/dev/tty`, `/dev/pts/N`, `/dev/stdin|stdout|stderr`, `/dev/fd`;
  `/proc/self`, `/proc/<pid>/{stat,comm,environ,fd,cwd}`, and system files
  such as `/proc/uptime`, `/proc/loadavg`, `/proc/meminfo`, and
  `/proc/version`.
- Per-process `umask` (`ProcessContext.umask(_:)`, `fileCreationMask`), and
  `Kernel.onPowerRequest` for `shutdown`/`reboot`.
- Network commands: `ip addr|link|route|neigh`, `ss`, `dig`, `telnet`,
  `hostname -I|-i|-s|-f`, a fuller `curl`/`wget`/`nc`/`ping`/`traceroute`
  option set, and uniform option parsing — an unknown option is a usage error
  (exit 2), never taken for a host name.
- Ctrl-C at the shell: at an idle prompt it discards the input line and
  prompts again; at a continuation prompt (`> `) it abandons the pending
  command; it stops a running shell loop; and a nested interactive shell
  survives it. `$?` is 130 afterwards.
- Swiftix Go: `os.Stdin`/`os.Stdout`/`os.Stderr`, `fmt.Fprint`/`fmt.Fprintln`,
  `(*os.File).Read`/`Write`/`WriteString`, `os.ReadFile`/`os.WriteFile`,
  `sort.Strings`/`sort.Ints`, `strconv.Itoa`, the bitwise operators, the
  `byte`/`uint8` type, and conversions among `int`, `byte`, `string`, and
  `[]byte`. `GoVirtualMachine.startProcess` runs an executable cooperatively
  as the body of a process.
- Swiftix Go links the local packages of a module into one program:
  `GoCompiler.compile(packages:root:)` and
  `GoCompiler.compile(root:sources:)` (with `GoPackageSource`) compile a
  `package main` together with every package it imports, directly or
  transitively. Across packages a program may call functions with any number
  of results, use exported constants, read and assign exported variables, and
  use exported types, struct fields, and methods; packages initialize
  dependencies first, each exactly once. A cross-package reference compiles to
  the same instructions as the in-package form. Unexported and undefined
  names, import cycles, unused local imports, imports of a `package main`, and
  `internal/` packages imported from outside their tree are diagnosed.
  `go build`, `go run`, and `go install` accept a package directory such as
  `./cmd/tool`.
- Swiftix Go language: compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`,
  `&=`, `|=`, `^=`, `&^=`, `<<=`, `>>=`); hexadecimal, octal (`0o644` and
  `0644`), and binary integer literals with `_` separators; `return f()`
  forwarding every result of a multi-result call; qualified composite
  literals (`pkg.Type{...}`); and package-level initializers that call
  imported packages.

### Changed

- Swiftix Go: the `go` tool builds multi-package modules through the module
  linker, so a main package is no longer limited to single-result functions
  of the packages it imports. The build cache key now also names the root
  package (entries written by earlier builds are simply not reused), and an
  import chain deeper than 128 packages is refused. A leading zero now selects
  octal (`010` is 8), `12ab` is an invalid literal instead of two tokens, and
  `gofmt` writes a space before a parenthesized result list
  (`func f() (int, error)`).
- Unquoted expansions are split into fields on `$IFS` and then globbed;
  quote an expansion (`"$v"`) to keep it as one word.
- Shell variables are no longer exported by default: `v=1` is visible to
  child processes only after `export v` (or as a `v=1 command` prefix).
- Command substitution, pipeline stages that run shell code, and `( ... )`
  run in a child shell, so their assignments and `cd` do not affect the
  parent.
- New files, directories, and FIFOs honor the process `umask` (022 by
  default): `mkdir` creates mode 0755 and `mkfifo` 0644.
- `grep` and `sed` use POSIX basic regular expressions by default; pass `-E`
  for extended syntax (`+`, `?`, `|`, unescaped groups).
- `mkdir` without `-p` no longer creates missing parent directories, and
  reports an existing directory as an error.
- `head` and `tail` print `==> NAME <==` headers when given several files.
- `find`, `du`, `tree`, `ls -R`, `grep -r`, `rm -r`, and `cp -r` no longer
  follow symbolic links met during a walk (`grep -R` follows them, visiting
  each directory once); `chmod -R`, `chown -R`, and `tar` walk the same way.
  `grep -r`, `cp -r`, and `tar` skip device nodes met during a walk.
- `ls -l` and `stat` print calendar times and user/group names (`ls -n` for
  numeric ids). In `stat -c`, `%X`/`%Y`/`%Z` are integer epoch seconds and
  `%x`/`%y`/`%z` the readable forms.
- Reading an endless device with `cat` (`cat /dev/zero`) streams until
  interrupted, as on Linux. A failed write is reported and fails the command:
  `echo x > /dev/full` prints `echo: write error: No space left on device`
  and exits 1.
- PID 1 of a PID namespace ignores guest signals it has no handler for, so
  `kill -9 1` no longer ends the session it is typed into. Signals sent
  through the host `Kernel` API are unaffected.
- A foreground job killed by Ctrl-C ends the rest of its command line
  (`sleep 100; echo done` prints nothing).
- `hostname -I` and other options are parsed as options; they previously set
  the host name to the option text.
- `whoami` and the shell's default `USER`/`HOME` come from the user database.
- Directory search (execute) permission is enforced on every component of a
  path, not only the last: as uid 1000, `cat /root/x` now fails with
  `Permission denied` when `/root` is mode 0700, whatever the mode of `x`.
  This applies to every path syscall, to symbolic-link targets, to mount
  namespaces, and to `FileSystemScope` operations; uid 0 is unaffected. A path
  at or below the working directory still resolves from the working
  directory. `link` fails when the caller cannot reach the target, and tab
  completion lists only what the shell's user may list.
- `mount` and `umount` (and `mountTmpfs`/`mountBind`/`unmount`) require
  uid 0; other users get `must be superuser to use mount.` Previously any user
  could change the mount table, including bind-mounting a directory it could
  not otherwise enter.
- A connected TCP socket is closed by its last descriptor: `tcpClose` on one
  of several descriptors sharing a connection (a `dup`, or a socket inherited
  by a child) no longer sends a FIN; the last close does.
- Swiftix Go conformance: `s[i]` on a string is a `byte` and `time.After`/
  `time.Tick` return `<-chan time.Time`, as in Go. Source that used a string
  byte as an `int` needs `int(s[i])`.
- File-backed Swiftix Go programs are scheduled cooperatively. They yield to
  the event loop every instruction quantum instead of stopping at 1,000,000
  instructions, `time.Sleep` and timers park the process until logical time
  advances instead of fast-forwarding the clock, and reads of standard input
  no longer run the upstream pipeline stage nested inside the reader. A host
  that runs such a program must advance logical time for its timers to fire.

### Fixed

- A directory tree nested thousands of levels deep (reachable from a guest
  with `mkdir -p`) no longer overflows the host stack. Releasing the tree,
  `/proc/meminfo` and resource accounting, rename's subtree check, filesystem
  snapshot capture/validation/restore, and `rm -r`, `chmod -R`, `chown -R`,
  `du`, `tree`, `grep -r`, `df`, and `free` now walk with explicit worklists.
  A snapshot's legacy `root` projection is written to at most
  `FilesystemSnapshot.legacyProjectionDepthLimit` (256) directory levels;
  the inode table still holds every level, and images whose `root` carries
  the full tree remain valid.
- Swiftix Go programs no longer lose output beyond a pipe's 64 KiB: a write
  parks until the reader makes room.
- A goroutine that sleeps or reads standard input exactly on an instruction
  quantum boundary no longer aborts the run with `bytecode operand type
  mismatch`.
- The Go heap no longer scans every cell after each instruction, and a slice
  element store or `append` no longer copies the whole backing array.

- A process that exits or is killed with a connected TCP socket open now
  closes the connection: Ctrl-C on `nc` or `curl` no longer leaves the server
  side established forever. The peer sees a FIN, or a reset if the process
  left received data unread (as on Linux). Connections nobody accepted are
  reset when their listener closes, data sent to a closed peer draws a reset,
  an ownerless connection whose peer never closes is released after 60
  seconds, and one whose last data is stuck behind a zero window resets the
  peer after 8 unanswered probes.
- A TCP close with data still waiting for the send window sends the FIN after
  that data instead of ahead of it.
- Data can be sent on a connection after the peer has closed its half
  (CLOSE_WAIT).
- A receive on a connection that was already reset returns immediately
  instead of parking forever, and bytes that arrived before a reset are
  delivered before the reset is reported.
- `mv`, `chmod`, `chown`, and `du` report `Permission denied` rather than
  `No such file or directory` for a path behind an unsearchable directory.
- Output larger than a pipe buffer (64 KiB) is no longer truncated in
  pipelines or command substitution (`x=$(seq 1 20000)`,
  `seq 1 50000 | sort -rn | head -1`): producers wait for the reader.

## 0.12.0 — 2026-09-30

This release lets independently packaged Swiftix Go programs run full-screen
in a terminal, such as the nano-style editor from the `editors` repository.
It is an intentional pre-1.0 API break: see the 0.12 notes in
[compatibility](docs/compatibility.md).

### Changed

- The GitHub Actions workflow is removed. Verification runs locally with the
  commands in the README, and host toolchain packages are built, signed, and
  notarized as manual release steps; this release publishes no packaged
  toolchain.
- The package version advances to 0.12.0: the public `GoInstruction` and
  `GoIROperation` enums gain cases for the terminal ABI and `strings`, which
  breaks exhaustive switches. See the 0.12 notes in
  [compatibility](docs/compatibility.md).

### Added

- `swiftix/userland` terminal calls for full-screen Go programs:
  `ReadStdin`, `WriteFile`, `SetRawMode`, and `WindowSize`. Images that use
  them encode four new bytecode opcodes (97–100); the image format and ABI
  versions are unchanged, and older runtimes reject such images at decode.
- `GoVirtualMachine.startProgram`, a resumable run that suspends while its
  goroutines wait on terminal input. `GoExecutableLoader` uses it, so
  file-backed interactive programs wait for keystrokes instead of reporting a
  deadlock. Its instruction and output budgets apply per uninterrupted slice.
- Go interpreted string literals accept `\a`, `\b`, `\f`, `\v`, `\xHH`,
  three-digit octal, `\uHHHH`, and `\UHHHHHHHH` escapes, so programs can
  emit terminal control sequences such as `"\x1b[2J"`. Escapes must still
  form valid UTF-8, and `gofmt -r` re-quotes control characters as `\x`
  escapes.
- A native `strings` package: `Contains`, `Count`, `HasPrefix`, `HasSuffix`,
  `Index`, `Join`, `LastIndex`, `Repeat`, `Split`, and `TrimSpace`, with Go
  semantics and string and collection limits. Calls encode as opcode 101
  followed by a function byte, so later functions need no new opcode; older
  runtimes reject them at decode.

### Fixed

- A process step that completes nested inside another step of the same
  process (for example a read resumed while the Go VM drives the event loop)
  no longer reaps the process with status 0 while the enclosing step is still
  running.
- A Swiftix Go run that fails with the terminal in raw mode restores cooked
  mode.
- A `for` header no longer parses an identifier before `{` as a composite
  literal, so `for i < limit {` and `for …; …; i = i + step {` compile.
- Indexing, slicing, and ranging over a Go string no longer copy the whole
  string on every operation, which made byte loops quadratic.

## 0.11.2 — 2026-09-29

This release republishes the host toolchain packages so that every
platform's downloads are complete. The toolchain is unchanged from 0.11.0.

### Fixed

- The Linux `arm64` `.tar.gz` package, which was missing from the 0.11.1
  downloads, is published again alongside the other seven packages.

## 0.11.1 — 2026-09-29

This release adds host toolchain packages for two more host platforms. The
toolchain itself is unchanged from 0.11.0.

### Added

- `swiftix-toolchain` packages for macOS on Intel (`amd64`: `.pkg` and
  `.tar.gz`) and Linux on `arm64` (`.deb` and `.tar.gz`). CI builds and
  install-smoke-tests them next to the existing macOS `arm64` and Linux
  `amd64` packages, and signs and notarizes both macOS packages for tagged
  releases.

## 0.11.0 — 2026-08-16

This release establishes the versioned teaching-observability surface used by
independently packaged system diagnostic commands.

### Added

- Kernel-wide managed-runtime memory admission with configurable limits, exact
  Swiftix Go heap reporting, per-process heap/GC diagnostics, and separate VFS
  byte accounting.
- `/proc/<pid>/fdinfo` descriptor diagnostics for files, pipes, FIFOs, PTYs,
  UDP sockets, TCP sockets, and devices.
- A versioned teaching-observability contract in `/proc/swiftix`, plus the last
  128 completed Swift-native calls per process in `/proc/<pid>/syscalls`.

### Changed

- `/proc/meminfo` and `free` now report actual managed-runtime heap usage instead
  of treating VFS file bytes as synthetic physical memory. Output explicitly
  distinguishes the managed-runtime model from host memory and VFS storage.
- `/proc/processes` adds a `MEM` field containing exact runtime-reported bytes;
  `top` displays the same value without labeling it RSS.

### Fixed

- Release validation now rejects a tag that disagrees with `Swiftix.version` or
  lacks a matching changelog entry. The historical `v0.10.1` tag contained the
  `0.10.0` runtime version string; 0.11 establishes the corrected baseline.

## 0.10.0 — 2026-08-15

This pre-1.0 minor intentionally changes the public kernel API described in the
0.9-to-0.10 migration notes.

### Added

- Public process diagnostics through `Kernel.snapshotProcesses()`, including
  lifecycle, Linux-style state, exit status, wait reasons, queued work, signals,
  descriptors, and scheduler ticks.
- `ProcessExitStatus`, `SIGSTOP`, continued child notifications, and the
  `ProcessWaitOptions.continued` (`WCONTINUED`) option.
- Separate live and zombie counts in kernel resource snapshots and `/proc/resources`.
- `SIGPIPE` plus typed `SyscallError.brokenPipe` (`EPIPE`) for readerless
  pipe/FIFO writes.
- Supplementary process groups and a compact inherited mode-bit DAC model.
- Injectable asynchronous `BlockVolume` storage with typed failures and an
  explicit flush/durability barrier, while retaining RamDisk compatibility.
- Pager-friendly `pread`/`pwrite` regular-file operations that preserve the
  shared open-file-description offset.
- Typed device/storage syscall failures for missing devices, I/O failure,
  exhausted space, and read-only storage.

### Changed

- Process execution state and terminal lifecycle are independent. Exited
  children now remain observable as zombies until a parent wait reaps them.
- Process-owned timers, resumptions, and parked operations are cancelled at
  logical exit; orphaned children are adopted by a namespace reaper or the host.
- Blocking operations use a structured wait registry instead of an opaque count.
- Descriptors created by `dup` or spawn inheritance now share one open-file
  description, including status flags, locks, offsets, and last-close lifetime.
- VFS names now belong to directory entries, so hard links and rename preserve
  independent names for one inode-like node.
- Pipe, PTY, and TCP blocking reads retain FIFO queues of waiters rather than one
  overwriteable callback.
- `pids.max` rejects child creation before PID allocation (`spawn` returns `0`),
  while migration into an over-limit cgroup remains allowed.
- UDP binding is single-owner and non-replacing; port `0` allocates an ephemeral
  port and `SO_REUSEADDR` no longer silently steals an existing binding.
- Credential changes now inherit across spawn and enforce root/owner boundaries
  for identity, ownership, mode, and parent-directory mutation.

## 0.9.0 — 2026-08-15

### Added

- Single-node kernel, VFS, process/fd/signal/pty model and IPv4 TCP/IP stack.
- Swiftix Go compiler, bytecode runtime and macOS/Linux host tools.
- Deterministic root filesystem images and Debian-style package management.
- Public topology, terminal, uplink and observability seams.

### Changed

- Distribution content moved to SwiftixDistribution.
- Core version advanced from `0.0.1` to `0.9.0` for the 1.0 stabilization cycle.
- Root filesystem minimum-version checks now implement SemVer prerelease precedence.
- Host image execution moved from `swiftix-run` to `swiftix-go exec`.
- Removed the unconsumed built-in `awk` and `nano` programs and the partial
  IPv6 address/ICMPv6 surface.

### Known limits

- IPv6 is not supported; Swiftix Go and Linux compatibility are documented subsets.
- `pkg` uses HTTP + SHA-256 in trusted experiment networks; it does not
  authenticate arbitrary public repositories.
- Public API remains subject to review until 1.0.
