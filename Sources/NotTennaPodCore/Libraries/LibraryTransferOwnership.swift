import Foundation

/// Background-transfer reconciliation across libraries (PROTOCOL §15.4). The background download session is one per
/// app, while each library downloads into its own `media/`; a transfer that finishes while its library is inactive
/// waits in that library's `media/background-transfers/` for the job's next attempt.
public enum LibraryTransferOwnership {
    /// The active library's destinations (read from its open store by the caller) and those of every other library
    /// on this device, each read through a short read-only connection. Whatever cannot be accounted for keeps its
    /// transfers: a library that cannot be read or examined keeps every transfer into its media folder, and when the
    /// server libraries cannot be listed, every transfer into `Server Libraries/` is kept. Only a library without a
    /// database (none exists at all) has no transfers to keep. Does blocking file work: call it off the main actor.
    public static func collect(root: URL, active: LibraryReference, activeDestinations: [URL]) -> BackgroundTransferOwnership {
        var ownership = BackgroundTransferOwnership(destinations: activeDestinations)
        var libraries = [LibraryLocation(root: root, reference: .standalone)]
        do { libraries = try LibraryLocation.all(root: root) }
        catch { ownership.protectedFolders.append(LibraryLocation.serverLibraries(root: root)) }
        for location in libraries where location.reference != active {
            if LibraryLocation.isAbsent(location.database) { continue }
            do { ownership.destinations += try activeDownloadDestinations(database: location.database) }
            catch { ownership.protectedFolders.append(location.media) }
        }
        return ownership
    }

    /// The destinations of a closed library's active download jobs, resolved onto the library's current folder
    /// without writing (PROTOCOL §15.4 "One resolution function").
    public static func activeDownloadDestinations(database: URL) throws -> [URL] {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        guard try connection.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'download_jobs'") == 1 else {
            return []
        }
        let writtenUnder = try connection.libraryIdentity()?.pathsRoot
        let current = LibraryOwnedPaths.root(of: database.deletingLastPathComponent())
        return try connection.transaction(write: false) {
            try connection.rows("SELECT record FROM download_jobs WHERE active = 1 ORDER BY id").map { row in
                guard let data = row.first?.data else { throw FeedLibraryError.corruptRecord }
                let destination = try JSONDecoder().decode(LibraryDownloadJob.self, from: data).destination
                return writtenUnder.map { LibraryOwnedPaths.resolve(destination, writtenUnder: $0, current: current) } ?? destination
            }
        }
    }
}

/// The one owned-path resolution for background transfers (PROTOCOL §15.4): a task record's destination mapped onto
/// its library's current `media/`, found by the library's identity. While a Keep at logout is unfinished that is the
/// folder its markers show, so a rename that succeeded is recognized even if the manifest did not record it;
/// otherwise the folder the registry gives for the identity. A record without an identity, or of a library the device
/// does not know, keeps its recorded path.
public enum LibraryTransferRouting {
    public static func resolve(_ destination: String, library: String?, root: URL) -> String {
        guard let library, let media = mediaFolder(identity: library, root: root) else { return destination }
        return media.appendingPathComponent(URL(fileURLWithPath: destination).lastPathComponent).standardizedFileURL.path
    }

    /// The current `media/` of the library `identity`.
    public static func mediaFolder(identity: String, root: URL) -> URL? {
        let rootMedia = root.appendingPathComponent("media", isDirectory: true)
        // Markers first: they are where a Keep's renames left each folder.
        if LibraryKeep.marker(in: rootMedia)?.identity == identity { return rootMedia }
        let previous = (try? PreviousLibraryLocation.all(root: root)) ?? []
        for location in previous where LibraryKeep.marker(in: location.media)?.identity == identity { return location.media }
        func free(_ folder: URL) -> Bool { LibraryKeep.marker(in: folder).map { $0.identity == identity } ?? true }
        let registry = (try? LibraryRegistryFile(root: root).read()) ?? LibraryRegistry()
        if registry.standaloneIdentity == identity, free(rootMedia) { return rootMedia }
        if ContractIdentity.isUUID(identity), registry.library(identity) != nil {
            let server = LibraryLocation(root: root, reference: .server(identity)).media
            if free(server) { return server }
        }
        if let entry = registry.previous.first(where: { $0.identity == identity }) {
            return PreviousLibraryLocation(root: root, id: entry.id).media
        }
        return nil
    }
}
