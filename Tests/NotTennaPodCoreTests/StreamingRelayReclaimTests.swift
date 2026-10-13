import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The loopback streaming relay is retired when the app becomes eligible for suspension
/// (iOS may defunct a suspended app's sockets) and rebuilt on the next demand; a local
/// connection failure rebuilds it once before the retry budget.
@MainActor @Suite(.serialized) struct StreamingRelayEligibilityTests {
    /// Reconciles as the real participants do: the registry's current lifecycle, each epoch once.
    final class Participant: StreamingRelayReclaimParticipant, @unchecked Sendable {
        private let reclaim: StreamingRelayReclaim
        private let state = Mutex((suspends: 0, resumes: 0, parked: false, epoch: UInt64(0)))
        /// Runs inside the participant's transition before it reads the lifecycle (a delayed callback).
        let beforeReconcile = Mutex<(@Sendable () -> Void)?>(nil)
        init(_ reclaim: StreamingRelayReclaim) { self.reclaim = reclaim }
        var suspends: Int { state.withLock { $0.suspends } }
        var resumes: Int { state.withLock { $0.resumes } }
        var parked: Bool { state.withLock { $0.parked } }
        func reclaimLifecycleChanged() {
            if let delay = beforeReconcile.withLock({ hook in defer { hook = nil }; return hook }) { delay() }
            state.withLock { state in
                let now = reclaim.lifecycle
                guard now.epoch > state.epoch else { return }
                state.epoch = now.epoch
                if now.suspended { if !state.parked { state.parked = true; state.suspends += 1 } }
                else if state.parked { state.parked = false; state.resumes += 1 }
            }
        }
    }

    @Test func backgroundPlaybackIsNeverRetiredAndAPauseThereRetiresUntilRemotePlay() {
        let reclaim = StreamingRelayReclaim(), state = StreamingRelayEligibility(reclaim: reclaim), relay = Participant(reclaim)
        reclaim.register(relay)
        state.setForeground(true); state.setPlaybackActive(true)
        let resumes = relay.resumes
        // Playing, then the phone is locked: working audio keeps its relay.
        state.setForeground(false)
        #expect(!state.isEligible && !reclaim.isSuspended && relay.suspends == 0)
        // Pause from the Lock Screen: no second background transition, but now eligible.
        state.setPlaybackActive(false)
        #expect(state.isEligible && reclaim.isSuspended && relay.suspends == 1 && relay.resumes == resumes)
        // Later state changes while still eligible retire nothing again.
        state.setPlaybackActive(false); state.setForeground(false)
        #expect(relay.suspends == 1)
        // Remote Play with no scene activation is a demand.
        state.setPlaybackActive(true)
        #expect(!reclaim.isSuspended && relay.resumes == resumes + 1 && relay.suspends == 1)
    }

    @Test func repeatedCyclesRetireAndRebuildEachTimeWithANewEpoch() {
        let reclaim = StreamingRelayReclaim(), state = StreamingRelayEligibility(reclaim: reclaim), relay = Participant(reclaim)
        reclaim.register(relay)
        state.setForeground(false)
        var epochs: [UInt64] = []
        for cycle in 1...3 {
            state.setPlaybackActive(false)
            epochs.append(reclaim.epoch)
            #expect(relay.suspends == cycle && relay.resumes == cycle - 1)
            state.setPlaybackActive(true)
            epochs.append(reclaim.epoch)
            #expect(relay.resumes == cycle)
        }
        #expect(epochs == epochs.sorted() && Set(epochs).count == epochs.count)
        #expect(reclaim.suspensions == 3)
    }

    @Test func aSecondForegroundSceneKeepsRelaysOpen() {
        let reclaim = StreamingRelayReclaim(), state = StreamingRelayEligibility(reclaim: reclaim), relay = Participant(reclaim)
        reclaim.register(relay)
        // One window goes to the background while another stays in the foreground (iPad, Duo).
        state.setForeground(true); state.setPlaybackActive(false)
        state.setForeground(true)
        #expect(!state.isEligible && !reclaim.isSuspended && relay.suspends == 0)
        state.setForeground(false)
        #expect(reclaim.isSuspended && relay.suspends == 1)
    }

    @Test func preparingOrBufferingForRequestedPlaybackIsNotEligible() {
        let reclaim = StreamingRelayReclaim(), state = StreamingRelayEligibility(reclaim: reclaim), relay = Participant(reclaim)
        reclaim.register(relay)
        state.setForeground(false); state.setPlaybackActive(false)
        #expect(relay.suspends == 1)
        // A Lock Screen seek of paused audio buffers: the demand rebuilds, buffering keeps it.
        reclaim.demand()
        state.setPlaybackActive(true)
        #expect(!reclaim.isSuspended && relay.resumes >= 1 && relay.suspends == 1)
        // Once the seek lands paused, the app is eligible again.
        state.setPlaybackActive(false)
        #expect(reclaim.isSuspended && relay.suspends == 2)
    }

    @Test func foregroundAloneReopensNothingAndNewRelaysStartNormally() {
        let reclaim = StreamingRelayReclaim(), state = StreamingRelayEligibility(reclaim: reclaim), retired = Participant(reclaim)
        reclaim.register(retired)
        state.setForeground(false); state.setPlaybackActive(false)
        // A relay registered while the app may be suspended starts retired.
        let late = Participant(reclaim)
        reclaim.register(late)
        #expect(late.suspends == 1)
        // Opening the app is not a demand: retired relays stay closed until something needs them.
        state.setForeground(true)
        #expect(!reclaim.isSuspended && retired.resumes == 0 && late.resumes == 0)
        let fresh = Participant(reclaim)
        reclaim.register(fresh)
        #expect(fresh.suspends == 0)
        // Play in the app rebuilds them.
        reclaim.demand()
        #expect(retired.resumes == 1 && late.resumes == 1)
    }

    @Test func relayFailureExplanationNeverAdvisesRedownloading() {
        let failure = StreamingRelayUnavailable(underlying: URLError(.cannotConnectToHost))
        #expect(PlaybackFailureExplanation(details: failure.localizedDescription) == .tryAgain)
        #expect(PlaybackFailureExplanation(details: (failure as NSError).localizedDescription) == .tryAgain)
        #expect(PlaybackFailureExplanation(details: URLError(.cannotConnectToHost).localizedDescription) == .generic)
        #expect(PCMSourceRetry.causes(of: failure) == [.network])
    }
}

