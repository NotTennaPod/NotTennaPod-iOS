import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The background download session inside the app process (a background URLSession needs an
/// app), against a loopback server. Checks what a person would notice: the saved episode is the exact
/// file, an interrupted download continues from its bytes, and a cut or failed response is never saved
/// as a finished download. Requests match the foreground engine's.
/// The system schedules background-session tasks: on a newly created Simulator its own asset downloads
/// held our first task for up to about 3.5 minutes (nsurlsessiond log), so waits are generous.
@Suite(.serialized, .timeLimit(.minutes(6)))
struct BackgroundMediaDownloadsViewTests {
    static let media = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 9)) })
    static let tag = "\"m29-v1\""

    /// Serves `media` with strong ETag and byte ranges, the way podcast hosts do.
    static func respond(_ request: LoopbackHTTPServer.Request, body: Data = media) -> LoopbackHTTPServer.Response {
        var response = LoopbackHTTPServer.Response(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": tag,
                                                                          "Accept-Ranges": "bytes"], body: body)
        if let range = request.headers["range"], range.hasPrefix("bytes="),
           request.headers["if-range"].map({ $0 == tag }) ?? true,
           let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            guard start < body.count else {
                return .init(status: 416, headers: ["Content-Range": "bytes */\(body.count)"], body: Data())
            }
            response.status = 206
            response.headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
            response.body = body.suffix(from: start)
        }
        return response
    }

    private func environment(_ body: (BackgroundMediaDownloads, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M29Background-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloads = BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)")
        defer { downloads.invalidate(); try? FileManager.default.removeItem(at: directory) }
        try await body(downloads, directory)
    }

    private func sha(_ file: URL) throws -> SHA256.Digest { SHA256.hash(data: try Data(contentsOf: file)) }

    @Test func downloadsExactFileWithSourceHeadersAndIdentity() async throws {
        let server = try await LoopbackHTTPServer.start { Self.respond($0) }
        defer { server.stop() }
        try await environment { downloads, directory in
            let destination = directory.appendingPathComponent("episode.media")
            try Data().write(to: destination)
            let accepted = Mutex<[MediaDownloadRepresentation?]>([])
            let progress = Mutex<[MediaDownloadProgress]>([])
            let result = try await downloads.download(.init(
                source: "http://127.0.0.1:\(server.url.port!)/episode.mp3", destination: destination, networkConstraint: .connected,
                acceptRepresentation: { identity in accepted.withLock { $0.append(identity) } }),
                userAgent: "AntennaPod/9.9.9", progress: { value in progress.withLock { $0.append(value) } })
            #expect(try sha(destination) == SHA256.hash(data: Self.media) && result.size == Int64(Self.media.count))
            #expect(result.representation?.entityTag == Self.tag && result.representation?.total == Int64(Self.media.count))
            #expect(accepted.withLock { $0.count } == 1)
            #expect(progress.withLock { $0.last } == .init(received: Int64(Self.media.count), expected: Int64(Self.media.count)))
            let headers = try #require(server.requests.last?.headers)
            #expect(headers["user-agent"] == "AntennaPod/9.9.9")
            #expect(headers["accept-encoding"] == "identity" && headers["cache-control"] == "no-cache")
            #expect(headers["upgrade-insecure-requests"] == "1")
            #expect(headers["range"] == nil && headers["authorization"] == nil)
        }
    }

    @Test func partialFileResumesWithRangeAndStrongValidator() async throws {
        let server = try await LoopbackHTTPServer.start { Self.respond($0) }
        defer { server.stop() }
        try await environment { downloads, directory in
            let destination = directory.appendingPathComponent("episode.media")
            try Self.media.prefix(1_000_000).write(to: destination)
            let source = "http://127.0.0.1:\(server.url.port!)/episode.mp3"
            let identity = MediaDownloadRepresentation(resource: URL(string: source)!, entityTag: Self.tag, total: Int64(Self.media.count))
            _ = try await downloads.download(.init(source: source, destination: destination, networkConstraint: .connected,
                                                   representation: identity), userAgent: "AntennaPod/9.9.9")
            #expect(try sha(destination) == SHA256.hash(data: Self.media))
            let headers = try #require(server.requests.last?.headers)
            #expect(headers["range"] == "bytes=1000000-" && headers["if-range"] == Self.tag)
        }
    }

    @Test func changedFileOnServerReplacesThePartialWithTheNewFile() async throws {
        let replacement = Data(Self.media.reversed())
        let server = try await LoopbackHTTPServer.start { request in
            // The episode was replaced: the server ignores the old validator and sends the new file.
            .init(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": "\"m29-v2\""], body: replacement)
        }
        defer { server.stop() }
        try await environment { downloads, directory in
            let destination = directory.appendingPathComponent("episode.media")
            try Self.media.prefix(700_000).write(to: destination)
            let source = "http://127.0.0.1:\(server.url.port!)/episode.mp3"
            let identity = MediaDownloadRepresentation(resource: URL(string: source)!, entityTag: Self.tag, total: Int64(Self.media.count))
            _ = try await downloads.download(.init(source: source, destination: destination, networkConstraint: .connected,
                                                   representation: identity), userAgent: "AntennaPod/9.9.9")
            #expect(try sha(destination) == SHA256.hash(data: replacement), "no mix of old and new bytes")
        }
    }

    /// A server that drops the connection mid-transfer: the background session retries on its own with
    /// a Range request from the received bytes (no attempt used, no log row), and the saved file is exact.
    @Test func droppedConnectionResumesWithRangeAndSavesExactFile() async throws {
        let dropped = Mutex(false)
        let server = try await LoopbackHTTPServer.start { request in
            if !dropped.withLock({ let was = $0; $0 = true; return was }) {
                return .init(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": Self.tag, "Accept-Ranges": "bytes",
                                                    "Content-Length": String(Self.media.count)],
                             body: Self.media.prefix(900_000), includeAutomaticContentLength: false)
            }
            return Self.respond(request)
        }
        defer { server.stop() }
        try await environment { downloads, directory in
            let destination = directory.appendingPathComponent("episode.media")
            try Data().write(to: destination)
            _ = try await downloads.download(.init(source: "http://127.0.0.1:\(server.url.port!)/episode.mp3", destination: destination,
                                                   networkConstraint: .connected), userAgent: "AntennaPod/9.9.9")
            #expect(try sha(destination) == SHA256.hash(data: Self.media))
            #expect(server.requests.contains { $0.headers["range"].map { $0 != "bytes=0-" } ?? false }, "continued, not restarted")
        }
    }

    @Test func failedResponsesAreNeverSavedAsFinished() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            switch request.path {
            case "/gone.mp3": return .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("missing".utf8))
            case "/page.mp3": return .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>login</html>".utf8))
            default: return .init(status: 416, headers: ["Content-Range": "bytes */2500000"], body: Data())
            }
        }
        defer { server.stop() }
        try await environment { downloads, directory in
            for (path, expected) in [("gone.mp3", MediaDownloadFailure.http(404)), ("page.mp3", .fileType), ("range.mp3", .http(416))] {
                let destination = directory.appendingPathComponent(path + ".media")
                try Data().write(to: destination)
                var failure: (any Error)?
                do {
                    _ = try await downloads.download(.init(source: "http://127.0.0.1:\(server.url.port!)/\(path)", destination: destination,
                                                           networkConstraint: .connected), userAgent: "AntennaPod/9.9.9")
                } catch { failure = error }
                #expect(failure.map { MediaDownloadFailure($0) } == expected, "\(path)")
                #expect(BackgroundMediaDownloads.size(of: destination) == 0, "\(path): nothing saved")
            }
        }
    }

    /// Transfers left in the session by an earlier run or a replaced library (no job adopts them)
    /// hold the host's eight connections, so a new download never reaches the server. Reconciling with
    /// the library cancels them and keeps the active download's own task, which the job then adopts:
    /// the new download finishes with one request and the exact file.
    @Test func orphanedTransfersAreCancelledSoANewDownloadStarts() async throws {
        let disconnects = Mutex(0)
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnects.withLock { $0 += 1 } }) { request in
            // An earlier library's episodes: the server never answers (a dead transfer).
            request.path.hasPrefix("/old-") ? nil : Self.respond(request)
        }
        defer { server.stop() }
        try await environment { downloads, directory in
            let session = downloads.activate()
            let port = server.url.port!
            for index in 0..<9 {
                let old = directory.appendingPathComponent("replaced-library/media/episode-\(index)-download-\(index).media")
                let task = session.downloadTask(with: URL(string: "http://127.0.0.1:\(port)/old-\(index).mp3")!)
                task.taskDescription = BackgroundMediaDownloads.describe(.init(destination: BackgroundMediaDownloads.Files(destination: old).key, base: 0))
                task.resume()
            }
            // The active download's task, issued by an earlier process of this library.
            let destination = directory.appendingPathComponent("episode.media")
            try Data().write(to: destination)
            let files = BackgroundMediaDownloads.Files(destination: destination)
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            let record = BackgroundMediaDownloads.TaskRecord(destination: files.key, base: 0)
            try files.write(record)
            let source = "http://127.0.0.1:\(port)/episode.mp3"
            var request = URLRequest(url: URL(string: source)!)
            request.setValue("AntennaPod/9.9.9", forHTTPHeaderField: "User-Agent")
            let kept = session.downloadTask(with: request)
            kept.taskDescription = BackgroundMediaDownloads.describe(record)
            kept.resume()
            // The dead transfers fill the host's connections (system scheduling can delay the first).
            let deadline = ContinuousClock.now + .seconds(300)
            let oldRequests = { server.requests.filter { $0.path.hasPrefix("/old-") }.count }
            while oldRequests() < 8, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try #require(oldRequests() >= 8, "eight dead transfers hold the host")
            let cancelled = try await downloads.reconcile { [destination] }
            #expect(cancelled == 9, "every transfer of no current download goes")
            let result = try await downloads.download(.init(source: source, destination: destination, networkConstraint: .connected),
                                                      userAgent: "AntennaPod/9.9.9")
            #expect(try sha(destination) == SHA256.hash(data: Self.media) && result.size == Int64(Self.media.count))
            #expect(server.requests.filter { $0.path == "/episode.mp3" }.count == 1, "the kept task was adopted, not repeated")
            #expect(oldRequests() <= 8, "no dead transfer was issued again")
            let closed = ContinuousClock.now + .seconds(30)
            while disconnects.withLock({ $0 }) < 8, ContinuousClock.now < closed { try await Task.sleep(for: .milliseconds(50)) }
            #expect(disconnects.withLock { $0 } >= 8, "the dead transfers' connections were closed")
            // Their late events leave nothing a later download with the same path could adopt.
            let orphanFiles = directory.appendingPathComponent("replaced-library/media/background-transfers").path
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: orphanFiles)) ?? []
            #expect(leftovers.isEmpty, "\(leftovers)")
        }
    }

    /// An interruption (network constraint lost, app stopped) keeps what was received: the next attempt
    /// asks only for the rest and the saved file is exact.
    @Test func interruptedTransferContinuesFromReceivedBytes() async throws {
        let firstRequest = Mutex(true)
        let server = try await LoopbackHTTPServer.start { request in
            if firstRequest.withLock({ let first = $0; $0 = false; return first }) {
                // Half the file, then the connection stays open without more bytes.
                return .init(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": Self.tag, "Accept-Ranges": "bytes",
                                                    "Content-Length": String(Self.media.count)],
                             body: Self.media.prefix(1_200_000), keepConnectionOpen: true, includeAutomaticContentLength: false)
            }
            return Self.respond(request)
        }
        defer { server.stop() }
        try await environment { downloads, directory in
            let destination = directory.appendingPathComponent("episode.media")
            try Data().write(to: destination)
            let source = "http://127.0.0.1:\(server.url.port!)/episode.mp3"
            let received = Mutex<Int64>(0)
            let first = Task {
                try await downloads.download(.init(source: source, destination: destination, networkConstraint: .connected),
                                             userAgent: "AntennaPod/9.9.9", progress: { value in received.withLock { $0 = value.received } })
            }
            let deadline = ContinuousClock.now + .seconds(300)
            while received.withLock({ $0 }) < 1_200_000, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(received.withLock { $0 } >= 1_200_000)
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
            let resumeFile = BackgroundMediaDownloads.Files(destination: destination).resumeFile
            let saved = ContinuousClock.now + .seconds(10)
            while !FileManager.default.fileExists(atPath: resumeFile.path), ContinuousClock.now < saved { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await downloads.download(.init(source: source, destination: destination, networkConstraint: .connected),
                                             userAgent: "AntennaPod/9.9.9")
            #expect(try sha(destination) == SHA256.hash(data: Self.media))
            let range = try #require(server.requests.last?.headers["range"])
            #expect(range.hasPrefix("bytes=") && (Int(range.dropFirst(6).dropLast()) ?? 0) >= 1_000_000,
                    "asks only for the rest: \(range)")
        }
    }
}
