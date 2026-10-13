// The server's handlers.go and atom.go: SyndHandler, HandlerState and the namespace handlers of AntennaPod's
// parser/feed/namespace, rule for rule. Where the Java code would throw (a null item, a missing chapter list, an
// empty stack), the parse fails as Android's does.

/// SAX Attributes, looked up by qualified name: the start tag's attributes that declare no namespace, in order, by
/// their numbers in the tag.
struct ParityAttributes {
    var attributes = GoXMLAttributes()
    var included: [Int32] = []

    func get(_ name: StaticString) -> String? {
        name.withUTF8Buffer { key in
            for i in included where attributes.qualifiedIs(Int(i), key) {
                return String(decoding: attributes.value(Int(i)), as: UTF8.self)
            }
            return nil
        }
    }
}

extension Array where Element == UInt8 {
    /// Byte equality with a literal name.
    @inline(__always) func `is`(_ s: StaticString) -> Bool { s.withUTF8Buffer { self.elementsEqual($0) } }
}

extension ArraySlice where Element == UInt8 {
    /// Byte equality with a literal name.
    @inline(__always) func `is`(_ s: StaticString) -> Bool { s.withUTF8Buffer { self.elementsEqual($0) } }
}

/// A namespace handler (parser/feed/namespace).
enum ParityNamespace {
    case rss20, atom, content, itunes, simpleChapters, media, dublinCore, podcastIndex
}

/// SyndElement (with AtomText's type and content).
struct SyndElement {
    var name: [UInt8]
    var atomType: String?
    var atom = false
    var content: String?

    init(_ name: [UInt8], atom: Bool = false, atomType: String? = nil) {
        self.name = name
        self.atom = atom
        self.atomType = atomType
    }
}

/// HandlerState.
final class ParityHandlerState {
    var feed = ParityFeed()
    var items: [ParityItem] = []
    /// The current item: always the last one added, while it is open.
    var current: Int?
    var currentFunding: Int?
    var tagstack: [SyndElement] = []
    /// Per open element: whether its start pushed onto tagstack.
    var pushed: [Bool] = []
    var namespaces: [[UInt8]: ParityNamespace] = [:]
    var defaults: [ParityNamespace] = []
    /// nil is Java's null.
    var contentBuf: [UInt8]?
    /// tempObjects[Itunes.DURATION].
    var duration: Int32?
    var alternates: [ParityAlternateFeed] = []
    /// Each alternate's position in alternates by its URL's bytes (Android's HashMap; a scan would be quadratic).
    var alternateIndex: [[UInt8]: Int] = [:]
    var alternateNull: String?
    var hasAlternateNull = false
    var redirectURL: String?
    /// The UTF-16 length of each item's description: Java keeps a string's length, so comparing many candidates to a
    /// long description stays linear. Every description is set through setDescriptionIfLonger.
    var descriptionLengths: [Int] = []
    /// Atom's feed author names joined so far, while they are the feed's author (another handler may replace it):
    /// appended in place, not concatenated anew for each name. The feed's author is this when it is set.
    var authorNames: String?
    let now: Int64
    let cancellation: ParityCancellation

    init(kind: ParitySAX.Kind, now: Int64, cancellation: ParityCancellation) {
        self.now = now
        self.cancellation = cancellation
        if kind == .rss20 || kind == .rss091 { defaults.append(.rss20) }
    }

    // MARK: Stack and buffer

    /// tagstack.peek(): Java throws on an empty stack.
    func top() throws -> SyndElement {
        guard let last = tagstack.last else { throw ParityParseError.parserException }
        return last
    }

    /// getSecondTag: the element under the top.
    func secondTag() throws -> SyndElement {
        guard tagstack.count >= 2 else { throw ParityParseError.parserException }
        return tagstack[tagstack.count - 2]
    }

    func thirdTag() throws -> SyndElement {
        guard tagstack.count >= 3 else { throw ParityParseError.parserException }
        return tagstack[tagstack.count - 3]
    }

    /// getContentBuf().toString(), or nil for a null buffer.
    var content: String? { contentBuf.map { String(decoding: $0, as: UTF8.self) } }