/// A seekable episode body: distinct bytes everywhere, so any lost or repeated range is visible.
enum ReclaimFixture {
    static func body(_ count: Int) -> Data {
        var state: UInt64 = 0x2545_f491_4f6c_dd1d, bytes = Data(capacity: count)
        while bytes.count < count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            withUnsafeBytes(of: state) { bytes.append(contentsOf: $0.prefix(count - bytes.count)) }
        }
        return bytes
    }
    /// Ranged responses validated with If-Range; `etag` may change between requests.
    static func ranged(_ body: @escaping @Sendable () -> Data, etag: @escaping @Sendable () -> String = { "\"v1\"" },
                       status: (@Sendable (Int) -> Int?)? = nil, firstLimit: Int? = nil)
        -> @Sendable (LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response? {
        let count = Mutex(0)
        return { request in
            let number = count.withLock { $0 += 1; return $0 }
            if let status = status?(number) { return .init(status: status, headers: ["Content-Type": "audio/mpeg"], body: Data()) }
            let media = body(), tag = etag()
            let start = rangeStart(request) ?? 0
            if start > 0, request.headers["if-range"] == tag {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": tag, "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
            }
            if number == 1, let firstLimit {
                // A response still in flight: its rest never comes on this connection.
                return .init(headers: ["Content-Type": "audio/mpeg", "ETag": tag, "Accept-Ranges": "bytes",
                    "Content-Length": String(media.count)], body: media.prefix(firstLimit), keepConnectionOpen: true,
                    includeAutomaticContentLength: false)
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": tag, "Accept-Ranges": "bytes"], body: media)
        }
    }
    static func rangeStart(_ request: LoopbackHTTPServer.Request) -> Int? {
        request.headers["range"].flatMap { Int($0.dropFirst(6).split(separator: "-").first ?? "") }
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct StreamingRelayReclaimInputTests {
    private func wait(_ condition: () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try condition(), sourceLocation: sourceLocation)
    }
    /// Sequential reads off the cooperative pool, as a decoder's producer reads.
    private func read(_ input: HTTPCodecByteInput, _ range: Range<Int>) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    var data = Data(), offset = range.lowerBound
                    while offset < range.upperBound {
                        let chunk = try input.read(at: Int64(offset), maximumCount: min(16_384, range.upperBound - offset))
                        guard !chunk.isEmpty else { break }
                        data.append(chunk); offset += chunk.count
                    }
                    return data
                })
            }
        }
    }
    private func relayed(_ url: URL, reclaim: StreamingRelayReclaim,
                         retry: PCMSourceRetry) async throws -> (NativeStreamingRelay, HTTPCodecByteInput) {
        let relay = try await NativeStreamingRelay.start(url: url, playlist: false, proxy: PodcastProxy(),
            onFailure: { retry.recordRelayFailure($0) })
        let input = try HTTPCodecByteInput(relay: relay, reclaim: reclaim, sequentialReadAheadBytes: 65_536,
            backing: .memory(capacity: 131_072), retry: retry)
        return (relay, input)
    }

    @Test func socketReclaimRepairsTheRelayOnceAndReadingContinuesWithoutLostOrRepeatedBytes() async throws {
        let media = ReclaimFixture.body(1 << 20)
        // The response is still in flight (its rest has not arrived) when iOS closes the sockets.
        let server = try await LoopbackHTTPServer.start(handler: ReclaimFixture.ranged({ media }, firstLimit: 400_000))
        defer { server.stop() }
        let url = server.url
        let retry = PCMSourceRetry(), reclaim = StreamingRelayReclaim()
        let (relay, input) = try await relayed(url, reclaim: reclaim, retry: retry)
        defer { input.cancel(); relay.cancel() }
        var heard = try await read(input, 0..<300_000)
        // The transfer is held by back pressure when iOS closes the sockets.
        try await wait { input.snapshot().waitingForDemand }
        let generation = relay.generation, oldURL = relay.url
        relay.simulateSocketReclaim()
        heard += try await read(input, 300_000..<media.count)
        #expect(heard == media)
        #expect(relay.generation == generation + 1 && relay.url != oldURL)
        // Repaired before the retry budget: no error was counted.
        #expect(retry.snapshot.errorCount == 0 && retry.currentError == nil && input.snapshot().failure == nil)
        // The rebuilt relay continued the same representation at the transfer's cursor.
        let continued = try #require(server.requests.last)
        #expect(server.requests.count == 2 && continued.headers["if-range"] == "\"v1\"")
        #expect(ReclaimFixture.rangeStart(continued) == 400_000)
    }

    @Test func suspensionParksPendingReadAheadAndNothingReopensUntilDemand() async throws {
        let media = ReclaimFixture.body(1 << 20)
        let server = try await LoopbackHTTPServer.start(handler: ReclaimFixture.ranged({ media }))
        defer { server.stop() }
        let url = server.url
        let retry = PCMSourceRetry(), reclaim = StreamingRelayReclaim()
        let (relay, input) = try await relayed(url, reclaim: reclaim, retry: retry)
        defer { input.cancel(); relay.cancel() }
        var heard = try await read(input, 0..<200_000)
        try await wait { input.snapshot().waitingForDemand }
        let generation = relay.generation
        reclaim.suspend()
        // The listener, its connections and the back-pressured transfer are gone.
        #expect(relay.isRetired && input.snapshot().activeTransfers == 0)
        let kept = try #require(input.snapshot().cachedRanges.last)
        #expect(kept.upperBound > 200_000)
        // Bytes the read-ahead already received are still read, without the network.
        heard += try await read(input, 200_000..<Int(kept.upperBound))
        // Reading further waits; neither it nor read-ahead reopens the relay.
        let rest = Task { try await read(input, Int(kept.upperBound)..<media.count) }
        try await wait { input.isWaitingForData }
        #expect(relay.isRetired && relay.generation == generation && input.snapshot().activeTransfers == 0)
        #expect(server.requests.count == 1)
        // Play: a new listener on a new port, and the parked cursor continues.
        reclaim.demand()
        heard += try await rest.value
        #expect(heard == media)
        #expect(!relay.isRetired && relay.generation == generation + 1)
        #expect(retry.snapshot.errorCount == 0 && input.snapshot().failure == nil)
        #expect(server.requests.count == 2 && ReclaimFixture.rangeStart(server.requests[1]) == Int(kept.upperBound))
    }

    @Test func repeatedLocalFailureIsRepairedOnceThenEndsAsTheRelayBeingUnavailable() async throws {
        let media = ReclaimFixture.body(256 << 10)
        let server = try await LoopbackHTTPServer.start(handler: ReclaimFixture.ranged({ media }))
        defer { server.stop() }
        let url = server.url
        let retry = PCMSourceRetry(sleep: { _ in }), reclaim = StreamingRelayReclaim()
        let (relay, input) = try await relayed(url, reclaim: reclaim, retry: retry)
        defer { input.cancel(); relay.cancel() }
        let generation = relay.generation
        // Every listener, the rebuilt one too, is closed as soon as it opens.
        relay.simulateSocketReclaim(includingReplacements: true)
        let error = await #expect(throws: StreamingRelayUnavailable.self) { try await read(input, 0..<4096) }
        #expect(relay.generation == generation + 1, "one repair per epoch until progress")
        #expect(retry.snapshot.errorCount == 4 && server.requests.isEmpty)
        // Its details never advise deleting and re-downloading the episode.
        #expect(PlaybackFailureExplanation(details: try #require(error).localizedDescription) == .tryAgain)
        #expect(PlaybackFailureExplanation(details: try #require(input.snapshot().failure)) == .tryAgain)
    }

    @Test(arguments: [false, true])
    func upstreamOutageWithAHealthyListenerEndsInTheUsualErrorWithoutRepair(unreachable: Bool) async throws {
        let server = try await LoopbackHTTPServer.start(handler: ReclaimFixture.ranged({ Data() }, status: { _ in 503 }))
        let url = server.url
        if unreachable { server.stop() }
        defer { server.stop() }
        let retry = PCMSourceRetry(sleep: { _ in }), reclaim = StreamingRelayReclaim()
        let (relay, input) = try await relayed(url, reclaim: reclaim, retry: retry)
        defer { input.cancel(); relay.cancel() }
        let generation = relay.generation
        do {
            _ = try await read(input, 0..<4096)
            Issue.record("An outage must end in an error")
        } catch {
            // The upstream outcome, reported through the relay, is the error: never a relay repair.
            if unreachable { #expect((error as? URLError)?.code == .cannotConnectToHost) }
            else { #expect(error as? MediaDownloadError == .httpStatus(503)) }
            #expect(PlaybackFailureExplanation(details: error.localizedDescription) == .generic)
        }
        #expect(relay.generation == generation && !relay.isRetired)
        #expect(retry.snapshot.errorCount == 4)
        if !unreachable { #expect(server.requests.count == 4) }
    }
}

/// A response that stops at each of `holds` in turn (absolute offsets) and keeps its connection open; every
/// later range request is answered in full. Counts the relay's upstream connections it saw close.
final class HeldMediaServer: @unchecked Sendable {
    let media: Data
    private final class Counter: Sendable { let value = Mutex(0) }
    private let disconnects = Counter()
    var closedConnections: Int { disconnects.value.withLock { $0 } }
    private(set) var server: LoopbackHTTPServer!
    init(media: Data, holds: [Int], etag: String = "\"v1\"") async throws {
        self.media = media
        let count = Mutex(0), disconnects = disconnects
        server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnects.value.withLock { $0 += 1 } }) { request in
            let number = count.withLock { $0 += 1; return $0 }
            let start = ReclaimFixture.rangeStart(request) ?? 0
            let stop = number <= holds.count ? holds[number - 1] : media.count
            var headers = ["Content-Type": "audio/mpeg", "ETag": etag, "Accept-Ranges": "bytes",
                           "Content-Length": String(media.count - start)]
            if start > 0 { headers["Content-Range"] = "bytes \(start)-\(media.count - 1)/\(media.count)" }
            return .init(status: start > 0 ? 206 : 200, headers: headers, body: media.subdata(in: start..<max(start, stop)),
                         keepConnectionOpen: stop < media.count, includeAutomaticContentLength: false)
        }
    }
    var url: URL { server.url }
    var requests: [LoopbackHTTPServer.Request] { server.requests }
    func stop() { server.stop() }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(4))) struct StreamingRelayReclaimSourceTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private func fixture(_ name: String, _ directory: String) throws -> Data {
#if SWIFT_PACKAGE
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures" + directory)))
#else
        try Data(contentsOf: #require(Bundle(for: ReclaimFixtures.self).url(forResource: name, withExtension: nil)))
#endif
    }
    private func wait(_ condition: () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try condition(), sourceLocation: sourceLocation)
    }
    /// Presents everything a session writes until it ends; `during` runs once audio is heard.
    private func play(_ factory: PCMRecoveryFactory, outputs: @escaping () -> Transport?,
                      during: (() async throws -> Void)? = nil) async throws -> [Int16] {
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare(); try session.play()
        let output = try #require(outputs())
        let driver = Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(90)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline, !Task.isCancelled {
                if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                await Task.yield()
            }
        }
        defer { driver.cancel() }
        if let during {
            try await wait { !output.buffers.isEmpty }
            try await during()
        }
        await driver.value
        try #require(session.state == .ended && session.failure == nil, "\(String(describing: session.failure))")
        var data = Data()
        for buffer in output.buffers { data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        return PCMTestFixture.samples(data)
    }
    private func factory(_ url: URL, root: URL, reclaim: StreamingRelayReclaim,
                         outputs: @escaping (Transport) -> Void) async throws -> PCMRecoveryFactory {
        let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent(UUID().uuidString), reclaim: reclaim,
            makeTransport: { let output = Transport(); outputs(output); return output })
        return try #require(try await owner.processedIfSupported(url: url, proxy: PodcastProxy(), credentials: nil, userAgent: "test"))
    }

    /// The MP3 source, native ADTS AAC and the bundled decoder (M4A) each continue the same item
    /// after their relay is retired and rebuilt, or after iOS closes its sockets without notice.
    @Test(arguments: [("playback-30sec.mp3", ""), ("long.aac", "/LongNativeFormats"), ("long.m4a", "/LongNativeFormats")],
          [false, true])
    func streamedSourcesContinueAcrossRetirementAndSocketReclaim(fixture name: (String, String), reclaimSockets: Bool) async throws {
        let media = try fixture(name.0, name.1), held = media.count / 3
        let root = URL.temporaryDirectory.appendingPathComponent("relay-reclaim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: media) }
        defer { reference.stop() }
        var referenceOutputs: [Transport] = []
        let expected = try await play(factory(reference.url, root: root, reclaim: StreamingRelayReclaim()) { referenceOutputs.append($0) },
                                      outputs: { referenceOutputs.last })
        let server = try await HeldMediaServer(media: media, holds: [held])
        defer { server.stop() }
        let reclaim = StreamingRelayReclaim()
        var outputs: [Transport] = []
        let actual = try await play(factory(server.url, root: root, reclaim: reclaim) { outputs.append($0) },
                                    outputs: { outputs.last }) {
            #expect(server.requests.count == 1)
            if reclaimSockets {
                reclaim.simulateSocketReclaim()
            } else {
                reclaim.suspend()
                // The relay let go of the response in flight, and nothing opens while parked.
                #expect(reclaim.participantCount >= 1 && reclaim.retiredRelayCount == reclaim.participantCount)
                try await wait { server.closedConnections >= 1 }
                #expect(server.requests.count == 1 && reclaim.retiredRelayCount == reclaim.participantCount)
                reclaim.demand()
                try await wait { reclaim.retiredRelayCount == 0 }
            }
        }
        #expect(actual == expected, "\(actual.count) samples, expected \(expected.count)")
        // One continuation at the parked cursor, past what was already received.
        #expect(server.requests.count == 2)
        #expect((ReclaimFixture.rangeStart(server.requests[1]) ?? 0) > 0)
    }

    /// Identification keeps a large tag beyond its prefix in item storage; after the relay is
    /// rebuilt the decoder still reads those bytes from storage and the rest continues the item.
    @Test func largeTagKeptByIdentificationIsNotFetchedAgainAfterTheRelayIsRebuilt() async throws {
        let tagLength = 3 << 20
        let mp3 = try fixture("playback-30sec.mp3", "")
        let media = LargeID3TagRoutingTests.tag(length: tagLength) + mp3
        let root = URL.temporaryDirectory.appendingPathComponent("relay-reclaim-tag-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: mp3) }
        defer { reference.stop() }
        var referenceOutputs: [Transport] = []
        let expected = try await play(factory(reference.url, root: root, reclaim: StreamingRelayReclaim()) { referenceOutputs.append($0) },
                                      outputs: { referenceOutputs.last })
        let server = try await HeldMediaServer(media: media, holds: [tagLength + mp3.count / 2])
        defer { server.stop() }
        let reclaim = StreamingRelayReclaim()
        var outputs: [Transport] = []
        let identified = try await factory(server.url, root: root, reclaim: reclaim) { outputs.append($0) }
        // Retired after identification spooled the tag, rebuilt for playback.
        reclaim.suspend()
        #expect(reclaim.participantCount >= 1 && reclaim.retiredRelayCount == reclaim.participantCount)
        try await wait { server.closedConnections >= 1 }
        reclaim.demand()
        try await wait { reclaim.retiredRelayCount == 0 }
        let actual = try await play(identified, outputs: { outputs.last })
        #expect(actual == expected, "\(actual.count) samples, expected \(expected.count)")
        #expect(server.requests.count == 2)
        #expect((ReclaimFixture.rangeStart(server.requests[1]) ?? 0) >= tagLength, "kept tag bytes are never requested again")
    }
}
#if !SWIFT_PACKAGE
private final class ReclaimFixtures: NSObject {}
#endif

/// The app's own composition: coordinator, application engine, processed engine and the
/// eligibility state fed as the app feeds it (scenes, and playback intent from coordinator events).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct StreamingRelayReclaimPlaybackTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    enum Hold: String, CaseIterable, Sendable { case remotePause, interruption }
    private func wait(_ condition: () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try condition(), sourceLocation: sourceLocation)
    }
    private func fixture() throws -> Data {
#if SWIFT_PACKAGE
        try Data(contentsOf: #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")))
#else
        try Data(contentsOf: #require(Bundle(for: ReclaimPlaybackFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")))
#endif
    }

    /// Playing → background (nothing changes) → a pause or an interruption there retires the relay →
    /// remote Play or the interruption's end rebuilds it; repeated, and every second of audio is heard once.
    @Test(arguments: Hold.allCases)
    func backgroundHoldRetiresTheRelayAndResumingContinuesWithNothingLost(hold: Hold) async throws {
        let media = try fixture(), holds = [media.count / 4, media.count / 2]
        let server = try await HeldMediaServer(media: media, holds: holds)
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("relay-reclaim-playback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Relay", episodes: [
            .init(identifier: "relay", title: "Episode", media: .init(url: server.url.absoluteString, size: 0, durationMilliseconds: 30_000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let reclaim = StreamingRelayReclaim(), eligibility = StreamingRelayEligibility(reclaim: reclaim)
        var outputs: [Transport] = []
        let factories = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), reclaim: reclaim,
            makeTransport: { let output = Transport(); outputs.append(output); return output })
        let processed = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, url in
            guard let factory = try await factories.processedIfSupported(url: url, proxy: PodcastProxy(), credentials: nil,
                userAgent: "test") else { throw PlaybackSourceError.invalidURL }
            return factory
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        let engine = ApplicationPlaybackEngine(resolve: { _ in { processed } })
        engine.relayReclaim = reclaim
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { Date(timeIntervalSince1970: 5) })
        let events = player.events()
        let observation = Task { @MainActor [weak player] in
            for await _ in events {
                guard let player else { return }
                eligibility.setPlaybackActive(player.wantsPlayback || player.isBuffering)
            }
        }
        defer { observation.cancel() }
        eligibility.setForeground(true)
        try await player.select(episodeID: 1, play: true)
        try await wait { player.phase == .playing && outputs.last?.playing == true }
        let output = try #require(outputs.last)
        func present(until milliseconds: Int32) async throws {
            try await wait {
                if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                return (engine.reading?.sample.positionMilliseconds ?? 0) >= milliseconds
            }
        }
        try await present(until: 1_000)
        // The phone is locked while audio plays: nothing is retired.
        eligibility.setForeground(false)
        try await present(until: 2_000)
        #expect(!reclaim.isSuspended && server.closedConnections == 0 && server.requests.count == 1)
        for (cycle, _) in holds.enumerated() {
            switch hold {
            case .remotePause: try await player.pause()
            case .interruption: processed.receive(.interrupted(reason: 0))
            }
            // Paused or interrupted in the background: eligible, so the relay lets go of its response.
            try await wait { reclaim.isSuspended && reclaim.participantCount >= 1 && reclaim.retiredRelayCount == reclaim.participantCount }
            try await wait { server.closedConnections == cycle + 1 }
            #expect(!player.wantsPlayback && server.requests.count == cycle + 1, "nothing reopens while parked")
            #expect(reclaim.retiredRelayCount == reclaim.participantCount)
            switch hold {
            case .remotePause: try await player.play()
            case .interruption: processed.receive(.resumptionRecommended(true))
            }
            try await wait { !reclaim.isSuspended && player.phase == .playing }
            let target = Int32((cycle + 1) * 9_000)
            try await present(until: target)
            #expect(server.requests.count == cycle + 2)
        }
        try await wait {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            return player.phase == .idle || player.phase == .stopped || player.phase == .failed
        }
        #expect(player.phase != .failed)
        var data = Data()
        for buffer in output.buffers { data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        let file = try AVAudioFile(forReading: #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")),
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let expected = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        PCMTestFixture.expectAudiblyEquivalent(PCMTestFixture.samples(data), expected, channels: 1, sampleRate: 44_100)
        // Each resume continued the parked cursor: one ranged request per cycle, in order.
        let starts = server.requests.dropFirst().compactMap(ReclaimFixture.rangeStart)
        #expect(starts.count == holds.count && starts == starts.sorted() && starts.allSatisfy { $0 > 0 })
        try await store.close()
    }
}
#if !SWIFT_PACKAGE
private final class ReclaimPlaybackFixtures: NSObject {}
#endif

/// The AVPlayer route's own contract: a new URL cannot repair an asset or its rewritten playlist, so a
/// paused relay route lets its item go and Play or a seek installs a new relay generation and item.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct StreamingRelayReclaimAVPlayerTests {
    private func wait(_ condition: () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try condition(), sourceLocation: sourceLocation)
    }
    private func fixture(_ name: String, _ directory: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures" + directory))
#else
        try #require(Bundle(for: ReclaimAVPlayerFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }

    /// A proxied playlist with a login, a same-origin redirect and a foreign one, retired while paused; a
    /// Lock Screen seek rebuilds it at the target with the play intent kept, also when the server's
    /// playlist and validators changed meanwhile.
    @Test(arguments: [false, true])
    func proxiedPlaylistRetiredWhilePausedContinuesAtAPendingSeek(changedRepresentation: Bool) async throws {
        let index = try fixture("index.m3u8", "/StreamingHLS")
        let parts = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: index.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let login = FeedCredentials(username: "private", password: "fixture")
        let version = Mutex(1), foreignLogins = Mutex(0)
        let proxy = try await LoopbackHTTPServer.start { request in
            let path = request.path, name = URL(string: path)?.lastPathComponent ?? ""
            let current = version.withLock { $0 }, etag = "\"v\(current)\""
            if path.hasPrefix("http://foreign.invalid/") {
                if request.headers["authorization"] != nil { foreignLogins.withLock { $0 += 1 } }
                return .init(headers: ["Content-Type": "video/mp2t", "ETag": etag], body: parts[name] ?? Data())
            }
            guard path.hasPrefix("http://origin.invalid/"), request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 403)
            }
            if name == "index.m3u8" {
                // part02 moves on the same origin; part03 is served by another origin.
                let prefix = current == 1 ? "" : "v2/"
                let text = String(decoding: parts["index.m3u8"]!, as: UTF8.self)
                    .replacingOccurrences(of: "\npart02.ts", with: "\n\(prefix)moved/part02.ts")
                    .replacingOccurrences(of: "\npart03.ts", with: "\n\(prefix)away/part03.ts")
                    .replacingOccurrences(of: "\npart0", with: "\n\(prefix)part0")
                return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl", "ETag": etag], body: Data(text.utf8))
            }
            if path.contains("/moved/") { return .init(status: 302, headers: ["Location": "/cdn/\(name)"]) }
            if path.contains("/away/") { return .init(status: 302, headers: ["Location": "http://foreign.invalid/\(name)"]) }
            guard let data = parts[name] else { return .init(status: 404) }
            return .init(headers: ["Content-Type": "video/mp2t", "ETag": etag], body: data)
        }
        defer { proxy.stop() }
        let client = ProxyNetworkEnvironment.Client(configuration: PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let reclaim = StreamingRelayReclaim()
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login }, proxyClient: { client })
        engine.relayReclaim = reclaim
        defer { engine.unload() }
        var failures: [String] = [], ready = 0
        engine.onEvent = { event in
            if case .failed(_, let message) = event { failures.append(message) }
            if case .ready = event { ready += 1 }
        }
        engine.load(episode: .init(id: 1, details: .init(identifier: "hls", title: "Playlist",
            media: .init(url: "http://origin.invalid/show/index.m3u8", size: 0))), generation: UUID(), positionMilliseconds: 0)
        try await wait { (engine.reading?.isPrepared == true && engine.nativeRelay != nil) || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        let firstRelay = try #require(engine.nativeRelay)
        let playlists = proxy.requests.filter { $0.path.hasSuffix("index.m3u8") }.count
        // Paused in the background: the item, its observers and the relay's listener all go.
        reclaim.suspend()
        try await wait { engine.nativeRelay == nil && engine.nativePlayer == nil }
        #expect(firstRelay.snapshot.cancelled && engine.reading?.sample.status == .paused)
        #expect(engine.reading?.sample.positionMilliseconds == 0 && engine.reading?.buffering == false)
        if changedRepresentation { version.withLock { $0 = 2 } }
        // A Lock Screen seek is a demand: a new relay generation and item, at the target, still paused.
        reclaim.demand()
        engine.seek(to: 5_000, commandID: UUID())
        #expect(engine.reading?.buffering == true)
        try await wait { (engine.nativePlayer != nil && engine.reading?.buffering == false) || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        let landed = try #require(engine.reading?.sample.positionMilliseconds)
        #expect((5_000...5_250).contains(landed) && engine.reading?.sample.status == .paused)
        #expect(engine.nativeRelay != nil && engine.nativeRelay !== firstRelay && ready == 1)
        // The new relay generation loaded the playlist again (the retired one's routes are gone).
        #expect(proxy.requests.filter { $0.path.hasSuffix("index.m3u8") }.count > playlists)
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 5_600 || !failures.isEmpty }
        #expect(failures.isEmpty, "\(failures)")
        // The login reached the origin through the same-origin redirect, never the foreign origin.
        let moved = proxy.requests.filter { $0.path.contains("/cdn/") }
        #expect(!moved.isEmpty && moved.allSatisfy { $0.headers["authorization"] != nil })
        #expect(foreignLogins.withLock { $0 } == 0)
        if changedRepresentation { #expect(proxy.requests.contains { $0.path.contains("/v2/") }) }
    }

    /// An open-ended live stream keeps today's reconnection: Play after retirement starts a new live period at zero.
    @Test func openEndedStreamRetiredWhilePausedStartsANewLivePeriodOnPlay() async throws {
        let audio = try Data(contentsOf: fixture("playback-30sec.mp3", ""))
        let prefix = audio.prefix(audio.count * 3 / 4)
        let chunked = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunked, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let reclaim = StreamingRelayReclaim()
        let engine = AVPlayerPlaybackEngine(muted: true)
        engine.relayReclaim = reclaim
        defer { engine.unload() }
        var failures: [String] = [], resets: [Int32] = []
        engine.onEvent = { event in
            if case .failed(_, let message) = event { failures.append(message) }
            if case .timelineReset(let final) = event { resets.append(final.sample.positionMilliseconds) }
        }
        engine.load(episode: .init(id: 1, details: .init(identifier: "live", title: "Live", media: .init(url: server.url.absoluteString, size: 0))),
                    generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        try await wait { ((engine.reading?.sample.positionMilliseconds ?? 0) > 800 && engine.nativeRelay != nil) || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        engine.pause(commandID: UUID())
        let heard = try #require(engine.reading?.sample.positionMilliseconds)
        let requests = server.requests.count
        reclaim.suspend()
        try await wait { engine.nativeRelay == nil && engine.nativePlayer == nil }
        #expect(engine.reading?.sample.status == .paused && resets.isEmpty)
        reclaim.demand()
        engine.play(commandID: UUID())
        // The heard period ends where it was paused; the stream reconnects as a new live period.
        #expect(resets.count == 1 && abs(Int(resets[0]) - Int(heard)) <= 250)
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 300 && engine.reading?.sample.status == .playing || !failures.isEmpty }
        #expect(failures.isEmpty, "\(failures)")
        #expect((engine.reading?.sample.positionMilliseconds ?? .max) < heard, "a new period starts at zero")
        #expect(server.requests.count > requests && engine.nativeRelay != nil)
    }
}
#if !SWIFT_PACKAGE
private final class ReclaimAVPlayerFixtures: NSObject {}
#endif

// MARK: - Delayed lifecycle deliveries, native-route repair, seeks, interruptions

/// Set once, from any thread.
final class ReclaimOnce: Sendable {
    private let value = Mutex(false)
    /// True the first time only.
    func claim() -> Bool { value.withLock { old in defer { old = true }; return !old } }
    var isClaimed: Bool { value.withLock { $0 } }
}

extension StreamingRelayEligibilityTests {
    enum Delay: String, CaseIterable, Sendable { case registryDelivery, participant }

    /// A registration's or a suspension's delivery that a newer demand overtakes (in the registry, or
    /// inside the participant before it applies anything) is reconciled to the newer state.
    @Test(arguments: [false, true], Delay.allCases)
    func aDelayedLifecycleDeliveryNeverUndoesANewerDemand(atRegistration: Bool, delay: Delay) {
        let reclaim = StreamingRelayReclaim(), relay = Participant(reclaim), once = ReclaimOnce()
        let overtake: @Sendable () -> Void = { if once.claim() { reclaim.demand() } }
        if atRegistration { reclaim.suspend() } else { reclaim.register(relay) }
        switch delay {
        case .registryDelivery: reclaim.beforeDelivery.withLock { $0 = overtake }
        case .participant: relay.beforeReconcile.withLock { $0 = overtake }
        }
        if atRegistration { reclaim.register(relay) } else { reclaim.suspend() }
        reclaim.beforeDelivery.withLock { $0 = nil }
        #expect(!reclaim.isSuspended && !relay.parked && relay.suspends == 0)
    }
}

extension StreamingRelayReclaimInputTests {
    /// A real input: a demand that overtakes the delivery of its registration (made while suspended)
    /// or of a suspension leaves it reading; the older delivery cannot park it afterwards.
    @Test(arguments: [false, true])
    func aDelayedLifecycleDeliveryNeverParksAWantedInput(atRegistration: Bool) async throws {
        let media = ReclaimFixture.body(512 << 10)
        let server = try await LoopbackHTTPServer.start(handler: ReclaimFixture.ranged({ media }))
        defer { server.stop() }
        let url = server.url
        let retry = PCMSourceRetry(), reclaim = StreamingRelayReclaim(), once = ReclaimOnce()
        let overtake: @Sendable () -> Void = { if once.claim() { reclaim.demand() } }
        var heard = Data()
        let relay: NativeStreamingRelay, input: HTTPCodecByteInput
        if atRegistration {
            reclaim.suspend()
            reclaim.beforeDelivery.withLock { $0 = overtake }
            (relay, input) = try await relayed(url, reclaim: reclaim, retry: retry)
        } else {
            (relay, input) = try await relayed(url, reclaim: reclaim, retry: retry)
            heard = try await read(input, 0..<100_000)
            reclaim.beforeDelivery.withLock { $0 = overtake }
            reclaim.suspend()
        }
        reclaim.beforeDelivery.withLock { $0 = nil }
        defer { input.cancel(); relay.cancel() }
        #expect(!reclaim.isSuspended && !relay.isRetired && reclaim.retiredRelayCount == 0)
        // Playback stays wanted: the rest arrives without another demand (a parked input would wait forever).
        let finished = ReclaimOnce(), start = heard.count
        let rest = Task { defer { _ = finished.claim() }; return try await read(input, start..<media.count) }
        let deadline = ContinuousClock.now + .seconds(8)
        while !finished.isClaimed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        if !finished.isClaimed { Issue.record("The input stayed parked"); input.cancel() }
        heard += try await rest.value
        #expect(heard == media)
    }
}

extension StreamingRelayReclaimAVPlayerTests {
    /// A proxied VOD playlist served through a relay route (no login), and the engine paused on it.
    /// The last segments are withheld until `box.release()`, so a seek there must fetch them.
    private func pausedPlaylist(reclaim: StreamingRelayReclaim, owner: AudioSessionOwner? = nil)
        async throws -> (LoopbackHTTPServer, AVPlayerPlaybackEngine, Box) {
        let withheld = ReclaimOnce()
        let index = try fixture("index.m3u8", "/StreamingHLS")
        let parts = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: index.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let proxy = try await LoopbackHTTPServer.start { request in
            let name = URL(string: request.path)?.lastPathComponent ?? ""
            if name == "index.m3u8" { return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: parts[name]!) }
            guard let data = parts[name] else { return .init(status: 404) }
            if ["part03.ts", "part04.ts"].contains(name), !withheld.isClaimed { return nil }
            return .init(headers: ["Content-Type": "video/mp2t"], body: data)
        }
        let client = ProxyNetworkEnvironment.Client(configuration: PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let engine = owner.map { AVPlayerPlaybackEngine(muted: true, proxyClient: { client }, configureAudioSession: {}, sessionOwner: $0) }
            ?? AVPlayerPlaybackEngine(muted: true, proxyClient: { client })
        engine.relayReclaim = reclaim
        let box = Box(release: { _ = withheld.claim() })
        engine.onEvent = { [weak box] event in box?.receive(event) }
        engine.load(episode: .init(id: 1, details: .init(identifier: "hls", title: "Playlist",
            media: .init(url: "http://origin.invalid/show/index.m3u8", size: 0))), generation: UUID(), positionMilliseconds: 0)
        try await wait { (engine.reading?.isPrepared == true && engine.nativeRelay != nil) || !box.failures.isEmpty }
        try #require(box.failures.isEmpty, "\(box.failures)")
        return (proxy, engine, box)
    }
    @MainActor final class Box {
        let release: () -> Void
        init(release: @escaping () -> Void) { self.release = release }
        var failures: [String] = [], ready = 0
        var onState: ((PlaybackEngineReading) -> Void)?
        func receive(_ event: PlaybackEngineEvent) {
            switch event {
            case .failed(_, let message): failures.append(message)
            case .ready: ready += 1
            case .stateChanged(let reading): onState?(reading)
            default: break
            }
        }
    }

    /// The native relay dies without any eligibility notice (iOS closed its sockets): the next seek's
    /// refused connections rebuild the route on a new relay, at the seek target, still paused.
    @Test func nativeRelayLostWithoutNoticeIsRebuiltAtTheLatestSeek() async throws {
        let reclaim = StreamingRelayReclaim()
        let (proxy, engine, box) = try await pausedPlaylist(reclaim: reclaim)
        defer { engine.unload(); proxy.stop() }
        let lost = try #require(engine.nativeRelay)
        box.release()
        lost.simulateSocketReclaim()
        engine.seek(to: 7_000, commandID: UUID())
        try await wait { (engine.nativeRelay.map { $0 !== lost } == true && engine.nativePlayer != nil
                          && engine.reading?.buffering == false) || !box.failures.isEmpty }
        try #require(box.failures.isEmpty, "\(box.failures)")
        #expect(lost.snapshot.cancelled && box.ready == 1)
        let landed = try #require(engine.reading?.sample.positionMilliseconds)
        #expect((7_000...7_250).contains(landed) && engine.reading?.sample.status == .paused)
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 7_500 || !box.failures.isEmpty }
        #expect(box.failures.isEmpty, "\(box.failures)")
    }

    /// When the rebuilt relay dies too before its item loads, playback ends as the relay being
    /// unavailable (the try-again explanation), not an endless spinner or a media error.
    @Test func repeatedNativeRelayLossEndsAsTheRelayBeingUnavailable() async throws {
        let reclaim = StreamingRelayReclaim()
        let (proxy, engine, box) = try await pausedPlaylist(reclaim: reclaim)
        defer { engine.unload(); proxy.stop() }
        let lost = try #require(engine.nativeRelay)
        let playlists = proxy.requests.filter { $0.path.hasSuffix("index.m3u8") }.count
        // This relay, and every one the engine starts for the route afterwards, loses its sockets.
        box.release()
        lost.simulateSocketReclaim()
        engine.reclaimsNewRelaysForTesting = true
        engine.seek(to: 7_000, commandID: UUID())
        try await wait { !box.failures.isEmpty }
        #expect(box.failures == [StreamingRelayUnavailable.message])
        #expect(PlaybackFailureExplanation(details: box.failures[0]) == .tryAgain)
        // The replacement never reached the upstream: its listener was gone too.
        #expect(proxy.requests.filter { $0.path.hasSuffix("index.m3u8") }.count == playlists)
    }

    /// A newer seek while the replacement item's first native seek is in flight lands at the newer
    /// target and answers the newer command.
    @Test func aNewerSeekWhileTheReplacementSeeksLandsAtTheNewerTarget() async throws {
        let reclaim = StreamingRelayReclaim()
        let (proxy, engine, box) = try await pausedPlaylist(reclaim: reclaim)
        defer { engine.unload(); proxy.stop() }
        box.release()
        reclaim.suspend()
        try await wait { engine.nativeRelay == nil && engine.nativePlayer == nil }
        let first = UUID(), second = UUID()
        var issued = false
        box.onState = { [weak engine] reading in
            // The replacement is ready and its native seek to the first target was just issued.
            guard !issued, reading.buffering, reading.commandID == first,
                  engine?.nativePlayer?.currentItem?.status == .readyToPlay else { return }
            issued = true
            Task { @MainActor in engine?.seek(to: 6_000, commandID: second) }
        }
        reclaim.demand()
        engine.seek(to: 3_000, commandID: first)
        try await wait { (issued && engine.reading?.commandID == second && engine.nativePlayer != nil
                          && engine.reading?.buffering == false) || !box.failures.isEmpty }
        try #require(box.failures.isEmpty, "\(box.failures)")
        let landed = try #require(engine.reading?.sample.positionMilliseconds)
        #expect((6_000...6_250).contains(landed), "landed at \(landed)")
        #expect(engine.reading?.sample.status == .paused && box.ready == 1)
    }

    /// The final segments stay withheld, the original relay dies, ONE seek to 7 s, and
    /// every replacement dies once its item is ready but before its seek lands. Readiness is not
    /// progress: one repair at most, then the relay is unavailable (try again), never endless rebuilds.
    @Test func lossAfterTheReplacementIsReadyButBeforeItsSeekLandsIsRepairedOnceOnly() async throws {
        let reclaim = StreamingRelayReclaim()
        let (proxy, engine, box) = try await pausedPlaylist(reclaim: reclaim)
        defer { engine.unload(); proxy.stop() }
        let original = try #require(engine.nativeRelay)
        var killed: Set<ObjectIdentifier> = [ObjectIdentifier(original)], replacements = 0
        box.onState = { [weak engine] reading in
            guard reading.buffering, let engine, let relay = engine.nativeRelay,
                  engine.nativePlayer?.currentItem?.status == .readyToPlay,
                  killed.insert(ObjectIdentifier(relay)).inserted else { return }
            replacements += 1
            relay.simulateSocketReclaim()
        }
        original.simulateSocketReclaim()
        engine.seek(to: 7_000, commandID: UUID())
        try await wait { !box.failures.isEmpty || replacements > 1 }
        #expect(replacements == 1)
        #expect(box.failures == [StreamingRelayUnavailable.message])
        #expect(PlaybackFailureExplanation(details: box.failures.first ?? "") == .tryAgain)
    }

    /// The safe baseline on AVPlayer routes (no automatic resumption there): an interruption pauses a
    /// native relay route, it is retired, and the end of the interruption neither plays nor asks for
    /// the session again.
    @Test(arguments: [false, true])
    func interruptionEndNeverResumesANativeRelayRouteByItself(systemPauseFirst: Bool) async throws {
        let driver = AudioSessionOwnerTests.SessionDriver(); driver.autoComplete = true
        let events = PCMSystemSessionTests.SystemEvents()
        let owner = AudioSessionOwner(driver: driver, events: events.subscribe)
        let reclaim = StreamingRelayReclaim()
        let (proxy, engine, box) = try await pausedPlaylist(reclaim: reclaim, owner: owner)
        defer { engine.unload(); proxy.stop() }
        box.release()
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 800 || !box.failures.isEmpty }
        #expect(driver.calls == [true])
        if !systemPauseFirst { events.post(.interrupted(reason: 0)) }
        engine.nativePlayer?.pause()
        try await wait { engine.reading?.sample.status == .paused }
        if systemPauseFirst { events.post(.interrupted(reason: 0)) }
        reclaim.suspend()
        try await wait { engine.nativeRelay == nil && engine.nativePlayer == nil }
        events.post(.resumptionRecommended(true))
        await Task.yield()
        #expect(engine.reading?.sample.status == .paused && engine.nativePlayer == nil && engine.nativeRelay == nil)
        #expect(driver.calls == [true] && owner.isIdle && box.failures.isEmpty)
    }

    enum RebuildBranch: String, CaseIterable, Sendable { case live, neverPrepared }
    enum AfterInterruption: String, CaseIterable, Sendable { case nothing, play, pauseThenPlay }

    /// An open-ended stream through a native relay, through the coordinator, the
    /// application engine and the actual session owner. The relay dies (listener, connections and the
    /// native refused-connection failure) and the replacement's upstream answer is held, so the engine
    /// has no reading. A call begins and ends there: nothing resumes by itself, but an explicit Play
    /// in that interval reaches the engine, and the replacement then plays. Also while the item was
    /// never prepared (the first relay died before the stream started).
    @Test(arguments: RebuildBranch.allCases, AfterInterruption.allCases)
    func anExplicitPlayDuringARelayRebuildAfterAnInterruptionIsNotLost(branch: RebuildBranch, after: AfterInterruption) async throws {
        let audio = try Data(contentsOf: fixture("playback-30sec.mp3", ""))
        let prefix = audio.prefix(audio.count * 3 / 4)
        let chunked = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let stream = LoopbackHTTPServer.Response(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                                                 body: chunked, keepConnectionOpen: true)
        let requests = Mutex(0), hold = ReclaimOnce(), release = ReclaimOnce()
        // Live: answered until the test holds. Never prepared: only the source's detection is answered.
        // After the release, everything is answered.
        let server = try await LoopbackHTTPServer.start { _ in
            let number = requests.withLock { $0 += 1; return $0 }
            if release.isClaimed { return stream }
            if branch == .neverPrepared { return number == 1 ? stream : nil }
            return hold.isClaimed ? nil : stream
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("relay-rebuild-interruption-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Live", episodes: [
            .init(identifier: "live", title: "Live", media: .init(url: server.url.absoluteString, size: 0))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let driver = AudioSessionOwnerTests.SessionDriver(); driver.autoComplete = true
        let events = PCMSystemSessionTests.SystemEvents()
        let owner = AudioSessionOwner(driver: driver, events: events.subscribe)
        let reclaim = StreamingRelayReclaim()
        let engine = AVPlayerPlaybackEngine(muted: true, configureAudioSession: {}, sessionOwner: owner)
        engine.relayReclaim = reclaim
        let app = ApplicationPlaybackEngine(resolve: { _ in { engine } }, sessionOwner: owner)
        app.relayReclaim = reclaim
        app.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        defer { app.unload() }
        let player = PlaybackCoordinator(store: store, engine: app, clock: { Date(timeIntervalSince1970: 5) })
        try await player.select(episodeID: 1, play: true)
        if branch == .live {
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 800 && (engine.nativePlayer?.rate ?? 0) > 0 }
            _ = hold.claim()
        } else {
            try await wait { engine.nativeRelay != nil && !server.heldRequestPaths.isEmpty }
            #expect(engine.reading == nil)
        }
        let calls = driver.calls.count
        // The relay dies: its sockets close and the item reports the refused loopback connection.
        let lost = try #require(engine.nativeRelay), item = try #require(engine.nativePlayer?.currentItem)
        lost.simulateSocketReclaim()
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: URLError(.cannotConnectToHost)])
        try await wait { engine.nativeRelay.map { $0 !== lost } == true && engine.reading == nil && server.heldRequestPaths.contains("/feed") }
        // A call begins and ends while the replacement has no reading.
        events.post(.interrupted(reason: 0))
        events.post(.resumptionRecommended(true))
        // The pause reaches the coordinator at once (not, seconds later, the held request's failure).
        try await wait { !player.wantsPlayback }
        try #require(player.phase != .failed && engine.reading == nil, "\(player.phase)")
        let identity = try #require(player.systemSnapshot?.identity)
        switch after {
        case .nothing: break
        case .play:
            if branch == .live { #expect(try await player.performSystemCommand(.play, for: identity)) }
            else { try await player.play() }
        case .pauseThenPlay:
            _ = try await player.performSystemCommand(.pause, for: identity)
            if branch == .live { #expect(try await player.performSystemCommand(.play, for: identity)) }
            else { try await player.play() }
        }
        _ = release.claim()
        try server.respond(toPath: "/feed", with: stream)
        try await wait { engine.reading?.isPrepared == true && engine.nativePlayer != nil && engine.reading?.buffering == false && owner.isIdle }
        if after == .nothing {
            #expect(engine.reading?.sample.status == .paused && (engine.nativePlayer?.rate ?? 0) == 0)
            #expect(driver.calls.count == calls)
        } else {
            try await wait { engine.reading?.sample.status == .playing && (engine.nativePlayer?.rate ?? 0) > 0 && owner.isIdle }
            #expect(driver.calls.count == calls + 1 && driver.calls.last == true && player.wantsPlayback)
        }
        #expect(player.phase != .failed)
        try await store.close()
    }

    /// A call that begins while a lost relay route is being rebuilt (the old player retired, no
    /// replacement yet) ends the play intent: the replacement settles paused at the seek target and
    /// never asks for the session; only a later explicit Play does.
    @Test func anInterruptionDuringARelayRebuildRequestsNoSession() async throws {
        let driver = AudioSessionOwnerTests.SessionDriver(); driver.autoComplete = true
        let events = PCMSystemSessionTests.SystemEvents()
        let owner = AudioSessionOwner(driver: driver, events: events.subscribe)
        let reclaim = StreamingRelayReclaim()
        let (proxy, engine, box) = try await pausedPlaylist(reclaim: reclaim, owner: owner)
        defer { engine.unload(); proxy.stop() }
        box.release()
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 800 || !box.failures.isEmpty }
        let lost = try #require(engine.nativeRelay)
        var interrupted = false
        box.onState = { [weak engine] reading in
            guard !interrupted, reading.buffering, engine?.nativePlayer == nil, engine?.nativeRelay !== lost else { return }
            interrupted = true
            Task { @MainActor in events.post(.interrupted(reason: 0)) }
        }
        lost.simulateSocketReclaim()
        engine.seek(to: 7_000, commandID: UUID())
        try await wait { (interrupted && engine.nativePlayer != nil && engine.reading?.buffering == false) || !box.failures.isEmpty }
        try #require(box.failures.isEmpty, "\(box.failures)")
        #expect(engine.reading?.sample.status == .paused && (engine.nativePlayer?.rate ?? 0) == 0)
        #expect((7_000...7_250).contains(engine.reading?.sample.positionMilliseconds ?? -1))
        #expect(driver.calls == [true] && owner.isIdle)
        // A new explicit Play asks for the session again.
        engine.play(commandID: UUID())
        try await wait { driver.calls == [true, true] && (engine.nativePlayer?.rate ?? 0) > 0 }
    }
}
