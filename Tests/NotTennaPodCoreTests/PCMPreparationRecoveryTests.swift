import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct PCMPreparationRecoveryTests {
    private let helper = PCMPlaybackEngineTests()

    @Test(arguments: [false, true], [false, true])
    func oneFlushDuringInitialPreparationOrSeekRetainsTargetAndIntent(seeking: Bool, play: Bool) async throws {
        try await helper.withPlayer(speed: 1.5, skipSilence: false) { store, player, engine, outputs, _, _ in
            if seeking {
                try await player.select(episodeID: 1, play: play)
                try await helper.wait { engine.reading?.isPrepared == true }
            }
            let originalCount = outputs.values.count
            outputs.configure = { t in
                if outputs.values.count == originalCount {
                    t.error = NativeSampleBufferTransport.Failure.automaticallyFlushed(at: .zero)
                }
            }
            if seeking { try await player.seek(to: 300) }
            else { try await player.select(episodeID: 1, play: play) }
            try await helper.wait { outputs.values.count == originalCount + 2 && engine.reading?.isPrepared == true
                && engine.reading?.buffering == false }
            #expect(outputs.values[originalCount].closed && !outputs.values[originalCount].playing)
            #expect(outputs.values.last?.playing == play)
            #expect(engine.reading?.sample.positionMilliseconds == (seeking ? 300 : 0))
            #expect(engine.reading?.speed == 1.5 && engine.reading?.skipSilence == false)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            outputs.configure = nil
        }
    }

    @Test(arguments: [Float(0.5), 1.5], [false, true])
    func processingAfterRecoveryMatchesTheSamePreparationWithoutFailure(speed: Float, silence: Bool) async throws {
        var expected: (Int32?, Data)?
        for failFirst in [false, true] {
            try await helper.withPlayer(speed: speed, skipSilence: silence) { _, player, engine, outputs, _, _ in
                outputs.configure = { if failFirst && outputs.values.isEmpty {
                    $0.error = NativeSampleBufferTransport.Failure.reconfigurationRequired
                } }
                defer { outputs.configure = nil }
                try await player.select(episodeID: 1)
                try await helper.wait { engine.reading?.isPrepared == true && engine.reading?.buffering == false }
                let output = try #require(outputs.values.last)
                let position = engine.reading?.sample.positionMilliseconds
                while player.phase != .idle {
                    let previousCount = output.buffers.count
                    output.advance(output.end.value)
                    try await helper.wait { output.buffers.count > previousCount || player.phase == .idle }
                }
                let bytes = try output.buffers.reduce(into: Data()) { data, buffer in
                    data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
                }
                #expect(player.speed == speed && player.skipSilence == silence)
                if let expected { #expect(position == expected.0 && bytes == expected.1) }
                else { expected = (position, bytes) }
            }
        }
    }

    @Test func supersedingSeekHasItsOwnRecoveryAttempt() async throws {
        try await helper.withPlayer { _, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            outputs.configure = { if outputs.values.count == 1 {
                $0.error = NativeSampleBufferTransport.Failure.reconfigurationRequired
            } }
            defer { outputs.configure = nil }
            outputs.values[0].onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            // Supersede the scheduled reconstruction before its task enters the session port.
            engine.seek(to: 300, commandID: UUID())
            try await helper.wait { outputs.values.count == 3 && outputs.values[2].playing }
            #expect(engine.reading?.sample.positionMilliseconds == 300)
            #expect(outputs.values[0].closed && outputs.values[1].closed)
        }
    }

    @Test func repeatedPreparationFailureIsTerminalUntilExplicitRetry() async throws {
        try await helper.withPlayer { store, player, engine, outputs, _, _ in
            outputs.configure = { $0.error = NativeSampleBufferTransport.Failure.reconfigurationRequired }
            try await player.select(episodeID: 1)
            try await helper.wait { player.phase == .failed }
            #expect(outputs.values.count == 2 && outputs.values.allSatisfy { $0.closed && !$0.playing })
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            outputs.configure = nil
            try await player.play()
            try await helper.wait { outputs.values.count == 3 && outputs.values[2].playing }
            #expect(engine.reading?.sample.positionMilliseconds == 0)
        }
    }

    @Test(arguments: [NativeSampleBufferTransport.Failure.flushed, .automaticallyFlushed(at: .invalid)])
    func unidentifiedOrInvalidFlushDoesNotAuthorizeRetry(error: NativeSampleBufferTransport.Failure) async throws {
        try await helper.withPlayer { _, player, _, outputs, _, _ in
            outputs.configure = { $0.error = error }
            try await player.select(episodeID: 1)
            try await helper.wait { player.phase == .failed }
            #expect(outputs.values.count == 1 && outputs.values[0].closed)
            outputs.configure = nil
        }
    }

    enum Command: CaseIterable { case pause, seek, replace, unload }
    @Test(arguments: Command.allCases)
    func newerCommandsWinBeforeFailedEnqueueReturns(command: Command) async throws {
        try await helper.withPlayer { _, player, engine, outputs, _, _ in
            outputs.configure = { if outputs.values.isEmpty { $0.hold = true } }
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.pending != nil }
            let failed = outputs.values[0]
            defer { failed.release(); outputs.configure = nil }
            failed.onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            switch command {
            case .pause: try await player.pause()
            case .seek: try await player.seek(to: 300)
            case .replace: try await player.select(episodeID: 2, play: false)
            case .unload: engine.unload()
            }
            failed.release()
            if command == .unload {
                await Task.yield()
                #expect(engine.reading == nil && outputs.values.count == 1 && failed.closed)
            } else {
                try await helper.wait { outputs.values.count == 2 && engine.reading?.isPrepared == true
                    && engine.reading?.buffering == false }
                #expect(failed.closed && !failed.playing)
                #expect(engine.reading?.sample.positionMilliseconds == (command == .seek ? 300 : 0))
                #expect(outputs.values[1].playing == (command == .seek))
                #expect(player.episode?.id == (command == .replace ? 2 : 1))
            }
        }
    }
}
