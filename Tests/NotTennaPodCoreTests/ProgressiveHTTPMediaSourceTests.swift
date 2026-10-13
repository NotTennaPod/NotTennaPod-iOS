import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ProgressiveHTTPMediaSourceTests {
    private enum Failure: Error { case timedOut }
    @MainActor private final class SeekResult { var value: Bool? }
    @MainActor private final class Failures { var values: [Error] = [] }
    private var fixture: URL {
        Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func nativePlaybackMustAdvanceBeforeServerSendsEOFAndCancellationDeletesPartialCache() async throws {
        let data = try Data(contentsOf: fixture)
        // Intentionally never send the last quarter or EOF: passing requires progressive playback.
        let prefix = data.prefix(data.count * 3 / 4)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)"],
                  body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil); source.cancel() }
        player.play()
        do {
            try await wait { player.currentTime().seconds >= 1 || item.status == .failed }
        } catch {
            let state = await source.snapshot()
            print("Progressive startup: status=\(item.status.rawValue), time=\(player.currentTime().seconds), duration=\(item.duration.seconds), bytes=\(state.received)/\(state.expected ?? -1), pending=\(state.pendingRequests), failure=\(state.failure ?? "none")")
            throw error
        }
        #expect(item.status == .readyToPlay && player.currentTime().seconds >= 1)
        #expect(item.duration.seconds.isFinite && item.duration.seconds > 0)
        let state = await source.snapshot()
        #expect(state.received == Int64(prefix.count) && !state.completed)
        #expect(state.received < data.count && state.failure == nil)
        #expect(server.requests.count == 1)
        #expect(server.requests[0].headers["accept-encoding"] == "identity")
        player.pause()
        player.replaceCurrentItem(with: nil)
        source.cancel()
        let retired = await source.snapshot()
        #expect(retired.cancelled && retired.pendingRequests == 0 && retired.cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await source.snapshot().received == state.received)
    }

    @Test func fullNonRangeHTTPHasNativeDurationAndRepeatableForwardBackwardSeeks() async throws {
        let data = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status != .unknown }
        #expect(item.status == .readyToPlay)
        #expect(abs(item.duration.seconds - 30.040816326530614) < 0.01)
        for target: Int64 in [15_000, 3_883, 25_000, 0] {
            let finished = await player.seek(to: CMTime(value: target, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
            #expect(finished)
            #expect(abs(player.currentTime().seconds - Double(target) / 1_000) < 0.25)
        }
        try await wait { await source.snapshot().completed }
        #expect(try Data(contentsOf: source.cacheURL) == data)
        #expect(server.requests.count == 1) // Repeated seeks read the disk cache.
        player.replaceCurrentItem(with: nil)
        source.cancel()
        #expect(await source.snapshot().cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test func HTTPFailureReachesNativePlayerAndRemovesCache() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: 403, body: Data()) }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status == .failed }
        let state = await source.snapshot()
        #expect(state.failure != nil && state.pendingRequests == 0 && state.cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test func chunkedUnknownLengthBecomesExactAtEOFWithoutFabricatingLength() async throws {
        let data = try Data(contentsOf: fixture)
        var wire = Data()
        for offset in stride(from: 0, to: data.count, by: 701) {
            let chunk = data[offset..<min(offset + 701, data.count)]
            wire.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
            wire.append(chunk)
            wire.append(Data("\r\n".utf8))
        }
        wire.append(Data("0\r\n\r\n".utf8))
        let body = wire
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: body)
        }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status != .unknown }
        #expect(item.status == .readyToPlay)
        #expect(abs(item.duration.seconds - 30.040816326530614) < 0.01)
        let state = await source.snapshot()
        #expect(state.completed && state.expected == Int64(data.count) && state.received == Int64(data.count))
        #expect(try Data(contentsOf: source.cacheURL) == data)
        #expect(state.failure == nil && state.cleanupFailure == nil)
    }

    @Test(arguments: [false, true])
    func truncatedAndMalformedTransfersFailWithoutRetainingPartialFiles(malformedChunking: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            if malformedChunking {
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                             body: Data("not-a-chunk-size\r\n".utf8))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "120017"], body: Data("partial".utf8))
        }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status == .failed }
        let state = await source.snapshot()
        #expect(state.failure != nil && !state.completed && state.pendingRequests == 0)
        #expect(state.cleanupFailure == nil && !FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test func retiringOneSourceDoesNotCancelAnotherSourceForTheSameURL() async throws {
        let data = try Data(contentsOf: fixture)
        let prefix = data.prefix(data.count * 3 / 4)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)"],
                  body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let first = try ProgressiveHTTPMediaSource(url: server.url)
        let second = try ProgressiveHTTPMediaSource(url: server.url)
        #expect(first.cacheURL != second.cacheURL)
        let firstPlayer = AVPlayer(playerItem: AVPlayerItem(asset: first.asset))
        let secondPlayer = AVPlayer(playerItem: AVPlayerItem(asset: second.asset))
        firstPlayer.isMuted = true
        secondPlayer.isMuted = true
        defer {
            firstPlayer.replaceCurrentItem(with: nil); secondPlayer.replaceCurrentItem(with: nil)
            first.cancel(); second.cancel()
        }
        firstPlayer.play(); secondPlayer.play()
        try await wait { firstPlayer.currentTime().seconds >= 0.3 && secondPlayer.currentTime().seconds >= 0.3 }
        firstPlayer.replaceCurrentItem(with: nil)
        first.cancel()
        #expect(await first.snapshot().cancelled)
        #expect(!FileManager.default.fileExists(atPath: first.cacheURL.path))
        let before = secondPlayer.currentTime().seconds
        try await wait { secondPlayer.currentTime().seconds >= before + 0.5 }
        #expect(await second.snapshot().failure == nil)
        #expect(FileManager.default.fileExists(atPath: second.cacheURL.path))
        #expect(server.requests.count == 2)
    }

    @Test(arguments: [false, true])
    func unrecognizedBytesFailInsteadOfLeavingResourceRequestsHanging(declaresMP3: Bool) async throws {
        let data = Data("<html><body>This is not an audio file.</body></html>".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: declaresMP3 ? ["Content-Type": "audio/mpeg"] : [:], body: data)
        }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status == .failed }
        let state = await source.snapshot()
        #expect(state.failure != nil && state.pendingRequests == 0 && state.cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test(arguments: ["absent", "application/octet-stream", "text/plain", "audio/wav", "audio/mp4"], [false, true])
    func nativeTypeDetectionAllowsMissingOrIncorrectMetadata(mime: String, wrongExtension: Bool) async throws {
        let data = try Data(contentsOf: fixture)
        var fields = ["Content-Length": String(data.count)]
        if mime != "absent" { fields["Content-Type"] = mime }
        let headers = fields
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: headers, body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let url = wrongExtension ? server.url.appendingPathExtension("wav") : server.url
        let failures = Failures()
        let source = try ProgressiveHTTPMediaSource(url: url, onFailure: { error in
            Task { @MainActor in failures.values.append(error) }
        })
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        player.play()
        try await wait { player.currentTime().seconds >= 0.5 || !failures.values.isEmpty }
        #expect(failures.values.isEmpty && item.status == .readyToPlay && player.currentTime().seconds >= 0.5)
        #expect(abs(item.duration.seconds - 30.040816326530614) < 0.01)
        let state = await source.snapshot()
        #expect(state.contentType == "public.mp3" && state.received < data.count && !state.completed)
        source.cancel()
        #expect(await source.snapshot().cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test(arguments: ["partial", "partial-short", "unknown-total", "ignored", "bad-range", "changed-validator", "changed-overlap"])
    func uncachedSeekUsesValidatedRangesAndRejectsInconsistentResponses(mode: String) async throws {
        let data = try Data(contentsOf: fixture)
        let prefix = data.prefix(data.count / 4)
        let server = try await LoopbackHTTPServer.start { request in
            guard let range = request.headers["range"],
                  let offset = Int(range.dropFirst("bytes=".count).dropLast()) else {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)", "ETag": "\"version-1\""],
                             body: prefix, keepConnectionOpen: true)
            }
            if mode == "ignored" || mode == "changed-overlap" {
                var body = data
                if mode == "changed-overlap" { body[0] ^= 0xff }
                return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"version-1\""], body: body)
            }
            let end = mode == "partial-short" ? min(offset + 4096, data.count) : data.count
            let total = mode == "unknown-total" ? "*" : String(data.count)
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg",
                "Content-Range": "bytes \(offset + (mode == "bad-range" ? 1 : 0))-\(end - 1)/\(total)",
                "ETag": mode == "changed-validator" ? "\"version-2\"" : "\"version-1\""], body: data[offset..<end])
        }
        defer { server.stop() }
        let failures = Failures()
        let source = try ProgressiveHTTPMediaSource(url: server.url, onFailure: { error in
            Task { @MainActor in failures.values.append(error) }
        })
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        player.play()
        try await wait { player.currentTime().seconds >= 0.3 }
        player.pause()
        let seekResult = SeekResult()
        player.seek(to: CMTime(value: 25_000, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in seekResult.value = finished }
        }
        do {
            try await wait { seekResult.value != nil || item.status == .failed }
        } catch {
            let state = await source.snapshot()
            print("Range seek \(mode): requests=\(server.requests.map(\.headers)), ranges=\(state.cachedRanges), active=\(state.activeTransfers), failure=\(state.failure ?? "none")")
            throw error
        }
        let positionAfterSeek = player.currentTime().seconds
        player.play()
        // A native seek callback can precede its HTTP request. Require actual network and
        // source outcomes, not completion of the native time repositioning alone.
        try await wait {
            guard server.requests.contains(where: { $0.headers["range"] != nil }) else { return false }
            return await source.snapshot().failure != nil || player.currentTime().seconds >= 25.3
        }
        let ranged = try #require(server.requests.first { $0.headers["range"] != nil })
        #expect(ranged.headers["if-range"] == "\"version-1\"")
        if ["partial", "partial-short", "unknown-total", "ignored"].contains(mode) {
            #expect(seekResult.value == true && abs(positionAfterSeek - 25) < 0.25)
            #expect(player.currentTime().seconds >= 25.3)
            let state = await source.snapshot()
            #expect(state.failure == nil)
            #expect(failures.values.isEmpty)
            let stored = try Data(contentsOf: source.cacheURL)
            for range in state.cachedRanges {
                #expect(stored[Int(range.lowerBound)..<Int(range.upperBound)] == data[Int(range.lowerBound)..<Int(range.upperBound)])
            }
            if mode != "ignored" {
                #expect(state.received < data.count)
            } else {
                try await wait { await source.snapshot().completed }
                #expect(try Data(contentsOf: source.cacheURL) == data)
            }
        } else {
            // The diagnostic run proves native seek can return true and item status remain
            // ready despite rejected bytes. Require direct failure delivery to the owner;
            // engine integration must use it before this candidate can be adopted.
            try await wait { !failures.values.isEmpty }
            #expect(failures.values.count == 1)
            let state = await source.snapshot()
            #expect(state.failure != nil && state.pendingRequests == 0 && state.activeTransfers == 0)
            #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
            source.cancel()
            try await Task.sleep(for: .milliseconds(100))
            #expect(failures.values.count == 1) // Retired native/network callbacks cannot report twice.
        }
    }

    @Test(arguments: [false, true])
    func pendingRangeCanBeCancelledOrSupersededWithoutAcceptingRetiredCallbacks(supersede: Bool) async throws {
        let data = try Data(contentsOf: fixture)
        let count = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                let number = count.withLock { $0 += 1; return $0 }
                if number == 1 { return nil } // First range cannot complete on its own.
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"v1\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: data.dropFirst(offset))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)", "ETag": "\"v1\""],
                         body: data.prefix(data.count / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let failures = Failures()
        let source = try ProgressiveHTTPMediaSource(url: server.url, onFailure: { error in
            Task { @MainActor in failures.values.append(error) }
        })
        let player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        player.play()
        try await wait { player.currentTime().seconds >= 0.3 }
        player.seek(to: CMTime(value: 25_000, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero,
                    completionHandler: { _ in })
        try await wait { count.withLock { $0 } == 1 }
        if supersede {
            player.seek(to: CMTime(value: 15_000, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero,
                        completionHandler: { _ in })
            try await wait { count.withLock { $0 } >= 2 && player.currentTime().seconds >= 15.3 }
            #expect(player.currentTime().seconds < 20)
            #expect(await source.snapshot().failure == nil)
        }
        source.cancel()
        let state = await source.snapshot()
        #expect(state.cancelled && state.activeTransfers == 0 && state.pendingRequests == 0 && state.failure == nil)
        #expect(state.cleanupFailure == nil && !FileManager.default.fileExists(atPath: source.cacheURL.path))
        server.stop() // Any late connection failure belongs to retired tasks.
        try await Task.sleep(for: .milliseconds(100))
        #expect(failures.values.isEmpty)
        #expect(await source.snapshot().received == state.received)
    }

    @Test(arguments: ["absent", "weak", "date-only", "malformed"], ["partial", "ignored", "ignored-chunked"])
    func uncachedSeekingDoesNotRequireAnETag(metadata: String, mode: String) async throws {
        let data = try Data(contentsOf: fixture)
        var fields = ["Content-Type": "audio/mpeg"]
        if metadata == "weak" { fields["ETag"] = "W/\"v1\"" }
        if metadata == "malformed" { fields["ETag"] = "not-an-entity-tag" }
        if metadata == "date-only" {
            fields["Last-Modified"] = "Wed, 21 Oct 2015 07:28:00 GMT"
            fields["Date"] = "Sun, 13 Sep 2026 10:00:00 GMT"
        }
        let headers = fields
        let server = try await LoopbackHTTPServer.start { request in
            var response = headers
            guard let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) else {
                response["Content-Length"] = String(data.count)
                return .init(headers: response, body: data.prefix(data.count / 4), keepConnectionOpen: true)
            }
            if mode == "partial" {
                response["Content-Range"] = "bytes \(offset)-\(data.count - 1)/\(data.count)"
                return .init(status: 206, headers: response, body: data.dropFirst(offset))
            }
            if mode == "ignored-chunked" {
                response["Transfer-Encoding"] = "chunked"
                var wire = Data("\(String(data.count, radix: 16))\r\n".utf8)
                wire.append(data); wire.append(Data("\r\n0\r\n\r\n".utf8))
                return .init(headers: response, body: wire)
            }
            return .init(headers: response, body: data)
        }
        defer { server.stop() }
        let failures = Failures()
        let source = try ProgressiveHTTPMediaSource(url: server.url, onFailure: { error in
            Task { @MainActor in failures.values.append(error) }
        })
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        player.play()
        try await wait { player.currentTime().seconds >= 0.3 }
        player.seek(to: CMTime(value: 25_000, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero,
                    completionHandler: { _ in })
        try await wait {
            server.requests.contains(where: { $0.headers["range"] != nil }) && player.currentTime().seconds >= 25.3
        }
        #expect(failures.values.isEmpty && item.status == .readyToPlay)
        let ranged = server.requests.filter { $0.headers["range"] != nil }
        #expect(!ranged.isEmpty && ranged.allSatisfy { $0.headers["if-range"] == nil })
        let state = await source.snapshot()
        #expect(state.failure == nil)
        let stored = try Data(contentsOf: source.cacheURL)
        for range in state.cachedRanges {
            #expect(stored[Int(range.lowerBound)..<Int(range.upperBound)] == data[Int(range.lowerBound)..<Int(range.upperBound)])
        }
        if mode == "partial" { #expect(state.received < data.count) }
        else {
            try await wait { await source.snapshot().completed }
            #expect(try Data(contentsOf: source.cacheURL) == data)
        }
    }

    @Test(arguments: ["overlap", "length"])
    func unvalidatedRangeStillRejectsObservableDataChanges(change: String) async throws {
        let data = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["range"] != nil else {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(data.count)],
                             body: data.prefix(data.count / 4), keepConnectionOpen: true)
            }
            var body = data
            if change == "overlap" { body[5] ^= 0xff } else { body.append(0) }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: body)
        }
        defer { server.stop() }
        let failures = Failures()
        let source = try ProgressiveHTTPMediaSource(url: server.url, onFailure: { error in
            Task { @MainActor in failures.values.append(error) }
        })
        let player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        player.play()
        try await wait { player.currentTime().seconds >= 0.3 }
        player.seek(to: CMTime(value: 25_000, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero,
                    completionHandler: { _ in })
        try await wait { !failures.values.isEmpty }
        #expect(failures.values.count == 1)
        let state = await source.snapshot()
        #expect(state.failure != nil && state.pendingRequests == 0 && state.activeTransfers == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }
}
