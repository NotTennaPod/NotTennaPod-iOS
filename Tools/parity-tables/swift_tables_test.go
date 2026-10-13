package feed

// The generator of NotTennaPod-iOS's parity parse tables (Tools/parity-tables.sh copies this file into an archived
// copy of the server's internal/feed and runs it there). It writes what the Go parse reads from Go's own libraries
// and from the server's generated tables, so the Swift port answers exactly as the server does on any OS version:
// the Unicode properties and case mappings of Go's unicode package, encoding/xml's name tables, the charsets
// of golang.org/x/text that decodeCharset reaches (ianaindex, then htmlindex), the date symbols and zones of
// datezones.go and TagSoup's schema.

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/xml"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"unicode"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/htmlindex"
	"golang.org/x/text/encoding/ianaindex"
	"golang.org/x/text/encoding/japanese"
	"golang.org/x/text/encoding/korean"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/traditionalchinese"
	xunicode "golang.org/x/text/encoding/unicode"
)

type swiftWriter struct{ bytes.Buffer }

func (w *swiftWriter) line(format string, args ...any) { fmt.Fprintf(&w.Buffer, format+"\n", args...) }

// swiftString is a Swift string literal: ASCII printable as is, everything else escaped.
func swiftString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r >= 0x20 && r < 0x7F:
			b.WriteRune(r)
		default:
			fmt.Fprintf(&b, "\\u{%X}", r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func (w *swiftWriter) numbers(indent string, values []uint32) {
	for i := 0; i < len(values); i += 12 {
		var parts []string
		for _, v := range values[i:min(i+12, len(values))] {
			parts = append(parts, fmt.Sprintf("0x%X", v))
		}
		w.line("%s%s,", indent, strings.Join(parts, ", "))
	}
}

func (w *swiftWriter) table(doc, name string, values []uint32) {
	w.line("    /// %s", doc)
	w.line("    static let %s: [UInt32] = [", name)
	w.numbers("        ", values)
	w.line("    ]")
}

// ranges flattens a RangeTable into (low, high, stride) triples in order.
func ranges(t *unicode.RangeTable) []uint32 {
	var out []uint32
	for _, r := range t.R16 {
		out = append(out, uint32(r.Lo), uint32(r.Hi), uint32(r.Stride))
	}
	for _, r := range t.R32 {
		out = append(out, r.Lo, r.Hi, r.Stride)
	}
	return out
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// literalRanges reads a RangeTable variable's literal from a Go source file (encoding/xml keeps its name tables
// unexported).
func literalRanges(t *testing.T, file, name string) []uint32 {
	f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	check(t, err)
	var out []uint32
	found := false
	ast.Inspect(f, func(n ast.Node) bool {
		spec, ok := n.(*ast.ValueSpec)
		if !ok || len(spec.Names) != 1 || spec.Names[0].Name != name {
			return true
		}
		found = true
		ast.Inspect(spec.Values[0], func(n ast.Node) bool {
			lit, ok := n.(*ast.CompositeLit)
			if !ok || len(lit.Elts) != 3 {
				return true
			}
			var triple []uint32
			for _, e := range lit.Elts {
				b, ok := e.(*ast.BasicLit)
				if !ok {
					return true
				}
				v, err := strconv.ParseUint(b.Value, 0, 32)
				check(t, err)
				triple = append(triple, uint32(v))
			}
			out = append(out, triple...)
			return false
		})
		return false
	})
	if !found {
		t.Fatalf("%s: no %s", file, name)
	}
	return out
}

// keyedArray reads a keyed array literal ([...]uintN{index: value, ...}) from a Go source file.
func keyedArray(t *testing.T, file, name string) []uint32 {
	f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	check(t, err)
	var out []uint32
	found := false
	ast.Inspect(f, func(n ast.Node) bool {
		spec, ok := n.(*ast.ValueSpec)
		if !ok || len(spec.Names) != 1 || spec.Names[0].Name != name {
			return true
		}
		found = true
		lit := spec.Values[0].(*ast.CompositeLit)
		next := 0
		for _, e := range lit.Elts {
			var key, value ast.Expr = nil, e
			if kv, ok := e.(*ast.KeyValueExpr); ok {
				key, value = kv.Key, kv.Value
			}
			if key != nil {
				k, err := strconv.ParseUint(key.(*ast.BasicLit).Value, 0, 32)
				check(t, err)
				next = int(k)
			}
			v, err := strconv.ParseUint(value.(*ast.BasicLit).Value, 0, 32)
			check(t, err)
			for len(out) <= next {
				out = append(out, 0)
			}
			out[next] = uint32(v)
			next++
		}
		return false
	})
	if !found {
		t.Fatalf("%s: no %s", file, name)
	}
	return out
}

// pairArray reads a [...][2]uint16 literal.
func pairArray(t *testing.T, file, name string) []uint32 {
	f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	check(t, err)
	var out []uint32
	ast.Inspect(f, func(n ast.Node) bool {
		spec, ok := n.(*ast.ValueSpec)
		if !ok || len(spec.Names) != 1 || spec.Names[0].Name != name {
			return true
		}
		for _, e := range spec.Values[0].(*ast.CompositeLit).Elts {
			for _, x := range e.(*ast.CompositeLit).Elts {
				v, err := strconv.ParseUint(x.(*ast.BasicLit).Value, 0, 32)
				check(t, err)
				out = append(out, uint32(v))
			}
		}
		return false
	})
	if len(out) == 0 {
		t.Fatalf("%s: no %s", file, name)
	}
	return out
}

// aliasKeys are the string keys of a map literal in a Go source file.
func aliasKeys(t *testing.T, file, name string) []string {
	f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	check(t, err)
	var out []string
	ast.Inspect(f, func(n ast.Node) bool {
		spec, ok := n.(*ast.ValueSpec)
		if !ok || len(spec.Names) != 1 || spec.Names[0].Name != name {
			return true
		}
		for _, e := range spec.Values[0].(*ast.CompositeLit).Elts {
			k, err := strconv.Unquote(e.(*ast.KeyValueExpr).Key.(*ast.BasicLit).Value)
			check(t, err)
			out = append(out, k)
		}
		return false
	})
	if len(out) == 0 {
		t.Fatalf("%s: no %s", file, name)
	}
	return out
}

// htmlEntities reads html's entity and entity2 map literals: "name=hex" and "name=hex,hex" entries, sorted.
func htmlEntities(t *testing.T, file string) (single, double []string) {
	f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	check(t, err)
	char := func(e ast.Expr) rune {
		v, _, _, err := strconv.UnquoteChar(strings.Trim(e.(*ast.BasicLit).Value, "'"), '\'')
		check(t, err)
		return v
	}
	ast.Inspect(f, func(n ast.Node) bool {
		kv, ok := n.(*ast.KeyValueExpr)
		if !ok {
			return true
		}
		key, ok := kv.Key.(*ast.BasicLit)
		if !ok || key.Kind != token.STRING {
			return true
		}
		name, err := strconv.Unquote(key.Value)
		check(t, err)
		if !regexp.MustCompile(`^[A-Za-z0-9]+;?$`).MatchString(name) {
			t.Fatalf("html entity name %q", name)
		}
		switch v := kv.Value.(type) {
		case *ast.BasicLit:
			single = append(single, fmt.Sprintf("%s=%X", name, char(v)))
		case *ast.CompositeLit:
			double = append(double, fmt.Sprintf("%s=%X,%X", name, char(v.Elts[0]), char(v.Elts[1])))
		default:
			t.Fatalf("html entity %q: %T", name, v)
		}
		return false
	})
	sort.Strings(single)
	sort.Strings(double)
	if len(single) < 2000 || len(double) < 50 {
		t.Fatalf("html entities: %d and %d", len(single), len(double))
	}
	return single, double
}

// The decoder kinds of the Swift port (ParityCharset.Kind), in this order.
var charsetKinds = []string{"charmap", "ascii", "utf8", "utf16BEUseBOM", "utf16BEIgnoreBOM", "utf16LEIgnoreBOM",
	"utf16BEExpectBOM", "utf16LEUseBOM", "utf16LEExpectBOM", "eucJP", "iso2022JP", "shiftJIS", "eucKR", "gbk",
	"gb18030", "hzGB2312", "big5", "replacement"}

// asCharmap is e's charmap, unwrapping x/text's internal.Encoding (ISO-8859-6E and the like name a charmap).
func asCharmap(e encoding.Encoding) *charmap.Charmap {
	for {
		if cm, ok := e.(*charmap.Charmap); ok {
			return cm
		}
		v := reflect.ValueOf(e)
		if v.Kind() != reflect.Pointer || v.Elem().Kind() != reflect.Struct {
			return nil
		}
		f := v.Elem().FieldByName("Encoding")
		if !f.IsValid() || f.IsNil() {
			return nil
		}
		e = f.Interface().(encoding.Encoding)
	}
}

func charsetKind(t *testing.T, name string, e encoding.Encoding) string {
	if asCharmap(e) != nil {
		return "charmap"
	}
	ascii, _ := ianaindex.IANA.Encoding("US-ASCII")
	for kind, x := range map[string]encoding.Encoding{
		"ascii": ascii, "utf8": xunicode.UTF8,
		"utf16BEUseBOM":    xunicode.UTF16(xunicode.BigEndian, xunicode.UseBOM),
		"utf16BEIgnoreBOM": xunicode.UTF16(xunicode.BigEndian, xunicode.IgnoreBOM),
		"utf16LEIgnoreBOM": xunicode.UTF16(xunicode.LittleEndian, xunicode.IgnoreBOM),
		"utf16BEExpectBOM": xunicode.UTF16(xunicode.BigEndian, xunicode.ExpectBOM),
		"utf16LEUseBOM":    xunicode.UTF16(xunicode.LittleEndian, xunicode.UseBOM),
		"utf16LEExpectBOM": xunicode.UTF16(xunicode.LittleEndian, xunicode.ExpectBOM),
		"eucJP":            japanese.EUCJP, "iso2022JP": japanese.ISO2022JP, "shiftJIS": japanese.ShiftJIS,
		"eucKR": korean.EUCKR, "gbk": simplifiedchinese.GBK, "gb18030": simplifiedchinese.GB18030,
		"hzGB2312": simplifiedchinese.HZGB2312, "big5": traditionalchinese.Big5, "replacement": encoding.Replacement,
	} {
		if e == x {
			return kind
		}
	}
	t.Fatalf("charset %q: unknown encoding %v", name, e)
	return ""
}

// TestEmitSwiftCharsetFixtures writes the charset cases of the Swift port's tests: what the server's charset and
// decodeCharset answer for every alias name (and variants of them) and for seeded byte strings in each decoder.
func TestEmitSwiftCharsetFixtures(t *testing.T) {
	out := os.Getenv("NTP_SWIFT_FIXTURES_OUT")
	if out == "" {
		t.Skip("NTP_SWIFT_FIXTURES_OUT is not set")
	}
	xtext := os.Getenv("NTP_XTEXT_DIR")
	var b strings.Builder
	fmt.Fprintf(&b, "# Generated by Tools/parity-tables.sh from NotTennaPod-Server %s: the server's charset(name) and\n", os.Getenv("NTP_SERVER_COMMIT"))
	b.WriteString("# decodeCharset(bytes, name). charset<TAB>name (Go-quoted)<TAB>encoding or !none;\n")
	b.WriteString("# decode<TAB>name<TAB>hex input<TAB>hex output or !error.\n")
	names := map[string]bool{"": true, "x-unknown-charset": true, " utf-8 ": true, "\u212aOI8-R": true, "ISO-8859-1\t": true,
		"\u00a0latin1": true, "UTF-16": true, "utf-32": true, "Cp1252": true, "CP1252": true, "ASCII": true, "ISO-2022-KR": true}
	for _, file := range []struct{ path, name string }{
		{filepath.Join(xtext, "encoding", "ianaindex", "tables.go"), "ianaAliases"},
		{filepath.Join(xtext, "encoding", "htmlindex", "tables.go"), "nameMap"},
	} {
		for _, k := range aliasKeys(t, file.path, file.name) {
			names[k] = true
			names[strings.ToUpper(k)] = true
		}
	}
	var sorted []string
	for k := range names {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		e, err := charset(k)
		answer := "!none"
		if err == nil {
			answer = fmt.Sprint(e)
		}
		fmt.Fprintf(&b, "charset\t%s\t%s\n", strconv.Quote(k), answer)
	}
	// Seeded byte strings, drawn from the bytes each decoder treats specially.
	special := []byte{0x00, 0x0a, 0x1b, 0x21, 0x24, 0x28, 0x30, 0x39, 0x40, 0x41, 0x42, 0x44, 0x49, 0x4a, 0x5f, 0x60, 0x7b,
		0x7d, 0x7e, 0x7f, 0x80, 0x81, 0x8e, 0x8f, 0x9f, 0xa0, 0xa1, 0xa4, 0xb0, 0xc6, 0xc7, 0xdf, 0xe0, 0xef, 0xfc, 0xfd,
		0xfe, 0xff, '@', '{', '}', '~', 'B', 'D', 'I', 'J', 0x88, 0x62, 0x66, 0xa3, 0xfa}
	seed := uint64(0x5eed7)
	next := func() uint64 {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
		return seed
	}
	for _, name := range []string{"EUC-JP", "ISO-2022-JP", "Shift_JIS", "EUC-KR", "GBK", "GB18030", "HZ-GB-2312", "Big5",
		"UTF-16BE", "csUnicode", "UnicodeFFFE", "x-user-defined", "ISO-8859-6-E", "csUTF8", "US-ASCII", "replacement",
		"windows-1252", "ISO-8859-1", "KOI8-R", "macintosh", "IBM037", "UTF-32", "UTF-32LE"} {
		for i := 0; i < 160; i++ {
			n := int(next() % 13)
			in := make([]byte, n)
			for j := range in {
				if next()%3 == 0 {
					in[j] = byte(next())
				} else {
					in[j] = special[next()%uint64(len(special))]
				}
			}
			got, err := decodeCharset(in, name)
			answer := "!error"
			if err == nil {
				answer = fmt.Sprintf("%x", got)
			}
			fmt.Fprintf(&b, "decode\t%s\t%x\t%s\n", name, in, answer)
		}
	}
	check(t, os.WriteFile(out, []byte(b.String()), 0o644))
}

func TestEmitSwiftTables(t *testing.T) {
	out := os.Getenv("NTP_SWIFT_TABLES_OUT")
	if out == "" {
		t.Skip("NTP_SWIFT_TABLES_OUT is not set")
	}
	xtext := os.Getenv("NTP_XTEXT_DIR")
	commit := os.Getenv("NTP_SERVER_COMMIT")
	var w swiftWriter
	w.line("// Code generated by Tools/parity-tables.sh from NotTennaPod-Server %s with %s (Unicode %s) and", commit,
		runtime.Version(), unicode.Version)
	w.line("// golang.org/x/text %s. DO NOT EDIT.", filepath.Base(xtext))
	w.line("// swiftlint:disable all")
	w.line("")

	// ---- Unicode
	w.line("/// Go's unicode package (the server's): range tables as (low, high, stride) triples, and simple case")
	w.line("/// mappings as sorted (code point, mapping) pairs of the code points that change.")
	w.line("enum ParityUnicodeTables {")
	for _, p := range []struct {
		name string
		tab  *unicode.RangeTable
	}{
		{"nd", unicode.Nd}, {"letter", unicode.L}, {"nl", unicode.Nl}, {"otherAlphabetic", unicode.Other_Alphabetic},
		{"mark", unicode.M}, {"pc", unicode.Pc}, {"mn", unicode.Mn}, {"me", unicode.Me},
		{"otherGraphemeExtend", unicode.Other_Grapheme_Extend}, {"cf", unicode.Cf}, {"bidiControl", unicode.Bidi_Control},
		{"z", unicode.Z}, {"whiteSpace", unicode.White_Space}, {"lu", unicode.Lu}, {"ll", unicode.Ll}, {"lt", unicode.Lt},
		{"otherLowercase", unicode.Other_Lowercase}, {"otherUppercase", unicode.Other_Uppercase},
	} {
		w.table(p.name, p.name, ranges(p.tab))
	}
	var upper, lower, fold []uint32
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if u := unicode.ToUpper(r); u != r {
			upper = append(upper, uint32(r), uint32(u))
		}
		if l := unicode.ToLower(r); l != r {
			lower = append(lower, uint32(r), uint32(l))
		}
		m := r
		for f := unicode.SimpleFold(r); f != r; f = unicode.SimpleFold(f) {
			m = min(m, f)
		}
		if m != r {
			fold = append(fold, uint32(r), uint32(m))
		}
	}
	w.table("unicode.ToUpper", "upper", upper)
	w.table("unicode.ToLower", "lower", lower)
	w.table("The smallest code point of each simple case folding orbit (unicode.SimpleFold).", "foldMin", fold)
	w.line("}")
	w.line("")

	// ---- encoding/xml names
	xmlSource := filepath.Join(runtime.GOROOT(), "src", "encoding", "xml", "xml.go")
	w.line("/// encoding/xml's name tables: `first` (Letter | '_' | ':') and `second` (the other NameChars).")
	w.line("enum ParityXMLNameTables {")
	w.table("first", "first", literalRanges(t, xmlSource, "first"))
	w.table("second", "second", literalRanges(t, xmlSource, "second"))
	var names []string
	for k := range xml.HTMLEntity {
		names = append(names, k)
	}
	sort.Strings(names)
	w.line("    /// xml.HTMLEntity (name, replacement text)")
	w.line("    static let htmlEntities: [(String, String)] = [")
	for _, k := range names {
		w.line("        (%s, %s),", swiftString(k), swiftString(xml.HTMLEntity[k]))
	}
	w.line("    ]")
	w.line("}")
	w.line("")

	// ---- html (jsoup's entity lookup goes through html.UnescapeString)
	single, double := htmlEntities(t, filepath.Join(runtime.GOROOT(), "src", "html", "entity.go"))
	w.line("/// Go's html package entities (entity.go): name=code point, and name=two code points, separated by spaces.")
	w.line("enum ParityHTMLEntityTables {")
	w.line("    static let single = \"\"\"")
	for i := 0; i < len(single); i += 8 {
		w.line("        %s", strings.Join(single[i:min(i+8, len(single))], " "))
	}
	w.line("        \"\"\"")
	w.line("    static let double = \"\"\"")
	for i := 0; i < len(double); i += 8 {
		w.line("        %s", strings.Join(double[i:min(i+8, len(double))], " "))
	}
	w.line("        \"\"\"")
	w.line("}")
	w.line("")

	// ---- charsets
	type alias struct {
		name     string
		encoding int
	}
	var encodings []encoding.Encoding
	index := func(e encoding.Encoding) int {
		for i, x := range encodings {
			if x == e {
				return i
			}
		}
		encodings = append(encodings, e)
		return len(encodings) - 1
	}
	var iana, html []alias
	for _, name := range aliasKeys(t, filepath.Join(xtext, "encoding", "ianaindex", "tables.go"), "ianaAliases") {
		if e, err := ianaindex.IANA.Encoding(name); err == nil && e != nil {
			iana = append(iana, alias{name, index(e)})
		}
	}
	for _, name := range aliasKeys(t, filepath.Join(xtext, "encoding", "htmlindex", "tables.go"), "nameMap") {
		e, err := htmlindex.Get(name)
		check(t, err)
		html = append(html, alias{name, index(e)})
	}
	sort.Slice(iana, func(i, j int) bool { return iana[i].name < iana[j].name })
	sort.Slice(html, func(i, j int) bool { return html[i].name < html[j].name })
	w.line("/// golang.org/x/text's charsets as decodeCharset reaches them: ianaindex's supported aliases (looked up as")
	w.line("/// given, then lower-cased), then htmlindex's labels (lower-cased); each names an entry of `encodings`.")
	w.line("enum ParityCharsetTables {")
	w.line("    static let ianaAliases: [(String, Int)] = [")
	for _, a := range iana {
		w.line("        (%s, %d),", swiftString(a.name), a.encoding)
	}
	w.line("    ]")
	w.line("    static let htmlLabels: [(String, Int)] = [")
	for _, a := range html {
		w.line("        (%s, %d),", swiftString(a.name), a.encoding)
	}
	w.line("    ]")
	w.line("    /// Each encoding: its decoder kind (%s) and, for a charmap, its", strings.Join(charsetKinds, ", "))
	w.line("    /// 256 decoded code points.")
	w.line("    static let encodings: [(kind: Int, name: String, charmap: [UInt32])] = [")
	for _, e := range encodings {
		kind := charsetKind(t, fmt.Sprint(e), e)
		var table []uint32
		if cm := asCharmap(e); cm != nil {
			for b := 0; b < 256; b++ {
				table = append(table, uint32(cm.DecodeByte(byte(b))))
			}
		}
		w.line("        (%d, %s, [", slices.Index(charsetKinds, kind), swiftString(fmt.Sprint(e)))
		w.numbers("            ", table)
		w.line("        ]),")
	}
	w.line("    ]")
	w.line("}")
	w.line("")

	// ---- dates
	w.line("/// datezones.go: Locale.US date symbols on Android 16 and ICU's English zone names, metazones and zone rules.")
	w.line("enum ParityDateTables {")
	strs := func(ss []string) string {
		var q []string
		for _, s := range ss {
			q = append(q, swiftString(s))
		}
		return "[" + strings.Join(q, ", ") + "]"
	}
	w.line("    static let weekdays: [String] = %s", strs(dateWeekdays))
	w.line("    static let shortWeekdays: [String] = %s", strs(dateShortWeekdays))
	w.line("    static let months: [String] = %s", strs(dateMonths))
	w.line("    static let shortMonths: [String] = %s", strs(dateShortMonths))
	w.line("    /// (name, daylight, zone, metazone)")
	w.line("    static let zoneNames: [(String, Bool, String, String)] = [")
	for _, z := range dateZoneNames {
		w.line("        (%s, %v, %s, %s),", swiftString(z.name), z.dst, swiftString(z.tz), swiftString(z.mz))
	}
	w.line("    ]")
	var keys []string
	for k := range dateMetaZoneRefs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	w.line("    static let metaZoneRefs: [String: String] = [")
	for _, k := range keys {
		w.line("        %s: %s,", swiftString(k), swiftString(dateMetaZoneRefs[k]))
	}
	w.line("    ]")
	keys = nil
	for k := range dateZoneMetaZones {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	w.line("    static let zoneMetaZones: [String: [String]] = [")
	for _, k := range keys {
		w.line("        %s: %s,", swiftString(k), strs(dateZoneMetaZones[k]))
	}
	w.line("    ]")
	keys = nil
	for k := range dateZoneRules {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	w.line("    /// (offsets in seconds, DST flags, base64 transitions)")
	w.line("    static let zoneRules: [String: ([Int32], String, String)] = [")
	for _, k := range keys {
		r := dateZoneRules[k]
		var offs []string
		for _, o := range r.offsets {
			offs = append(offs, strconv.Itoa(int(o)))
		}
		w.line("        %s: ([%s], %s, %s),", swiftString(k), strings.Join(offs, ", "), swiftString(r.isDst), swiftString(r.trans))
	}
	w.line("    ]")
	w.line("}")
	w.line("")

	// ---- TagSoup
	w.line("/// tagsoup_schema.go: HTMLSchema's element types (name, content model, member-of models, flags, parent)")
	w.line("/// and entities.")
	w.line("enum ParityTagSoupTables {")
	w.line("    static let elements: [(String, UInt32, UInt32, Int, String)] = [")
	for _, d := range tagsoupElementDefs {
		w.line("        (%s, 0x%08X, 0x%08X, %d, %s),", swiftString(d.name), d.model, d.memberOf, d.flags, swiftString(d.parent))
	}
	w.line("    ]")
	keys = nil
	for k := range tagsoupEntities {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	w.line("    /// name=hex pairs separated by spaces")
	var ents []string
	for _, k := range keys {
		if !regexp.MustCompile(`^[A-Za-z0-9.]+$`).MatchString(k) {
			t.Fatalf("entity name %q", k)
		}
		ents = append(ents, fmt.Sprintf("%s=%X", k, tagsoupEntities[k]))
	}
	w.line("    static let entities = \"\"\"")
	for i := 0; i < len(ents); i += 10 {
		w.line("        %s", strings.Join(ents[i:min(i+10, len(ents))], " "))
	}
	w.line("        \"\"\"")
	w.line("}")
	check(t, os.WriteFile(filepath.Join(out, "ParityTables.swift"), w.Bytes(), 0o644))

	// ---- CJK decoding tables (x/text, WHATWG indexes), base64 of little-endian arrays.
	var c swiftWriter
	c.line("// Code generated by Tools/parity-tables.sh from golang.org/x/text %s (the WHATWG indexes). DO NOT EDIT.", filepath.Base(xtext))
	c.line("// swiftlint:disable all")
	c.line("")
	c.line("/// The decoding tables of golang.org/x/text's CJK decoders, as base64 of little-endian arrays.")
	c.line("enum ParityCJKTables {")
	enc := func(name, doc string, values []uint32, size int) {
		var b []byte
		for _, v := range values {
			if size == 2 {
				if v > 0xFFFF {
					t.Fatalf("%s: %X", name, v)
				}
				b = binary.LittleEndian.AppendUint16(b, uint16(v))
			} else {
				b = binary.LittleEndian.AppendUint32(b, v)
			}
		}
		s := base64.StdEncoding.EncodeToString(b)
		c.line("    /// %s (%d entries of %d bytes)", doc, len(values), size)
		c.line("    static let %s = \"\"\"", name)
		for i := 0; i < len(s); i += 120 {
			c.line("        %s", s[i:min(i+120, len(s))])
		}
		c.line("        \"\"\"")
	}
	enc("jis0208", "japanese jis0208Decode", keyedArray(t, filepath.Join(xtext, "encoding", "japanese", "tables.go"), "jis0208Decode"), 2)
	enc("jis0212", "japanese jis0212Decode", keyedArray(t, filepath.Join(xtext, "encoding", "japanese", "tables.go"), "jis0212Decode"), 2)
	enc("eucKR", "korean decode", keyedArray(t, filepath.Join(xtext, "encoding", "korean", "tables.go"), "decode"), 2)
	enc("gbk", "simplifiedchinese decode", keyedArray(t, filepath.Join(xtext, "encoding", "simplifiedchinese", "tables.go"), "decode"), 2)
	enc("gb18030", "simplifiedchinese gb18030 ranges (pointer, code point) pairs", pairArray(t, filepath.Join(xtext, "encoding", "simplifiedchinese", "tables.go"), "gb18030"), 2)
	enc("big5", "traditionalchinese decode", keyedArray(t, filepath.Join(xtext, "encoding", "traditionalchinese", "tables.go"), "decode"), 4)
	c.line("}")
	check(t, os.WriteFile(filepath.Join(out, "ParityCJKTables.swift"), c.Bytes(), 0o644))
}
