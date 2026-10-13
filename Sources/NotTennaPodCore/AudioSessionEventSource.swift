import CoreFoundation
import Foundation
#if os(iOS)
import AVFAudio
#endif

/// Immutable system facts. Recommendations do not mutate user play intent; the recovery
/// owner must combine them with the source-derived focus policy and current media generation.
enum AudioSessionEvent: Equatable, Sendable {
    case becameActive
    case appDeactivated
    case interrupted(reason: UInt64)
    case resumptionRecommended(Bool)
    case routeChanged(reason: UInt64)
    case mediaServicesLost, mediaServicesReset
    case malformedRouteChange, unsupportedSystemMessage
}

/// Retains observations for one audio-session subject. Delivery is synchronous on MainActor
/// across typed and route/service messages, without independent per-notification Tasks.
@MainActor final class AudioSessionEventSource {
    struct Names: Sendable {
        let routeChanged: Notification.Name
        let mediaServicesLost: Notification.Name
        let mediaServicesReset: Notification.Name
        let routeReasonKey: String
    }
    private let center: NotificationCenter
    private var rawTokens: [any NSObjectProtocol] = []
    private var typedTokens: [NotificationCenter.ObservationToken] = []
    private var handler: (@MainActor (AudioSessionEvent) -> Void)?
    private(set) var isClosed = false

    init(center: NotificationCenter, subject: NSObject, names: Names,
         handler: @escaping @MainActor (AudioSessionEvent) -> Void) {
        self.center = center
        self.handler = handler
        rawTokens.append(center.addObserver(forName: names.routeChanged, object: subject, queue: .main) { [weak self] notification in
            let event = Self.routeEvent(notification.userInfo?[names.routeReasonKey])
            // NotificationCenter's explicitly selected main operation queue guarantees this
            // executor. Only the immutable event enters it; Notification never crosses a Task.
            MainActor.assumeIsolated { self?.receive(event) }
        })
        for (name, event) in [(names.mediaServicesLost, AudioSessionEvent.mediaServicesLost),
                              (names.mediaServicesReset, AudioSessionEvent.mediaServicesReset)] {
            rawTokens.append(center.addObserver(forName: name, object: subject, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(event) }
            })
        }
    }

    /// Uses Foundation's typed MainActor path both for native iOS 27 messages and host tests.
    func observe<Message: NotificationCenter.MainActorMessage>(subject: Message.Subject, message: Message.Type,
        transform: @escaping @MainActor (Message) -> AudioSessionEvent) where Message.Subject: AnyObject {
        guard !isClosed else { return }
        typedTokens.append(center.addObserver(of: subject, for: message) { [weak self] value in
            self?.receive(transform(value))
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        handler = nil
        for token in rawTokens { center.removeObserver(token) }
        for token in typedTokens { center.removeObserver(token) }
        rawTokens.removeAll()
        typedTokens.removeAll()
    }

    isolated deinit {
        for token in rawTokens { center.removeObserver(token) }
        for token in typedTokens { center.removeObserver(token) }
    }

    private func receive(_ event: AudioSessionEvent) {
        guard !isClosed else { return }
        handler?(event)
    }

    nonisolated static func routeEvent(_ value: Any?) -> AudioSessionEvent {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return .malformedRouteChange }
        let raw = number.uint64Value
        guard number.compare(NSNumber(value: raw)) == .orderedSame else { return .malformedRouteChange }
        // Preserve unknown future reasons instead of treating them as a disconnection.
        return .routeChanged(reason: raw)
    }
}

#if os(iOS)
extension AudioSessionEventSource {
    static func system(session: AVAudioSession = .sharedInstance(), center: NotificationCenter = .default,
                       handler: @escaping @MainActor (AudioSessionEvent) -> Void) -> AudioSessionEventSource {
        let source = AudioSessionEventSource(center: center, subject: session, names: Names(
            routeChanged: AVAudioSession.routeChangeNotification,
            mediaServicesLost: AVAudioSession.mediaServicesWereLostNotification,
            mediaServicesReset: AVAudioSession.mediaServicesWereResetNotification,
            routeReasonKey: AVAudioSessionRouteChangeReasonKey), handler: handler)
        source.observe(subject: session, message: AVAudioSession.DidBecomeActiveMessage.self) { _ in .becameActive }
        source.observe(subject: session, message: AVAudioSession.DidBecomeInactiveMessage.self) { message in
            switch message.deactivationResult {
            case .appDeactivated: return .appDeactivated
            case .systemInterruption(let context): return .interrupted(reason: UInt64(context.reason.rawValue))
            @unknown default: return .unsupportedSystemMessage
            }
        }
        source.observe(subject: session, message: AVAudioSession.ResumptionRecommendationMessage.self) { message in
            switch message.recommendation {
            case .shouldResume: return .resumptionRecommended(true)
            case .shouldNotResume: return .resumptionRecommended(false)
            @unknown default: return .unsupportedSystemMessage
            }
        }
        return source
    }
}
#endif