    func addItem() throws {
        items.append(ParityItem())
        descriptionLengths.append(0)
        current = items.count - 1
        if items.count > ParitySAX.maxItems { throw ParityParseError.parserException }
    }

    /// The current item: Java throws on a null one.
    func item() throws -> Int {
        guard let current else { throw ParityParseError.parserException }
        return current
    }

    /// FeedItem.setDescriptionIfLonger: the longer description by UTF-16 length.
    func setDescriptionIfLonger(_ index: Int, _ d: String?) {
        guard let d else { return }
        let n = JavaStrings.length(d)
        if items[index].description == nil || descriptionLengths[index] < n {
            items[index].description = d
            descriptionLengths[index] = n
        }
    }

    /// The feed's author: Atom's names joined so far, when they are it.
    var feedAuthor: String? { authorNames ?? feed.author }

    /// Atom's feed author name: the author, or the author so far, ", " and the name. Java concatenates anew each
    /// time, quadratic time for very many names; here they are appended in place while the author is the one built
    /// so (another handler may replace it).
    func addFeedAuthor(_ name: String) {
        guard let author = feedAuthor else {
            feed.author = name
            return
        }
        if authorNames == nil { authorNames = author }
        authorNames! += ", "
        authorNames! += name
    }

    func html(_ s: String, compact: Bool) throws -> String {
        try ParityHTMLText.text(s, compact: compact, cancellation: cancellation)
    }

    // MARK: SyndHandler

    /// The longest namespace a handler is registered for: namespaces holds no longer URI, and a longer one, which can
    /// be as long as the document, is never hashed again for every element (Go's small map does not hash a key whose
    /// length matches no entry).
    private static let longestNamespace = [ParitySAX.nsAtom, ParitySAX.nsContent, ParitySAX.nsItunes, ParitySAX.nsChapters,
                                           ParitySAX.nsMedia, ParitySAX.nsDublinCore, ParitySAX.nsPodcastIndex,
                                           ParitySAX.nsPodcastIndex2].map(\.count).max() ?? 0

    /// The handler registered for a namespace URI.
    private func registered(_ uri: ArraySlice<UInt8>) -> ParityNamespace? {
        uri.count <= Self.longestNamespace ? namespaces[Array(uri)] : nil
    }

    func startPrefixMapping(_ prefix: ArraySlice<UInt8>, _ uri: ArraySlice<UInt8>) {
        if registered(uri) != nil { return }
        if uri.elementsEqual(ParitySAX.nsAtom) {
            if prefix.isEmpty {
                defaults.append(.atom)
            } else if prefix.is("atom") {
                namespaces[Array(uri)] = .atom
            }
        } else if uri.elementsEqual(ParitySAX.nsContent) && prefix.is("content") {
            namespaces[Array(uri)] = .content
        } else if uri.elementsEqual(ParitySAX.nsItunes) && prefix.is("itunes") {
            namespaces[Array(uri)] = .itunes
        } else if uri.elementsEqual(ParitySAX.nsChapters) && (prefix.is("psc") || prefix.is("sc")) {
            namespaces[Array(uri)] = .simpleChapters
        } else if uri.elementsEqual(ParitySAX.nsMedia) && prefix.is("media") {
            namespaces[Array(uri)] = .media
        } else if uri.elementsEqual(ParitySAX.nsDublinCore) && prefix.is("dc") {
            namespaces[Array(uri)] = .dublinCore
        } else if uri.elementsEqual(ParitySAX.nsPodcastIndex) || (uri.elementsEqual(ParitySAX.nsPodcastIndex2) && prefix.is("podcast")) {
            // Java precedence: NSURI || (NSURI2 && prefix == "podcast").
            namespaces[Array(uri)] = .podcastIndex
        }
    }

    func endPrefixMapping(_ prefix: ArraySlice<UInt8>) {
        if defaults.count > 1 && prefix.isEmpty { defaults.removeLast() }
    }

    private func handling(_ uri: ArraySlice<UInt8>, _ qName: [UInt8]) -> ParityNamespace? {
        if let h = registered(uri) { return h }
        if let last = defaults.last, !qName.contains(UInt8(ascii: ":")) { return last }
        return nil
    }

