// Literals for strconv.ParseFloat in families that reach every path of Go 1.27.1's atof (fast exact paths,
// unrounded scaling, the truncated-mantissa check and the 800-digit decimal fallback), with Go's answers: the
// fixture of ParityGoFloatTests, and streams for a larger differential run against GoFloat. Run with the server's
// Go 1.27.1 toolchain (GOTOOLCHAIN=local):
//
//	go run . fixture 9000 20261010 > Tests/NotTennaPodCoreTests/Fixtures/ParityGoFloatCases.jsonl
//	go run . stream N seed > cases.tsv      bitSize \t literal \t bits|error
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"math/rand/v2"
	"os"
	"strconv"
	"strings"
)

type spec struct {
	prefix, unit string
	count        int
	suffix       string
}

func (s spec) literal() string { return s.prefix + strings.Repeat(s.unit, s.count) + s.suffix }

func answer(lit string, bitSize int) string {
	f, err := strconv.ParseFloat(lit, bitSize)
	e := ""
	if err != nil {
		if errors.Is(err, strconv.ErrRange) {
			e = "range"
		} else {
			e = "syntax"
		}
	}
	if bitSize == 32 {
		return fmt.Sprintf("%08x|%s", math.Float32bits(float32(f)), e)
	}
	return fmt.Sprintf("%016x|%s", math.Float64bits(f), e)
}

func digits(r *rand.Rand, n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte('0' + r.IntN(10))
	}
	if n > 0 && r.IntN(3) > 0 {
		b[0] = byte('1' + r.IntN(9))
	}
	return string(b)
}

func sign(r *rand.Rand) string {
	switch r.IntN(6) {
	case 0:
		return "-"
	case 1:
		return "+"
	}
	return ""
}

// exactDecimal is the exact decimal expansion of x (a binary fraction), as digits and a decimal exponent:
// x = 0.digits × 10^exp... returned as an integer string and a power of ten: x = D × 10^p.
func exactDecimal(x *big.Rat) (string, int) {
	p := 0
	num := new(big.Int).Set(x.Num())
	den := new(big.Int).Set(x.Denom())
	ten := big.NewInt(10)
	for new(big.Int).Mod(num, den).Sign() != 0 {
		num.Mul(num, ten)
		p--
	}
	q := new(big.Int).Quo(num, den)
	return q.String(), p
}

// midpoint is the exact midpoint between two adjacent floats around a random value of the width, or a boundary.
func midpoint(r *rand.Rand, bitSize int) *big.Rat {
	var lo, hi *big.Rat
	if bitSize == 32 {
		var bits uint32
		switch r.IntN(5) {
		case 0:
			bits = uint32(r.IntN(8)) // subnormals near zero
		case 1:
			bits = 0x7f7fffff - uint32(r.IntN(4)) // near the largest
		case 2:
			bits = 0x007fffff + uint32(r.IntN(4)) - 2 // the subnormal/normal edge
		default:
			bits = r.Uint32() & 0x7f7fffff
		}
		a := float64(math.Float32frombits(bits))
		b := float64(math.Float32frombits(bits + 1))
		lo, hi = new(big.Rat).SetFloat64(a), new(big.Rat).SetFloat64(b)
		if math.IsInf(b, 0) {
			// The midpoint to 2^128.
			hi = new(big.Rat).SetInt(new(big.Int).Lsh(big.NewInt(1), 128))
		}
	} else {
		var bits uint64
		switch r.IntN(5) {
		case 0:
			bits = uint64(r.IntN(8))
		case 1:
			bits = 0x7fefffffffffffff - uint64(r.IntN(4))
		case 2:
			bits = 0x000fffffffffffff + uint64(r.IntN(4)) - 2
		default:
			bits = r.Uint64() & 0x7fefffffffffffff
		}
		a := math.Float64frombits(bits)
		b := math.Float64frombits(bits + 1)
		lo = new(big.Rat).SetFloat64(a)
		if math.IsInf(b, 0) {
			hi = new(big.Rat).SetInt(new(big.Int).Lsh(big.NewInt(1), 1024))
		} else {
			hi = new(big.Rat).SetFloat64(b)
		}
	}
	m := new(big.Rat).Add(lo, hi)
	return m.Quo(m, big.NewRat(2, 1))
}

