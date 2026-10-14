/// `encoding/binary`, `hash`, `hash/crc32`, `hash/fnv`, `math/bits`, and
/// `io`, as a server reads and writes a protocol and checks what it stored.
///
/// What each program prints is what Go 1.24.5 printed for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go binary encodings, hashes, and io")
struct GoBinaryHashTests {
    private func run(_ source: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        var output = ""
        try GoVirtualMachine(maximumInstructions: 50_000_000).run(executable) { output += $0 }
        return output
    }

    /// `encoding/binary`: the byte orders, `Read`, `Write`, `Size`, `Append`, `Encode`, and `Decode` of fixed-size values and slices of them, varints, and Go's errors for what it refuses.
    @Test func binaryOrdersVarintsAndFixedSizeValuesAreGos() throws {
        #expect(try run(binarySource) == binaryExpected)
    }

    /// `hash/crc32` with the IEEE, Castagnoli, and Koopman tables, its state marshalled and restored, the six `hash/fnv` hashes, and `math/bits`, whose division by zero and overflow panic as Go's do.
    @Test func checksumsAndBitsAreGos() throws {
        #expect(try run(hashesSource) == hashesExpected)
    }

    /// `io`, Go's text: `Copy` and `CopyN` give an `int64`, `LimitReader`, `SectionReader`, `TeeReader`, `MultiReader`, `MultiWriter`, `Pipe`, `OffsetWriter`, the byte and rune interfaces, and the errors.
    @Test func ioHasGosReadersWritersAndPipe() throws {
        #expect(try run(ioSource) == ioExpected)
    }
}

private let binarySource = #"""
package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
)

type header struct {
	Magic uint32
	Len   uint16
}

func main() {
	b := make([]byte, 8)
	binary.BigEndian.PutUint32(b, 0xCAFEBABE)
	binary.LittleEndian.PutUint16(b[4:], 0x1234)
	fmt.Printf("%x %x %x %d\n", b, binary.BigEndian.Uint32(b), binary.LittleEndian.Uint16(b[4:]), binary.BigEndian.Uint64(b))
	fmt.Println(binary.BigEndian, binary.LittleEndian, binary.NativeEndian.Uint16([]byte{1, 0}))
	fmt.Printf("%#v %v\n", binary.BigEndian, binary.BigEndian.AppendUint64(nil, 1))

	var buf bytes.Buffer
	fmt.Println(binary.Write(&buf, binary.BigEndian, uint32(7)))
	fmt.Println(binary.Write(&buf, binary.LittleEndian, []int16{-1, 2}))
	fmt.Println(binary.Write(&buf, binary.BigEndian, math.Pi))
	fmt.Println(binary.Write(&buf, binary.BigEndian, true))
	fmt.Printf("%x\n", buf.Bytes())
	var n uint32
	var pair [2]int16
	var f float64
	var flag bool
	fmt.Println(binary.Read(&buf, binary.BigEndian, &n), n)
	fmt.Println(binary.Read(&buf, binary.LittleEndian, pair[:]), pair)
	fmt.Println(binary.Read(&buf, binary.BigEndian, &f), f)
	fmt.Println(binary.Read(&buf, binary.BigEndian, &flag), flag)
	err := binary.Read(&buf, binary.BigEndian, &n)
	fmt.Println(err, err == io.EOF)
	err = binary.Read(bytes.NewReader([]byte{1, 2}), binary.BigEndian, &n)
	fmt.Println(err, errors.Is(err, io.ErrUnexpectedEOF))
	fmt.Println(binary.Size(uint16(0)), binary.Size([]uint64{1, 2}), binary.Size("x"))
	fmt.Println(binary.Write(&buf, binary.BigEndian, "text"))
	fmt.Println(binary.Read(&buf, binary.BigEndian, new(string)))

	vb := binary.AppendUvarint(nil, 300)
	vb = binary.AppendVarint(vb, -129)
	x, k := binary.Uvarint(vb)
	y, k2 := binary.Varint(vb[k:])
	fmt.Println(vb, x, k, y, k2, binary.PutUvarint(make([]byte, binary.MaxVarintLen64), math.MaxUint64))
	r := bytes.NewReader([]byte{0xac, 0x02, 0x80})
	v1, e1 := binary.ReadUvarint(r)
	v2, e2 := binary.ReadUvarint(r)
	fmt.Println(v1, e1, v2, e2)
	_, bad := binary.Uvarint([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01})
	fmt.Println(bad)
	out, err := binary.Append(nil, binary.BigEndian, []uint16{1, 2})
	fmt.Println(out, err)
	m, err := binary.Encode(make([]byte, 3), binary.BigEndian, uint32(1))
	fmt.Println(m, err)
	m, err = binary.Decode([]byte{0, 0, 1, 0}, binary.BigEndian, &n)
	fmt.Println(m, err, n)
}
"""#

private let binaryExpected = #"""
cafebabe34120000 cafebabe 1234 14627333965826097152
BigEndian LittleEndian 1
binary.BigEndian [0 0 0 0 0 0 0 1]
<nil>
<nil>
<nil>
<nil>
00000007ffff0200400921fb54442d1801
<nil> 7
<nil> [-1 2]
<nil> 3.141592653589793
<nil> true
EOF true
unexpected EOF true
2 16 -1
binary.Write: some values are not fixed-sized in type string
binary.Read: invalid type *string
[172 2 129 2] 300 2 -129 2 10
300 <nil> 0 unexpected EOF
-11
[0 1 0 2] <nil>
0 buffer too small
4 <nil> 256

