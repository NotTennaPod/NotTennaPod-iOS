import Foundation

/// A provider grant covers only the coordinated immutable byte snapshot. Nothing
/// in the selection screen retains a provider URL, bookmark or open file handle.
public struct OPMLDocumentReader: Sendable {
    public enum Failure: Error { case unsupportedURL, coordinationDidNotRead }
    private let begin: @Sendable (URL) -> Bool
    private let end: @Sendable (URL) -> Void
    private let snapshot: @Sendable (URL) throws -> Data
    public init() {
        self.init(begin: { $0.startAccessingSecurityScopedResource() },
                  end: { $0.stopAccessingSecurityScopedResource() }, snapshot: Self.coordinatedSnapshot)
    }
    init(begin: @escaping @Sendable (URL) -> Bool, end: @escaping @Sendable (URL) -> Void,
         snapshot: @escaping @Sendable (URL) throws -> Data) {
        self.begin = begin; self.end = end; self.snapshot = snapshot
    }
    public func read(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw Failure.unsupportedURL }
        let task = Task.detached {
            try Task.checkCancellation()
            let acquired = begin(url)
            defer { if acquired { end(url) } }
            try Task.checkCancellation()
            let bytes = try snapshot(url)
            try Task.checkCancellation()
            return bytes
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func coordinatedSnapshot(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<Data, any Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { file in
            result = Result { try Task.checkCancellation(); return try Data(contentsOf: file) }
        }
        if let error { throw error }
        guard let result else { throw Failure.coordinationDidNotRead }
        return try result.get()
    }
}
