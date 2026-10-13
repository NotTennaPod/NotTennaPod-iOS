import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct ReceiverNetworkRouteTests {
    @Test(arguments: ["127.0.0.1", "::1"]) func routeChoosesMatchingLocalAddress(address: String) async throws {
        let endpoint = try await ReceiverNetworkRoute.endpoint(address: address, port: 8009)
        #expect(endpoint == (try .receiver(address: address)))
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("route".utf8)) }
        defer { server.stop() }
        let relay = try await NativeStreamingRelay.start(url: server.url, playlist: false, proxy: .init(), endpoint: endpoint)
        defer { relay.cancel() }
        let (body, _) = try await URLSession.shared.data(from: relay.url)
        #expect(body == Data("route".utf8))
    }
    @Test func invalidReceiverAndCancelledLookupFail() async throws {
        for address in ["receiver.invalid", "0.0.0.0", "::", "224.0.0.1"] {
            await #expect(throws: (any Error).self) { _ = try await ReceiverNetworkRoute.endpoint(address: address, port: 8009) }
        }
        await #expect(throws: (any Error).self) { _ = try await ReceiverNetworkRoute.endpoint(address: "127.0.0.1", port: 0) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ReceiverNetworkRoute.endpoint(address: "127.0.0.1", port: 8009)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    }
}
