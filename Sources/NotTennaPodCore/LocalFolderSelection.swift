import Foundation

/// Picker-granted directory access is captured off the UI executor and retained
/// in private storage. Selecting a folder never copies its media into the app.
public struct LocalFolderSelection: Sendable {
    public let title: String?
    public let identity: String
    public let bookmark: Data

    public static func prepare(directory: URL) async throws -> Self {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            let bookmark = try LocalFolderDocuments.makeBookmark(directory: directory)
            let title = try directory.resourceValues(forKeys: [.nameKey]).name
            try Task.checkCancellation()
            return Self(title: title, identity: directory.absoluteString, bookmark: bookmark)
        }
        return try await withTaskCancellationHandler {
            let value = try await work.value
            try Task.checkCancellation()
            return value
        } onCancel: { work.cancel() }
    }
}
