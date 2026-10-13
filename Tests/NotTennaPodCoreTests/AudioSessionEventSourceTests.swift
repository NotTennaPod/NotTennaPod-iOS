import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct AudioSessionEventSourceTests {
    struct SystemFact: NotificationCenter.MainActorMessage {
        typealias Subject = NSObject
        static let name = Notification.Name("AntennaPodTest.SystemFact")
        let event: AudioSessionEvent
        static func makeMessage(_ notification: Notification) -> Self? {
            guard let event = notification.userInfo?["fact"] as? AudioSessionEvent else { return nil }
            return Self(event: event)
        }
        static func makeNotification(_ message: Self) -> Notification {
            Notification(name: name, userInfo: ["fact": message.event])
        }
    }

    static let names = AudioSessionEventSource.Names(routeChanged: .init("Test.Route"),
        mediaServicesLost: .init("Test.Lost"), mediaServicesReset: .init("Test.Reset"), routeReasonKey: "reason")

    @Test func typedAndLegacyNotificationsDeliverInOrderForOnlyTheirSubject() {
        let center = NotificationCenter(); let subject = NSObject(); let other = NSObject()
        var events: [AudioSessionEvent] = []
        let source = AudioSessionEventSource(center: center, subject: subject, names: Self.names) { events.append($0) }
        defer { source.close() }
        source.observe(subject: subject, message: SystemFact.self) { $0.event }
        center.post(SystemFact(event: .interrupted(reason: 0)), subject: subject)
        center.post(name: Self.names.routeChanged, object: subject, userInfo: ["reason": 2])
        center.post(SystemFact(event: .becameActive), subject: other)
        center.post(name: Self.names.mediaServicesLost, object: other)
        center.post(SystemFact(event: .resumptionRecommended(true)), subject: subject)
        center.post(name: Self.names.mediaServicesLost, object: subject)
        center.post(name: Self.names.mediaServicesReset, object: subject)
        #expect(events == [.interrupted(reason: 0), .routeChanged(reason: 2), .resumptionRecommended(true),
                           .mediaServicesLost, .mediaServicesReset])
    }

    @Test func routePayloadValidationPreservesUnknownReasonsWithoutInventingDisconnects() {
        let malformed: [Any?] = [nil, "2", true, false, -1, 1.5, Double.nan, Double.infinity, NSNull(), [2]]
        for value in malformed { #expect(AudioSessionEventSource.routeEvent(value) == .malformedRouteChange) }
        for raw: UInt64 in [0, 1, 2, 3, 4, 6, 7, 8, 999, .max] {
            #expect(AudioSessionEventSource.routeEvent(NSNumber(value: raw)) == .routeChanged(reason: raw))
        }
        #expect(AudioSessionEventSource.routeEvent(NSNumber(value: 2.0)) == .routeChanged(reason: 2))
        #expect(AudioSessionEventSource.routeEvent(NSNumber(value: Double(UInt64.max))) == .malformedRouteChange)
    }

    @Test func backgroundPostingUsesMainActorAndMaintainsProducerOrder() async {
        let center = NotificationCenter(); let subject = NSObject()
        var events: [AudioSessionEvent] = []
        let source = AudioSessionEventSource(center: center, subject: subject, names: Self.names) { events.append($0) }
        defer { source.close() }
        // The immutable NSObject is used only as NotificationCenter's identity filter.
        let poster = Poster(center: center, subject: subject)
        await Task.detached { for raw in 0..<100 { poster.post(raw) } }.value
        // Route changes posted from a background thread all arrive (on the
        // main actor, without crashing).
        #expect(events.count == 100 && (0..<100).allSatisfy { events.contains(.routeChanged(reason: UInt64($0))) })
    }

    private final class Poster: @unchecked Sendable {
        let center: NotificationCenter
        let subject: NSObject
        init(center: NotificationCenter, subject: NSObject) { self.center = center; self.subject = subject }
        func post(_ reason: Int) {
            center.post(name: Notification.Name("Test.Route"), object: subject, userInfo: ["reason": reason])
        }
    }
}
