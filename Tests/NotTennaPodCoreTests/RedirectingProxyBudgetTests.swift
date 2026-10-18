import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// One byte budget per logical call: every redirect hop and every hidden proxy-login retry draws on it, charged as
/// the body arrives.
@Suite struct RedirectingProxyBudgetTests {
    private static let mib = 1024 * 1024
    private static let login = "Basic " + Data("proxy:secret".utf8).base64EncodedString()

    private static func challenge(_ size: Int) -> LoopbackHTTPServer.Response {
        .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"proxy\""], body: Data(count: size))
    }

    private static func proxy(_ server: LoopbackHTTPServer, login: Bool = true) -> PodcastProxy {
        login ? .init(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "secret")
              : .init(kind: .http, host: "127.0.0.1", port: server.url.port!)
    }

    private static func path(_ request: LoopbackHTTPServer.Request) -> String { URL(string: request.path)?.path ?? "" }

    /// A proxy asks for its login with a 3 MiB page, the origin then redirects with 1 MiB, the proxy asks again for the
    /// target with 1 MiB: the 5 MiB are spent, so the final body fails instead of being read: at its declared length,
    /// or while it arrives. A 1 MiB final body fits any single hop's 5 MiB, but not the call's.
    @Test(arguments: [(true, 1), (true, 32), (false, 32)])
    func challengeRedirectAndFinalShareOneBudget(declaresLength: Bool, finalMiB: Int) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            let authorized = request.headers["proxy-authorization"] == Self.login
            var response: LoopbackHTTPServer.Response
            switch (Self.path(request), authorized) {
            case ("/start", false): response = Self.challenge(3 * Self.mib)
            case ("/start", true): response = .init(status: 302, headers: ["Location": "/target"], body: Data(count: Self.mib))
            case ("/target", false): response = Self.challenge(Self.mib)
            case ("/target", true): response = .init(headers: ["Content-Type": "text/vtt"], body: Data(count: finalMiB * Self.mib))
            default: response = .init(status: 404, body: Data())
            }
            response.includeAutomaticContentLength = declaresLength
            return response
        }
        defer { server.stop() }
        let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: Self.proxy(server)))
        let budget = FeedTransferBudget(limit: 5 * Self.mib)
        await #expect(throws: FeedBodyLimitExceeded.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "http://transcripts.invalid/start")!), budget: budget)
        }
        #expect(server.requests.map { Self.path($0) } == ["/start", "/start", "/target", "/target"])
        // Declared, nothing of the final body is read. Undeclared, the transfer stops at the one delivered chunk that
        // crosses the budget: it is counted whole (a single loopback chunk can be several MiB, which is why the total can
        // be well above 5 MiB), and no data arrives after the stop. These are delegate counts, not a byte ceiling on
        // the wire.
#if DEBUG
        let charges = budget.charges
        if declaresLength {
            #expect(budget.consumed == 5 * Self.mib && charges.allSatisfy(\.fits))
        } else {
            let crossing = try #require(charges.last)
            #expect(!crossing.fits && !crossing.afterStop, "the last delivered chunk is the one that crossed the budget")
            #expect(charges.dropLast().allSatisfy { $0.fits && !$0.afterStop }, "no data after the stop")
            #expect(budget.consumed == 5 * Self.mib + crossing.delivered, "consumed \(budget.consumed), crossing \(crossing.delivered)")
        }
#else
        // The per-chunk trace is debug-only; the totals are not.
        #expect(declaresLength ? budget.consumed == 5 * Self.mib : budget.consumed > 5 * Self.mib, "consumed \(budget.consumed)")
