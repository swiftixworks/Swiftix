package os

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"time"
)

// The metadata of the file system are read by natives of the run-time
// library: the size, Go's FileMode, and the modification time of a node,
// and the names and types of a directory's entries. These types and
// functions are Go's around them.

// A FileInfo describes a file and is returned by [Stat] and [Lstat].
type FileInfo = fs.FileInfo

// A FileMode represents a file's mode and permission bits.
type FileMode = fs.FileMode

// A DirEntry is an entry read from a directory
// (using the [ReadDir] function or a [File.ReadDir] method).
type DirEntry = fs.DirEntry

// The defined file mode bits are the most significant bits of the [FileMode].
const (
	// The single letters are the abbreviations
	// used by the String method's formatting.
	ModeDir        = fs.ModeDir        // d: is a directory
	ModeAppend     = fs.ModeAppend     // a: append-only
	ModeExclusive  = fs.ModeExclusive  // l: exclusive use
	ModeTemporary  = fs.ModeTemporary  // T: temporary file; Plan 9 only
	ModeSymlink    = fs.ModeSymlink    // L: symbolic link
	ModeDevice     = fs.ModeDevice     // D: device file
	ModeNamedPipe  = fs.ModeNamedPipe  // p: named pipe (FIFO)
	ModeSocket     = fs.ModeSocket     // S: Unix domain socket
	ModeSetuid     = fs.ModeSetuid     // u: setuid
	ModeSetgid     = fs.ModeSetgid     // g: setgid
	ModeCharDevice = fs.ModeCharDevice // c: Unix character device, when ModeDevice is set
	ModeSticky     = fs.ModeSticky     // t: sticky
	ModeIrregular  = fs.ModeIrregular  // ?: non-regular file; nothing else is known about this file

	// Mask for the type bits. For regular files, none will be set.
	ModeType = fs.ModeType

	ModePerm = fs.ModePerm // Unix permission bits, 0o777
)

const (
	PathSeparator     = '/' // OS-specific path separator
	PathListSeparator = ':' // OS-specific path list separator
)

// IsPathSeparator reports whether c is a directory separator character.
func IsPathSeparator(c uint8) bool {
	return PathSeparator == c
}

// fileStat is what Stat and Lstat find of a node.
type fileStat struct {
	name    string
	size    int64
	mode    FileMode
	modTime time.Time
}

func (fs *fileStat) Name() string       { return fs.name }
func (fs *fileStat) IsDir() bool        { return fs.Mode().IsDir() }
func (fs *fileStat) Size() int64        { return fs.size }
func (fs *fileStat) Mode() FileMode     { return fs.mode }
func (fs *fileStat) ModTime() time.Time { return fs.modTime }

// Sys has nothing for this library: Go gives a *syscall.Stat_t.
func (fs *fileStat) Sys() any { return nil }

// basename removes trailing slashes and the leading directory name from path name.
func basename(name string) string {
	i := len(name) - 1
	// Remove trailing slashes
	for ; i > 0 && name[i] == '/'; i-- {
		name = name[:i]
	}
	// Remove leading directory name
	for i--; i >= 0; i-- {
		if name[i] == '/' {
			name = name[i+1:]
			break
		}
	}
	return name
}

func stat(name string, follow bool) (FileInfo, error) {
	size, mode, mtime, err := native.stat(name, follow)
	if err != nil {
		return nil, pathError(name, err)
	}
	return &fileStat{name: basename(name), size: int64(size), mode: FileMode(mode), modTime: time.Unix(0, int64(mtime))}, nil
}

// Stat returns a [FileInfo] describing the named file.
// If there is an error, it will be of type [*PathError].
func Stat(name string) (FileInfo, error) {
	return stat(name, true)
}

// Lstat returns a [FileInfo] describing the named file.
// If the file is a symbolic link, the returned FileInfo
// describes the symbolic link. Lstat makes no attempt to follow the link.
// If there is an error, it will be of type [*PathError].
func Lstat(name string) (FileInfo, error) {
	return stat(name, false)
}

// unixDirent is an entry of a directory.
type unixDirent struct {
	parent string
	name   string
	typ    FileMode
}

func (d *unixDirent) Name() string   { return d.name }
func (d *unixDirent) IsDir() bool    { return d.typ.IsDir() }
func (d *unixDirent) Type() FileMode { return d.typ }

func (d *unixDirent) Info() (FileInfo, error) {
	return Lstat(d.parent + "/" + d.name)
}

func (d *unixDirent) String() string {
	return fs.FormatDirEntry(d)
}

