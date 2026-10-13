import Foundation

public enum FeedParsingError: Error, Equatable, Codable, Sendable {
    case unsupportedRoot(String)
    case unsupportedRSSVersion(String)
    case malformedXML(line: Int, column: Int)
    case invalidText
    /// Android's `XmlStreamReader` cannot read the document (an unknown declared encoding); Android then
    /// classifies it as a website.
    case unreadableEncoding(String)
    /// A hostile structure or the parse time limit; shown as a broken feed.
    case limitExceeded(String)
}

public struct FeedParser: Sendable {
    /// Every parse ends within this time; a document still unparsed by then is reported as broken
    /// instead of holding up a refresh. Real feeds parse in well under a second.
    public var timeLimit: Duration

    public init(timeLimit: Duration = .seconds(60)) { self.timeLimit = timeLimit }

    public func parse(_ data: Data, now: Date = Date()) throws -> ParsedFeed {
        let deadline = ContinuousClock.now + timeLimit
        // Decode like Android's XmlStreamReader, then parse those characters.
        let text: String
        do { text = try AndroidXMLStreamDecoding.decode(data) }
        catch let failure as AndroidXMLStreamDecoding.Failure { throw FeedParsingError.unreadableEncoding(failure.message) }
        let document = AndroidXMLStreamDecoding.utf8Document(text)
        try XMLHostileStructureGuard.check(document)
        let handler = FeedXMLHandler(now: now, deadline: deadline)
        let parser = XMLParser(data: document)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = handler
        let succeeded = parser.parse()
        if let error = handler.failure { throw error }
        guard succeeded, parser.parserError == nil, handler.hasRoot else {
            throw FeedParsingError.malformedXML(line: parser.lineNumber, column: parser.columnNumber)
        }
        return handler.feed
    }
}

private final class FeedXMLHandler: NSObject, XMLParserDelegate {
    enum Namespace {
        case rss, atom, itunes, content, dc, media, chapters, podcast
    }

    struct Element {
        var name: String
        var type: String?
    }

    var feed = ParsedFeed(format: .rss)
    var hasRoot = false
    var failure: FeedParsingError?
    private let now: Date
    private let dates = FeedDateParser()
    private var defaults: [Namespace] = [.rss]
    private var namespaces: [String: Namespace] = [:]
    private var stack: [Element] = []
    private var text: String?
    private var currentIndex: Int?
    private var fundingIndex: Int?
    private var pendingDuration: Int32?
    private var boundPrefixes: [String: Int] = [:]
    private let deadline: ContinuousClock.Instant
    private var callbacks = 0

    init(now: Date, deadline: ContinuousClock.Instant) { self.now = now; self.deadline = deadline }

    /// Checked every 1,024 parser callbacks: past the deadline the parse stops as a broken feed.
    private func checkDeadline(_ parser: XMLParser) {
        callbacks &+= 1
        guard callbacks & 1023 == 0, failure == nil, ContinuousClock.now >= deadline else { return }
        failure = .limitExceeded("The feed took too long to read")
        parser.abortParsing()
    }