func cases(r *rand.Rand, bitSize int) []spec {
	var out []spec
	s := sign(r)
	switch r.IntN(14) {
	case 0: // short decimals
		d := digits(r, 1+r.IntN(20))
		e := ""
		if r.IntN(2) == 0 {
			e = "e" + strconv.Itoa(r.IntN(700)-350)
		}
		if k := r.IntN(len(d) + 1); r.IntN(2) == 0 {
			d = d[:k] + "." + d[k:]
		}
		out = append(out, spec{s + d + e, "", 0, ""})
	case 1, 2: // midpoints, exact and nudged, with zeros after them and the point moved
		m := midpoint(r, bitSize)
		d, p := exactDecimal(m)
		zeros := []int{0, 1, 5, 88, 89, 700, 740, 760, 790, 799, 800, 801, 900}[r.IntN(13)]
		tail := []string{"", "1", "0001"}[r.IntN(3)]
		if tail != "" && r.IntN(2) == 0 {
			// just below: subtract from the last digit's place by writing the midpoint minus a unit far down
			tail = ""
			out = append(out, spec{s + d[:len(d)-1] + string(d[len(d)-1]-1) + "9", "9", zeros, "e" + strconv.Itoa(p-1-zeros)})
		}
		out = append(out, spec{s + d, "0", zeros, tail + "e" + strconv.Itoa(p-zeros-len(tail))})
		k := 1 + r.IntN(len(d))
		out = append(out, spec{s + d[:k] + "." + d[k:], "0", zeros, "e" + strconv.Itoa(p+len(d)-k)})
	case 3: // around 800 significant digits before the point, with and without a point after
		n := 780 + r.IntN(40)
		lead := digits(r, 20)
		out = append(out, spec{s + "1" + lead, "0", n, "1.e-" + strconv.Itoa(n+r.IntN(30))})
		out = append(out, spec{s + "1" + lead, "0", n, "1e-" + strconv.Itoa(n+r.IntN(30))})
		out = append(out, spec{s + lead, digits(r, 1), n, "." + digits(r, 5) + "e-" + strconv.Itoa(r.IntN(900))})
	case 4: // very long significands
		n := []int{1000, 5000, 16384, 20000}[r.IntN(4)]
		out = append(out, spec{s + digits(r, 3), digits(r, 1+r.IntN(3)), n / 2, "e-" + strconv.Itoa(n/2+r.IntN(60))})
		out = append(out, spec{s + "0.", "0", n, digits(r, 30) + "e" + strconv.Itoa(n-r.IntN(60))})
	case 5: // exponents read only to 10,000
		out = append(out, spec{s + digits(r, 1+r.IntN(30)), "", 0, "e" + []string{"", "+", "-"}[r.IntN(3)] + strconv.Itoa([]int{9999, 10000, 10001, 99999, 100000, 1000000}[r.IntN(6)])})
		out = append(out, spec{s, "1", 1 + r.IntN(20000), "e-" + strconv.Itoa(10000+r.IntN(100000))})
		out = append(out, spec{s + "0.", "0", r.IntN(20000), "1e" + strconv.Itoa(r.IntN(30000))})
	case 6: // subnormal and underflow edges
		if bitSize == 32 {
			out = append(out, spec{s + []string{"1.4e-45", "7e-46", "7.006492321624085e-46", "1.401298464324817e-45", "1.1754942e-38", "1.17549435e-38", "2.8e-45"}[r.IntN(7)], "", 0, ""})
		} else {
			out = append(out, spec{s + []string{"4.9e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "2.2250738585072011e-308", "2.2250738585072014e-308", "5e-324"}[r.IntN(6)], "", 0, ""})
		}
	case 7: // overflow edges
		if bitSize == 32 {
			out = append(out, spec{s + []string{"3.4028235e38", "3.4028236e38", "340282356779733661637539395458142568448", "340282356779733661637539395458142568447", "3.40282357e38"}[r.IntN(5)], "", 0, ""})
		} else {
			out = append(out, spec{s + []string{"1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308", "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792"}[r.IntN(4)], "", 0, ""})
		}
	case 8: // hexadecimal
		h := "0123456789abcdefABCDEF"
		n := 1 + r.IntN(24)
		var b strings.Builder
		for i := 0; i < n; i++ {
			b.WriteByte(h[r.IntN(len(h))])
		}
		m := b.String()
		if k := r.IntN(len(m) + 1); r.IntN(2) == 0 {
			m = m[:k] + "." + m[k:]
		}
		out = append(out, spec{s + "0" + []string{"x", "X"}[r.IntN(2)] + m + []string{"p", "P"}[r.IntN(2)] + strconv.Itoa(r.IntN(400)-250), "", 0, ""})
		out = append(out, spec{s + "0x1.", "0", r.IntN(60), "1p" + strconv.Itoa(r.IntN(40000)-20000)})
	case 9: // leading zeros
		out = append(out, spec{s + "0", "0", r.IntN(2000), "." + "0" + digits(r, 1+r.IntN(25)) + "e" + strconv.Itoa(r.IntN(2000))})
		out = append(out, spec{s, "0", r.IntN(2000), digits(r, 1+r.IntN(25))})
	case 10: // syntax
		out = append(out, spec{[]string{"", "e5", "1e", "1e+", "0x1p", "0x", "--1", "1..2", ".", "+", "-.e1", "1e1.5", "1_000", "1__0", "_1", "1_", "0x_1p0", "0x1_p0", "1e1_0", "0b1", "1f", "1.5d", " 1", "1 ", "0x1.8", "0xp1", "0x.p1", ".e1", "1e-", "1.0e+_1"}[r.IntN(30)], "", 0, ""})
	case 11: // specials
		out = append(out, spec{[]string{"inf", "Inf", "+INF", "-inf", "infinity", "-Infinity", "infin", "infinityx", "nan", "NaN", "+nan", "-NaN", "Infinit", "i", "n"}[r.IntN(15)], "", 0, ""})
	case 12: // 19 and 20 digit mantissas around the truncation, near midpoints
		m := midpoint(r, bitSize)
		d, p := exactDecimal(m)
		if len(d) > 19 {
			k := 17 + r.IntN(4)
			if k > len(d) {
				k = len(d)
			}
			out = append(out, spec{s + d[:k], "", 0, "e" + strconv.Itoa(p+len(d)-k)})
			out = append(out, spec{s + d[:k] + "1", "", 0, "e" + strconv.Itoa(p+len(d)-k-1)})
		}
		out = append(out, spec{s + digits(r, 19+r.IntN(3)), "", 0, "e" + strconv.Itoa(r.IntN(80)-40)})
	default: // the date number's literals: trimmed digits, "e", a scale
		out = append(out, spec{digits(r, 1+r.IntN(40)), "", 0, "e" + strconv.Itoa(r.IntN(200000)-100000)})
		out = append(out, spec{"1", digits(r, 1), r.IntN(3000), "e-" + strconv.Itoa(r.IntN(3000))})
	}
	return out
}

func main() {
	mode := os.Args[1]
	n, _ := strconv.Atoi(os.Args[2])
	seed, _ := strconv.ParseUint(os.Args[3], 10, 64)
	r := rand.New(rand.NewPCG(seed, 2027))
	w := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer w.Flush()
	if mode == "fixture" {
		fmt.Fprintln(w, "# [bitSize, prefix, unit, count, suffix, \"bits|error\"]: strconv.ParseFloat(prefix + unit×count + suffix, bitSize) in Go 1.27.1 (Tools/parity-float-cases)")
	}
	written := 0
	for written < n {
		bitSize := []int{32, 64}[r.IntN(2)]
		for _, c := range cases(r, bitSize) {
			lit := c.literal()
			a := answer(lit, bitSize)
			if mode == "fixture" {
				row, _ := json.Marshal([]any{bitSize, c.prefix, c.unit, c.count, c.suffix, a})
				w.Write(row)
				w.WriteString("\n")
			} else {
				fmt.Fprintf(w, "%d\t%s\t%s\n", bitSize, lit, a)
			}
			written++
		}
	}
}
