import XCTest
import GoogleCast
@testable import NotTennaPod

@MainActor final class CastMediaItemCodecTests: XCTestCase {
    func testDownloadedEpisodeRetainsRemoteAndLocalIdentity() {
        let item = CastMediaItemCodec.Item(contentURL: "https://media.example/episode.mp3?token=fixture",
            mediaID: "9223372036854775806", localPlaybackURL: "file:///media/downloaded.mp3",
            title: "Episode — 日本語", subtitle: "Podcast", artworkURL: URL(string: "https://media.example/cover.jpg"))
        let encoded = CastMediaItemCodec.encode(item)
        XCTAssertEqual(encoded.mediaInformation.contentID, item.contentURL)
        XCTAssertEqual(encoded.mediaInformation.metadata?.metadataType, .generic)
        XCTAssertTrue(encoded.autoplay)
        XCTAssertEqual(CastMediaItemCodec.decode(encoded.mediaInformation), item)
    }

    /// PROTOCOL §15.4: a standalone load's metadata is exactly what it was before libraries existed; a server library's
    /// adds only its library ID.
    func testStandaloneMetadataIsUnchangedAndServerLoadsAddTheirLibrary() throws {
        let loadID = UUID()
        let item = CastMediaItemCodec.Item(contentURL: "https://relay.example/episode", mediaID: "42",
            localPlaybackURL: "file:///media/downloaded.mp3", title: "Episode", subtitle: "Podcast",
            artworkURL: URL(string: "https://media.example/cover.jpg"))
        // The metadata as this codec wrote it before the library tag.
        let before = GCKMediaMetadata(metadataType: .generic)
        before.setString("Episode", forKey: kGCKMetadataKeyTitle); before.setString("Podcast", forKey: kGCKMetadataKeySubtitle)
        before.setString("42", forKey: "media_id"); before.setString("file:///media/downloaded.mp3", forKey: "local_file_url")
        before.setString(loadID.uuidString, forKey: "org.nottennapod.app.load_id")
        before.addImage(GCKImage(url: URL(string: "https://media.example/cover.jpg")!, width: 0, height: 0))
        func strings(_ metadata: GCKMediaMetadata) -> [String: String] {
            Dictionary(uniqueKeysWithValues: metadata.allKeys().map { ($0, metadata.string(forKey: $0) ?? "") })
        }
        let standalone = CastMediaItemCodec.encode(item, loadID: loadID).mediaInformation
        let metadata = try XCTUnwrap(standalone.metadata)
        XCTAssertEqual(strings(metadata), strings(before))
        XCTAssertEqual((metadata.images() as? [GCKImage])?.map(\.url), (before.images() as? [GCKImage])?.map(\.url))
        XCTAssertEqual(standalone.contentID, "https://relay.example/episode")
        XCTAssertNil(CastMediaItemCodec.decode(standalone).libraryID)

        var tagged = item; tagged.libraryID = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        let server = try XCTUnwrap(CastMediaItemCodec.encode(tagged, loadID: loadID).mediaInformation.metadata)
        var expected = strings(before); expected[CastMediaItemCodec.libraryIDKey] = tagged.libraryID
        XCTAssertEqual(strings(server), expected)
        XCTAssertEqual(CastMediaItemCodec.decode(CastMediaItemCodec.encode(tagged).mediaInformation), tagged)
    }

    func testStreamOnlyReceiverItemUsesContentURLForLocalHandback() {
        let information = GCKMediaInformationBuilder(contentURL: URL(string: "https://example.org/stream.mp3")!)
        let metadata = GCKMediaMetadata(metadataType: .generic)
        metadata.setString("27", forKey: "media_id")
        metadata.addImage(GCKImage(url: URL(string: "https://example.org/first.png")!, width: 128, height: 128))
        metadata.addImage(GCKImage(url: URL(string: "https://example.org/second.png")!, width: 256, height: 256))
        information.metadata = metadata
        let result = CastMediaItemCodec.decode(information.build())
        XCTAssertEqual(result.mediaID, "27")
        XCTAssertEqual(result.contentURL, "https://example.org/stream.mp3")
        XCTAssertEqual(result.localPlaybackURL, result.contentURL)
        XCTAssertEqual(result.artworkURL?.lastPathComponent, "first.png")
    }

    func testMissingStreamDoesNotExposeLocalFileAsReceiverContent() {
        let item = CastMediaItemCodec.Item(mediaID: "", localPlaybackURL: "file:///media/local-only.mp3")
        let information = CastMediaItemCodec.encode(item).mediaInformation
        XCTAssertEqual(information.contentID, "")
        XCTAssertFalse(information.metadata!.containsKey("media_id"))
        XCTAssertEqual(CastMediaItemCodec.decode(information).localPlaybackURL, item.localPlaybackURL)
        XCTAssertEqual(CastMediaItemCodec.decode(nil), CastMediaItemCodec.Item())
    }

    func testIdleReasonDistinguishesNaturalEndFromStopAndFailure() {
        // Source scenarios: natural completion, explicit stop, interruption,
        // receiver error, and a stale FINISHED reason outside the idle state.
        let reasons: [GCKMediaPlayerIdleReason] = [.none, .finished, .cancelled, .interrupted, .error]
        let cases: [(GCKMediaPlayerState, [Bool])] = [
            (.unknown, [false, false, false, false, false]),
            (.idle, [false, true, false, false, false]),
            (.playing, [false, false, false, false, false]),
            (.paused, [false, false, false, false, false]),
            (.buffering, [false, false, false, false, false]),
            (.loading, [false, false, false, false, false])
        ]
        for (state, outcomes) in cases {
            for (reason, expected) in zip(reasons, outcomes) {
                XCTAssertEqual(CastMediaItemCodec.hasPlaybackJustFinished(state: state, idleReason: reason),
                               expected, "\(state) / \(reason)")
            }
        }
    }

    func testApplicationPackagesDiscoveryDeclarationsAndSDKResources() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String],
                       ["_googlecast._tcp", "_CC1AD845._googlecast._tcp"])
        XCTAssertFalse(try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String).isEmpty)
        for name in ["GoogleCastCoreResources", "GoogleCastUIResources", "GoogleCastOptionalUIResources",
                     "GoogleSansRegular", "GoogleSansMedium", "GoogleSansBold", "MaterialDialogs", "GoogleCastPrivacy"] {
            XCTAssertNotNil(bundle.url(forResource: name, withExtension: "bundle"), name)
        }
        let privacy = try XCTUnwrap(bundle.url(forResource: "GoogleCastPrivacy", withExtension: "bundle"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: privacy.appendingPathComponent("PrivacyInfo.xcprivacy").path))
    }
}
