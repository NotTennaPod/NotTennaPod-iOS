import AVFoundation
import Foundation
import Synchronization

/// One admitted playback load's credentials. Redirects and playlist resources
/// cannot grant a different server access to the original media server's login.
struct PlaybackHTTPAuthentication: Sendable {
    let origin: URL
    let credentials: FeedCredentials

    init?(url: URL, credentials: FeedCredentials?) {
        guard let credentials, let user = credentials.username, !user.isEmpty,
              let password = credentials.password, !password.isEmpty,
              HTTPOrigin.matches(url, url) else { return nil }
        origin = url; self.credentials = credentials
    }

    var authorization: String { credentials.authorization(utf8: false) }

    func accepts(_ space: URLProtectionSpace) -> Bool {
        guard !space.isProxy(), space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
              let scheme = space.protocol?.lowercased(), scheme == origin.scheme?.lowercased(),
              space.host.lowercased() == origin.host?.lowercased() else { return false }
        return space.port == (origin.port ?? (scheme == "https" ? 443 : 80))
    }
}

/// Supported AVFoundation authentication hook for its native playlist/open-ended
/// loader. No shared credential storage, URL user-info or private asset options.
final class NativePlaybackAuthentication: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    private let authentication: PlaybackHTTPAuthentication
    private let cancelled = Mutex(false)
    private let onFailure: @Sendable (Error) -> Void
    let queue = DispatchQueue(label: "AntennaPod.NativePlaybackAuthentication")

    init(_ authentication: PlaybackHTTPAuthentication, onFailure: @escaping @Sendable (Error) -> Void) {
        self.authentication = authentication; self.onFailure = onFailure
    }
    func cancel() { cancelled.withLock { $0 = true } }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForResponseTo challenge: URLAuthenticationChallenge) -> Bool {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { return false }
        let rejected = !authentication.accepts(challenge.protectionSpace) || challenge.previousFailureCount > 0
        let wasCancelled = cancelled.withLock { value in
            let previous = value
            if rejected { value = true }
            return previous
        }
        guard !wasCancelled, !rejected else {
            challenge.sender?.cancel(challenge)
            // AVFoundation can keep an HLS item unknown and retry its playlist
            // after a rejected segment challenge. Report the definitive auth
            // failure once so the application can end preparation and offer retry.
            if !wasCancelled { onFailure(URLError(.userAuthenticationRequired)) }
            return true
        }
        let login = authentication.credentials
        challenge.sender?.use(URLCredential(user: login.username!, password: login.password!, persistence: .none),
                              for: challenge)
        return true
    }
}
