/// `path`, `path/filepath`, `io/fs`, and what `os` knows of the file
/// system: each program makes a tree of files and directories in its
/// working directory, reads it back, and removes it.
///
/// What each program prints is what Go 1.24.5 printed for it. The sizes of
/// directories and links, the permissions of links, and the order of a
/// directory's entries are the system's, and the programs print none.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go paths and the file system")
struct GoFileSystemTreeTests: GoTestHarness {
    /// What `go run` prints for `source`, in a directory of its own.
    private func run(_ source: String) -> String {
        runShell(
            ["cd /tree", "GOCACHE=off go run ."],
            seed: { context in
                _ = context.mkdir("/tree")
                Self.write(context, path: "/tree/go.mod", contents: "module example/tree\n\ngo 1.24\n")
                Self.write(context, path: "/tree/main.go", contents: source)
            })
    }

    /// `path`: `Clean`, `Split`, `Join`, `Base`, `Dir`, `Ext`, `IsAbs`, and `Match` with its errors.
    @Test func pathCleansJoinsAndMatchesAsGosDoes() {
        let output = run(path1Source)
        #expect(output.contains(path1Expected))
    }

    /// `os.Stat`, `Lstat`, `ReadDir`, `MkdirAll`, `RemoveAll`, `Chmod`, `Chdir`, `Symlink`, `Readlink`, and a file's `Name`, `Stat`, `Readdirnames`, and `Readdir`, with Go's errors; `fs.FileMode` prints as Go prints it.
    @Test func theFileSystemIsReadAndChangedAsGosIs() {
        let output = run(fs1Source)
        #expect(output.contains(fs1Expected))
    }

    /// `path/filepath`: the lexical functions, `Rel`, `Match`, `WalkDir` with `SkipDir`, `Walk` with `SkipAll`, `Glob`, `Abs`, and `EvalSymlinks`.
    @Test func filepathWalksGlobsAndRelatesPaths() {
        let output = run(fp1Source)
        #expect(output.contains(fp1Expected))
    }
}

private let path1Source = #"""
package main

import (
	"fmt"
	"path"
)