// readDir is the entries of the directory name, in the order of their names.
func readDir(name string) ([]DirEntry, error) {
	names, modes, err := native.readdir(name)
	if err != nil {
		return nil, pathError(name, err)
	}
	dirs := make([]DirEntry, len(names))
	for i := range names {
		dirs[i] = &unixDirent{parent: name, name: names[i], typ: FileMode(modes[i]).Type()}
	}
	return dirs, nil
}

// ReadDir reads the named directory,
// returning all its directory entries sorted by filename.
// If an error occurs reading the directory,
// ReadDir returns the entries it was able to read before the error,
// along with the error.
func ReadDir(name string) ([]DirEntry, error) {
	dirs, err := readDir(name)
	if dirs == nil {
		dirs = []DirEntry{}
	}
	return dirs, err
}

// Chmod changes the mode of the named file to mode.
// If the file is a symbolic link, it changes the mode of the link's target.
// If there is an error, it will be of type [*PathError].
func Chmod(name string, mode FileMode) error {
	return pathError(name, native.chmod(name, int(syscallMode(mode))))
}

// syscallMode returns the syscall-specific mode bits from Go's portable mode bits.
func syscallMode(i FileMode) (o uint32) {
	o |= uint32(i.Perm())
	if i&ModeSetuid != 0 {
		o |= 0o4000
	}
	if i&ModeSetgid != 0 {
		o |= 0o2000
	}
	if i&ModeSticky != 0 {
		o |= 0o1000
	}
	return
}

// Chdir changes the current working directory to the named directory.
// If there is an error, it will be of type [*PathError].
func Chdir(dir string) error {
	return pathError(dir, native.chdir(dir))
}

// Symlink creates newname as a symbolic link to oldname.
// If there is an error, it will be of type [*LinkError].
func Symlink(oldname, newname string) error {
	failure := native.symlink(oldname, newname)
	if failure == nil {
		return nil
	}
	return &LinkError{Op: "symlink", Old: oldname, New: newname, Err: linkErrno(failure, "symlink "+oldname+" "+newname+": ")}
}

// Readlink returns the destination of the named symbolic link.
// If there is an error, it will be of type [*PathError].
func Readlink(name string) (string, error) {
	target, err := native.readlink(name)
	return target, pathError(name, err)
}

func linkErrno(failure error, prefix string) error {
	text := failure.Error()
	if len(text) > len(prefix) && text[:len(prefix)] == prefix {
		return errno(text[len(prefix):])
	}
	return failure
}

// The methods of *File that are Go: the compiler calls these for
// f.Stat(), f.ReadDir(n), f.Readdir(n), and f.Readdirnames(n).

// dirOffsets is how far ReadDir and the like have read each directory.
var dirOffsets = map[*os.File]int{}

func fileMethodStat(f *os.File) (FileInfo, error) {
	if f == nil {
		return nil, ErrInvalid
	}
	return Stat(f.Name())
}

// fileMethodReadDir is f.ReadDir(n): the entries in directory order, all of them
// when n <= 0, else at most n, with io.EOF at the end.
func fileMethodReadDir(f *os.File, n int) ([]DirEntry, error) {
	if f == nil {
		return nil, ErrInvalid
	}
	all, err := readDir(f.Name())
	if err != nil {
		if pe, ok := err.(*PathError); ok && pe.Op == "open" {
			pe.Op = "readdirent"
		}
		return []DirEntry{}, err
	}
	start := dirOffsets[f]
	if start > len(all) {
		start = len(all)
	}
	rest := all[start:]
	if n <= 0 {
		dirOffsets[f] = len(all)
		return rest, nil
	}
	if len(rest) == 0 {
		return []DirEntry{}, io.EOF
	}
	if n > len(rest) {
		n = len(rest)
	}
	dirOffsets[f] = start + n
	return rest[:n], nil
}

func fileMethodReaddirnames(f *os.File, n int) ([]string, error) {
	entries, err := fileMethodReadDir(f, n)
	names := make([]string, len(entries))
	for i, e := range entries {
		names[i] = e.Name()
	}
	return names, err
}

func fileMethodReaddir(f *os.File, n int) ([]FileInfo, error) {
	entries, err := fileMethodReadDir(f, n)
	infos := make([]FileInfo, 0, len(entries))
	for _, e := range entries {
		info, ierr := e.Info()
		if ierr != nil {
			if errors.Is(ierr, ErrNotExist) {
				continue
			}
			return infos, ierr
		}
		infos = append(infos, info)
	}
	return infos, err
}
