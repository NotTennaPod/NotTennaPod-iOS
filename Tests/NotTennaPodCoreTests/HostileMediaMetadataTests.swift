import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Damaged and hostile media files never crash or stall the readers that run
/// when a person opens chapters, imports a local folder or shows an episode's cover: ID3 tags (comments,
/// chapters, pictures), MP4 atoms (Nero chapters, metadata), Ogg/Opus comments and Podcast Index chapter
/// JSON. Android reads such files with its own readers and shows no chapters, description or cover when they
/// fail; here a read may likewise fail or return less, but it must end, within a bound, without a crash.
/// Every read runs on a thread with iOS's 512 KB secondary-thread stack; its bound is the CPU time that thread uses.
@Suite(.serialized) struct HostileMediaMetadataTests {
    struct Bounded<T: Sendable>: Sendable {
        let value: T?
        /// Wall time, which a loaded host stretches.
        let seconds: Double
        /// CPU time of the reading thread: the reader's own work, which a loaded host does not stretch the same way.
        let cpuSeconds: Double
    }

    /// Runs `body` on a 512 KB-stack thread and waits for it. The reader's work is bounded by the CPU time its thread
    /// uses: a read that uses more than `cpuLimit` seconds of CPU is recorded and left running, as is one that has
    /// not ended after `wallLimit` seconds without using the CPU (blocked). Waiting polls the thread's CPU time while
    /// waiting for the read to end.
    static func bounded<T: Sendable>(_ label: String, cpuLimit: Double = 10, wallLimit: Double = 120,
                                     _ body: @escaping @Sendable () throws -> T) -> Bounded<T> {
        let box = Mutex<(value: T?, cpu: Double)>((nil, 0)), port = Mutex<thread_act_t>(0), done = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        let thread = Thread {
            port.withLock { $0 = mach_thread_self() }
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let value = try? body()
            box.withLock { $0 = (value, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e9) }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        func seconds(_ elapsed: Duration) -> Double { Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            let used = threadCPUSeconds(port.withLock { $0 })
            if used > cpuLimit {
                Issue.record("\(label) used more than \(cpuLimit) s of CPU")
                return Bounded(value: nil, seconds: seconds(ContinuousClock.now - start), cpuSeconds: used)
            }
            if seconds(ContinuousClock.now - start) > wallLimit {
                Issue.record("\(label) did not finish within \(wallLimit) s")
                return Bounded(value: nil, seconds: wallLimit, cpuSeconds: used)
            }
        }
        let port_ = port.withLock { $0 }
        if port_ != 0 { mach_port_deallocate(mach_task_self_, port_) }
        let result = box.withLock { $0 }
        return Bounded(value: result.value, seconds: seconds(ContinuousClock.now - start), cpuSeconds: result.cpu)
    }

    /// The CPU time a running thread has used (0 before it has started).
    static func threadCPUSeconds(_ thread: thread_act_t) -> Double {
        guard thread != 0 else { return 0 }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// Whether work grew with the input rather than with its square: ten times the input may take at most twenty times
    /// the CPU (linear work takes about ten times; work growing with the square, a hundred). Both are measured in the
    /// same run, so a loaded host slows both alike.
    static func growsLinearly(_ large: Double, _ small: Double) -> Bool { large <= 20 * max(small, 0.005) }

    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: path, withExtension: nil, subdirectory: "Fixtures")))
    }

    struct Reading: Sendable {
        var chapters: [ParsedChapter]?; var comment: String?; var metadata: LocalFileMetadata?; var artwork: Data?
        /// The CPU time each reader used, and all four.
        var cpu: [String: Double] = [:]
        var cpuSeconds: Double { cpu.values.reduce(0, +) }
    }

    /// Every reader a person's actions reach for a local or downloaded file.
    static func readAll(_ url: URL, label: String) -> Reading {
        var reading = Reading()
        let chapters = bounded("\(label) chapters") { try EmbeddedChapterReader.read(url: url, checkCancellation: {}) }
        let comment = bounded("\(label) ID3 comment") { try ID3CommentReader.read(url: url) }
        let metadata = bounded("\(label) metadata") { try LocalMediaMetadataReader.read(url: url, checkCancellation: {}) }
        let artwork = bounded("\(label) artwork") { try LocalMediaMetadataReader.artwork(url: url, checkCancellation: {}) }
        reading.chapters = chapters.value ?? nil; reading.comment = comment.value ?? nil
        reading.metadata = metadata.value; reading.artwork = artwork.value ?? nil
        reading.cpu = ["chapters": chapters.cpuSeconds, "comment": comment.cpuSeconds, "metadata": metadata.cpuSeconds, "artwork": artwork.cpuSeconds]
        return reading
    }

    /// What a person would notice as wrong output: chapters out of order or before the start, a cover larger
    /// than the file, a negative duration.
    static func checkSane(_ reading: Reading, fileSize: Int, label: String) {
        if let chapters = reading.chapters {
            #expect(chapters.allSatisfy { $0.startMilliseconds >= 0 }, "\(label): chapter before the start")
            #expect(zip(chapters, chapters.dropFirst()).allSatisfy { $0.startMilliseconds <= $1.startMilliseconds }, "\(label): chapter order")
        }
        if let artwork = reading.artwork { #expect(artwork.count <= fileSize, "\(label): cover larger than the file") }
        if let duration = reading.metadata?.durationMilliseconds { #expect(duration >= 0, "\(label): negative duration") }
    }

    static let seeds = ["EmbeddedChapters/original-auphonic.mp3", "EmbeddedChapters/id3-v4-embedded.mp3",
                        "EmbeddedChapters/id3-v3-ordered.mp3", "EmbeddedChapters/original-nero-chapters.m4a",
                        "AACEdits/hev2-forward.m4a", "EmbeddedChapters/original-auphonic.ogg",
                        "EmbeddedChapters/original-auphonic.opus", "playback-silence.mp3"]

    /// Positions of size fields: the four bytes before an MP4 atom type and after an ID3 frame identifier.
    static func sizeFields(_ bytes: [UInt8]) -> [Int] {
        func letter(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0xA9 }
        var positions: [Int] = []
        var index = 0
        while index + 8 <= bytes.count {
            if bytes[(index + 4)..<(index + 8)].allSatisfy(letter) { positions.append(index) }
            if bytes[index..<(index + 4)].allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) { positions.append(index + 4) }
            index += 1
        }
        return positions
    }

    static let sizes: [UInt32] = [0, 1, 7, 8, 0x7F, 0x7F7F_7F7F, 0x7FFF_FFFF, 0xFFFF_FFFF, 0x8000_0000, 0x0000_FFFF]

    /// 60 deterministic mutations per seed: size fields set to hostile values, bit flips, zeroed and
    /// duplicated ranges, truncation.
    static func mutations() throws -> [(name: String, data: Data)] {
        var random = LargeAndroidLibrary.Random(state: 0x3ED_1A_2026_0008)
        var result: [(String, Data)] = []
        for seed in seeds {
            let original = [UInt8](try fixture(seed))
            let fields = sizeFields(original)
            for number in 0..<60 {
                var bytes = original
                func position() -> Int { random.int(0...max(0, bytes.count - 1)) }
                switch number % 5 {
                case 0, 1:
                    for _ in 0..<random.int(1...3) where !fields.isEmpty {
                        let at = fields[random.int(0...(fields.count - 1))], value = sizes[random.int(0...(sizes.count - 1))]
                        for offset in 0..<4 where at + offset < bytes.count { bytes[at + offset] = UInt8(truncatingIfNeeded: value >> (24 - 8 * offset)) }
                    }
                case 2: for _ in 0..<random.int(1...8) { bytes[position()] ^= UInt8(1 << random.int(0...7)) }
                case 3:
                    let start = position(), end = min(bytes.count, start + random.int(1...512))
                    if random.chance(2) { bytes.replaceSubrange(start..<end, with: repeatElement(0, count: end - start)) }
                    else { bytes.insert(contentsOf: bytes[start..<end], at: position()) }
                default: bytes = Array(bytes.prefix(position()))
                }
                let name = seed.split(separator: "/").last!
                result.append(("\(number)-\(name)", Data(bytes)))
            }
        }
        return result
    }

    @Test func seededMediaMutationsNeverCrashOrStall() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GapRobustMedia-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var slowest = (name: "", seconds: 0.0)
        for (name, data) in try Self.mutations() {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let reading = Self.readAll(url, label: name)
            Self.checkSane(reading, fileSize: data.count, label: name)
            if reading.cpuSeconds > slowest.seconds { slowest = (name, reading.cpuSeconds) }
            try FileManager.default.removeItem(at: url)
        }
        #expect(slowest.seconds < 3, "most CPU: \(slowest.name) \(slowest.seconds) s")
    }

    // MARK: - Hand-made hostile files

    static func id3(version: UInt8 = 3, frames: [(String, [UInt8])], declaredSize: Int? = nil) -> [UInt8] {
        func size(_ value: Int, synchsafe: Bool) -> [UInt8] {
            synchsafe ? [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
                : [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        var body: [UInt8] = []
        for (id, payload) in frames { body += Array(id.utf8) + size(payload.count, synchsafe: version == 4) + [0, 0] + payload }
        return Array("ID3".utf8) + [version, 0, 0] + size(declaredSize ?? body.count, synchsafe: true) + body
    }
    static func chap(_ id: String, start: UInt32, title: String) -> [UInt8] {
        let tit2 = [0] + Array(title.utf8)
        return Array(id.utf8) + [0] + [UInt8(start >> 24), UInt8(start >> 16 & 0xFF), UInt8(start >> 8 & 0xFF), UInt8(start & 0xFF)]
            + Array(repeating: 0xFF, count: 12) + Array("TIT2".utf8) + [0, 0, 0, UInt8(tit2.count), 0, 0] + tit2
    }
    static func atom(_ type: String, _ payload: [UInt8], size: UInt32? = nil) -> [UInt8] {
        let value = size ?? UInt32(payload.count + 8)
        return [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] + Array(type.utf8) + payload
    }

    @Test func handMadeHostileFilesEndQuickly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GapRobustMediaHand-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let silence = [UInt8](try Self.fixture("playback-silence.mp3"))
        let manyChapters = (0..<50_000).map { Self.chap("c\($0)", start: UInt32($0) * 1000, title: "Chapter \($0)") }
        let tenthChapters = Array(manyChapters.prefix(5_000))
        let files: [(String, [UInt8])] = [
            // An ID3 header announcing 256 MB in a file of a few kilobytes.
            ("id3-huge-size.mp3", Self.id3(frames: [("COMM", [0] + Array("engcomment".utf8))], declaredSize: 0x0FFF_FFFF) + silence),
            // 50,000 chapters: all are read, in order, with work proportional to their number (compared below).
            ("id3-many-chapters.mp3", Self.id3(frames: manyChapters.map { ("CHAP", $0) }) + silence),
            // A picture frame claiming far more bytes than follow.
            ("id3-apic-overrun.mp3", Self.id3(frames: [("APIC", [0] + Array("image/png".utf8) + [0, 3, 0] + Array(repeating: 0x89, count: 64))]).enumerated()
                .map { $0.offset == 17 ? 0x7F : $0.element } + silence),
            // Nero chapters: a count of four billion with two entries; a zero-sized and an oversized atom.
            ("mp4-chpl-count.m4a", Self.atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + Self.atom("moov", Self.atom("udta",
                Self.atom("chpl", [1, 0, 0, 0, 0] + [0xFF, 0xFF, 0xFF, 0xFF] + [0, 0, 0, 0, 0, 0, 0, 0, 2] + Array("A1".utf8))))),
            ("mp4-zero-atom.m4a", Self.atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + Self.atom("moov", [], size: 0) + Array(repeating: 0, count: 4096)),
            ("mp4-huge-atom.m4a", Self.atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + Self.atom("moov", [], size: 1)
                + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + Array(repeating: 0, count: 64)),
            ("mp4-nested-moov.m4a", Self.atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
                + (0..<10_000).reduce([UInt8]()) { inner, _ in Self.atom("moov", inner) }),
            // A tenth of the chapters, to compare the work with.
            ("id3-tenth-chapters.mp3", Self.id3(frames: tenthChapters.map { ("CHAP", $0) }) + silence),
        ]
        var readings: [String: Reading] = [:]
        for (name, bytes) in files {
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            let reading = Self.readAll(url, label: name)
            readings[name] = reading
            Self.checkSane(reading, fileSize: bytes.count, label: name)
            print("hostile \(name): \(reading.cpu.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) s of CPU")
            #expect(reading.cpuSeconds < 10, "\(name) used \(reading.cpuSeconds) s of CPU")
            if name == "id3-many-chapters.mp3" {
                #expect(reading.chapters?.count == 50_000 && reading.chapters?.last?.title == "Chapter 49999")
            }
            if name == "id3-huge-size.mp3" { #expect(reading.chapters == nil) }
        }
        // 50,000 chapters take each reader about ten times the work of 5,000, not a hundred.
        let many = try #require(readings["id3-many-chapters.mp3"]), tenth = try #require(readings["id3-tenth-chapters.mp3"])
        #expect(tenth.chapters?.count == 5_000)
        for (reader, cpu) in many.cpu {
            #expect(Self.growsLinearly(cpu, tenth.cpu[reader] ?? 0), "\(reader): \(cpu) s of CPU for 50,000 chapters, \(tenth.cpu[reader] ?? 0) s for 5,000")
        }
    }

    /// A downloaded MP3 whose tag holds 50,000 frames: Apple's AudioFile needed seconds (growing with the
    /// square of the count) to open it for the download's duration and for playback; it now opens at once and
    /// the duration is the audio's.
    @Test func floodedTagOpensForDurationAndPlaybackQuickly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GapRobustFlood-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let silence = try Self.fixture("playback-silence.mp3")
        let plain = directory.appendingPathComponent("plain.mp3"), flooded = directory.appendingPathComponent("flooded.mp3")
        try silence.write(to: plain)
        let frames = (0..<50_000).map { ("CHAP", Self.chap("c\($0)", start: UInt32($0) * 1000, title: "Chapter \($0)")) }
        try (Data(Self.id3(frames: frames)) + silence).write(to: flooded)
        let expected = try #require(try await MediaDownloadWorker.mediaDuration(plain))
        let start = ContinuousClock.now
        let duration = try await MediaDownloadWorker.mediaDuration(flooded)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(duration.map { abs(Int($0) - Int(expected)) <= 50 } == true, "\(String(describing: duration)) vs \(expected)")
        let opened = Self.bounded("playback open", cpuLimit: 3) { () -> Bool in
            let input = try NativeAudioFileInput(url: flooded); defer { input.close() }
            return try input.fileType() == kAudioFileMP3Type
        }
        #expect(opened.value == true && opened.seconds < 1)
        // The tag's own readers still see every chapter.
        #expect(try EmbeddedChapterReader.read(url: flooded, checkCancellation: {})?.count == 50_000)
    }

    /// Podcast Index chapter JSON from a podcast's server: deep nesting is refused without a crash, and objects with
    /// very many keys and very many chapters parse with work that grows with their size (CPU time of the reading
    /// thread, compared with a tenth of the input in the same run).
    @Test func hostileChapterJSONEndsQuickly() {
        func manyKeysJSON(_ count: Int) -> String { "{\"chapters\":[{" + (0..<count).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + ",\"startTime\":5,\"title\":\"x\"}]}" }
        func manyChaptersJSON(_ count: Int) -> String { "{\"chapters\":[" + (0..<count).map { "{\"startTime\":\($0),\"title\":\"C\($0)\"}" }.joined(separator: ",") + "]}" }
        let manyKeys = manyKeysJSON(100_000), manyChapters = manyChaptersJSON(100_000)
        let deep = "{\"chapters\":[{\"startTime\":1,\"title\":" + String(repeating: "[", count: 400) + String(repeating: "]", count: 400) + "}]}"
        let deeper = "{\"chapters\":" + String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000) + "}"
        var cpu: [String: Double] = [:]
        for (name, json) in [("many keys", manyKeys), ("many chapters", manyChapters), ("deep", deep), ("deeper", deeper),
                             ("a tenth of the keys", manyKeysJSON(10_000)), ("a tenth of the chapters", manyChaptersJSON(10_000))] {
            let result = Self.bounded(name, cpuLimit: 5) { PodcastIndexChapterParser.parse(json) }
            cpu[name] = result.cpuSeconds
            print("hostile chapter JSON \(name): \(result.cpuSeconds) s of CPU, \(result.seconds) s")
            #expect(result.cpuSeconds < 5, "\(name) used \(result.cpuSeconds) s of CPU")
            if name == "many keys" { #expect(result.value??.first?.startMilliseconds == 5_000) }
            if name == "many chapters" { #expect(result.value??.count == 100_000) }
            if name == "deep" || name == "deeper" { #expect(result.value == .some(nil), "\(name) is refused, not read") }
        }
        // Ten times the keys or chapters take about ten times the work, not a hundred.
        #expect(Self.growsLinearly(cpu["many keys"]!, cpu["a tenth of the keys"]!), "keys: \(cpu)")
        #expect(Self.growsLinearly(cpu["many chapters"]!, cpu["a tenth of the chapters"]!), "chapters: \(cpu)")
    }
}
