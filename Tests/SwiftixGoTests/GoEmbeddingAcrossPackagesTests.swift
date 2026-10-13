/// Embedding across the packages of a module: a struct that embeds a type
/// of another package, by value and by pointer, under the name an import
/// gives the package, is lent its exported fields and its methods, and
/// implements the interfaces of that package through them.
///
/// The module below was run through Go 1.24.5, and what it printed is
/// pinned here without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go embedding across packages")
struct GoEmbeddingAcrossPackagesTests {

    /// The embedded field of `lib.Base` is `Base`, whatever the file calls
    /// the package, and a method declared for a promoted one is found by
    /// the name of the type that embeds, in whichever package that is.
    @Test func aTypeOfAnotherPackageIsEmbedded() throws {
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/embedmod",
                    sources: [GoSourceFile(path: "/m/main.go", text: mainSource)]),
                GoPackageSource(
                    importPath: "example/embedmod/lib",
                    sources: [GoSourceFile(path: "/m/lib/lib.go", text: libSource)]),
                GoPackageSource(
                    importPath: "example/embedmod/internal/deep",
                    sources: [GoSourceFile(path: "/m/internal/deep/deep.go", text: deepSource)]),
            ],
            root: "example/embedmod")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == expectedOutput)
    }
}

private let libSource = #"""
package lib

import "fmt"

type Base struct {
	ID    int
	label string
}

func NewBase(id int, label string) Base { return Base{id, label} }

func (b Base) Describe() string  { return fmt.Sprintf("%s#%d", b.label, b.ID) }
func (b *Base) Rename(to string) { b.label = to }
func (b Base) hidden() string    { return "hidden:" + b.label }
func (b Base) Reveal() string    { return b.hidden() }

type Namer interface {
	Name() string
}

type Described interface {
	Namer
	Describe() string
}

type Node struct {
	Base
	Children []*Node
}

func (n *Node) Add(c *Node) *Node {
	n.Children = append(n.Children, c)
	return n
}

func (n Node) Name() string { return "node:" + n.label }

type Logger struct {
	Prefix string
	lines  []string
}

func (l *Logger) Logf(format string, args ...interface{}) {
	l.lines = append(l.lines, l.Prefix+fmt.Sprintf(format, args...))
}

func (l *Logger) Lines() []string { return l.lines }

"""#

private let deepSource = #"""
package deep

import (
	"example/embedmod/lib"
)

type Service struct {
	*lib.Logger
	lib.Node
	Port int
}

func New(port int) *Service {
	s := &Service{Logger: &lib.Logger{Prefix: "[svc] "}, Port: port}
	s.ID = port
	s.Rename("service")
	s.Logf("created %d", port)
	return s
}

func (s *Service) Name() string { return "svc:" + s.Describe() }

"""#

private let mainSource = #"""
package main

import (
	"fmt"

	"example/embedmod/internal/deep"
	l "example/embedmod/lib"
)

type Local struct {
	l.Base
	extra string
}

type PLocal struct {
	*l.Base
}

type App struct {
	*deep.Service
	name string
}

func show(d l.Described) { fmt.Println(d.Name(), "/", d.Describe()) }

func main() {
	x := Local{l.NewBase(1, "one"), "e"}
	fmt.Println(x.ID, x.Describe(), x.Reveal())
	x.ID = 2
	x.Rename("two")
	fmt.Printf("%v %+v %T\n", x, x, x)
	fmt.Printf("%#v\n", x)

	b := l.NewBase(3, "three")
	p := PLocal{&b}
	p.Rename("drei")
	p.ID++
	fmt.Println(b.Describe(), p.Describe())

	app := App{deep.New(8080), "app"}
	app.Logf("started %s on %d", app.name, app.Port)
	app.Add(&l.Node{Base: l.NewBase(9, "kid")})
	fmt.Println(app.Name(), app.ID, app.Port, len(app.Children), app.Children[0].Describe())
	fmt.Println(app.Prefix, len(app.Lines()), app.Lines()[1])
	show(app)
	show(app.Service)
	var n l.Namer = app.Node
	fmt.Println(n.Name())
	d := l.Described(&app.Node)
	fmt.Println(d.Describe())
	f := app.Describe
	g := (*deep.Service).Name
	h := l.Node.Describe
	fmt.Println(f(), g(app.Service), h(app.Node))
	fmt.Printf("%T %T\n", app, app.Service.Node)
}

"""#

private let expectedOutput = #"""
1 one#1 hidden:one
{{2 two} e} {Base:{ID:2 label:two} extra:e} main.Local
main.Local{Base:lib.Base{ID:2, label:"two"}, extra:"e"}
drei#4 drei#4
svc:service#8080 8080 8080 1 kid#9
[svc]  2 [svc] started app on 8080
svc:service#8080 / service#8080
svc:service#8080 / service#8080
node:service
service#8080
service#8080 svc:service#8080 service#8080
main.App lib.Node

"""#
