import Foundation

public struct FeedFetchRequest: Sendable {
    public var source: String
    public var validator: String?
    public var credentials: FeedCredentials?
    public var force: Bool
    /// Remote refresh creates fallback artwork; initial online preview preserves the parsed image.
    public var generateMissingArtwork: Bool
    /// The online feed page: documents that are not feeds throw `FeedDocumentError` with the
    /// body, so websites can be searched for feed links; parser failures carry their message.
    public var classifiesDocuments: Bool
    /// A server library's refresh: the parity parse, which also gives the record-level
    /// parse (`FetchedFeed.catalog`). The app's parser otherwise.
    public var parity: Bool

    public init(source: String, validator: String? = nil, credentials: FeedCredentials? = nil, force: Bool = false,
                generateMissingArtwork: Bool = true, classifiesDocuments: Bool = false, parity: Bool = false) {
        self.source = source
        self.validator = validator
        self.credentials = credentials
        self.force = force
        self.generateMissingArtwork = generateMissingArtwork
        self.classifiesDocuments = classifiesDocuments
        self.parity = parity
    }
}

public struct FetchedFeed: Sendable, Equatable {
    public var feed: ParsedFeed
    public var source: String
    public var responseURL: URL
    public var validator: String?
    public var permanentRedirectURL: String?
    /// The parse at record level, which a server library observes and identifies items by (PROTOCOL §9.4); nil when
    /// the fetch did not make one (the store then maps `feed`).
    public var catalog: ServerCatalogParse? = nil

    public var proposedSourceUpdate: String? { permanentRedirectURL ?? feed.redirectURL }
}

public enum FeedFetchResult: Sendable, Equatable {
    case notModified
    case updated(FetchedFeed)
}

public enum FeedFetchError: Error, Sendable, Equatable, Codable {
    case malformedURL
    case unauthorized
    case forbidden
    case notFound(status: Int)
    case httpStatus(Int)
    case tooManyRedirects
    case connection
    case unknownHost
    case certificate
    case blocked
    case io(code: Int?)
    case wrongSize(expected: Int64, received: Int64)
    case unsupportedFeed
    case websiteInsteadOfFeed
    case parsing(FeedParsingError)
    case missingFeedTitle
    case missingEpisodeTitle(index: Int)
}

public struct FeedFetcher: Sendable {
    private let transport: any FeedHTTPTransport
    private let userAgent: String
    private let clock: @Sendable () -> Date
    private let parityDeadline: Duration

    /// The server's fetch bounds (`S/internal/feed/fetch.go`), a server library's fetches' too: a body of at most
    /// 64 MiB, and one deadline for the fetch and its parse (`FetchLimit`, 120 s).
    public static let serverBodyLimit = 64 << 20
    public static let serverFetchLimit = Duration.seconds(120)

    public init(transport: any FeedHTTPTransport = URLSessionFeedTransport(), userAgent: String = HTTPUserAgent.unversioned,
                clock: @escaping @Sendable () -> Date = { Date() }, parityDeadline: Duration = FeedFetcher.serverFetchLimit) {
        self.transport = transport
        self.userAgent = userAgent
        self.clock = clock
        self.parityDeadline = parityDeadline
    }

    public func fetch(_ input: FeedFetchRequest,
                      failureDiagnostic: @escaping @Sendable (String) -> Void = { _ in }) async throws -> FeedFetchResult {
        try Task.checkCancellation()
        guard input.parity else { return try await fetchOnce(input, failureDiagnostic: failureDiagnostic) }
        // A server library's fetch and parse share the server's deadline: cancellation reaches the parse when it
        // passes, whatever the feed (Task.isCancelled alone never fires on a slow feed).
        let deadline = parityDeadline
        return try await withThrowingTaskGroup(of: FeedFetchResult?.self) { group in
            group.addTask { try await fetchOnce(input, failureDiagnostic: failureDiagnostic) }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let result = first else {
                failureDiagnostic(Self.timeLimit)
                throw FeedFetchError.parsing(.limitExceeded(Self.timeLimit))
            }
            return result
        }
    }

    static let timeLimit = "time_limit: the feed was not fetched and read within 120 seconds"
    static let sizeLimit = "size_limit: the feed is larger than 64 MiB"