func main() {
	for _, p := range []string{"", ".", "a/b/../c", "/../x", "//a//b/./c/", "../../a", "a/..", "/", "abc/def/", "x.tar.gz", "/a/b.c/d"} {
		dir, file := path.Split(p)
		fmt.Printf("%q clean=%q base=%q dir=%q ext=%q abs=%v split=%q,%q\n", p, path.Clean(p), path.Base(p), path.Dir(p), path.Ext(p), path.IsAbs(p), dir, file)
	}
	fmt.Println(path.Join("a", "", "b/", "../c"), path.Join(), path.Join("", ""), path.Join("/", "x"))
	for _, c := range [][2]string{{"*.go", "main.go"}, {"a/*/c", "a/b/c"}, {"a/*", "a/b/c"}, {"[a-c]x", "bx"}, {"[^a-c]x", "bx"}, {"\\*", "*"}, {"a?c", "abc"}, {"[", "a"}, {"[a-", "a"}, {"*", ""}, {"[]a]", "]"}, {"x[\\]]", "x]"}} {
		m, err := path.Match(c[0], c[1])
		fmt.Println(c[0], c[1], m, err)
	}
	fmt.Println(path.ErrBadPattern)
}
"""#

private let path1Expected = #"""
"" clean="." base="." dir="." ext="" abs=false split="",""
"." clean="." base="." dir="." ext="." abs=false split="","."
"a/b/../c" clean="a/c" base="c" dir="a" ext="" abs=false split="a/b/../","c"
"/../x" clean="/x" base="x" dir="/" ext="" abs=true split="/../","x"
"//a//b/./c/" clean="/a/b/c" base="c" dir="/a/b/c" ext="" abs=true split="//a//b/./c/",""
"../../a" clean="../../a" base="a" dir="../.." ext="" abs=false split="../../","a"
"a/.." clean="." base=".." dir="a" ext="." abs=false split="a/",".."
"/" clean="/" base="/" dir="/" ext="" abs=true split="/",""
"abc/def/" clean="abc/def" base="def" dir="abc/def" ext="" abs=false split="abc/def/",""
"x.tar.gz" clean="x.tar.gz" base="x.tar.gz" dir="." ext=".gz" abs=false split="","x.tar.gz"
"/a/b.c/d" clean="/a/b.c/d" base="d" dir="/a/b.c" ext="" abs=true split="/a/b.c/","d"
a/c   /x
*.go main.go true <nil>
a/*/c a/b/c true <nil>
a/* a/b/c false <nil>
[a-c]x bx true <nil>
[^a-c]x bx false <nil>
\* * true <nil>
a?c abc true <nil>
[ a false syntax error in pattern
[a- a false syntax error in pattern
*  true <nil>
[]a] ] false syntax error in pattern
x[\]] x] true <nil>
syntax error in pattern

"""#

private let fs1Source = #"""
package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"sort"
	"strings"
)

func show(info fs.FileInfo, err error) {
	if err != nil {
		fmt.Println("err:", err)
		return
	}
	size := info.Size()
	if info.IsDir() || info.Mode()&fs.ModeSymlink != 0 {
		size = -1 // directory and link sizes are the system's
	}
	mode := info.Mode().String()
	if info.Mode()&fs.ModeSymlink != 0 {
		mode = info.Mode().Type().String()
	}
	fmt.Println(info.Name(), size, mode, info.IsDir(), info.Mode().IsRegular())
}

func main() {
	fmt.Println(os.MkdirAll("work/a/b/c", 0o755))
	fmt.Println(os.MkdirAll("work/a/b", 0o755))
	fmt.Println(os.WriteFile("work/a/one.txt", []byte("hello"), 0o644))
	fmt.Println(os.WriteFile("work/a/b/two.txt", []byte("hi there"), 0o600))
	fmt.Println(os.MkdirAll("work/a/one.txt/x", 0o755))
	show(os.Stat("work/a/one.txt"))
	show(os.Stat("work/a/b"))
	show(os.Stat("work/nope"))
	show(os.Stat("work/a/one.txt/sub"))
	show(os.Lstat("work/a/b/two.txt"))
	fmt.Println(os.Symlink("one.txt", "work/a/link"))
	show(os.Lstat("work/a/link"))
	show(os.Stat("work/a/link"))
	fmt.Println(os.Readlink("work/a/link"))
	_, err := os.Readlink("work/a/one.txt")
	fmt.Println(err)

	entries, err := os.ReadDir("work/a")
	fmt.Println(len(entries), err)
	for _, e := range entries {
		info, _ := e.Info()
		fmt.Println(e.Name(), e.IsDir(), e.Type(), info.Mode().IsRegular(), e)
	}
	_, err = os.ReadDir("work/missing")
	fmt.Println(err, errors.Is(err, fs.ErrNotExist))

	f, err := os.Open("work/a/one.txt")
	fmt.Println(err, f.Name())
	st, err := f.Stat()
	fmt.Println(st.Name(), st.Size(), err)
	f.Close()

	d, err := os.Open("work/a")
	fmt.Println(err, d.Name())
	names, err := d.Readdirnames(-1)
	sort.Strings(names)
	fmt.Println(names, err)
	names, err = d.Readdirnames(10)
	fmt.Println(names, err == io.EOF)
	d.Close()
	d, _ = os.Open("work/a/b")
	infos, err := d.Readdir(-1)
	sort.Slice(infos, func(i, j int) bool { return infos[i].Name() < infos[j].Name() })
	for _, i := range infos {
		fmt.Println("readdir", i.Name(), i.IsDir())
	}
	d.Close()

	fmt.Println(os.Chmod("work/a/one.txt", 0o600))
	show(os.Stat("work/a/one.txt"))
	fmt.Println(os.Chmod("work/zzz", 0o600))

	wd, _ := os.Getwd()
	fmt.Println(os.Chdir("work/a"))
	nwd, _ := os.Getwd()
	fmt.Println(strings.TrimPrefix(nwd, wd))
	show(os.Stat("b/two.txt"))
	fmt.Println(os.Chdir("missing"))
	fmt.Println(os.Chdir(wd))

	fmt.Println(fs.ModeDir|0o755, fs.FileMode(0o644), os.ModeSymlink|os.ModePerm, os.ModePerm)
	fmt.Println(os.RemoveAll("work/a/b"))
	show(os.Stat("work/a/b"))
	fmt.Println(os.RemoveAll("work"), os.RemoveAll("work"))
	fmt.Println(os.RemoveAll("."))
	_, err = os.Stat("work")
	fmt.Println(os.IsNotExist(err))
}
"""#

private let fs1Expected = #"""
<nil>
<nil>
<nil>
<nil>
mkdir work/a/one.txt: not a directory
one.txt 5 -rw-r--r-- false true
b -1 drwxr-xr-x true false
err: stat work/nope: no such file or directory
err: stat work/a/one.txt/sub: not a directory
two.txt 8 -rw------- false true
<nil>
link -1 L--------- false false
link 5 -rw-r--r-- false true
one.txt <nil>
readlink work/a/one.txt: invalid argument
3 <nil>
b true d--------- false d b/
link false L--------- false L link
one.txt false ---------- true - one.txt
open work/missing: no such file or directory true
<nil> work/a/one.txt
one.txt 5 <nil>
<nil> work/a
[b link one.txt] <nil>
[] true
readdir c true
readdir two.txt false
<nil>
one.txt 5 -rw------- false true
chmod work/zzz: no such file or directory
<nil>
/work/a
two.txt 8 -rw------- false true
chdir missing: no such file or directory
<nil>
drwxr-xr-x -rw-r--r-- Lrwxrwxrwx -rwxrwxrwx
<nil>
err: stat work/a/b: no such file or directory
<nil> <nil>
RemoveAll .: invalid argument
true

"""#

private let fp1Source = #"""
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	for _, p := range []string{"", ".", "a//b/../c/", "/x/../../y", "dir/file.tar.gz", "/", "../a"} {
		dir, file := filepath.Split(p)
		fmt.Printf("%q %q %q %q %q %v %q %q %v\n", p, filepath.Clean(p), filepath.Base(p), filepath.Dir(p), filepath.Ext(p), filepath.IsAbs(p), dir, file, filepath.IsLocal(p))
	}
	fmt.Println(filepath.Join("a", "b/../c", "", "d"), filepath.Join(), filepath.ToSlash("a/b"), filepath.FromSlash("a/b"), filepath.VolumeName("/x"))
	fmt.Println(filepath.SplitList("/bin:/usr/bin::/x"), len(filepath.SplitList("")), string(filepath.Separator), string(filepath.ListSeparator))
	for _, c := range [][2]string{{"/a/b", "/a/b/c/d"}, {"/a/b/c", "/a/x"}, {"a", "/b"}, {"a/b", "a/b"}, {"../a", "b"}, {"/", "/x/y"}} {
		r, err := filepath.Rel(c[0], c[1])
		fmt.Printf("rel %q %q -> %q %v\n", c[0], c[1], r, err)
	}
	m, err := filepath.Match("*.go", "x.go")
	fmt.Println(m, err)
	_, err = filepath.Match("[", "x")
	fmt.Println(err == filepath.ErrBadPattern)

	os.MkdirAll("tree/a/b", 0o755)
	os.MkdirAll("tree/c", 0o755)
	os.WriteFile("tree/a/one.go", []byte("x"), 0o644)
	os.WriteFile("tree/a/b/two.go", []byte("x"), 0o644)
	os.WriteFile("tree/a/b/three.txt", []byte("x"), 0o644)
	os.WriteFile("tree/top.md", []byte("x"), 0o644)

	err = filepath.WalkDir("tree", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && d.Name() == "c" {
			return filepath.SkipDir
		}
		fmt.Println("walkdir", path, d.IsDir())
		return nil
	})
	fmt.Println(err)
	err = filepath.Walk("tree", func(path string, info fs.FileInfo, err error) error {
		if strings.HasSuffix(path, ".txt") {
			return filepath.SkipAll
		}
		fmt.Println("walk", path, info.Name(), info.IsDir())
		return nil
	})
	fmt.Println(err)
	err = filepath.WalkDir("tree/missing", func(path string, d fs.DirEntry, err error) error {
		fmt.Println("callback", path, d == nil, err)
		return err
	})
	fmt.Println(err, errors.Is(err, fs.ErrNotExist))
	matches, err := filepath.Glob("tree/a/*.go")
	fmt.Println(matches, err)
	matches, err = filepath.Glob("tree/*/*/t*")
	fmt.Println(matches, err)
	matches, err = filepath.Glob("tree/[")
	fmt.Println(matches, err)
	abs, err := filepath.Abs("tree/a")
	wd, _ := os.Getwd()
	fmt.Println(strings.TrimPrefix(abs, wd), err)
	os.Symlink("a", "tree/link")
	ev, err := filepath.EvalSymlinks("tree/link/one.go")
	fmt.Println(ev, err)
	_, err = filepath.EvalSymlinks("tree/nope")
	fmt.Println(err)
	os.RemoveAll("tree")
}
"""#

private let fp1Expected = #"""
"" "." "." "." "" false "" "" false
"." "." "." "." "." false "" "." true
"a//b/../c/" "a/c" "c" "a/c" "" false "a//b/../c/" "" true
"/x/../../y" "/y" "y" "/" "" true "/x/../../" "y" false
"dir/file.tar.gz" "dir/file.tar.gz" "file.tar.gz" "dir" ".gz" false "dir/" "file.tar.gz" true
"/" "/" "/" "/" "" true "/" "" false
"../a" "../a" "a" ".." "" false "../" "a" false
a/c/d  a/b a/b\#u{20}
[/bin /usr/bin  /x] 0 / :
rel "/a/b" "/a/b/c/d" -> "c/d" <nil>
rel "/a/b/c" "/a/x" -> "../../x" <nil>
rel "a" "/b" -> "" Rel: can't make /b relative to a
rel "a/b" "a/b" -> "." <nil>
rel "../a" "b" -> "" Rel: can't make b relative to ../a
rel "/" "/x/y" -> "x/y" <nil>
true <nil>
true
walkdir tree true
walkdir tree/a true
walkdir tree/a/b true
walkdir tree/a/b/three.txt false
walkdir tree/a/b/two.go false
walkdir tree/a/one.go false
walkdir tree/top.md false
<nil>
walk tree tree true
walk tree/a a true
walk tree/a/b b true
<nil>
callback tree/missing true lstat tree/missing: no such file or directory
lstat tree/missing: no such file or directory true
[tree/a/one.go] <nil>
[tree/a/b/three.txt tree/a/b/two.go] <nil>
[] syntax error in pattern
/tree/a <nil>
tree/a/one.go <nil>
lstat tree/nope: no such file or directory

"""#
