import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Probe: does a background URLSession send a media download through the
/// configured proxy, as every Android download does (AntennapodHttpClient.java:83–95)? Uses the owned
/// loopback proxy fixture (`serve-proxy-protocol-fixture.py`, HTTP 18790 with Basic proxy credentials,
/// SOCKSv5 18791); start it with `Tools/test-fixtures.sh start` first. The fixture report
/// (`.work/test-fixtures/proxy-report.json` in this checkout) is the record of which bytes went
/// through the proxy; the observed result is noted below.
@Suite(.serialized, .timeLimit(.minutes(2))) struct BackgroundProxyProbeTests {
    private final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let proxy: PodcastProxy
        let result = Mutex<(status: Int?, bytes: Int64?, error: String?, proxyChallenges: Int)>((nil, nil, nil, 0))
        let done = Mutex<CheckedContinuation<Void, Never>?>(nil)
        init(proxy: PodcastProxy) { self.proxy = proxy }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value
            result.withLock { $0.status = (downloadTask.response as? HTTPURLResponse)?.statusCode; $0.bytes = size }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.isProxy() {
                result.withLock { $0.proxyChallenges += 1 }
                completionHandler(.useCredential, proxy.credential(for: challenge))
            } else { completionHandler(.performDefaultHandling, nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { result.withLock { $0.error = String(describing: error) } }
            done.withLock { $0?.resume(); $0 = nil }
        }
    }

    private func run(_ proxy: PodcastProxy, url: String, preemptive: Bool = false) async throws -> (status: Int?, bytes: Int64?, error: String?, proxyChallenges: Int) {
        let configuration = URLSessionConfiguration.background(withIdentifier: "org.nottennapod.app.probe.\(UUID().uuidString)")
        configuration.urlCredentialStorage = nil
        try proxy.apply(to: configuration, scheme: URL(string: url)!.scheme!)
        let delegate = Delegate(proxy: proxy)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        await withCheckedContinuation { continuation in
            delegate.done.withLock { $0 = continuation }
            var request = URLRequest(url: URL(string: url)!)
            if preemptive, let username = proxy.username, let password = proxy.password {
                request.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false),
                                 forHTTPHeaderField: "Proxy-Authorization")
            }
            session.downloadTask(with: request).resume()
        }
        return delegate.result.withLock { $0 }
    }

    /// Observed 2026-09-28 (iOS 27.0 Simulator): the request reaches the proxy, but its 407 challenge is
    /// not offered to a background session's delegate; the task completes with the 407 response.
    @Test func httpProxyChallengeIsNotDeliveredToBackgroundSession() async throws {
        let proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: 18790, username: "fixture-user", password: "fixture-secret")
        let result = try await run(proxy, url: "http://proxy-feed.invalid/episode.mp3?session=m29-p1")
        print("M29-P1 http: \(result)")
        #expect(result.status == 407 && result.proxyChallenges == 0, "\(result)")
    }

    /// A plain-HTTP request that already carries the proxy credentials is accepted by the proxy.
    @Test func httpProxyAcceptsPreemptiveProxyAuthorizationInBackgroundSession() async throws {
        let proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: 18790, username: "fixture-user", password: "fixture-secret")
        let result = try await run(proxy, url: "http://proxy-feed.invalid/episode.mp3?session=m29-p1b", preemptive: true)
        print("M29-P1 http preemptive: \(result)")
        #expect(result.status == 200 && (result.bytes ?? 0) > 0, "\(result)")
    }

    @Test func httpsThroughAuthenticatedConnectProxyInBackgroundSession() async throws {
        let proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: 18790, username: "fixture-user", password: "fixture-secret")
        let result = try await run(proxy, url: "https://www.example.com/")
        print("M29-P1 https connect: \(result)")
        #expect(result.status == 200 && (result.bytes ?? 0) > 0, "\(result)")
    }

    @Test func socksProxyCarriesBackgroundDownload() async throws {
        let proxy = PodcastProxy(kind: .socks, host: "127.0.0.1", port: 18791, username: "fixture-user", password: "fixture-secret")
        let result = try await run(proxy, url: "https://www.example.com/")
        print("M29-P1 socks: \(result)")
        #expect(result.status == 200 && (result.bytes ?? 0) > 0, "\(result)")
    }
}
