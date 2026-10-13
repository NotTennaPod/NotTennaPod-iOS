import CryptoKit
import Darwin
import Foundation

/// Playback temp files (`antennapod-*.cache`, `antennapod-mllt-*.index`) belong to one open item
/// and are removed when it closes. After the app is killed mid-playback nothing owns them.
public enum PlaybackTemporaryFiles {
    /// Call once at launch, before any playback can create new ones, to reclaim that storage.
    public static func removeOrphaned(in directory: URL = .temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("antennapod-")
            && (name.hasSuffix(".cache") || (name.hasPrefix("antennapod-mllt-") && name.hasSuffix(".index"))) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
