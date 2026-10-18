import Foundation
import Testing
@testable import NotTennaPodCore

/// A library found in another folder (a device restore, a new phone, a Keep) has its owned paths rewritten before it opens
/// (PROTOCOL §15.4). That runs at launch, so its work must follow the records that hold an owned path, not the size of the
/// library: it used to decode and search every episode, about 10 s for 26,000 before anything was drawn.
@Suite(.serialized) struct LibraryOwnedPathsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OwnedPaths-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The normalization this replaced, kept as the reference: every record that mentions `media` is decoded and searched.
    @discardableResult
    private static func fullScan(_ database: LibrarySQLite, folder: URL) throws -> Int {
        guard let identity = try database.libraryIdentity() else { return 0 }
        let current = LibraryOwnedPaths.root(of: folder)
        guard identity.pathsRoot != current else { return 0 }
        return try database.transaction {
            var rewritten = 0
            for table in ["episodes", "download_jobs", "pending_effects"] {
                for row in try database.rows("SELECT rowid, record FROM \(table) WHERE instr(CAST(record AS TEXT), 'media') > 0") {
                    guard let id = row[0].integer, let data = row[1].data,
                          let next = LibraryOwnedPaths.rewrite(data, from: identity.pathsRoot, to: current) else { continue }
                    try database.execute("UPDATE \(table) SET record = ? WHERE rowid = ?", [.blob(next), .integer(id)])
                    rewritten += 1
                }
            }
            try database.execute("UPDATE library_identity SET paths_root = ? WHERE id = 1", [.text(current)])
            return rewritten
        }
    }

    /// Every record of the three tables normalization writes, and `paths_root`.
    private static func contents(_ database: LibrarySQLite) throws -> [String: [Int64: Data]] {
        var result: [String: [Int64: Data]] = [:]
        for table in ["episodes", "download_jobs", "pending_effects"] {
            for row in try database.rows("SELECT rowid, record FROM \(table)") {
                result[table, default: [:]][row[0].integer ?? -1] = row[1].data
            }
        }
        result["paths_root"] = [1: Data((try database.libraryIdentity()?.pathsRoot ?? "").utf8)]
        return result
    }

    /// A bare library at `url` whose owned paths were written under `root`, holding `records` in each of the three tables.
    private static func library(_ url: URL, writtenUnder root: String, records: [Data]) throws -> LibrarySQLite {
        let database = try LibrarySQLite(url: url)
        try database.execute("PRAGMA foreign_keys = OFF")
        try database.transaction {
            try database.execute("UPDATE library_identity SET paths_root = ? WHERE id = 1", [.text(root)])
            for (index, record) in records.enumerated() {
                try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, 1, 0, ?)", [.integer(Int64(index + 1)), .blob(record)])
                try database.execute("INSERT INTO download_jobs(episode_id, source, active, record) VALUES (?, ?, 0, ?)",
                                     [.integer(Int64(index + 1)), .text("source-\(index)"), .blob(record)])
                try database.execute("INSERT INTO pending_effects(record, kind) VALUES (?, 'test')", [.blob(record)])
            }
        }
        return database
    }

    /// The old and new normalization on two copies of the same records: the same rows, byte for byte, and the same
    /// `paths_root`. Returns the rows each read in Swift (the new one) and rewrote.
    private func expectEquivalent(_ records: [Data], from old: String, to new: String,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws -> (examined: Int, rewritten: Int) {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = URL(fileURLWithPath: new, isDirectory: true)
        let reference = try Self.library(directory.appendingPathComponent("reference.sqlite"), writtenUnder: old, records: records)
        let subject = try Self.library(directory.appendingPathComponent("subject.sqlite"), writtenUnder: old, records: records)
        defer { try? reference.close(); try? subject.close() }
        let expected = try Self.fullScan(reference, folder: target)
        let result = try LibraryOwnedPaths.normalize(subject, folder: target)
        #expect(result.rewritten == expected, sourceLocation: sourceLocation)
        let (before, after) = (try Self.contents(reference), try Self.contents(subject))
        #expect(before == after, "the rewritten records differ from the full scan's", sourceLocation: sourceLocation)
        return result
    }

    /// The text forms an owned path takes in the app's records, and look-alikes that are not owned.
    private static func fragments(old: String, new: String) -> (owned: [String], other: [String]) {
        func url(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }
        func escaped(_ text: String) -> String { text.replacingOccurrences(of: "/", with: "\\/") }
        func quoted(_ text: String) -> String { "\"" + text + "\"" }
        let file = old + "/media/feed-1/episode 1.mp3"
        let forms: [String] = [file, escaped(file), url(file), escaped(url(file)), old + "/media/"]
        var owned: [String] = forms.map(quoted)
        // Canonically equivalent text, which the old search matched: NFD, and KELVIN SIGN for K.
        owned += forms.map { quoted($0.decomposedStringWithCanonicalMapping) }
        owned += forms.map { quoted($0.replacingOccurrences(of: "K", with: "\u{212A}", options: .literal)) }
        // Mixed: one character decomposed, the others not (neither NFC nor NFD).
        owned.append(quoted(file.replacingOccurrences(of: "\u{E8}", with: "e\u{300}", options: .literal)))
        // Inside a JSON string that is itself inside a record (an escaped quote before the path).
        owned.append("\"{\\\"file\\\":\\\"" + file + "\\\"}\"")
        // As the encoders write them.
        let slashes = JSONEncoder()
        let plain = JSONEncoder()
        plain.outputFormatting = .withoutEscapingSlashes
        for encoder in [slashes, plain] {
            owned.append(String(decoding: try! encoder.encode(["path": file]), as: UTF8.self))
            owned.append(String(decoding: try! encoder.encode(["files": [URL(fileURLWithPath: file)]]), as: UTF8.self))
        }
        let parent = (old as NSString).deletingLastPathComponent
        let elsewhere: [String] = ["/private/var/LocalFolder/episode.mp3", old + "2/media/episode.mp3",
                                   old + "/streaming-cache/episode.mp3", new + "/media/episode.mp3", parent + "/media/episode.mp3"]
        var other: [String] = []
        for path in elsewhere {
            other += [quoted(path), quoted(escaped(path)), quoted(url(path)), quoted(escaped(url(path)))]
        }
        // Not at the start of a JSON string, and records that mention media without a path.
        other += ["\"see " + file + "\"", "{\"media\":{\"url\":\"https:\\/\\/example.test\\/media\\/1.mp3\"}}", "media", ""]
        return (owned, other)
    }

    private static let roots: [(old: String, new: String)] = [
        // As on a phone: the container's folder changes; the library's folder name has a space (escaped in file URLs).
        ("/private/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000001/Library/Application Support",
         "/private/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000002/Library/Application Support"),
        // A server library whose name is outside ASCII (written NFC; records may hold it NFD or mixed).
        ("/private/var/Containers/Library/Application Support/Server Libraries/Biblioth\u{E8}que-\u{E9}t\u{E9}",
         "/private/var/Containers/Library/Application Support/Server Libraries/Nouvelle"),
        // The longest component has a K, which KELVIN SIGN equals: it cannot be the anchor.
        ("/u/KKKKKKKKKKKKKKKKKKKK/Kit Folder/abc", "/u/new"),
        // No component a file URL keeps as it is: the anchor is media, as the old search's.
        ("/a b/c d", "/e f/g h"),
    ]

    /// Every owned-path form, in every table, under each kind of root: the same records as the full scan, byte for byte;
    /// look-alikes elsewhere stay as they are.
    @Test(arguments: 0..<4) func everyOwnedPathFormIsRewrittenAsTheFullScanDid(_ index: Int) throws {
        let (old, new) = Self.roots[index]
        let (owned, other) = Self.fragments(old: old, new: new)
        var records = (owned + other).map { Data($0.utf8) }
        // Several forms in one record, and an owned path among other text.
        records.append(Data(("{\"a\":" + owned[0] + ",\"b\":" + owned[3] + ",\"c\":" + other[0] + "}").utf8))
        records.append(Data(("{\"description\":\"" + String(repeating: "media ", count: 400) + "\",\"file\":" + owned[1] + "}").utf8))
        let result = try expectEquivalent(records, from: old, to: new)
        #expect(result.rewritten == 3 * (owned.count + 2), "every record with an owned path, in each table")
        let anchor = String(decoding: LibraryOwnedPaths.recordAnchor(old), as: UTF8.self)
        #expect(anchor == ["00000000-0000-4000-8000-000000000001", "Containers", "abc", "media"][index])
    }

    /// Random records built from owned forms, look-alikes and noise (punctuation, escapes, other scripts, combining
    /// marks): the same result as the full scan for every one, with a fixed seed.
    @Test(arguments: 0..<4) func randomRecordsAreRewrittenAsTheFullScanDid(_ index: Int) throws {
        let (old, new) = Self.roots[index]
        let (owned, other) = Self.fragments(old: old, new: new)
        let noise: [String] = ["\"", "\\", "\\/", "/", ":", ",", "{", "}", "media", "/media/", "file://", " ", "\u{301}", "\u{E9}", "e\u{301}",
                     "\u{1F600}", "\u{5D0}", "%20", "K", "\u{212A}", "e\u{300}", "\u{E8}", old, new, String(old.dropLast()), "\"" + String(old.dropFirst())]
        var generator = SeededGenerator(seed: UInt64(index + 1))
        var records: [Data] = []
        for _ in 0..<1_500 {
            var text = ""
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                switch Int.random(in: 0..<10, using: &generator) {
                case 0..<3: text += owned.randomElement(using: &generator)!
                case 3..<5: text += other.randomElement(using: &generator)!
                default: text += noise.randomElement(using: &generator)!
                }
            }
            records.append(Data(text.utf8))
        }
        let result = try expectEquivalent(records, from: old, to: new)
        #expect(result.rewritten > 0)
    }

    /// 26,271 episodes of realistic size (a large real-world library), 271 downloaded, plus a download job:
    /// normalization reads and rewrites those 272 records only; every other record stays byte for byte.
    @Test func aMovedLargeLibraryReadsOnlyTheRecordsWithOwnedPaths() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("00000000-0000-4000-8000-000000000001/Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let url = container.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        var fetched = ServerLibraryFixture.fetched(count: 2)
        for index in fetched.feed.episodes.indices { fetched.feed.episodes[index].description = String(repeating: "Show notes. ", count: 190) }
        let feed = try await store.insert(fetched)
        let episodes = feed.episodes.map(\.id).sorted()
        let media = container.appendingPathComponent("media", isDirectory: true)
        try await store.updateEpisode(id: episodes[0]) { episode in
            episode.userState.isDownloaded = true
            episode.userState.localFileURL = media.appendingPathComponent("episode-1.media").path
        }
        _ = try await store.requestDownload(episodeID: episodes[1], directory: media)
        try await store.close()

        let database = try LibrarySQLite(url: url)
        let old = try #require(try database.libraryIdentity()).pathsRoot
        #expect(old == LibraryOwnedPaths.root(of: container))
        let downloaded = try #require(try database.rows("SELECT record FROM episodes WHERE id = ?", [.integer(episodes[0])]).first?.first?.data)
        let plain = try #require(try database.rows("SELECT record FROM episodes WHERE id = ?", [.integer(episodes[1])]).first?.first?.data)
        #expect(plain.count > 2_000)
        // Clones up to 26,271 episodes; one in 97 downloaded (270 more).
        try database.transaction {
            try database.execute("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 26269)
                INSERT INTO episodes(id, feed_id, pubdate, record) SELECT 100000 + i, ?, i, CASE WHEN i % 97 = 0 THEN ? ELSE ? END FROM n
                """, [.integer(feed.id), .blob(downloaded), .blob(plain)])
        }
        #expect(try database.scalar("SELECT count(*) FROM episodes") == 26_271)
        let owned = Int(try database.scalar("SELECT count(*) FROM episodes WHERE record = ?", [.blob(downloaded)]))
            + Int(try database.scalar("SELECT count(*) FROM download_jobs"))
        #expect(owned == 272)

        // The phone's folder moved: the container is another one.
        let moved = directory.appendingPathComponent("00000000-0000-4000-8000-000000000002/Library/Application Support", isDirectory: true)
        let start = ContinuousClock.now
        let result = try LibraryOwnedPaths.normalize(database, folder: moved)
        let elapsed = ContinuousClock.now - start
        print("OWNED-PATHS timing: 26,271 episodes, moved root, \(elapsed)")
        #expect(result.examined == owned, "read only the records with an owned path: \(result.examined)")
        #expect(result.rewritten == owned)
        // A budget far above the measured time (about 0.1 s on a Mac), far below the full scan's (about 10 s).
        #expect(elapsed < .seconds(3), "\(elapsed)")

        let current = LibraryOwnedPaths.root(of: moved)
        #expect(try database.libraryIdentity()?.pathsRoot == current)
        let expected = try #require(LibraryOwnedPaths.rewrite(downloaded, from: old, to: current))
        #expect(try database.scalar("SELECT count(*) FROM episodes WHERE record = ?", [.blob(expected)]) == 271)
        #expect(try database.scalar("SELECT count(*) FROM episodes WHERE record = ?", [.blob(plain)]) == 26_000)
        let job = try #require(try database.rows("SELECT record FROM download_jobs").first?.first?.data)
        #expect(LibraryOwnedPaths.rewrite(job, from: old, to: current) == nil, "no path under the old root is left")
        #expect(String(decoding: job, as: UTF8.self).contains(LibraryOwnedPaths.recordForms(current)[3]), "the job's destination is under the new root")
        try database.close()
    }

    /// The library is where its paths were written (every ordinary launch): normalization reads only the identity.
    @Test func aLibraryThatHasNotMovedIsNotSearched() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibrarySQLite(url: directory.appendingPathComponent("library.sqlite"))
        defer { try? database.close() }
        var (statements, steps) = (database.statementsRun, database.statementSteps)
        _ = try database.libraryIdentity()
        let identityRead = (database.statementsRun - statements, database.statementSteps - steps)
        (statements, steps) = (database.statementsRun, database.statementSteps)
        let result = try LibraryOwnedPaths.normalize(database, folder: directory)
        #expect(result == (0, 0))
        #expect((database.statementsRun - statements, database.statementSteps - steps) == identityRead)
    }
}

/// SplitMix64: the same sequence for a seed on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
