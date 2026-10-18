import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct CredentialOriginTests {
    enum Client: CaseIterable, Sendable { case feed, media }

    @Test(arguments: Client.allCases, [false, true])
    func crossOriginChallengeNeverReceivesSavedOrEmbeddedCredentials(client: Client, authenticateFirst: Bool) async throws {
        for embedded in [false, true] {
            let target = try await LoopbackHTTPServer.start { _ in
                .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Same name is not shared authority\""], body: Data())
            }
            defer { target.stop() }
            // Redirect-supplied userinfo must not become URLSession credentials either.
            var redirect = try #require(URLComponents(url: target.url, resolvingAgainstBaseURL: false))
            redirect.user = "untrusted"; redirect.password = "redirect"
            let targetAddress = try #require(redirect.string)
            let source = try await LoopbackHTTPServer.start { request in
                if authenticateFirst && request.headers["authorization"] == nil {
                    return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Same name is not shared authority\""], body: Data())
                }
                return .init(status: 302, headers: ["Location": targetAddress], body: Data())
            }
            defer { source.stop() }
            var address = try #require(URLComponents(url: source.url, resolvingAgainstBaseURL: false))
            if embedded { address.user = "é"; address.password = "£" }
            let input = try #require(address.string)
            let credentials = FeedCredentials(username: embedded ? "ignored" : "é", password: embedded ? "ignored" : "£")
            switch client {
            case .feed:
                await #expect(throws: FeedFetchError.unauthorized) {
                    try await FeedFetcher().fetch(.init(source: input, credentials: credentials))
                }
            case .media:
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialOrigin-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let file = root.appendingPathComponent("episode")
                let partial = Data("previous partial media".utf8)
                try partial.write(to: file)
                await #expect(throws: MediaDownloadError.httpStatus(401)) {
                    try await MediaDownloadTransfer().download(.init(source: input, destination: file, credentials: credentials))
                }
                #expect(try Data(contentsOf: file) == partial)
            }
            #expect(source.requests.map { $0.headers["authorization"] } == (authenticateFirst ? [nil, "Basic 6Tqj"] : [nil]))
            #expect(target.requests.map { $0.headers["authorization"] } == [nil])
            #expect(target.requests.allSatisfy { $0.path == "/feed" })
        }
    }
}