    func startElement(uri: ArraySlice<UInt8>, local: [UInt8], qName: [UInt8], attributes: ParityAttributes) throws {
        contentBuf = []
        let h = handling(uri, qName)
        if let h { tagstack.append(try start(h, local, attributes)) }
        pushed.append(h != nil)
    }

    func characters(_ s: [UInt8]) {
        if tagstack.count >= 2 && contentBuf != nil { contentBuf!.append(contentsOf: s) }
    }

    /// endElement chooses the handler again, as Android does. A namespace that a child declared can make an element
    /// handled at only one of its ends; its start's push and its end's pop would then no longer pair up (Android pops
    /// another element's entry, or an empty stack), so that is a parse error.
    func endElement(uri: ArraySlice<UInt8>, local: [UInt8], qName: [UInt8]) throws {
        let h = handling(uri, qName)
        let wasPushed = pushed.popLast() ?? false
        if (h != nil) != wasPushed { throw ParityParseError.parserException }
        if let h {
            try end(h, local)
            tagstack.removeLast()
        }
        contentBuf = nil
    }

    // MARK: Handlers

    private func start(_ ns: ParityNamespace, _ local: [UInt8], _ a: ParityAttributes) throws -> SyndElement {
        switch ns {
        case .rss20: try rss20Start(local, a)
        case .atom: return try atomStart(local, a)
        case .content, .dublinCore: break
        case .itunes: try itunesStart(local, a)
        case .simpleChapters: try chaptersStart(local, a)
        case .media: return try mediaStart(local, a)
        case .podcastIndex: try podcastIndexStart(local, a)
        }
        return SyndElement(local)
    }

    private func end(_ ns: ParityNamespace, _ local: [UInt8]) throws {
        switch ns {
        case .rss20: try rss20End(local)
        case .atom: try atomEnd(local)
        case .content:
            if local.is("encoded"), let current, contentBuf != nil { setDescriptionIfLonger(current, content) }
        case .dublinCore:
            if let current, let text = content, tagstack.count >= 2, try top().name.is("date"), try secondTag().name.is("item") {
                items[current].pubDate = try ParityDates.parseOrNullIfFuture(text, now: now, cancellation: cancellation)
            }
        case .itunes: try itunesEnd(local)
        case .simpleChapters: break
        case .media:
            if local.is("description") {
                guard let c = content else { throw ParityParseError.parserException }  // toString() on null
                if let current { setDescriptionIfLonger(current, c) }
            }
        case .podcastIndex:
            if let c = content, local.is("funding"), let currentFunding, !c.isEmpty { feed.funding[currentFunding].content = c }
        }
    }

    // MARK: RSS 2.0 (Rss20)

    private func rss20Start(_ local: [UInt8], _ a: ParityAttributes) throws {
        if tagstack.isEmpty && (local.is("item") || local.is("enclosure")) {
            throw ParityParseError.parserException  // Stack.lastElement() / peek() on an empty stack
        }
        if local.is("item"), try top().name.is("channel") {
            try addItem()
        } else if local.is("enclosure"), try top().name.is("item"), let current {
            let url = a.get("url")
            var mime = try ParityValues.mimeType(a.get("type"), url, work: cancellation)
            var valid = ParityValues.isMediaFile(mime)
            if !valid && !ParityValues.isImageFile(mime) && items[current].media == nil {
                valid = true
                mime = "audio/*"
            }
            if items[current].media == nil && valid, let url, !url.isEmpty {
                var size: Int64 = 0
                if let s = a.get("length"), !s.isEmpty, let v = try ParityValues.javaParseLong(s, work: cancellation) { size = v }
                if size < 16384 { size = 0 }  // less than 16 KiB is suspicious
                items[current].media = ParityMedia(url: url, size: size, mimeType: mime)
            }
        }
    }

