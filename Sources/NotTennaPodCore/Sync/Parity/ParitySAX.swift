// The server's sax.go and TypeGetter (parse.go): the XML reader that feeds the namespace handlers, Expat with
// namespace processing as Android's SAX parser, over Go's encoding/xml tokens; internal DTD entities expanded at
// use as Expat does; and the budgets that bound what a hostile feed costs (Android has none: a feed over one fails
// like a parser exception). The parse's cancellation is asked between tokens, every 64 KiB of input the decoder reads,
// and every 65,536 steps of a pass over one token (its attributes, a blank text, an entity declaration), as the
// server's sax.go asks its context.

enum ParitySAX {
    static let maxEntityText = 16 << 20  // expanded entity text in total
    static let maxText = 64 << 20  // decoded text and attribute values in total
    static let maxItems = 100_000
    static let maxDepth = 256
    static let checkEvery = 1024  // tokens between cancellation checks
    // Expat's billion-laughs protection (Android has it): past the activation threshold, input plus expansions may be
    // at most this factor of the input.
    static let expatAmplification = 100
    static let expatActivation = 8 << 20
    static let maxEntityDepth = 64
    private static let commentEnd = Array("-->".utf8)
    private static let cdataEnd = Array("]]>".utf8)
    private static let processingInstructionEnd = Array("?>".utf8)

    static let nsAtom = Array("http://www.w3.org/2005/Atom".utf8)
    static let nsContent = Array("http://purl.org/rss/1.0/modules/content/".utf8)
    static let nsItunes = Array("http://www.itunes.com/dtds/podcast-1.0.dtd".utf8)
    static let nsChapters = Array("http://podlove.org/simple-chapters".utf8)
    static let nsMedia = Array("http://search.yahoo.com/mrss/".utf8)
    static let nsDublinCore = Array("http://purl.org/dc/elements/1.1/".utf8)
    static let nsPodcastIndex = Array("https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md".utf8)
    static let nsPodcastIndex2 = Array("https://podcastindex.org/namespace/1.0".utf8)
    static let nsXML = Array("http://www.w3.org/XML/1998/namespace".utf8)
    static let nsXMLNS = Array("http://www.w3.org/2000/xmlns/".utf8)

    enum Kind { case atom, rss20, rss091 }

    // MARK: TypeGetter

    /// TypeGetter.getType: the first start tag decides; an Atom feed's xml:lang is its language.
    static func typeOf(_ text: [UInt8], cancellation: ParityCancellation) throws -> (Kind, String?) {
        var d = GoXMLDecoder(text, entities: GoXMLDecoder.htmlEntities, cancellation: cancellation)
        var n = 1
        while true {
            if n % checkEvery == 0 { try cancellation.check() }
            n += 1
            guard let token = d.rawToken() else {
                // The decoder stopped at cancellation, or it ended: an expired parse reports neither.
                if d.failure == .cancelled { throw CancellationError() }
                try cancellation.check()
                if d.failure == .eof {
                    throw ParityParseError(label: "unsupported_type", detail: "Unknown problem when trying to determine feed type")
                }
                throw try ParityWebsite.error(text, cancellation: cancellation)
            }
            switch token {
            case .charData(let data):
                if !(try blank(data, cancellation)) {
                    throw try ParityWebsite.error(text, cancellation: cancellation)
                }
            case .start(let name, let attrs):
                if name.local.is("feed") {
                    var language: String?
                    for i in 0..<attrs.count where attrs.space(i).is("xml") && attrs.local(i).is("lang") {
                        language = String(decoding: attrs.value(i), as: UTF8.self)
                    }
                    return (.atom, language)
                }
                if name.local.is("rss") {
                    var version: ArraySlice<UInt8>?
                    for i in 0..<attrs.count where attrs.space(i).isEmpty && attrs.local(i).is("version") { version = attrs.value(i) }
                    guard let version, !version.is("2.0") else { return (.rss20, nil) }
                    if version.is("0.91") || version.is("0.92") { return (.rss091, nil) }
                    throw ParityParseError(label: "unsupported_type", detail: "Unsupported rss version")
                }
                throw try ParityWebsite.error(text, cancellation: cancellation)
            default:
                continue
            }
        }
    }

    // MARK: The XML reader