"""#

private let hashesSource = #"""
package main

import (
	"encoding"
	"fmt"
	"hash"
	"hash/crc32"
	"hash/fnv"
	"math/bits"
)

func main() {
	data := []byte("The quick brown fox jumps over the lazy dog")
	fmt.Println(crc32.ChecksumIEEE(data), crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli)), crc32.Checksum(data, crc32.MakeTable(crc32.Koopman)))
	h := crc32.NewIEEE()
	h.Write(data[:10])
	h.Write(data[10:])
	fmt.Printf("%x %d %d %x\n", h.Sum(nil), h.Size(), h.BlockSize(), h.Sum32())
	fmt.Println(crc32.Update(0, crc32.IEEETable, data), crc32.Update(crc32.Checksum(data[:5], crc32.IEEETable), crc32.IEEETable, data[5:]))
	big := make([]byte, 5000)
	for i := range big {
		big[i] = byte(i * 31)
	}
	fmt.Println(crc32.ChecksumIEEE(big), crc32.Checksum(big, crc32.MakeTable(crc32.Castagnoli)))
	state, err := h.(encoding.BinaryMarshaler).MarshalBinary()
	fmt.Printf("%x %v\n", state, err)
	h2 := crc32.NewIEEE()
	fmt.Println(h2.(encoding.BinaryUnmarshaler).UnmarshalBinary(state), h2.Sum32() == h.Sum32())

	var hashes = []hash.Hash{fnv.New32(), fnv.New32a(), fnv.New64(), fnv.New64a(), fnv.New128(), fnv.New128a()}
	for _, f := range hashes {
		f.Write(data)
		fmt.Printf("%x %d\n", f.Sum([]byte{0xAA}), f.Size())
	}
	f64 := fnv.New64a()
	f64.Write([]byte("key"))
	fmt.Println(f64.Sum64(), f64.Sum64()%16)

	fmt.Println(bits.OnesCount64(0xF0F0), bits.LeadingZeros32(1), bits.TrailingZeros64(8), bits.Len(255), bits.Reverse8(1), bits.ReverseBytes32(0x01020304))
	fmt.Println(bits.RotateLeft64(1, -1), bits.RotateLeft32(0x80000000, 1), bits.UintSize)
	hi, lo := bits.Mul64(0xFFFFFFFFFFFFFFFF, 3)
	sum, carry := bits.Add64(0xFFFFFFFFFFFFFFFF, 1, 0)
	diff, borrow := bits.Sub64(0, 1, 0)
	q, r := bits.Div64(1, 0, 3)
	fmt.Println(hi, lo, sum, carry, diff, borrow, q, r, bits.Rem64(5, 7, 3))
	defer func() { fmt.Println("recovered:", recover()) }()
	bits.Div64(5, 1, 3)
}
"""#

private let hashesExpected = #"""
1095738169 576848900 3760315280
414fa339 4 1 414fa339
1095738169 1095738169
2615396959 3179420599
63726301ca87914d414fa339 <nil>
<nil> true
aae9c86c6e 4
aa048fff90 4
aaa8b2f3117de37ace 8
aaf3f9b7f5e7e47110 8
aa185adb693e7c97844ecfa9497cb529b6 16
aa68cce4cd885ea04239f02af30e297870 16
4452171178779021548 12
8 31 3 8 128 67305985
9223372036854775808 1 64
2 18446744073709551613 0 1 18446744073709551615 1 6148914691236517205 1 0
recovered: runtime error: integer overflow