    private func rss20End(_ local: [UInt8]) throws {
        if local.is("item") {
            if let current {
                // The title is optional in RSS 2.0; the description stands in.
                if items[current].title == nil { items[current].title = items[current].description }
                if let duration {
                    if items[current].media != nil { items[current].media!.duration = duration }
                    self.duration = nil
                }
            }
            current = nil
            return
        }
        guard tagstack.count >= 2, let raw = content else { return }
        let text = try JavaStrings.trimAllWhitespace(raw, work: cancellation)
        let top = try top().name
        let second = try secondTag().name
        let third = try tagstack.count >= 3 ? thirdTag().name : []
        if top.is("guid") && second.is("item") {
            // An empty or non-standard guid is ignored.
            if !raw.isEmpty, let current { items[current].guid = raw }
        } else if top.is("title") {
            let t = try html(text, compact: true)
            if second.is("item"), let current {
                items[current].title = t
            } else if second.is("channel") {
                feed.title = t
            }
        } else if top.is("link") {
            if second.is("channel") {
                feed.link = text
            } else if second.is("item"), let current {
                items[current].link = text
            }
        } else if top.is("pubDate") && second.is("item"), let current {
            items[current].pubDate = try ParityDates.parseOrNullIfFuture(text, now: now, cancellation: cancellation)
        } else if top.is("url") && second.is("image") && third.is("channel") {
            if feed.imageURL == nil { feed.imageURL = text }  // prefer itunes:image
        } else if local.is("description") {
            if second.is("channel") {
                feed.description = try html(text, compact: true)
            } else if second.is("item"), let current {
                setDescriptionIfLonger(current, text)
            }
        } else if local.is("language") {
            feed.language = try JavaStrings.lowerUS(text, work: cancellation)
        }
    }

    // MARK: iTunes (Itunes)

    private func itunesStart(_ local: [UInt8], _ a: ParityAttributes) throws {
        if local.is("image") {
            let url = a.get("href")
            if let current {
                items[current].imageURL = url
            } else if let url, !url.isEmpty {
                feed.imageURL = url  // prefer to all other images
            }
        }
    }

    private func itunesEnd(_ local: [UInt8]) throws {
        guard let c = content, !c.isEmpty else { return }
        if local.is("author") && tagstack.count <= 3 {
            authorNames = nil
            feed.author = try html(c, compact: true)
        } else if local.is("duration") {
            if let ms = try ParityValues.durationMillis(c, work: cancellation) { duration = Int32(truncatingIfNeeded: ms) }  // (int) durationMs
        } else if local.is("subtitle") {
            if let current, items[current].description?.isEmpty ?? true {
                setDescriptionIfLonger(current, c)
            } else if feed.description?.isEmpty ?? true {
                feed.description = c
            }
        } else if local.is("summary") {
            if let current {
                setDescriptionIfLonger(current, c)
            } else if try secondTag().name.is("channel") {
                feed.description = c
            }
        } else if local.is("new-feed-url") {
            let trimmed = try JavaStrings.trim(c, work: cancellation)
            if GoStrings.hasPrefix(trimmed, "http") { redirectURL = trimmed }
        }
    }

    // MARK: Media RSS (Media)

    private func mediaStart(_ local: [UInt8], _ a: ParityAttributes) throws -> SyndElement {
        if local.is("content") {
            guard let current else { return SyndElement(local) }
            let url = a.get("url")
            let isDefault = a.get("isDefault").map { GoStrings.same($0, "true") } ?? false
            let medium = a.get("medium")
            var mime = try ParityValues.mimeType(a.get("type"), url, work: cancellation)
            var validMedia = false
            var validImage = false
            if let medium, GoStrings.same(medium, "audio") {
                validMedia = true
                mime = "audio/*"
            } else if let medium, GoStrings.same(medium, "video") {
                validMedia = true
                mime = "video/*"
            } else if let medium, GoStrings.same(medium, "image"),
                      mime == nil || (!GoStrings.hasPrefix(mime!, "audio/") && !GoStrings.hasPrefix(mime!, "video/")) {
                // Some publishers explicitly declare the audio file as an image.
                validImage = true
                mime = "image/*"
            } else if ParityValues.isMediaFile(mime) {
                validMedia = true
            } else if ParityValues.isImageFile(mime) {
                validImage = true
            } else {
                // Workaround for broken feeds.
                validMedia = items[current].media == nil
                mime = "audio/*"
            }
            if items[current].media == nil || isDefault, let url, validMedia {
                var size: Int64 = 0
                if let s = a.get("fileSize"), !s.isEmpty, let v = try ParityValues.javaParseLong(s, work: cancellation) { size = v }
                var durationMs: Int32 = 0
                if let s = a.get("duration"), !s.isEmpty, let v = try ParityValues.javaParseLong(s, work: cancellation) {
                    // (int) TimeUnit.MILLISECONDS.convert(duration, SECONDS)
                    durationMs = Int32(truncatingIfNeeded: v &* 1000)
                    if v > Int64.max / 1000 || v < Int64.min / 1000 {
                        durationMs = Int32(truncatingIfNeeded: v > 0 ? Int64.max : Int64.min)
                    }
                }
                var media = ParityMedia(url: url, size: size, mimeType: mime)
                if durationMs > 0 { media.duration = durationMs }
                items[current].media = media
            } else if let url, validImage {
                items[current].imageURL = url
            }
        } else if local.is("thumbnail") {
            if let url = a.get("url") {
                if let current {
                    items[current].imageURL = url
                } else if feed.imageURL == nil {
                    feed.imageURL = url
                }
            }
        } else if local.is("description") {
            return SyndElement(local, atom: true, atomType: a.get("type"))
        }
        return SyndElement(local)
    }