#endif
        // The ordinary bounded overload builds the same single budget.
        await #expect(throws: FeedBodyLimitExceeded.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "http://transcripts.invalid/start")!), bodyLimit: 5 * Self.mib)
        }
    }

    /// Redirect bodies count: three 2 MiB redirect pages exhaust a 5 MiB budget before the small final body.
    @Test func redirectBodiesShareTheBudget() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            let path = Self.path(request)
            if path.hasPrefix("/hop-"), let hop = Int(path.dropFirst(5)) {
                return .init(status: 302, headers: ["Location": hop == 2 ? "/final" : "/hop-\(hop + 1)"], body: Data(count: 2 * Self.mib))
            }
            return .init(body: Data(count: 1000))
        }
        defer { server.stop() }
        let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: Self.proxy(server, login: false)))
        await #expect(throws: FeedBodyLimitExceeded.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "http://transcripts.invalid/hop-0")!), bodyLimit: 5 * Self.mib)
        }
        let budget = FeedTransferBudget(limit: 7 * Self.mib)
        let response = try await transport.send(URLRequest(url: URL(string: "http://transcripts.invalid/hop-0")!), budget: budget)
        #expect(response.body.count == 1000 && budget.consumed == 6 * Self.mib + 1000)
    }

    /// The hidden proxy-login retry draws on the same budget as the page that asked for the login.
    @Test func proxyLoginRetrySharesTheBudget() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            request.headers["proxy-authorization"] == Self.login ? .init(body: Data(count: 2 * Self.mib)) : Self.challenge(4 * Self.mib)
        }
        defer { server.stop() }
        let transport = try URLSessionFeedTransport(proxy: Self.proxy(server))
        let url = URL(string: "http://transcripts.invalid/file")!
        await #expect(throws: FeedBodyLimitExceeded.self) { _ = try await transport.send(URLRequest(url: url), bodyLimit: 5 * Self.mib) }
        let budget = FeedTransferBudget(limit: 6 * Self.mib)
        #expect(try await transport.send(URLRequest(url: url), budget: budget).body.count == 2 * Self.mib)
        #expect(budget.consumed == 6 * Self.mib)
    }

    /// `ProxyNetworkEnvironment` (the app's shared client) hands the caller's budget to the real transport, so the
    /// hidden login page is charged too; a test double's compatibility default only sees the final body.
    @Test func sharedClientForwardsTheSameBudget() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            request.headers["proxy-authorization"] == Self.login ? .init(body: Data(count: 10_000)) : Self.challenge(100_000)
        }
        defer { server.stop() }
        let environment = ProxyNetworkEnvironment(configuration: Self.proxy(server))
        let budget = FeedTransferBudget(limit: Self.mib)
        let response = try await environment.send(URLRequest(url: URL(string: "http://transcripts.invalid/file")!), budget: budget)
        #expect(response.body.count == 10_000 && budget.consumed == 110_000)
    }

    /// A chapter picture behind redirects: their pages count against the picture's budget (two 4 MiB redirect pages
    /// and a 128 KiB picture do not fit 5 MiB).
    @Test func chapterPictureRedirectBodiesCountAgainstBudget() async throws {
        let picture = Data((0..<131_072).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) })
        let file = Data(count: 1000) + picture
        let server = try await LoopbackHTTPServer.start { request in
            switch Self.path(request) {
            case "/first.mp3": .init(status: 302, headers: ["Location": "/second.mp3"], body: Data(count: 4 * Self.mib))
            case "/second.mp3": .init(status: 302, headers: ["Location": "/final.mp3"], body: Data(count: 4 * Self.mib))
            case "/final.mp3": .init(headers: ["Content-Type": "audio/mpeg"], body: file)
            default: .init(status: 404, body: Data())
            }
        }
        defer { server.stop() }
        let reader = RemoteChapterMediaReader(proxy: Self.proxy(server, login: false))
        let reference = EmbeddedChapterImage(offset: 1000, length: picture.count)
        await #expect(throws: FeedBodyLimitExceeded.self) {
            _ = try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/first.mp3")!, budget: 5 * Self.mib)
        }
        #expect(try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/final.mp3")!, budget: 5 * Self.mib) == picture)
    }

    /// `completeAfter` still ends a Range-ignored response at the picture after a redirect; every delivered chunk is
    /// charged, including the part of the last one past the picture.
    @Test func completeAfterWithARedirectStopsAtThePictureAndChargesWholeChunks() async throws {
        let file = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) })
        let server = try await LoopbackHTTPServer.start { request in
            Self.path(request) == "/moved" ? .init(status: 302, headers: ["Location": "/file"], body: Data(count: 500)) : .init(body: file)
        }
        defer { server.stop() }
        let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: Self.proxy(server, login: false)))
        let budget = FeedTransferBudget(limit: 1500)
        let response = try await transport.send(URLRequest(url: URL(string: "http://chapter-media.invalid/moved")!), budget: budget) { status in
            status == 200 ? 1000 : nil
        }
        #expect(response.status == 200 && response.body.count >= 1000 && response.body == file.prefix(response.body.count))
        #expect(budget.consumed > 1500, "the redirect page and the whole delivered chunk: \(budget.consumed)")
        // One byte more than the budget left after the redirect page refuses at the headers.
        await #expect(throws: FeedBodyLimitExceeded.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "http://chapter-media.invalid/moved")!),
                                         bodyLimit: 1500) { $0 == 200 ? 1001 : nil }
        }
    }

    /// A send without a limit (HEAD resolution, feed refresh) reads everything, across redirects, as before.
    @Test func unlimitedSendIsUnchanged() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            Self.path(request) == "/moved" ? .init(status: 302, headers: ["Location": "/file"], body: Data(count: 1000))
                                           : .init(body: Data(count: 7 * Self.mib + 1))
        }
        defer { server.stop() }
        let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: Self.proxy(server, login: false)))
        let response = try await transport.send(URLRequest(url: URL(string: "http://transcripts.invalid/moved")!))
        #expect(response.status == 200 && response.body.count == 7 * Self.mib + 1)
    }

    /// The budget's own rule: a charge past the limit fails, the bytes still count; a response that completes early
    /// needs only its prefix to fit.
    @Test func budgetChargesDeliveredBytesAndFailsPastItsLimit() throws {
        let budget = FeedTransferBudget(limit: 100)
        try budget.charge(60)
        #expect(budget.remaining == 40)
        try budget.charge(50, needed: 40)
        #expect(budget.consumed == 110 && budget.remaining == 0)
        #expect(throws: FeedBodyLimitExceeded.self) { try budget.charge(1) }
        #expect(budget.consumed == 111)
    }

    /// A test double without a delegate reads the whole body, then charges it to the shared budget.
    @Test func compatibilityDefaultChargesTheReturnedBody() async throws {
        struct Double: FeedHTTPTransport {
            func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
                .init(url: request.url!, status: 200, body: Data(count: 300))
            }
        }
        let budget = FeedTransferBudget(limit: 500)
        _ = try await Double().send(URLRequest(url: URL(string: "http://double.invalid/")!), budget: budget)
        #expect(budget.consumed == 300)
        await #expect(throws: FeedBodyLimitExceeded.self) {
            _ = try await Double().send(URLRequest(url: URL(string: "http://double.invalid/")!), budget: budget)
        }
    }
}
