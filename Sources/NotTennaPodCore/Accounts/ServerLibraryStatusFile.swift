import Foundation

/// A server library's last exchange with the server, for display only: the Synchronization page's "Successful (…)"
/// and the kept libraries' "last synchronized". It stays a small file in the library's folder (`server-status.json`),
/// written after every exchange that completed or failed, so the page reads it for every kept library
/// without opening their databases; its reader and writer stay in this one type.
public struct ServerLibraryStatus: Codable, Equatable, Sendable {
    /// Milliseconds since 1970.
    public var lastSynchronizedAt: Int64
    public var successful: Bool

    public init(lastSynchronizedAt: Int64, successful: Bool) {
        self.lastSynchronizedAt = lastSynchronizedAt; self.successful = successful
    }

    public var date: Date { Date(timeIntervalSince1970: Double(lastSynchronizedAt) / 1_000) }

    private enum CodingKeys: String, CodingKey {
        case successful
        case lastSynchronizedAt = "last_synchronized_at"
    }
}

public struct ServerLibraryStatusFile: Sendable {
    public static let fileName = "server-status.json"
    public let url: URL

    public init(location: LibraryLocation) { url = location.folder.appendingPathComponent(Self.fileName) }

    /// Nil when there is none yet or it cannot be read: it is only shown, never relied on.
    public func read() -> ServerLibraryStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerLibraryStatus.self, from: data)
    }

    public func record(at date: Date, successful: Bool) throws {
        let status = ServerLibraryStatus(lastSynchronizedAt: Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)),
                                         successful: successful)
        try DurableFile.replace(url, with: JSONEncoder().encode(status))
    }
}