"""#

private let ioSource = #"""
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
)

type upper struct{ w io.Writer }

func (u upper) Write(p []byte) (int, error) {
	return u.w.Write(bytes.ToUpper(p))
}

func main() {
	var buf bytes.Buffer
	n, err := io.Copy(&buf, strings.NewReader("hello world"))
	fmt.Printf("%d %T %v %q\n", n, n, err, buf.String())
	n, err = io.CopyN(io.Discard, strings.NewReader("abc"), 5)
	fmt.Println(n, err)
	lr := io.LimitReader(strings.NewReader("0123456789"), 4)
	b, _ := io.ReadAll(lr)
	fmt.Println(string(b))
	sr := io.NewSectionReader(strings.NewReader("0123456789"), 2, 5)
	p := make([]byte, 3)
	k, _ := sr.ReadAt(p, 1)
	pos, _ := sr.Seek(-2, io.SeekEnd)
	rest, _ := io.ReadAll(sr)
	fmt.Println(k, string(p), pos, string(rest), sr.Size())
	var tee bytes.Buffer
	tr := io.TeeReader(strings.NewReader("tee"), &tee)
	io.ReadAll(tr)
	fmt.Println(tee.String())
	mr := io.MultiReader(strings.NewReader("a"), strings.NewReader("b"), strings.NewReader("c"))
	all, _ := io.ReadAll(mr)
	var w1, w2 bytes.Buffer
	mw := io.MultiWriter(&w1, upper{&w2})
	io.WriteString(mw, "mix")
	fmt.Println(string(all), w1.String(), w2.String())
	pr, pw := io.Pipe()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		fmt.Fprint(pw, "through the pipe")
		pw.CloseWithError(errors.New("done writing"))
	}()
	got, err := io.ReadAll(pr)
	wg.Wait()
	fmt.Println(string(got), err)
	_, err = pw.Write([]byte("x"))
	fmt.Println(err, err == io.ErrClosedPipe)
	r := strings.NewReader("xy")
	var br io.ByteReader = r
	c, _ := br.ReadByte()
	var rs io.RuneScanner = r
	rr, size, _ := rs.ReadRune()
	fmt.Println(c, rr, size)
	ow := io.NewOffsetWriter(&fixed{b: make([]byte, 6)}, 2)
	ow.Write([]byte("ab"))
	fmt.Println(io.ErrUnexpectedEOF, io.ErrShortBuffer, io.ErrNoProgress, io.ErrShortWrite)
	_, err = io.ReadAtLeast(strings.NewReader("ab"), make([]byte, 4), 3)
	fmt.Println(err)
	rc := io.NopCloser(strings.NewReader("z"))
	fmt.Println(rc.Close())
}

type fixed struct{ b []byte }

func (f *fixed) WriteAt(p []byte, off int64) (int, error) {
	copy(f.b[off:], p)
	fmt.Printf("writeat %d %q\n", off, p)
	return len(p), nil
}
"""#

private let ioExpected = #"""
11 int64 <nil> "hello world"
3 EOF
0123
3 345 3 56 5
tee
abc mix MIX
through the pipe done writing
io: read/write on closed pipe true
120 121 1
writeat 2 "ab"
unexpected EOF short buffer multiple Read calls return no data or error short write
unexpected EOF
<nil>

"""#