    private func fetchOnce(_ input: FeedFetchRequest, failureDiagnostic: @Sendable (String) -> Void) async throws -> FeedFetchResult {
        try Task.checkCancellation()
        let original: URL
        do { original = try FeedAddress.requestURL(input.source) }
        catch { throw FeedFetchError.malformedURL }
        let credentials = credentials(for: original, fallback: input.credentials)
        guard var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            throw FeedFetchError.malformedURL
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        guard let url = components.url else { throw FeedFetchError.malformedURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        // OkHttp (Android) asks only for gzip. URLSession would otherwise advertise `br`/`deflate`, and some
        // servers answer Brotli feeds that Android never receives.
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if original.scheme == "http" { request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests") }
        if !input.force, let validator = input.validator, !validator.isEmpty {
            if let date = FeedDateParser().parse(validator) {
                if date > clock().addingTimeInterval(-3 * 24 * 60 * 60) {
                    request.setValue(validator, forHTTPHeaderField: "If-Modified-Since")
                }
            } else { request.setValue(validator, forHTTPHeaderField: "If-None-Match") }
        }
        let scopedTransport = try transport.requestScope()
        let bodyLimit = input.parity ? Self.serverBodyLimit : nil
        var responses = try await followingRedirects(request, transport: scopedTransport, bodyLimit: bodyLimit, failureDiagnostic: failureDiagnostic)
        for utf8 in [false, true] {
            guard let challenge = responses.last, challenge.status == 401, let credentials,
                  HTTPOrigin.matches(url, challenge.url) else { break }
            request.url = challenge.url
            request.setValue(credentials.authorization(utf8: utf8), forHTTPHeaderField: "Authorization")
            responses = try await followingRedirects(request, transport: scopedTransport, bodyLimit: bodyLimit, failureDiagnostic: failureDiagnostic)
        }
        try Task.checkCancellation()
        let response = responses.last!
        if response.status == 304 { return .notModified }
        switch response.status {
        case 200..<300: break
        case 401: throw FeedFetchError.unauthorized
        case 403: throw FeedFetchError.forbidden
        case 404, 410: throw FeedFetchError.notFound(status: response.status)
        default: throw FeedFetchError.httpStatus(response.status)
        }
        // Content-Length counts the encoded bytes; URLSession hands over the decoded body, so only an
        // unencoded (identity) body can be compared with it.
        let encoding = response.header("Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if encoding.isEmpty || encoding == "identity",
           let expected = FeedValueParsing.integer(response.header("Content-Length")), expected >= 0,
           Int64(response.body.count) != expected {
            throw FeedFetchError.wrongSize(expected: expected, received: Int64(response.body.count))
        }
        if input.classifiesDocuments, case .unsupported(let root, let message) = FeedDocumentClassifier.classify(response.body) {
            throw FeedDocumentError.unsupported(root: root, message: message, body: response.body)
        }
        // A server library's feed is what the parity parse reads (its refreshes and the server read the same); the
        // subscribe flow words a document it cannot read as it always has, with the app's parser below, and never
        // succeeds with it where the parity parse refused.
        var parityRefusal: ParityParseError?
        if input.parity {
            do {
                let parity = try ParityFeedParser.parse(response.body, source: input.source, now: Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down)))
                try Task.checkCancellation()
                var fetched = FetchedFeed(feed: ParsedFeed(parity: parity), source: input.source, responseURL: response.url,
                                          validator: response.header("Last-Modified") ?? response.header("ETag"),
                                          permanentRedirectURL: permanentRedirect(in: responses))
                fetched.catalog = ServerCatalogParse(parity: parity)
                return .updated(fetched)
            } catch let error as ParityParseError {
                try Task.checkCancellation()
                failureDiagnostic(error.detail ?? error.label)
                guard input.classifiesDocuments else { throw FeedFetchError(parity: error) }
                parityRefusal = error
            }
        }
        var parsed: ParsedFeed
        do { parsed = try FeedParser().parse(response.body, now: clock()) }
        catch let error as FeedParsingError {
            if input.classifiesDocuments { throw FeedDocumentError.broken(message: FeedDocumentClassifier.parserMessage(error)) }
            if case .limitExceeded = error { throw FeedFetchError.parsing(error) }
            // FeedHandler.parseFeed runs TypeGetter before the SAX parser: a document whose first start tag is
            // not rss/feed, that has none, or that cannot be read is a website or an unsupported type rather
            // than a broken feed.
            switch FeedDocumentClassifier.classify(response.body) {
            case .feed: throw FeedFetchError.parsing(error)
            case .unsupported(let root, let message):
                // The log's technical reason is UnsupportedFeedtypeException.getMessage, as FeedParserTask records it.
                failureDiagnostic(message)
                throw root?.lowercased() == "html" ? FeedFetchError.websiteInsteadOfFeed : FeedFetchError.unsupportedFeed
            }
        }
        guard parsed.title != nil else { failureDiagnostic("Feed has no title"); throw FeedFetchError.missingFeedTitle }
        if let index = parsed.episodes.firstIndex(where: { $0.title == nil }) {
            throw FeedFetchError.missingEpisodeTitle(index: index)
        }
        if let parityRefusal { throw FeedDocumentError.broken(message: parityRefusal.detail ?? parityRefusal.label) }
        if input.generateMissingArtwork, parsed.imageURL?.isEmpty != false { parsed.imageURL = GenerativeCoverPattern.artworkPrefix + input.source }
        try Task.checkCancellation()
        return .updated(FetchedFeed(feed: parsed, source: input.source, responseURL: response.url,
                                    validator: response.header("Last-Modified") ?? response.header("ETag"),
                                    permanentRedirectURL: permanentRedirect(in: responses)))
    }

    private func credentials(for url: URL, fallback: FeedCredentials?) -> FeedCredentials? {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let user = parts?.user, !user.isEmpty || parts?.password != nil {
            guard let password = parts?.password else { return nil }
            return FeedCredentials(username: user, password: password)
        }
        guard let fallback, fallback.username?.isEmpty == false || fallback.password?.isEmpty == false else { return nil }
        return fallback
    }

    private func followingRedirects(_ initial: URLRequest, transport: any FeedHTTPTransport, bodyLimit: Int?,
                                    failureDiagnostic: @Sendable (String) -> Void) async throws -> [FeedHTTPResponse] {
        var request = initial
        var responses: [FeedHTTPResponse] = []
        while true {
            try Task.checkCancellation()
            let response: FeedHTTPResponse
            do {
                if let bodyLimit { response = try await transport.send(request, bodyLimit: bodyLimit) }
                else { response = try await transport.send(request) }
            } catch is FeedBodyLimitExceeded {
                failureDiagnostic(Self.sizeLimit)
                throw FeedFetchError.parsing(.limitExceeded(Self.sizeLimit))
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                failureDiagnostic(error.localizedDescription)
                guard let error = error as? URLError else { throw FeedFetchError.io(code: nil) }
                switch error.code {
                case .badURL, .unsupportedURL: throw FeedFetchError.malformedURL
                case .timedOut, .cannotConnectToHost: throw FeedFetchError.connection
                case .cannotFindHost, .dnsLookupFailed: throw FeedFetchError.unknownHost
                case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid: throw FeedFetchError.certificate
                case .appTransportSecurityRequiresSecureConnection: throw FeedFetchError.blocked
                default: throw FeedFetchError.io(code: error.errorCode)
                }
            }
            responses.append(response)
            if response.status == 407 { throw FeedFetchError.io(code: nil) }
            if [408, 503].contains(response.status), responses.dropLast().last?.status != response.status {
                let retryAfter = response.header("Retry-After")
                let immediate = retryAfter.map { !$0.isEmpty && $0.allSatisfy { $0 == "0" } } ?? (response.status == 408)
                if immediate {
                    guard responses.count <= 20 else { throw FeedFetchError.tooManyRedirects }
                    continue
                }
            }
            guard [300, 301, 302, 303, 307, 308].contains(response.status),
                  let location = response.header("Location"),
                  let next = URL(string: location, relativeTo: response.url)?.absoluteURL,
                  ["http", "https"].contains(next.scheme?.lowercased() ?? "") else { return responses }
            guard responses.count <= 20 else { throw FeedFetchError.tooManyRedirects }
            if !HTTPOrigin.matches(response.url, next) { request.setValue(nil, forHTTPHeaderField: "Authorization") }
            guard var components = URLComponents(url: next, resolvingAgainstBaseURL: false) else { return responses }
            components.user = nil
            components.password = nil
            components.fragment = nil
            guard let nextURL = components.url else { return responses }
            request.url = nextURL
        }
    }

    private func permanentRedirect(in responses: [FeedHTTPResponse]) -> String? {
        guard responses.count > 1 else { return nil }
        let first = responses[0]
        let second = responses[1].url.absoluteString
        if [301, 308].contains(first.status) || second == first.url.absoluteString.replacingOccurrences(of: "http://", with: "https://") {
            return second
        }
        return nil
    }
}