    /// saxParse: the document's events to the handlers, as Expat with namespace processing reports them. Its
    /// namespace state is numbers in contiguous storage (ParityNames, NamespaceBindings) and a start tag's
    /// attributes are checked with tables of their numbers, so that a document of millions of declarations or
    /// attributes is released at once; every name is hashed and compared in counted steps.
    static func parse(_ document: [UInt8], state st: ParityHandlerState) throws {
        // Declared general entities are substituted into the text first, so their replacement text is parsed as
        // content, as Expat does; every use counts against the budgets before anything is built.
        let cancellation = st.cancellation
        let doc = try expandDocument(document, cancellation: cancellation)
        var d = GoXMLDecoder(doc, cancellation: cancellation)
        var raw: [GoXMLName] = []  // the open elements, for well-formedness
        var scopes: [Int] = []  // the namespace declarations of each open element: how many bindings it pushed
        var namespaces = try NamespaceBindings(cancellation)
        var rooted = false
        var closed = false
        var decoded = 0  // text and attribute bytes so far
        var n = 0
        while true {
            if n % checkEvery == 0 { try cancellation.check() }
            n += 1
            guard let token = d.rawToken() else {
                if d.failure == .eof { break }
                if d.failure == .cancelled { throw CancellationError() }
                try cancellation.check()  // an expired parse is no parse error
                throw ParityParseError.parserException
            }
            switch token {
            case .directive:
                if rooted { throw ParityParseError.parserException }
            case .start(let name, let attrs):
                if closed { throw ParityParseError.parserException }  // junk after the document element
                rooted = true
                if raw.count >= maxDepth { throw ParityParseError.parserException }
                // Qualified names are unique (a qualified name is its prefix and local name); declarations follow
                // Expat's namespace constraints: xml is bound only to its namespace and nothing else is; xmlns is
                // never declared; a prefix cannot be undeclared.
                // Local names' hashes, once each (only a tag of many attributes uses tables).
                var localHashes: [Int] = []
                if attrs.count > Uniqueness.small {
                    localHashes = try (0..<attrs.count).map { try ParityNames.hash(attrs.local($0), cancellation) }
                }
                var qualified = Uniqueness(capacity: attrs.count)
                var declarations: [Int32] = []
                for i in 0..<attrs.count {
                    // One token can hold the whole document's attributes: their processing is counted too.
                    try cancellation.tick(1)
                    let space = attrs.space(i)
                    let duplicate = try qualified.insert(i, hash: {
                        var hasher = Hasher()
                        hasher.combine(try ParityNames.hash(space, cancellation))
                        hasher.combine(localHashes[i])
                        return hasher.finalize()
                    }, equal: { j in
                        try ParityNames.equal(attrs.space(j), space, cancellation)
                            && ParityNames.equal(attrs.local(j), attrs.local(i), cancellation)
                    })
                    if duplicate { throw ParityParseError.parserException }  // duplicate attribute
                    let local = attrs.local(i)
                    let v = attrs.value(i)
                    if space.is("xmlns") {
                        if local.is("xmlns") || local.is("xml") != v.elementsEqual(nsXML) || v.elementsEqual(nsXMLNS) || v.isEmpty {
                            throw ParityParseError.parserException
                        }
                        declarations.append(Int32(i))
                    } else if space.isEmpty && local.is("xmlns") {
                        if v.elementsEqual(nsXML) || v.elementsEqual(nsXMLNS) { throw ParityParseError.parserException }
                        declarations.append(Int32(i))
                    }
                }
                for i in declarations {
                    let prefix = attrs.space(Int(i)).isEmpty ? attrs.space(Int(i)) : attrs.local(Int(i))  // "" for xmlns
                    try cancellation.tick(1)
                    try namespaces.bind(prefix, attrs.value(Int(i)), cancellation)
                    st.startPrefixMapping(prefix, attrs.value(Int(i)))
                }
                guard let uri = try namespaces.resolve(name.space[...], cancellation) else {
                    throw ParityParseError.parserException  // unbound prefix
                }
                var attributes = ParityAttributes(attributes: attrs)
                var expanded = Uniqueness(capacity: attrs.count)
                var attributeNamespaces = [Int](repeating: 0, count: attrs.count)
                for i in 0..<attrs.count {
                    try cancellation.tick(1)
                    let space = attrs.space(i)
                    if space.is("xmlns") || (space.isEmpty && attrs.local(i).is("xmlns")) { continue }
                    var namespace = 0
                    if !space.isEmpty {
                        // resolve's rules: xmlns is never bound to an attribute's prefix, an undeclared prefix is
                        // unbound. The namespace is its number, given by value where it was declared.
                        guard let number = try namespaces.number(space, cancellation) else { throw ParityParseError.parserException }
                        namespace = number
                    }
                    attributeNamespaces[i] = namespace
                    let duplicate = try expanded.insert(i, hash: {
                        var hasher = Hasher()
                        hasher.combine(namespace)
                        hasher.combine(localHashes[i])
                        return hasher.finalize()
                    }, equal: { j in
                        // Namespaces are compared by number.
                        guard attributeNamespaces[j] == namespace else { return false }
                        return try ParityNames.equal(attrs.local(j), attrs.local(i), cancellation)
                    })
                    if duplicate { throw ParityParseError.parserException }  // the same expanded name, as in Expat
                    attributes.included.append(Int32(i))
                    decoded += attrs.value(i).count
                }
                if decoded > maxText { throw ParityParseError.parserException }
                raw.append(name)
                scopes.append(declarations.count)
                try st.startElement(uri: uri, local: name.local, qName: name.qualified, attributes: attributes)
            case .end(let name):
                guard let last = raw.last, last == name else { throw ParityParseError.parserException }  // mismatched tag
                let uri = try namespaces.resolve(name.space[...], cancellation) ?? []
                try st.endElement(uri: uri, local: name.local, qName: name.qualified)
                let declared = scopes.removeLast()
                raw.removeLast()
                for _ in 0..<declared {
                    try cancellation.tick(1)
                    st.endPrefixMapping(namespaces.unbind())
                }
                if raw.isEmpty { closed = true }
            case .charData(let data):
                if raw.isEmpty {
                    if !(try blank(data, cancellation)) { throw ParityParseError.parserException }
                    continue
                }
                decoded += data.count
                if decoded > maxText { throw ParityParseError.parserException }
                st.characters(data)
            case .comment, .procInst:
                continue
            }
        }
        if !rooted || !raw.isEmpty { throw ParityParseError.parserException }
    }

