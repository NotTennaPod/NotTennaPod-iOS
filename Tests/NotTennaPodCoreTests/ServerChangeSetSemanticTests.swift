import Foundation
import Testing
@testable import NotTennaPodCore

/// The semantic oracle's own checks: the Go server's read API is compared with a phone on every canonical field, the
/// podcasts and episodes in both directions, and the device-only positions only as the reference holds them.
@Suite(.serialized) struct ServerChangeSetSemanticTests {
    /// Negative controls on a settled pair of phones: one canonical field or membership made wrong on the phone (B, which
    /// never parsed the feed itself) is reported; the clean phone is not.
    @Test(arguments: ["played time", "duration", "title", "publication date", "statistics units", "subscription state",
                      "a missing episode", "an extra episode", "favorite"])
    func theReadOracleReportsAWrongCanonicalField(field: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(10); try await player.pause()
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let reader = try await ServerReadOracle(world.server)
            var positions: [String: Int32] = [:]
            #expect(try await reader.differences(b, devicePositions: &positions, excluded: []).isEmpty, "clean")
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a, on: b)
            let other = try await ServerExchangeConcurrencyTests.same(ids[1], from: a, on: b)
            let wire = try #require(try await b.store.wireEpisodeForTesting(onB))
            func set(_ path: String, _ value: String, id: Int64) -> String {
                "UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '\(path)', \(value)) AS BLOB) WHERE id = \(id)"
            }
            let statement = switch field {
            case "played time": set("$.userState.playedDurationMilliseconds", "777777", id: onB)
            case "duration": set("$.details.media.durationMilliseconds", "1234", id: onB)
            case "title": set("$.details.title", "'Wrong'", id: onB)
            case "publication date": "UPDATE episodes SET pubdate = pubdate + 86400000, record = CAST(json_set(CAST(record AS TEXT), '$.details.publicationDate', json_extract(CAST(record AS TEXT), '$.details.publicationDate') + 86400) AS BLOB) WHERE id = \(onB)"
            case "statistics units": "INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES ('\(wire)', 'stray', x'7b7d')"
            case "subscription state": "UPDATE feeds SET record = CAST(json_set(CAST(record AS TEXT), '$.subscriptionState', 2) AS BLOB) WHERE id = (SELECT feed_id FROM episodes WHERE id = \(onB))"
            case "a missing episode": "DELETE FROM episodes WHERE id = \(other)"
            case "an extra episode": "INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) SELECT 'e1:' || hex(randomblob(32)), 900000, podcast_id, kind, 'extra' FROM ntp_episodes WHERE local_id = \(onB); INSERT INTO episodes(id, feed_id, pubdate, record) SELECT 900000, feed_id, pubdate, CAST(json_set(CAST(record AS TEXT), '$.id', 900000, '$.details.identifier', 'extra') AS BLOB) FROM episodes WHERE id = \(onB)"
            default: set("$.userState.isFavorite", "json('true')", id: onB)
            }
            try await b.store.databaseForTesting { db in try db.transaction { for part in statement.split(separator: ";") { try db.execute(String(part)) } } }
            let found = try await reader.differences(b, devicePositions: &positions, excluded: [])
            #expect(!found.isEmpty, "a wrong \(field) passes the read-API comparison")
        }
    }

    /// The rest of the canonical record and the statistics as the library shows them: on B (which never parsed the feed)
    /// a wrong episode description or link, a wrong podcast description, or a statistics row of its own (played 777777
    /// ms) that no server unit holds is reported; the clean phone is not.
    @Test(arguments: ["description", "link", "podcast description", "a library statistics unit"])
    func goOracleMustCompareDescriptionAndLocalStatistics(field: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let reader = try await ServerReadOracle(world.server)
            var positions: [String: Int32] = [:]
            #expect(try await reader.differences(b, devicePositions: &positions, excluded: []).isEmpty, "clean")
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a, on: b)
            func set(_ path: String, _ value: String, id: Int64) -> String {
                "UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '\(path)', \(value)) AS BLOB) WHERE id = \(id)"
            }
            let statement = switch field {
            case "description": set("$.details.description", "'Wrong notes'", id: onB)
            case "link": set("$.details.link", "'https://example.invalid/wrong'", id: onB)
            case "podcast description": "UPDATE feeds SET record = CAST(json_set(CAST(record AS TEXT), '$.metadata.description', 'Wrong') AS BLOB) WHERE id = (SELECT feed_id FROM episodes WHERE id = \(onB))"
            default: "INSERT INTO statistics_units(episode_id, unit_id, played_ms) VALUES (\(onB), 'stray', 777777)"
            }
            try await b.store.databaseForTesting { db in try db.execute(statement) }
            let found = try await reader.differences(b, devicePositions: &positions, excluded: [])
            #expect(!found.isEmpty, "a wrong \(field) passes the read-API comparison")
        }
    }

    /// The reference's device-only position: a paused seek on a never-played episode is the phone's own (PROTOCOL §8).
    /// The comparison accepts exactly that value, not another; once the person plays it, the position is the server's
    /// again and the entry resolves.
    @Test func aDevicePositionIsAcceptedOnlyAsTheReferenceHoldsItAndResolves() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            try await player.seek(to: 120_000); try await player.pause()
            try await player.load(ids[1])
            await a.exchange()
            let reader = try await ServerReadOracle(world.server)
            let wire = try #require(try await a.store.wireEpisodeForTesting(ids[0]))
            var none: [String: Int32] = [:]
            #expect(try await reader.differences(a, devicePositions: &none, excluded: []).contains { $0.contains("position") }, "without the reference")
            #expect(try await reader.differences(a, devicePositions: &none, excluded: []).contains { $0.contains("duration") }, "a measured duration without the reference")
            var wrong: [String: Int32] = [wire: 60_000]
            #expect(try await reader.differences(a, devicePositions: &wrong, excluded: []).contains { $0.contains("position") }, "another value")
            var held: [String: Int32] = [wire: 120_000]
            let selected = try #require(try await a.store.wireEpisodeForTesting(ids[1]))
            // The reference also holds the durations the player measured on loading both episodes.
            var durations: [String: Int32] = [wire: 600_000, selected: 600_000]
            let accepted = try await reader.differences(a, devicePositions: &held, deviceDurations: &durations, excluded: [selected])
            #expect(accepted.isEmpty, "\(accepted)")
            #expect(held[wire] == 120_000, "kept while the device holds it")
            // A Play here: the listening makes the position the server's; the entry resolves.
            try await player.load(ids[0]); try await player.play(); try await player.listen(5); try await player.pause()
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            for _ in 0..<2 { await a.exchange() }
            let resolved = try await reader.differences(a, devicePositions: &held, deviceDurations: &durations, excluded: [])
            #expect(resolved.isEmpty, "\(resolved)")
            #expect(held[wire] == nil, "resolved")
        }
    }
}
