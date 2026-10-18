import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Synchronization
import NotTennaPodCore

@MainActor
/// Covers decoded once and shared by every screen. Lists rebuild their rows on each library change; without this,
/// every rebuilt row fetched and decoded its full-size cover again on the main thread, so a large Subscriptions
/// grid flickered and lagged while podcasts refreshed (e.g. after an OPML import). Only web covers are kept on
/// disk; a streamed episode's chapter pictures are kept in memory; local-folder and embedded covers can change on
/// disk and are re-read.
enum ArtworkImageCache {
    /// Decoded covers are bounded: about a hundred 400 px list covers, and nothing kept while the app is in
    /// the background or after a memory warning (covers on screen stay drawn: their views hold them).
    nonisolated static let costLimit = 48 * 1024 * 1024
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = costLimit; cache.delegate = tracker; return cache
    }()
    /// What the cache holds, for the trim tests (NSCache tells neither).
    private final class Tracker: NSObject, NSCacheDelegate, Sendable {
        /// NSCache evicts on any thread.
        let costs = Mutex<[ObjectIdentifier: Int]>([:])
        func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
            let id = ObjectIdentifier(object as AnyObject)
            costs.withLock { $0[id] = nil }
        }
    }
    nonisolated private static let tracker = Tracker()
    /// Covers kept in memory now, and their decoded bytes.
    static var memoryCount: Int { tracker.costs.withLock { $0.count } }
    static var memoryCost: Int { tracker.costs.withLock { $0.values.reduce(0, +) } }
    private static func key(_ source: String, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(source)" as NSString }
    static func image(_ source: String, maxPixels: Int) -> UIImage? { cache.object(forKey: key(source, maxPixels)) }
    static func store(_ image: UIImage, source: String, maxPixels: Int) {
        startMemoryTrimming()
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        let key = key(source, maxPixels)
        let old = cache.object(forKey: key).map(ObjectIdentifier.init)
        tracker.costs.withLock { costs in
            if let old { costs[old] = nil }
            costs[ObjectIdentifier(image)] = cost
        }
        cache.setObject(image, forKey: key, cost: cost)
    }
    static func remove(source: String, maxPixels: Int) { cache.removeObject(forKey: key(source, maxPixels)) }
    private static var memoryObservers: [NSObjectProtocol] = []
    /// Purges the decoded covers (and the podcast headers' blurred backgrounds) when the app goes to the background and
    /// on a memory warning.
    private static func startMemoryTrimming() {
        guard memoryObservers.isEmpty else { return }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            memoryObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { trimMemory() }
            })
        }
    }
    static func trimMemory() {
        cache.removeAllObjects()
        tracker.costs.withLock { $0 = [:] }
        FeedAppBarView.removeBlurredFromMemory()
    }
    /// Source copies kept in memory only: a streamed episode's chapter pictures, whose media has no revision proving
    /// that a copy kept on disk still belongs to it.
    nonisolated(unsafe) private static let memorySources: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>(); cache.totalCostLimit = 64 * 1024 * 1024; return cache
    }()
    /// What a relaunch forgets (tests): every picture kept in memory.
    static func removeAllFromMemory() { cache.removeAllObjects(); tracker.costs.withLock { $0 = [:] }; memorySources.removeAllObjects() }

    /// The app's picture network rules (`MobileImageAccess`) for embedded chapter pictures read from a stream: the byte
    /// limit now, nil when none may be fetched ("Cover images" off on a restricted network); and a wait for an
    /// unrestricted network, after which deferred pictures are asked for again.
    static var fetchAllowance: (@MainActor () async throws -> (bytes: Int, restricted: Bool)?)?
    static var unrestrictedNetwork: (@MainActor () async throws -> Void)?

    /// One copy of each picture kept on disk (the Caches folder, which iOS may clear), like Glide's disk cache of
    /// AntennaPod's resized source: every size is made from it, so a cover is downloaded once for the list, the
    /// player and notifications, and not again after a relaunch. Covers saved per size by earlier versions are
    /// still read, never written.
    private static let directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Artwork", isDirectory: true)
    private static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func sourceURL(_ source: String) -> URL? { directory?.appendingPathComponent("\(digest(source))-src") }
    private static func legacyURL(_ source: String, _ maxPixels: Int) -> URL? {
        directory?.appendingPathComponent("\(digest(source))-\(maxPixels).jpg")
    }
    /// The file's bytes read away from the main thread, its use recorded for the least-recently-used trim.
    private static func readFile(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        startDiskTrimming()
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data else { return nil }
        diskQueue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return data
    }
    /// A cover an earlier version saved at this size, when no source copy exists yet.
    private static func legacyData(_ source: String, sizes: [Int]) async -> Data? {
        guard let copy = sourceURL(source) else { return nil }
        let candidates = sizes.compactMap { legacyURL(source, $0) }
        let found = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard !FileManager.default.fileExists(atPath: copy.path) else { return nil }
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }.value
        return await readFile(found)
    }
    /// Written whole (atomically) before the load that made it ends, so a second size asked for at once finds it.
    private static func saveSource(_ data: Data, source: String) async {
        guard let url = sourceURL(source), let directory else { return }
        startDiskTrimming()
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
        writesSinceTrim += 1
        if writesSinceTrim >= 32 { scheduleDiskTrim() }
    }

    /// AntennaPod's ResizingOkHttpStreamFetcher: a picture of at most 1 MB is kept as it is; a larger one is reduced
    /// to at most 1,500 px (JPEG, or PNG when it has transparency, first frame of an animation). nil if not a picture.
    nonisolated static func sourceCopy(of data: Data) -> Data? {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(image) != nil,
              CGImageSourceGetCount(image) > 0 else { return nil }
        if data.count <= 1024 * 1024 { return data }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1500]
        guard let reduced = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(reduced.alphaInfo)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, reduced, (opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Like Glide's 250 MB disk cache: the folder is trimmed, least recently used covers first, at launch
    /// (first use), when the app goes to the background and after every 32 new covers. Without a limit it
    /// grew by ~110 MB in one session of scrolling (a device profile).
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

    /// One load per picture at a time, whatever size each view asks for, shared by every view showing it: a list of
    /// one podcast's episodes otherwise downloaded the same cover 10–15 times at once, and the player downloaded
    /// it again for its larger size. When every view waiting for it has gone, the load still runs for a moment, so
    /// a row rebuilt by a library change joins it instead of starting it again.
    @MainActor private final class SharedLoad {
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data?, Never>] = [:]
    }
    private static var inFlight: [String: SharedLoad] = [:]
    static var loadsInFlight: Int { inFlight.count }
    static var cancelGrace: Duration = .seconds(2)
    /// Web covers that answered with a client error or an undecodable body, not asked again this session.
    private static var failed: Set<String> = []
    /// Pictures over the restricted-network limit, not asked for again until the network is unrestricted.
    private static var deferred: Set<String> = []
    private static var deferredRelease: Task<Void, Never>?
    private static var deferredWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Whether `source` waits for an unrestricted network.
    static func isDeferred(_ source: String) -> Bool { deferred.contains(source) }
    /// Returns true once deferred pictures may be asked for again; false if the caller is cancelled first.
    static func waitForUnrestrictedNetwork() async -> Bool {
        guard !deferred.isEmpty else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || deferred.isEmpty { continuation.resume(returning: !Task.isCancelled); return }
                deferredWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in deferredWaiters.removeValue(forKey: id)?.resume(returning: false) }
        }
    }
    private static func deferLoad(_ source: String) {
        deferred.insert(source)
        guard deferredRelease == nil, let unrestrictedNetwork else { return }
        deferredRelease = Task { @MainActor in
            try? await unrestrictedNetwork()
            deferredRelease = nil
            deferred.removeAll()
            let waiters = deferredWaiters; deferredWaiters = [:]
            for waiter in waiters.values { waiter.resume(returning: true) }
        }
    }

    /// The cover at `source` (http or https) from memory, disk or the web, shrunk and cached; nil if unavailable.
    static func remoteImage(_ source: String, maxPixels: Int) async -> UIImage? {
        if let cached = image(source, maxPixels: maxPixels) { return cached }
        guard !failed.contains(source), let url = URL(string: source) else { return nil }
        if let legacy = await legacyData(source, sizes: [maxPixels]), let decoded = await decode(legacy, maxPixels: maxPixels) {
            store(decoded, source: source, maxPixels: maxPixels); return decoded
        }
        return await cachedImage(key: source, maxPixels: maxPixels) { try await fetchRemote(url) }
    }

    /// The picture at `source` as kept on disk (at most 1,500 px), downloading it if needed; nil if unavailable.
    static func remoteSource(_ source: String) async -> Data? {
        guard !failed.contains(source), let url = URL(string: source) else { return nil }
        if let legacy = await legacyData(source, sizes: [1200, 400]) { return legacy }
        return await sourceData(key: source, persist: true) { try await fetchRemote(url) }
    }

    /// The picture known by `key`, from memory, its source copy (on disk, or in memory only without `persist`) or
    /// `fetch` (bytes, or nil if unavailable now); `ArtworkTooLarge` from `fetch` defers or drops it, `ArtworkMissing`
    /// drops it for the session.
    static func cachedImage(key: String, maxPixels: Int, persist: Bool = true,
                            fetch: @escaping @MainActor () async throws -> Data?) async -> UIImage? {
        if let cached = image(key, maxPixels: maxPixels) { return cached }
        guard let data = await sourceData(key: key, persist: persist, fetch: fetch) else { return nil }
        guard let decoded = await decode(data, maxPixels: maxPixels) else { failed.insert(key); return nil }
        store(decoded, source: key, maxPixels: maxPixels)
        return decoded
    }

    /// A picture that is not there or not a picture (a client error, an undecodable body).
    struct ArtworkMissing: Error {}

    private static func fetchRemote(_ url: URL) async throws -> Data? {
        let (data, response) = try await EpisodeArtworkView.loadRemote(url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // A missing or refused image stays missing; a busy or failing server is asked again later.
            if (400..<500).contains(status), status != 408, status != 429 { throw ArtworkMissing() }
            return nil
        }
        return data
    }

    private static func sourceData(key: String, persist: Bool, fetch: @escaping @MainActor () async throws -> Data?) async -> Data? {
        guard !failed.contains(key) else { return nil }
        let shared: SharedLoad
        if let existing = inFlight[key] { shared = existing } else {
            shared = SharedLoad()
            inFlight[key] = shared
            shared.task = Task { @MainActor in
                let data = await loadSource(key: key, persist: persist, fetch: fetch)
                if inFlight[key] === shared { inFlight[key] = nil }
                let waiters = shared.waiters; shared.waiters = [:]
                for waiter in waiters.values { waiter.resume(returning: data) }
            }
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                shared.waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in leave(shared, waiter: id, key: key) }
        }
    }
    private static func leave(_ shared: SharedLoad, waiter: UUID, key: String) {
        guard let continuation = shared.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        guard shared.waiters.isEmpty, inFlight[key] === shared else { return }
        Task { @MainActor in
            try? await Task.sleep(for: cancelGrace)
            guard shared.waiters.isEmpty, inFlight[key] === shared else { return }
            inFlight[key] = nil; shared.task?.cancel()
        }
    }
    private static func loadSource(key: String, persist: Bool, fetch: @MainActor () async throws -> Data?) async -> Data? {
        if persist, let stored = await readFile(sourceURL(key)) { return stored }
        if !persist, let stored = memorySources.object(forKey: key as NSString) { return stored as Data }
        guard !Task.isCancelled, !deferred.contains(key), !failed.contains(key) else { return nil }
        let fetched: Data?
        do { fetched = try await fetch() }
        catch let tooLarge as ArtworkTooLarge {
            if tooLarge.restricted { deferLoad(key) } else { failed.insert(key) }
            return nil
        } catch is ArtworkMissing { failed.insert(key); return nil }
        catch { return nil }
        guard let fetched else { return nil }
        // Kept even if every view has gone meanwhile: the bytes have been downloaded.
        guard let copy = await Task.detached(priority: .userInitiated, operation: { sourceCopy(of: fetched) }).value else {
            failed.insert(key); return nil
        }
        if persist { await saveSource(copy, source: key) }
        else { memorySources.setObject(copy as NSData, forKey: key as NSString, cost: copy.count) }
        return copy
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
