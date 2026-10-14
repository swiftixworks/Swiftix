/// `math/rand`, and the functions of `math` it needs, as Go has them.
///
/// What each program prints is what Go 1.24.5 printed for it on arm64.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go math/rand and math")
struct GoMathRandTests {
    private func run(_ source: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
        var output = ""
        try GoVirtualMachine(maximumInstructions: 50_000_000).run(executable) { output += $0 }
        return output
    }

    /// A generator made from a seed draws what Go's draws from it: `Int63`, `Intn`, `Float64`, `Perm`, `Shuffle`, `NormFloat64`, `ExpFloat64`, `Read`, `Seed`, and `Zipf`. The top-level functions draw from the run-time library's random numbers, as Go's from the runtime's, and `Seed` is a no-op, as in Go 1.24.
    @Test func seededGeneratorsDrawGosSequences() throws {
        #expect(try run(randSource) == randExpected)
    }

    /// `math.Log` and `math.Exp` give Go's bits on arm64 for hundreds of inputs and the special cases: Go's `log` with the multiplications its compiler fuses, and its assembly `Exp`.
    @Test func logAndExpAreGosBitForBit() throws {
        #expect(try run(logexpSource) == logexpExpected)
    }

    /// `math.NaN` is Go's NaN, whose bits differ from the NaN an operation makes.
    @Test func nanIsGosNaN() throws {
        #expect(try run(nanSource) == nanExpected)
    }
}

private let randSource = #"""
package main

import (
	"fmt"
	"math/rand"
)

func main() {
	r := rand.New(rand.NewSource(42))
	fmt.Println(r.Int63(), r.Int31(), r.Uint32(), r.Uint64(), r.Int())
	fmt.Println(r.Intn(100), r.Int63n(1000000007), r.Int31n(10), r.Float64(), r.Float32())
	fmt.Println(r.Perm(10))
	s := []string{"a", "b", "c", "d", "e", "f"}
	r.Shuffle(len(s), func(i, j int) { s[i], s[j] = s[j], s[i] })
	fmt.Println(s)
	fmt.Printf("%.6f %.6f\n", r.NormFloat64(), r.ExpFloat64())
	buf := make([]byte, 7)
	n, err := r.Read(buf)
	fmt.Println(n, err, buf)
	r.Seed(7)
	fmt.Println(r.Intn(1000), r.Intn(1000))
	z := rand.NewZipf(rand.New(rand.NewSource(1)), 1.5, 2, 100)
	fmt.Println(z.Uint64(), z.Uint64(), z.Uint64())
	total := 0
	for i := 0; i < 1000; i++ {
		v := rand.Intn(10)
		if v < 0 || v >= 10 {
			fmt.Println("bad")
		}
		total += v
	}
	fmt.Println(total > 3000 && total < 6000)
	rand.Seed(1)
	f := rand.Float64()
	fmt.Println(f >= 0 && f < 1, len(rand.Perm(5)))
	defer func() { fmt.Println(recover()) }()
	r.Intn(0)
}
"""#

private let randExpected = #"""
3440579354231278675 141734987 2594563336 1926012586526624009 404153945743547657
45 401235903 6 0.3830446530497163 0.6463764
[3 7 4 6 9 2 5 1 8 0]
[c d f e b a]
0.162477 2.269889
7 <nil> [28 28 112 113 231 150 162]
886 870
2 0 1
true
true 5
invalid argument to Intn

"""#

private let logexpSource = #"""
package main

import (
	"fmt"
	"math"
)

func main() {
	// A deterministic spread of inputs: tiny, near 1, large, negative,
	// subnormal, and the edges of Exp's range.
	seed := uint64(88172645463325252)
	next := func() uint64 {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
		return seed
	}
	logBad, expBad := 0, 0
	sumL, sumE := uint64(0), uint64(0)
	for i := 0; i < 400; i++ {
		b := next()
		x := math.Float64frombits(b &^ (1 << 63))
		if math.IsNaN(x) {
			continue
		}
		sumL = sumL*31 + math.Float64bits(math.Log(x))
		e := float64(int64(b%2000000)-1000000) / 1000
		sumE = sumE*31 + math.Float64bits(math.Exp(e))
		y := 1 + float64(int64(b%20001)-10000)/1e9
		sumL = sumL*31 + math.Float64bits(math.Log(y))
		z := float64(int64(b%1500)) - 750
		sumE = sumE*31 + math.Float64bits(math.Exp(z+0.123456789))
	}
	fmt.Println(sumL, sumE, logBad, expBad)
	for _, v := range []float64{0, -1, 1, 2, 0.5, 1e-300, 5e-324, math.Inf(1), math.NaN(), 709.78, 709.79, -745.13, -745.2, 1e-10, -1e-10} {
		fmt.Println(math.Float64bits(math.Log(v)), math.Float64bits(math.Exp(v)))
	}
}
"""#

private let logexpExpected = #"""
11897336128738073440 9474544964522773434 0 0
18442240474082181120 4607182418800017408
9221120237041090561 4600298746774613816
0 4613303445314885481
4604418534313441775 4620005356000828846
13827790571168217583 4610103999673009820
13872659378474614709 4607182418800017408
13873131416795836867 4607182418800017408
9218868437227405312 9218868437227405312
9221120237041090561 9221120237041090561
4619077500721092680 9218844034771735220
4619077516583641294 9218868437227405312
9221120237041090561 0
9221120237041090561 0
13850546455391152731 4607182418800467768
9221120237041090561 4607182418799116688

"""#

private let nanSource = #"""
package main

import (
	"fmt"
	"math"
)

func main() {
	z := 0.0
	fmt.Println(math.Float64bits(math.NaN()), math.Float64bits(z/z), math.Float64bits(math.Sqrt(-1)), math.Float64bits(math.Inf(1)-math.Inf(1)))
}
"""#

private let nanExpected = #"""
9221120237041090561 9221120237041090560 9221120237041090560 9221120237041090560

"""#