    private var current: ParsedEpisode? {
        get { currentIndex.map { feed.episodes[$0] } }
        set {
            if let currentIndex, let newValue { feed.episodes[currentIndex] = newValue }
        }
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
        boundPrefixes[prefix, default: 0] += 1
        guard namespaces[uri] == nil else { return }
        switch (uri, prefix) {
        case ("http://www.w3.org/2005/Atom", ""): defaults.append(.atom)
        case ("http://www.w3.org/2005/Atom", "atom"): namespaces[uri] = .atom
        case ("http://www.itunes.com/dtds/podcast-1.0.dtd", "itunes"): namespaces[uri] = .itunes
        case ("http://purl.org/rss/1.0/modules/content/", "content"): namespaces[uri] = .content
        case ("http://purl.org/dc/elements/1.1/", "dc"): namespaces[uri] = .dc
        case ("http://search.yahoo.com/mrss/", "media"): namespaces[uri] = .media
        case ("http://podlove.org/simple-chapters", "psc"), ("http://podlove.org/simple-chapters", "sc"):
            namespaces[uri] = .chapters
        case ("https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md", _),
             ("https://podcastindex.org/namespace/1.0", "podcast"):
            namespaces[uri] = .podcast
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        if let count = boundPrefixes[prefix] { boundPrefixes[prefix] = count > 1 ? count - 1 : nil }
        if prefix.isEmpty, defaults.count > 1 { defaults.removeLast() }
    }

    /// Android's parser (Expat with namespace processing) stops at a prefix no enclosing element declares
    /// ("unbound prefix"); Apple's parser only skips the element. Such a feed is broken on both.
    private func unboundPrefix(_ qualifiedName: String?, attributes: [String: String]) -> Bool {
        func unbound(_ name: String) -> Bool {
            guard let colon = name.firstIndex(of: ":") else { return false }
            let prefix = String(name[..<colon])
            return prefix != "xml" && prefix != "xmlns" && boundPrefixes[prefix] == nil
        }
        return qualifiedName.map(unbound) == true || attributes.keys.contains(where: unbound)
    }

    private func namespace(uri: String?, qualifiedName: String) -> Namespace? {
        if let uri, let handler = namespaces[uri] { return handler }
        return qualifiedName.contains(":") ? nil : defaults.last
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        checkDeadline(parser)
        guard failure == nil else { return }
        if unboundPrefix(qName, attributes: attributes) {
            failure = .malformedXML(line: parser.lineNumber, column: parser.columnNumber)
            parser.abortParsing()
            return
        }
        if !hasRoot {
            hasRoot = true
            switch elementName {
            case "rss":
                if let version = attributes["version"], !["2.0", "0.91", "0.92"].contains(version) {
                    failure = .unsupportedRSSVersion(version)
                    parser.abortParsing()
                    return
                }
            case "feed":
                feed.format = .atom
                feed.language = attributes["xml:lang"]
                if defaults.first == .rss { defaults.removeFirst() }
            default:
                failure = .unsupportedRoot(elementName)
                parser.abortParsing()
                return
            }
        }
        text = ""
        guard let handler = namespace(uri: namespaceURI, qualifiedName: qName ?? elementName) else { return }
        start(elementName, namespace: handler, attributes: attributes)
        stack.append(Element(name: elementName, type: attributes["type"]))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        checkDeadline(parser)
        if stack.count >= 2, text != nil { text! += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { text = nil }
        checkDeadline(parser)
        guard failure == nil, let handler = namespace(uri: namespaceURI, qualifiedName: qName ?? elementName),
              !stack.isEmpty else { return }
        do {
            try end(elementName, namespace: handler)
        } catch {
            failure = .invalidText
            parser.abortParsing()
        }
        stack.removeLast()
    }

    private func start(_ name: String, namespace: Namespace, attributes a: [String: String]) {
        let parent = stack.last?.name
        switch namespace {
        case .rss:
            if name == "item", parent == "channel" {
                beginEpisode()
            } else if name == "enclosure", parent == "item", current != nil,
                      let url = a["url"], !url.isEmpty {
                let size = FeedValueParsing.integer(a["length"]) ?? 0
                addEnclosure(url: url, type: a["type"], size: size < 16_384 ? 0 : size)
            }
        case .atom:
            if name == "entry" { beginEpisode() }
            if name == "link" { atomLink(a, parent: parent) }
        case .itunes:
            if name == "image" {
                if current != nil { current?.imageURL = a["href"] }
                else if let url = a["href"], !url.isEmpty { feed.imageURL = url }
            }
        case .podcast:
            switch name {
            case "funding":
                fundingIndex = feed.funding.count
                feed.funding.append(FeedFunding(url: a["url"], content: ""))
            case "chapters":
                if let url = a["url"], !url.isEmpty { current?.chapterURL = url }
            case "socialInteract":
                if let url = a["uri"], !url.isEmpty { current?.socialInteractionURL = url }
            case "transcript":
                if let url = a["url"], let type = a["type"] { current?.setTranscript(type: type, url: url) }
            default: break
            }
        case .media: mediaStart(name, attributes: a)
        case .chapters:
            if name == "chapters" { current?.chapters = [] }
            else if name == "chapter", let start = a["start"], !start.isEmpty,
                    let milliseconds = FeedValueParsing.chapterTime(start) {
                current?.chapters?.append(ParsedChapter(
                    startMilliseconds: milliseconds, title: a["title"], link: a["href"], imageURL: a["image"]
                ))
            }
        case .content, .dc: break
        }
    }

    private func beginEpisode() {
        currentIndex = feed.episodes.count
        feed.episodes.append(ParsedEpisode())
    }

    private func finishEpisode(rss: Bool) {
        if rss, current?.title == nil { current?.title = current?.description }
        if let pendingDuration { current?.media?.durationMilliseconds = pendingDuration }
        pendingDuration = nil
        currentIndex = nil
    }

    private func addEnclosure(url: String?, type: String?, size: Int64) {
        guard current != nil, current?.media == nil else { return }
        var mime = FeedMIME.resolve(type, url: url)
        if !FeedMIME.isMedia(mime), !FeedMIME.isImage(mime) { mime = "audio/*" }
        if let mime, FeedMIME.isMedia(mime) { current?.media = ParsedMedia(url: url, size: size, mimeType: mime) }
    }

    private func atomLink(_ a: [String: String], parent: String?) {
        let rel = a["rel"]
        let href = a["href"]
        let type = a["type"]
        if ["entry", "item"].contains(parent ?? ""), current != nil {
            if rel == nil || rel == "alternate" { current?.link = href }
            else if rel == "enclosure" {
                addEnclosure(url: href, type: type, size: FeedValueParsing.integer(a["length"]) ?? 0)
            } else if rel == "payment" { current?.paymentLink = href }
        } else if ["feed", "channel"].contains(parent ?? "") {
            if rel == nil || rel == "alternate" {
                if (type == nil && feed.link == nil) || type == "text/html" || type == "application/xml+xhtml" {
                    feed.link = href
                } else if type == "application/atom+xml" || type == "application/rss+xml" {
                    addAlternate(a)
                }
            } else if rel == "archives", type == "application/atom+xml" || type == "application/rss+xml" {
                addAlternate(a)
            } else if rel == "payment" {
                feed.funding.append(FeedFunding(url: href, content: ""))
            } else if rel == "next" {
                feed.isPaged = true
                feed.nextPageURL = href
            }
        }
    }

    private func addAlternate(_ a: [String: String]) {
        let title = a["title"].flatMap { $0.isEmpty ? nil : $0 } ?? a["href"]
        let alternate = AlternateFeed(title: title, url: a["href"])
        if let index = feed.alternateFeeds.firstIndex(where: { $0.url == a["href"] }) {
            feed.alternateFeeds[index] = alternate
        } else { feed.alternateFeeds.append(alternate) }
    }

    private func mediaStart(_ name: String, attributes a: [String: String]) {
        if name == "thumbnail", let url = a["url"] {
            if current != nil { current?.imageURL = url }
            else if feed.imageURL == nil { feed.imageURL = url }
        } else if name == "content", current != nil {
            let url = a["url"]
            var mime = FeedMIME.resolve(a["type"], url: url)
            var validMedia = false
            var validImage = false
            if a["medium"] == "audio" { validMedia = true; mime = "audio/*" }
            else if a["medium"] == "video" { validMedia = true; mime = "video/*" }
            else if a["medium"] == "image", mime?.hasPrefix("audio/") != true, mime?.hasPrefix("video/") != true {
                validImage = true; mime = "image/*"
            } else if FeedMIME.isMedia(mime) { validMedia = true }
            else if FeedMIME.isImage(mime) { validImage = true }
            else { validMedia = current?.media == nil; mime = "audio/*" }
            if (current?.media == nil || a["isDefault"] == "true"), let url, validMedia, let mime {
                let seconds = FeedValueParsing.integer(a["duration"]) ?? 0
                let duration = Int32(truncatingIfNeeded: FeedValueParsing.saturatedMultiply(seconds, by: 1_000))
                current?.media = ParsedMedia(url: url, size: FeedValueParsing.integer(a["fileSize"]) ?? 0,
                                             mimeType: mime, durationMilliseconds: max(0, duration))
            } else if let url, validImage { current?.imageURL = url }
        }
    }

    private func end(_ name: String, namespace: Namespace) throws {
        if namespace == .rss, name == "item" { finishEpisode(rss: true); return }
        if namespace == .atom, name == "entry" { finishEpisode(rss: false) }
        let parent = stack.dropLast().last?.name
        let grandparent = stack.dropLast(2).last?.name
        let raw = text ?? ""
        let trimmed = FeedValueParsing.trim(raw)
        switch namespace {
        case .rss:
            guard stack.count >= 2, text != nil else { return }
            switch (name, parent) {
            case ("guid", "item"):
                if !raw.isEmpty { current?.identifier = raw }
            case ("title", "item"): current?.title = try FeedValueParsing.htmlText(trimmed, compact: true)
            case ("title", "channel"): feed.title = try FeedValueParsing.htmlText(trimmed, compact: true)
            case ("link", "item"): current?.link = trimmed
            case ("link", "channel"): feed.link = trimmed
            case ("pubDate", "item"): current?.publicationDate = dates.parse(trimmed, now: now)
            case ("url", "image"):
                if grandparent == "channel", feed.imageURL == nil { feed.imageURL = trimmed }
            case ("description", "channel"): feed.description = try FeedValueParsing.htmlText(trimmed, compact: true)
            case ("description", "item"): current?.setDescriptionIfLonger(trimmed)
            case ("language", _): feed.language = trimmed.lowercased(with: Locale(identifier: "en_US"))
            default: break
            }
        case .atom:
            guard stack.count >= 2 else { return }
            let processed: String
            if ["title", "content", "subtitle", "summary"].contains(name), stack.last?.type == "html" {
                processed = try FeedValueParsing.htmlText(trimmed, compact: false)
            } else { processed = trimmed }
            switch (name, parent) {
            case ("id", "feed"): feed.identifier = raw
            case ("id", "entry"): current?.identifier = raw
            case ("title", "feed"): feed.title = processed
            case ("title", "entry"): current?.title = processed
            case ("subtitle", "feed"): feed.description = processed
            case ("content", "entry"), ("summary", "entry"): current?.setDescriptionIfLonger(processed)
            case ("updated", "entry"):
                if current?.publicationDate == nil { current?.publicationDate = dates.parse(trimmed, now: now) }
            case ("published", "entry"): current?.publicationDate = dates.parse(trimmed, now: now)
            case ("logo", _):
                if feed.imageURL == nil { feed.imageURL = trimmed }
            case ("icon", _): feed.imageURL = trimmed
            case ("name", "author"):
                if current == nil { feed.author = feed.author.map { $0 + ", " + trimmed } ?? trimmed }
            default: break
            }
        case .itunes:
            guard !raw.isEmpty else { return }
            switch name {
            case "author":
                if stack.count <= 3 { feed.author = try FeedValueParsing.htmlText(raw, compact: true) }
            case "duration":
                if let duration = FeedValueParsing.duration(raw) { pendingDuration = Int32(truncatingIfNeeded: duration) }
            case "subtitle":
                if current != nil, current?.description?.isEmpty != false { current?.setDescriptionIfLonger(raw) }
                else if feed.description?.isEmpty != false { feed.description = raw }
            case "summary":
                if current != nil { current?.setDescriptionIfLonger(raw) }
                else if parent == "channel" { feed.description = raw }
            case "new-feed-url":
                let url = JavaString.trim(raw)
                if url.hasPrefix("http") { feed.redirectURL = url }
            default: break
            }
        case .content:
            if name == "encoded", text != nil { current?.setDescriptionIfLonger(raw) }
        case .media:
            if name == "description", text != nil { current?.setDescriptionIfLonger(raw) }
        case .dc:
            if name == "date", parent == "item", text != nil { current?.publicationDate = dates.parse(raw, now: now) }
        case .podcast:
            if name == "funding", let fundingIndex, !raw.isEmpty { feed.funding[fundingIndex].content = raw }
        case .chapters: break
        }
    }
}
