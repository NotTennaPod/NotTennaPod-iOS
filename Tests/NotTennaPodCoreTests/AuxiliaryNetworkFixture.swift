import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The Mobile updates options, a network driven by the test, and the admission over them.
@MainActor final class AuxiliaryNetworkFixture {
    static let wifi = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi)
    static let cellular = DownloadNetworkState(connected: true, metered: true, cellular: true)
    static let lowData = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)

    let preferences: MobileNetworkPreferenceStore
    let network = DownloadNetworkMonitor(startMonitoring: false)
    let admission: AuxiliaryNetworkAdmission
    private let file: URL

    init(allowed: Set<String>, state: DownloadNetworkState) throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("AuxiliaryNetwork-\(UUID()).json")
        preferences = try MobileNetworkPreferenceStore(file: file)
        try preferences.updateAllowed(allowed)
        admission = AuxiliaryNetworkAdmission(network: network, preferences: preferences)
        network.update(state)
    }
    deinit { try? FileManager.default.removeItem(at: file) }

    /// As the app does: save the options, then tell the admission.
    func allow(_ values: Set<String>) throws { try preferences.updateAllowed(values); admission.preferencesChanged() }

    func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    func untilAsync(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(try await condition())
    }
}

/// gzip framing around Foundation's raw deflate, for a small transfer that decodes to many bytes.
enum TestGzip {
    static func encode(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data), size = UInt32(truncatingIfNeeded: data.count)
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return (crc ^ 0xFFFF_FFFF).littleEndian
    }
}
