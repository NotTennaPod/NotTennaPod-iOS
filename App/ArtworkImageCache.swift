import UIKit
import ImageIO
import CryptoKit
import NotTennaPodCore

@MainActor
/// Covers decoded once and shared by every screen. Lists rebuild their rows on each library change; without this,
/// every rebuilt row fetched and decoded its full-size cover again on the main thread, so a large Subscriptions
/// grid flickered and lagged while podcasts refreshed (e.g. after an OPML import). Only remote covers are kept:
/// local-folder and embedded covers can change on disk and are re-read.
enum ArtworkImageCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 256 * 1024 * 1024; return cache
    }()
    private static func key(_ source: String, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(source)" as NSString }
    static func image(_ source: String, maxPixels: Int) -> UIImage? { cache.object(forKey: key(source, maxPixels)) }
    static func store(_ image: UIImage, source: String, maxPixels: Int) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key(source, maxPixels), cost: cost)
    }
    /// Shrunk covers also kept on disk (the Caches folder, which iOS may clear), like Glide's disk cache: after
    /// a relaunch covers come from here instead of being downloaded again.
    private static let directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Artwork", isDirectory: true)
    private static func diskURL(_ source: String, _ maxPixels: Int) -> URL? {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent("\(digest)-\(maxPixels).jpg")
    }
    static func diskImage(_ source: String, maxPixels: Int) async -> UIImage? {
        guard let url = diskURL(source, maxPixels) else { return nil }
        startDiskTrimming()
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data else { return nil }
        // Least recently used goes first when the folder is trimmed; record this use without delaying the cover.
        diskQueue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return await decode(data, maxPixels: maxPixels)
    }
    static func saveToDisk(_ image: UIImage, source: String, maxPixels: Int) {
        guard let url = diskURL(source, maxPixels), let directory else { return }
        startDiskTrimming()
        Task.detached(priority: .utility) {
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        writesSinceTrim += 1
        if writesSinceTrim >= 32 { scheduleDiskTrim() }
    }

    /// Like Glide's 250 MB disk cache: the folder is trimmed, least recently used covers first, at launch
    /// (first use), when the app goes to the background and after every 32 new covers. Without a limit it
    /// grew by ~110 MB in one session of scrolling (2026-10-01 device profile).
    static let diskLimit: Int64 = 250 * 1024 * 1024
    private static let diskQueue = DispatchQueue(label: "de.danoeh.antennapod.artwork-disk", qos: .utility)
    private static var writesSinceTrim = 0
    private static var trimming = false
    private static var backgroundObserver: NSObjectProtocol?
    private static func startDiskTrimming() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { scheduleDiskTrim() }
        }
        scheduleDiskTrim()
    }
    private static func scheduleDiskTrim() {
        guard let directory, !trimming else { return }
        trimming = true; writesSinceTrim = 0
        let limit = diskLimit
        diskQueue.async {
            trimDisk(directory: directory, limit: limit)
            Task { @MainActor in trimming = false }
        }
    }
    /// Deletes the least recently used files (by modification date) until the folder holds at most `limit` bytes.
    nonisolated static func trimDisk(directory: URL, limit: Int64) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                       options: .skipsHiddenFiles) else { return }
        var entries: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            entries.append((file, values.contentModificationDate ?? .distantPast, size)); total += size
        }
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > limit else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }
    /// One load per web cover at a time, shared by every view showing it: a list of one podcast's
    /// episodes otherwise downloaded and decoded the same cover 10–15 times at once. The load stops only when
    /// every view waiting for it has gone.
    @MainActor private final class SharedLoad {
        var task: Task<UIImage?, Never>?
        var waiters: Set<UUID> = []
    }
    private static var inFlight: [String: SharedLoad] = [:]
    /// Web covers that answered with a client error or an undecodable body, not asked again this session.
    private static var failed: Set<String> = []
    static var loadsInFlight: Int { inFlight.count }

    /// The cover at `source` (http or https) from memory, disk or the web, shrunk and cached; nil if unavailable.
    static func remoteImage(_ source: String, maxPixels: Int) async -> UIImage? {
        if let cached = image(source, maxPixels: maxPixels) { return cached }
        guard !failed.contains(source), let url = URL(string: source) else { return nil }
        let key = "\(maxPixels)|\(source)"
        let shared: SharedLoad
        if let existing = inFlight[key] { shared = existing } else {
            shared = SharedLoad()
            inFlight[key] = shared
            shared.task = Task { @MainActor () -> UIImage? in
                defer { if inFlight[key] === shared { inFlight[key] = nil } }
                return await load(source, url: url, maxPixels: maxPixels)
            }
        }
        let waiter = UUID()
        shared.waiters.insert(waiter)
        let result = await withTaskCancellationHandler { await shared.task?.value } onCancel: {
            Task { @MainActor in leave(shared, waiter: waiter, key: key) }
        }
        leave(shared, waiter: waiter, key: key)
        return result ?? nil
    }
    private static func leave(_ shared: SharedLoad, waiter: UUID, key: String) {
        guard shared.waiters.remove(waiter) != nil, shared.waiters.isEmpty, inFlight[key] === shared else { return }
        inFlight[key] = nil; shared.task?.cancel()
    }
    private static func load(_ source: String, url: URL, maxPixels: Int) async -> UIImage? {
        if let stored = await diskImage(source, maxPixels: maxPixels) {
            store(stored, source: source, maxPixels: maxPixels); return stored
        }
        guard !Task.isCancelled else { return nil }
        do {
            let (data, response) = try await EpisodeArtworkView.loadRemote(url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // A missing or refused image stays missing; a busy or failing server is asked again later.
                if (400..<500).contains(status), status != 408, status != 429 { failed.insert(source) }
                return nil
            }
            guard !Task.isCancelled else { return nil }
            guard let decoded = await decode(data, maxPixels: maxPixels) else { failed.insert(source); return nil }
            store(decoded, source: source, maxPixels: maxPixels)
            saveToDisk(decoded, source: source, maxPixels: maxPixels)
            return decoded
        } catch { return nil }
    }

    /// Decodes away from the main thread, no larger than `maxPixels` on the longer side (screen size, not the
    /// 1,400–3,000 px podcast covers usually are).
    static func decode(_ data: Data, maxPixels: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: decoded)
        }.value
    }
}