    // MARK: Podcasting 2.0 (PodcastIndex)

    private func podcastIndexStart(_ local: [UInt8], _ a: ParityAttributes) throws {
        if local.is("funding") {
            feed.funding.append(ParityFunding(url: a.get("url"), content: ""))
            currentFunding = feed.funding.count - 1
        } else if local.is("chapters") {
            if let href = a.get("url"), !href.isEmpty { items[try item()].chapterURL = href }
        } else if local.is("socialInteract") {
            if let href = a.get("uri"), !href.isEmpty, let current { items[current].socialInteractURL = href }
        } else if local.is("transcript") {
            if let href = a.get("url"), !href.isEmpty, let type = a.get("type"), !type.isEmpty {
                items[try item()].setTranscriptURL(type: type, url: href)
            }
        }
    }

    // MARK: Podlove simple chapters (SimpleChapters)

    private func chaptersStart(_ local: [UInt8], _ a: ParityAttributes) throws {
        guard let current else { return }
        if local.is("chapters") {
            items[current].chapters = []
        } else if local.is("chapter"), let startText = a.get("start"), !startText.isEmpty {
            if let start = try ParityValues.parseTimeString(startText, work: cancellation) {
                guard items[current].chapters != nil else { throw ParityParseError.parserException }  // add on a missing list
                items[current].chapters!.append(ParityChapter(start: start, title: a.get("title"), link: a.get("href"),
                                                              imageURL: a.get("image")))
            }
        }
    }

    // MARK: Atom (namespace/Atom.java and element/AtomText.java)

    private static func isAtomText(_ name: [UInt8]) -> Bool {
        name.is("title") || name.is("content") || name.is("subtitle") || name.is("summary")
    }

    private static func isFeed(_ name: [UInt8]) -> Bool { name.is("feed") || name.is("channel") }
    private static func isFeedItem(_ name: [UInt8]) -> Bool { name.is("entry") || name.is("item") }

    private func atomStart(_ local: [UInt8], _ a: ParityAttributes) throws -> SyndElement {
        if local.is("entry") {
            try addItem()
        } else if Self.isAtomText(local) {
            return SyndElement(local, atom: true, atomType: a.get("type"))
        } else if local.is("link") {
            let href = a.get("href")
            let rel = a.get("rel")
            let parent = try top().name
            if Self.isFeedItem(parent), let current {
                if rel == nil || GoStrings.same(rel!, "alternate") {
                    items[current].link = href
                } else if GoStrings.same(rel!, "enclosure") {
                    var size: Int64 = 0
                    if let s = a.get("length"), !s.isEmpty, let v = try ParityValues.javaParseLong(s, work: cancellation) { size = v }
                    var mime = try ParityValues.mimeType(a.get("type"), href, work: cancellation)
                    var valid = ParityValues.isMediaFile(mime)
                    if !valid && items[current].media == nil && !ParityValues.isImageFile(mime) {
                        valid = true
                        mime = "audio/*"
                    }
                    if valid && items[current].media == nil { items[current].media = ParityMedia(url: href, size: size, mimeType: mime) }
                } else if GoStrings.same(rel!, "payment") {
                    items[current].paymentLink = href
                }
            } else if Self.isFeed(parent) {
                let type = a.get("type")
                func isFeedType(_ t: String?) -> Bool {
                    guard let t else { return false }
                    return GoStrings.same(t, "application/atom+xml") || GoStrings.same(t, "application/rss+xml")
                }
                if rel == nil || GoStrings.same(rel!, "alternate") {
                    // The link, unless typed as another feed (a podlove alternate feed).
                    if (type == nil && feed.link == nil)
                        || (type != nil && (GoStrings.same(type!, "text/html") || GoStrings.same(type!, "application/xml+xhtml"))) {
                        feed.link = href
                    } else if isFeedType(type) {
                        addAlternate(title: a.get("title"), href: href)
                    }
                } else if GoStrings.same(rel!, "archives") {
                    if isFeedType(type) { addAlternate(title: a.get("title"), href: href) }
                } else if GoStrings.same(rel!, "payment") {
                    feed.funding.append(ParityFunding(url: href, content: ""))
                } else if GoStrings.same(rel!, "next") {
                    feed.paged = true
                    feed.nextPageURL = href
                }
            }
        }
        return SyndElement(local)
    }