    /// A start tag's attributes by number, for its uniqueness checks: compared one by one while there are few, then
    /// in an open-addressing table by hash. equal(j) compares attribute j with the one being inserted.
    private struct Uniqueness {
        static let small = 8
        private var members: [Int32] = []
        private var slots: [Int32] = []
        private var hashes: [Int] = []

        init(capacity: Int) {
            guard capacity > Self.small else { return }
            var size = 16
            while size < 2 * capacity { size *= 2 }
            slots = [Int32](repeating: -1, count: size)
            hashes = [Int](repeating: 0, count: capacity)
        }

        /// Inserts attribute i, or reports that an equal one is there.
        mutating func insert(_ i: Int, hash: () throws -> Int, equal: (Int) throws -> Bool) rethrows -> Bool {
            if slots.isEmpty {
                for j in members where try equal(Int(j)) { return true }
                members.append(Int32(i))
                return false
            }
            let h = try hash()
            let mask = slots.count - 1
            var k = h & mask
            while slots[k] >= 0 {
                let j = Int(slots[k])
                if hashes[j] == h, try equal(j) { return true }
                k = (k + 1) & mask
            }
            slots[k] = Int32(i)
            hashes[i] = h
            return false
        }
    }

    /// The namespace bindings in force: prefixes and URIs numbered by value (ParityNames), each prefix's innermost
    /// binding, and the bindings in the order they were made, each with the binding it hides. The xml prefix is bound
    /// to its namespace, the URI numbered 1; 0 is no namespace.
    private struct NamespaceBindings {
        private var prefixes = ParityNames()
        private var uris = ParityNames()
        private var innermost: [Int32] = []  // by prefix: its binding, or -1
        private var prefixOf: [Int32] = []  // by binding
        private var uriOf: [Int32] = []
        private var hidden: [Int32] = []

        init(_ work: ParityCancellation) throws {
            try bind(Array("xml".utf8)[...], nsXML[...], work)
        }

        mutating func bind(_ prefix: ArraySlice<UInt8>, _ uri: ArraySlice<UInt8>, _ work: ParityCancellation) throws {
            let p = try prefixes.intern(prefix, work)
            if p == innermost.count { innermost.append(-1) }
            let u = try uris.intern(uri, work)
            prefixOf.append(Int32(p))
            uriOf.append(Int32(u))
            hidden.append(innermost[p])
            innermost[p] = Int32(prefixOf.count - 1)
        }

        /// Removes the latest binding, returning its prefix.
        mutating func unbind() -> ArraySlice<UInt8> {
            let p = Int(prefixOf.removeLast())
            uriOf.removeLast()
            innermost[p] = hidden.removeLast()
            return prefixes.name(p)
        }

