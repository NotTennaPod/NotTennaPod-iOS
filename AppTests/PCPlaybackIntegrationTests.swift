import XCTest
import UIKit
import MediaPlayer
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class PCPlaybackIntegrationTests: XCTestCase {
    func testActualDisconnectRowPersistsAndFailedSaveKeepsItsVisibleValue() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("PC-Disconnect-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hardware.json")
        let hardware = try PlaybackHardwarePreferenceStore(file: file)
        let view = NavigationSettingsView(navigation: nil, timeDisplay: nil, page: .playback,
            width: 390, playbackHardware: hardware)
        @MainActor func find(_ id: String, in view: UIView) -> UIControl? {
            if view.accessibilityIdentifier == id { return view as? UIControl }
            return view.subviews.compactMap { find(id, in: $0) }.first
        }
        let row = try XCTUnwrap(find("prefPauseOnHeadsetDisconnect", in: view))
        XCTAssertEqual(row.accessibilityValue, "On")
        row.sendActions(for: .touchUpInside)
        XCTAssertFalse(hardware.value.pauseOnDisconnect)
        XCTAssertFalse(try PlaybackHardwarePreferenceStore(file: file).value.pauseOnDisconnect)
        XCTAssertEqual(row.accessibilityValue, "Off")
        XCTAssertNil(find("prefUnpauseOnHeadsetReconnect", in: view))
        XCTAssertNil(find("prefUnpauseOnBluetoothReconnect", in: view))
        var failed = false; view.onFailure = { _ in failed = true }
        try FileManager.default.removeItem(at: root)
        row.sendActions(for: .touchUpInside)
        XCTAssertTrue(failed); XCTAssertFalse(hardware.value.pauseOnDisconnect)
        XCTAssertEqual(row.accessibilityValue, "Off")
    }
    func testNativeMetadataUsesOriginalTimeAndEffectiveRateAndOmitsUnknownDuration() async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            try await f.player.setSpeed(2)
            f.engine.position(42_000); try await f.player.awaitPendingOperations()
            var state = try XCTUnwrap(f.player.systemSnapshot)
            var values = PlaybackSystemControlsRuntime.nowPlayingInfo(state, feed: try await f.store.feed(id: 1), artwork: nil)
            XCTAssertEqual(values[MPMediaItemPropertyTitle] as? String, "Episode 1")
            XCTAssertEqual(values[MPMediaItemPropertyAlbumTitle] as? String, "System podcast")
            XCTAssertEqual(values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
            XCTAssertEqual(values[MPMediaItemPropertyPlaybackDuration] as? Double, 100)
            XCTAssertEqual(values[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 2)
            try await f.player.pause()
            state = try XCTUnwrap(f.player.systemSnapshot)
            values = PlaybackSystemControlsRuntime.nowPlayingInfo(state, feed: nil, artwork: nil)
            XCTAssertEqual(values[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 0)
            XCTAssertEqual(values[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Float, 2)
            f.engine.position(43_000, duration: -1)
            state = try XCTUnwrap(f.player.systemSnapshot)
            values = PlaybackSystemControlsRuntime.nowPlayingInfo(state, feed: nil, artwork: nil)
            XCTAssertNil(values[MPMediaItemPropertyPlaybackDuration])
            XCTAssertEqual(values[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
            XCTAssertFalse(PlaybackSystemControlsRuntime.available(.seek(milliseconds: 2000), state: state))
        }
    }

    func testNativeCommandMappingUsesLiveHardwareAndIntervalsAndRejectsMalformedValues() {
        var hardware = PlaybackHardwarePreferences(), intervals = PlaybackIntervalPreferences()
        func command(_ value: PlaybackSystemControlsRuntime.Input, remote: Bool = false) -> PlaybackSystemCommand? {
            PlaybackSystemControlsRuntime.command(value, hardware: hardware, intervals: intervals, remote: remote)
        }
        XCTAssertEqual(command(.next), .skip(seconds: 30, direction: .forward))
        XCTAssertEqual(command(.previous), .skip(seconds: 10, direction: .rewind))
        intervals.forwardSeconds = 45; intervals.rewindSeconds = 20
        XCTAssertEqual(command(.next), .skip(seconds: 45, direction: .forward))
        XCTAssertEqual(command(.previous), .skip(seconds: 20, direction: .rewind))
        hardware.forward = .next; hardware.previous = .restart
        XCTAssertEqual(command(.next), .next); XCTAssertEqual(command(.previous), .restart)
        XCTAssertEqual(command(.forward(15)), .skip(seconds: 15, direction: .forward))
        XCTAssertEqual(command(.backward(5)), .skip(seconds: 5, direction: .rewind))
        XCTAssertEqual(command(.position(42.5)), .seek(milliseconds: 42_500))
        XCTAssertEqual(command(.rate(4)), .rate(4)); XCTAssertNil(command(.rate(4), remote: true))
        XCTAssertEqual(command(.rate(2), remote: true), .rate(2))
        for value in [Double.nan, .infinity, -1] { XCTAssertNil(command(.position(value))); XCTAssertNil(command(.forward(value))) }
        XCTAssertNil(command(.rate(.nan)))
    }

}