    /// Atom's podlove alternate feed: the title, or the href when the title is empty, put into HandlerState's
    /// HashMap by href (a repeated href keeps the later title; a null href is the null key).
    private func addAlternate(title: String?, href: String?) {
        var title = title
        if title?.isEmpty ?? true { title = href }
        guard let href else {
            alternateNull = title
            hasAlternateNull = true
            return
        }
        let value = title ?? ""
        let key = Array(href.utf8)
        if let i = alternateIndex[key] {
            alternates[i].title = value
        } else {
            alternateIndex[key] = alternates.count
            alternates.append(ParityAlternateFeed(url: href, title: value))
        }
    }

    /// AtomText.getProcessedContent.
    private func processed(_ e: SyndElement) throws -> String? {
        guard let content = e.content else { return nil }
        if let type = e.atomType, GoStrings.same(type, "html") { return try html(content, compact: false) }
        return content
    }

    private func atomEnd(_ local: [UInt8]) throws {
        if local.is("entry") {
            if let current, let duration {
                if items[current].media != nil { items[current].media!.duration = duration }
                self.duration = nil
            }
            current = nil
        }
        guard tagstack.count >= 2 else { return }
        let raw = content ?? ""
        let text = try JavaStrings.trimAllWhitespace(raw, work: cancellation)
        let topIndex = tagstack.count - 1
        let top = tagstack[topIndex].name
        let second = try secondTag().name
        var textElement: SyndElement?
        if Self.isAtomText(top) {
            guard tagstack[topIndex].atom else { throw ParityParseError.parserException }  // only Atom's own elements are AtomText
            tagstack[topIndex].content = text
            textElement = tagstack[topIndex]
        }
        if top.is("id") {
            if second.is("feed") {
                feed.identifier = raw
            } else if second.is("entry"), let current {
                items[current].guid = raw
            }
        } else if top.is("title"), let textElement {
            if second.is("feed") {
                feed.title = try processed(textElement)
            } else if second.is("entry"), let current {
                items[current].title = try processed(textElement)
            }
        } else if top.is("subtitle") && second.is("feed"), let textElement {
            feed.description = try processed(textElement)
        } else if top.is("content") && second.is("entry"), let textElement, let current {
            setDescriptionIfLonger(current, try processed(textElement))
        } else if top.is("summary") && second.is("entry"), let textElement, let current {
            setDescriptionIfLonger(current, try processed(textElement))
        } else if top.is("updated") && second.is("entry"), let current, items[current].pubDate == nil {
            items[current].pubDate = try ParityDates.parseOrNullIfFuture(text, now: now, cancellation: cancellation)
        } else if top.is("published") && second.is("entry"), let current {
            items[current].pubDate = try ParityDates.parseOrNullIfFuture(text, now: now, cancellation: cancellation)
        } else if top.is("logo") && feed.imageURL == nil {
            feed.imageURL = text
        } else if top.is("icon") {
            feed.imageURL = text
        } else if top.is("name") && second.is("author") && current == nil {
            addFeedAuthor(text)
        }
    }
}