        /// The URI a prefix is bound to: nil for xmlns and for an unbound prefix but the empty one (no namespace).
        func resolve(_ prefix: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> ArraySlice<UInt8>? {
            if prefix.is("xmlns") { return nil }
            if let b = try binding(prefix, work) { return uris.name(Int(uriOf[b])) }
            return prefix.isEmpty ? [] : nil
        }

        /// The number of the URI a (non-empty) prefix is bound to; nil when it is unbound.
        func number(_ prefix: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Int? {
            if prefix.is("xmlns") { return nil }
            return try binding(prefix, work).map { Int(uriOf[$0]) + 1 }
        }

        private func binding(_ prefix: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Int? {
            guard let p = try prefixes.find(prefix, work), innermost[p] >= 0 else { return nil }
            return Int(innermost[p])
        }
    }

    /// Whether strings.TrimSpace(text) is empty: only Unicode white space. Its steps are counted.
    static func blank(_ text: [UInt8], _ cancellation: ParityCancellation) throws -> Bool {
        var i = 0
        let s = text[...]
        while i < s.count {
            let (r, n) = GoStrings.decodeRune(s, i)
            try cancellation.tick(n)
            if !GoUnicode.isSpace(r) { return false }  // an invalid byte is U+FFFD, which is no space
            i += n
        }
        return true
    }

    // MARK: Internal DTD entities

    /// The document with every use of a declared entity after the prolog replaced by its replacement text,
    /// recursively, as Expat parses it at use (or the document itself when it declares none): character references
    /// are replaced when a declaration is read; the predefined entities stay for the decoder. Uses in comments,
    /// CDATA sections and processing instructions are not uses. Each use counts, in document order and before its
    /// text is built, against Expat's amplification limit and the entity budget. Undefined, recursive or malformed
    /// references are malformed, but only when used. Every step is counted against the parse's cancellation (the
    /// server's entityWork): reading the declarations, replacing their references, expanding at use, and the scans
    /// between uses (the server's scans between uses are unchecked; output is the same).
    static func expandDocument(_ doc: [UInt8], cancellation work: ParityCancellation) throws -> [UInt8] {
        guard let (table, root) = try prologEntities(doc, cancellation: work), table.count > 0 else { return doc }
        // Character references are replaced when the declaration is read: a malformed one is malformed whether or
        // not the entity is used.
        var x = try EntityExpander(table: table, work: work)
        // A '&' starts a use only when the next ';' ends a declared name. The next ';' is found once for a run of
        // '&', and each '&' of the run has its own candidate, as long as the rest of the run: copying and looking
        // each up is quadratic (and with names of many lengths, so is looking up only those of a declared length).
        // The candidates of a run are filtered in one pass instead (EntityFilter, the server's entityFilter), and
        // only those it passes are copied, counted and looked up.
        var filter = try EntityFilter(declared: (0..<table.count).lazy.map { table.names.name($0) }, work: work)
        var semicolon = -1  // the next ';' at or after i, or doc.count when there is none
        var b: [UInt8] = []
        b.reserveCapacity(doc.count)
        b.append(contentsOf: doc[..<root])
        var indirect = 0
        var steps = 0
        var i = root
        while i < doc.count {
            steps += 1
            if steps % checkEvery == 0 { try work.check() }
            if doc[i] == UInt8(ascii: "<") && doc[i...].starts(with: "<!--".utf8) {
                let j = try skipPast(doc, i, commentEnd, work)
                b.append(contentsOf: doc[i..<j])
                i = j
            } else if doc[i] == UInt8(ascii: "<") && doc[i...].starts(with: "<![CDATA[".utf8) {
                let j = try skipPast(doc, i, cdataEnd, work)
                b.append(contentsOf: doc[i..<j])
                i = j
            } else if doc[i] == UInt8(ascii: "<") && doc[i...].starts(with: "<?".utf8) {
                let j = try skipPast(doc, i, processingInstructionEnd, work)
                b.append(contentsOf: doc[i..<j])
                i = j
            } else if doc[i] == UInt8(ascii: "&") {
                if semicolon < i {
                    semicolon = try index(of: UInt8(ascii: ";"), in: doc[i...], work) ?? doc.count
                    if semicolon < doc.count { try filter.window(doc, i, semicolon, work) }
                }
                var entity: Int?
                if semicolon < doc.count, filter.passed(semicolon - i - 1) {
                    try work.tick(semicolon - i)
                    entity = try table.names.find(doc[(i + 1)..<semicolon], work)
                }
                guard let entity else {
                    b.append(UInt8(ascii: "&"))  // a character reference, a predefined or an undefined entity: the decoder's
                    i += 1
                    continue
                }
                let n = try x.length(entity, depth: 0)
                indirect += n
                x.charged += n
                let direct = semicolon + 1
                if x.charged > maxEntityText
                    || direct + indirect >= expatActivation && direct + indirect > expatAmplification * direct {
                    throw ParityParseError.parserException
                }
                b.append(contentsOf: try x.value(entity, depth: 0))
                i = direct
            } else {
                var j = i + 1
                while j < doc.count && doc[j] != UInt8(ascii: "<") && doc[j] != UInt8(ascii: "&") {
                    try work.tick()
                    j += 1
                }
                b.append(contentsOf: doc[i..<j])
                i = j
            }
        }
        return b
    }

    /// Which candidate names of a run of '&' may be declared, without hashing each (the server's entityFilter): a
    /// polynomial hash modulo 2^61-1 with a random base, computed backward from the run's ';' in one pass, is compared
    /// with the declared names' hashes of the same length. Equal names hash alike, so every declared candidate passes;
    /// one that passes is looked up, which decides, so the result is the lookups'. With a random base, a candidate of
    /// n bytes that is no declared name passes with a probability of at most n/2^61, however the document is made.
    struct EntityFilter {
        static let mersenne61: UInt64 = (1 << 61) - 1
        let base: UInt64
        private(set) var longest = 0
        private var hashes = Set<Hash>()
        /// Bit sets by length: the declared names' lengths, and the candidates of the current run that passed.
        private var lengths: [UInt64]
        private var hits: [UInt64]
        private var hitLengths: [Int] = []

        @inline(__always) private static func contains(_ set: [UInt64], _ n: Int) -> Bool { set[n >> 6] & (1 << UInt64(n & 63)) != 0 }

        struct Hash: Hashable {
            let length: Int
            let value: UInt64
        }

        static func mulmod(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let (hi, lo) = a.multipliedFullWidth(by: b)
            var r = ((hi << 3) | (lo >> 61)) &+ (lo & mersenne61)
            r = (r & mersenne61) &+ (r >> 61)
            if r >= mersenne61 { r -= mersenne61 }
            return r
        }

        static func addmod(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let r = a &+ b
            return r >= mersenne61 ? r - mersenne61 : r
        }

        /// The declared names' hashes; hashing them is counted.
        init<Names: Collection>(declared names: Names, work: ParityCancellation,
                                base: UInt64 = UInt64.random(in: 256..<EntityFilter.mersenne61)) throws
            where Names.Element: Collection<UInt8> {
            self.base = base
            // Room for every hash at once: growing the set as it fills would place them all again, unchecked.
            hashes.reserveCapacity(names.count)
            for name in names {
                try work.tick()
                longest = max(longest, name.count)
            }
            lengths = [UInt64](repeating: 0, count: longest / 64 + 1)
            hits = lengths
            for name in names {
                var h: UInt64 = 0
                for c in name {
                    try work.tick()
                    h = Self.addmod(Self.mulmod(h, base), UInt64(c) + 1)
                }
                lengths[name.count >> 6] |= 1 << UInt64(name.count & 63)
                hashes.insert(Hash(length: name.count, value: h))
            }
        }

        /// Finds the candidates of the run of '&' from amp to the ';' at semi: doc[p..<semi] for each '&' at p-1 in
        /// amp..<semi. It reads at most the longest name's length back from semi, once per run (runs do not
        /// overlap), and counts it.
        mutating func window(_ doc: [UInt8], _ amp: Int, _ semi: Int, _ work: ParityCancellation) throws {
            for n in hitLengths { hits[n >> 6] = 0 }
            hitLengths.removeAll(keepingCapacity: true)
            let lo = max(amp + 1, semi - longest)
            var h: UInt64 = 0
            var pw: UInt64 = 1
            var p = semi - 1
            while p >= lo {
                try work.tick()
                h = Self.addmod(h, Self.mulmod(UInt64(doc[p]) + 1, pw))
                pw = Self.mulmod(pw, base)
                let n = semi - p
                if doc[p - 1] == UInt8(ascii: "&") && Self.contains(lengths, n) && hashes.contains(Hash(length: n, value: h)) {
                    hits[n >> 6] |= 1 << UInt64(n & 63)
                    hitLengths.append(n)
                }
                p -= 1
            }
        }

        /// Whether the current run's candidate of this length passed.
        func passed(_ length: Int) -> Bool { length >= 1 && length <= longest && Self.contains(hits, length) }
    }

    private static let entityOpener = Array("<!ENTITY".utf8)

    /// The internal subset's general entities, numbered in declaration order (the first declaration of a name
    /// binds): their names, and their values kept one after another. A prolog of millions of declarations is a few
    /// arrays, released at once.
    struct EntityTable {
        private(set) var names = ParityNames()
        private var values: [UInt8] = []
        private var valueEnds: [Int] = []

        var count: Int { names.count }

        /// Entity i's value, as declared.
        func value(_ i: Int) -> ArraySlice<UInt8> { values[(i == 0 ? 0 : valueEnds[i - 1])..<valueEnds[i]] }

        /// Declares an entity, unless its name is declared.
        mutating func declare(_ name: [UInt8], _ value: [UInt8], _ work: ParityCancellation) throws {
            let count = names.count
            guard try names.intern(name[...], work) == count else { return }
            if values.isEmpty {
                values = value  // the first value's storage, not a copy of it
            } else {
                values.append(contentsOf: value)
            }
            valueEnds.append(values.count)
        }
    }

    /// The prolog up to the document element: the internal subset's general entity declarations (the first
    /// declaration of a name binds; external ones are empty, never fetched) and the document element's offset;
    /// nil when the document declares no entity.
    static func prologEntities(_ doc: [UInt8], cancellation work: ParityCancellation) throws -> (EntityTable, Int)? {
        guard try firstIndex(of: entityOpener, in: doc, from: 0, work) != nil else { return nil }
        var d = GoXMLDecoder(doc, cancellation: work)
        var declared = EntityTable()
        while true {
            let offset = d.offset
            guard let token = d.rawToken() else {
                if d.failure == .cancelled { throw CancellationError() }
                try work.check()  // an expired parse is no parse error
                throw ParityParseError.parserException
            }
            switch token {
            case .start:
                return (declared, offset)
            case .directive(let text):
                try entityDeclarations(text, work: work) { name, value in
                    try declared.declare(name, value, work)  // empty for SYSTEM and PUBLIC
                }
            default:
                continue
            }
        }
    }

    /// A directive's general entity declarations, its matches of
    ///
    ///     <!ENTITY\s+([^\s%]+)\s+(?:"([^"]*)"|'([^']*)'|(SYSTEM|PUBLIC)\b[^>]*)\s*>
    ///
    /// as Go's regexp FindAllStringSubmatch finds them (the server's entityDeclarations): the leftmost matches in
    /// order, each searched for from the end of the last, a "<!ENTITY" the rest does not match passed over; value is
    /// the quoted text, empty for SYSTEM and PUBLIC. Every part is determined: \s is [\t\n\f\r ], the name is the
    /// longest run before the whitespace that must follow it, a quoted value ends at its quote, and [^>]* at the
    /// next '>'. A "<!ENTITY" without the whitespace is passed over at once (its name scan could run over every
    /// later "<!ENTITY"), and the next quote and '>' are found once for all attempts after them, so the scan is
    /// linear; its steps are counted, since a declaration can be as long as the document.
    static func entityDeclarations(_ dir: [UInt8], work: ParityCancellation,
                                   found: ([UInt8], [UInt8]) throws -> Void) throws {
        func space(_ c: UInt8) -> Bool { c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20 }
        func word(_ c: UInt8) -> Bool {
            c >= 0x30 && c <= 0x39 || c >= 0x41 && c <= 0x5A || c >= 0x61 && c <= 0x7A || c == UInt8(ascii: "_")
        }
        // The next quote or '>' at or after a position, or dir.count: a search from `from` found it `at`, which
        // stands for every position between.
        var next: [UInt8: (from: Int, at: Int)] = [:]
        func nextAt(_ c: UInt8, _ i: Int) throws -> Int {
            if let f = next[c], f.from <= i, i <= f.at { return f.at }
            let at = try index(of: c, in: dir[i...], work) ?? dir.count
            next[c] = (i, at)
            return at
        }
        var pos = 0
        while let start = try firstIndex(of: entityOpener, in: dir, from: pos, work) {
            pos = start + 1  // where the search goes on if this one does not match
            let i = start + entityOpener.count
            var j = i
            while j < dir.count && space(dir[j]) {
                try work.tick()
                j += 1
            }
            if j == i { continue }  // \s+ is needed
            var n = j
            while n < dir.count && !space(dir[n]) && dir[n] != UInt8(ascii: "%") {
                try work.tick()
                n += 1
            }
            var v = n
            while v < dir.count && space(dir[v]) {
                try work.tick()
                v += 1
            }
            if n == j || v == n || v == dir.count { continue }  // a name and \s+ are needed, then a value
            var value: [UInt8] = []
            var end = -1
            switch dir[v] {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                let q = try nextAt(dir[v], v + 1)
                if q == dir.count { continue }
                var e = q + 1
                while e < dir.count && space(dir[e]) {
                    try work.tick()
                    e += 1
                }
                if e < dir.count && dir[e] == UInt8(ascii: ">") {
                    value = Array(dir[(v + 1)..<q])
                    end = e + 1
                }
            case UInt8(ascii: "S"), UInt8(ascii: "P"):
                let keyword = dir[v..<min(v + 6, dir.count)]
                guard keyword.elementsEqual("SYSTEM".utf8) || keyword.elementsEqual("PUBLIC".utf8) else { continue }
                if v + 6 < dir.count && word(dir[v + 6]) { continue }  // \b
                let g = try nextAt(UInt8(ascii: ">"), v + 6)
                if g < dir.count { end = g + 1 }
            default:
                break
            }
            if end < 0 { continue }
            try work.tick(end - v)
            try found(Array(dir[j..<n]), value)
            pos = end
        }
    }

    /// Entities expanded at use, lazily: an entity that is never used is never expanded, and lengths are known
    /// before any text is built. Every use, and every expansion built along the way (an entity inside another is
    /// built and kept too), is charged to the entity budget before it is allocated. Entities are the table's
    /// numbers; their replacement texts and built expansions are kept one after another, so that millions of them
    /// are released at once.
    private struct EntityExpander {
        let table: EntityTable
        let work: ParityCancellation
        private var literals: [UInt8] = []  // replacement texts after character references, in the table's order
        private var literalEnds: [Int] = []
        private var lengths: [Int: Int] = [:]  // expanded lengths, at most maxEntityText+1
        private var built: [UInt8] = []  // expanded texts of used entities
        private var values: [Int: Range<Int>] = [:]
        var charged = 0  // entity text charged so far: uses and built expansions

        /// Replaces every declaration's character references.
        init(table: EntityTable, work: ParityCancellation) throws {
            self.table = table
            self.work = work
            literalEnds.reserveCapacity(table.count)
            for i in 0..<table.count {
                try ParitySAX.appendReplacingCharacterReferences(table.value(i), to: &literals, work: work)
                literalEnds.append(literals.count)
            }
        }

        private func literal(_ i: Int) -> ArraySlice<UInt8> { literals[(i == 0 ? 0 : literalEnds[i - 1])..<literalEnds[i]] }

        /// The entity's fully expanded length, saturated just past the budget; a recursive or undefined reference
        /// inside is malformed.
        mutating func length(_ entity: Int, depth: Int) throws -> Int {
            if let n = lengths[entity] {
                if n < 0 { throw ParityParseError.parserException }  // recursion
                return n
            }
            if depth > ParitySAX.maxEntityDepth { throw ParityParseError.parserException }
            lengths[entity] = -1
            var total = 0
            try ParitySAX.forReferences(literal(entity), work: work, text: { total += $0.count }, reference: { ref in
                guard let inner = try table.names.find(ref, work) else { throw ParityParseError.parserException }  // undefined
                total += try length(inner, depth: depth + 1)
            })
            lengths[entity] = min(total, ParitySAX.maxEntityText + 1)
            return lengths[entity]!
        }

        /// The entity's expanded text; length has measured it, and every reference inside. Building it is charged
        /// first.
        mutating func value(_ entity: Int, depth: Int) throws -> ArraySlice<UInt8> {
            if let range = values[entity] { return built[range] }
            charged += lengths[entity] ?? 0
            if charged > ParitySAX.maxEntityText { throw ParityParseError.parserException }
            var b: [UInt8] = []
            b.reserveCapacity(lengths[entity] ?? 0)
            try ParitySAX.forReferences(literal(entity), work: work, text: { b.append(contentsOf: $0) }, reference: { ref in
                if let inner = try table.names.find(ref, work) { b.append(contentsOf: try value(inner, depth: depth + 1)) }
            })
            let start = built.count
            built.append(contentsOf: b)
            values[entity] = start..<built.count
            return built[start..<built.count]
        }
    }

    private static let predefined: [[UInt8]] = ["amp", "lt", "gt", "quot", "apos"].map { Array($0.utf8) }

    /// Whether a reference's name is a predefined entity's, byte for byte. A name longer than four bytes is none, and
    /// is not read: a name as long as the document is looked up only by the counted ParityNames.
    static func isPredefined(_ name: ArraySlice<UInt8>) -> Bool {
        name.count <= 4 && predefined.contains { $0.elementsEqual(name) }
    }

    /// Splits a replacement text into its text and its references to declared or undefined general entities;
    /// character references and the predefined entities stay text, for the decoder. Its steps are counted; a
    /// reference's name is a slice of the text, not copied.
    static func forReferences(_ literal: ArraySlice<UInt8>, work: ParityCancellation, text: (ArraySlice<UInt8>) -> Void,
                              reference: (ArraySlice<UInt8>) throws -> Void) throws {
        var lit = literal
        while true {
            guard let i = try index(of: UInt8(ascii: "&"), in: lit, work) else {
                text(lit)
                return
            }
            guard let j = try index(of: UInt8(ascii: ";"), in: lit[i...], work), j - i >= 2 else {
                throw ParityParseError.parserException  // a "&" that starts no reference
            }
            let name = lit[(i + 1)..<j]
            if isPredefined(name) || name[name.startIndex] == UInt8(ascii: "#") {
                text(lit[..<(j + 1)])
            } else {
                text(lit[..<i])
                try reference(name)
            }
            lit = lit[(j + 1)...]
        }
    }

    /// Replaces the "&#…;" character references of a declaration's replacement text; other references stay. A "&"
    /// that starts no reference is malformed. Its steps are counted.
    static func replaceCharacterReferences(_ s: [UInt8], work: ParityCancellation) throws -> [UInt8] {
        var b: [UInt8] = []
        try appendReplacingCharacterReferences(s[...], to: &b, work: work)
        return b
    }

    /// replaceCharacterReferences, appending the text to b.
    static func appendReplacingCharacterReferences(_ s: ArraySlice<UInt8>, to b: inout [UInt8], work: ParityCancellation) throws {
        var rest = s
        while true {
            guard let i = try index(of: UInt8(ascii: "&"), in: rest, work) else {
                b.append(contentsOf: rest)
                return
            }
            b.append(contentsOf: rest[..<i])
            guard let j = try index(of: UInt8(ascii: ";"), in: rest[i...], work), j - i >= 2 else {
                throw ParityParseError.parserException
            }
            let ref = rest[(i + 1)..<j]
            if ref.first == UInt8(ascii: "#") {
                guard let r = characterReference(ref.dropFirst()) else { throw ParityParseError.parserException }
                GoStrings.appendRune(&b, r)
            } else {
                b.append(contentsOf: rest[i...j])
            }
            rest = rest[(j + 1)...]
        }
    }

    /// The index of the first c in s, counting each step.
    @inline(__always) static func index(of c: UInt8, in s: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Int? {
        var i = s.startIndex
        while i < s.endIndex {
            try work.tick()
            if s[i] == c { return i }
            i += 1
        }
        return nil
    }

    /// The first index at or after from where needle starts, counting each step.
    static func firstIndex(of needle: [UInt8], in s: [UInt8], from: Int, _ work: ParityCancellation) throws -> Int? {
        var i = from
        while i + needle.count <= s.count {
            try work.tick()
            if s[i] == needle[0] && s[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    /// An XML character reference's value ("65" or "x41").
    static func characterReference(_ reference: ArraySlice<UInt8>) -> UInt32? {
        var ref = reference
        var base: UInt64 = 10
        if ref.first == UInt8(ascii: "x") {
            ref = ref.dropFirst()
            base = 16
        }
        guard !ref.isEmpty else { return nil }
        // strconv.ParseUint(ref, base, 32): digits of the base only.
        var v: UInt64 = 0
        for c in ref {
            let d: UInt64
            switch c {
            case 0x30...0x39: d = UInt64(c - 0x30)
            case 0x61...0x66 where base == 16: d = UInt64(c - 0x61 + 10)
            case 0x41...0x46 where base == 16: d = UInt64(c - 0x41 + 10)
            default: return nil
            }
            v = v * base + d
            if v > UInt64(UInt32.max) { return nil }
        }
        let r = UInt32(v)
        guard r == 0x9 || r == 0xA || r == 0xD || r >= 0x20 && r <= 0xD7FF || r >= 0xE000 && r <= 0xFFFD
                || r >= 0x10000 && r <= 0x10FFFF else { return nil }
        return r
    }

    static func skipPast(_ s: [UInt8], _ i: Int, _ end: [UInt8], _ work: ParityCancellation) throws -> Int {
        guard let j = try firstIndex(of: end, in: s, from: i, work) else { return s.count }
        return j + end.count
    }
}
