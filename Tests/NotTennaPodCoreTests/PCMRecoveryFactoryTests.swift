import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct PCMRecoveryFactoryTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport

    @Test func independentSessionsStartAtTheirRequestedPositions() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var outputs: [Transport] = []
        let factory = try PCMRecoveryFactory(url: url, makeTransport: {
            let t = Transport(); outputs.append(t); return t
        })
        let a = try await factory.make(positionMilliseconds: 100, parameters: .init(speed: 1, skipSilence: false))
        let b = try await factory.make(positionMilliseconds: 500, parameters: .init(speed: 2, skipSilence: true))
        defer { a.close(); b.close() }
        try #require(outputs.count == 2)
        #expect(outputs.allSatisfy { !$0.playing })
        try await a.prepare(); try await b.prepare()
        // The fixture is only 600 ms long, so a 0.25 s tolerance could not tell 100 ms from 50 ms.
        // This lossless WAV seeks exactly; allow 50 ms.
        #expect(abs(try #require(try a.mediaMicroseconds) - 100_000) <= 50_000)
        #expect(abs(try #require(try b.mediaMicroseconds) - 500_000) <= 50_000)
        // Closing one session leaves the other paused and usable.
        a.close(); #expect(outputs[0].closed && !outputs[1].closed && b.state == .paused)
    }

    @Test func badSourceOrParametersCannotConstructOutput() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var outputs = 0
        let factory = try PCMRecoveryFactory(url: url, makeTransport: { outputs += 1; return Transport() })
        await #expect(throws: NativePCMDecoder.Failure.invalidStart) {
            try await factory.make(positionMilliseconds: -1, parameters: .init(speed: 1, skipSilence: false))
        }
        await #expect(throws: PCMSpeedProcessor.Failure.invalidSpeed) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: .nan, skipSilence: false))
        }
        try FileManager.default.removeItem(at: url)
        await #expect(throws: (any Error).self) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        }
        #expect(outputs == 0)
    }
}
