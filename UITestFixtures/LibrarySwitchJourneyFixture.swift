#if DEBUG
import Foundation
import NotTennaPodCore

/// Library switching UI journey only (UUID test libraries). Server libraries are created by a first attachment
///; until then this keeps one on the device directly:
/// - `-test-server-library <android-db>`: a ready server library seeded from an Android database, kept once;
/// - `-test-record-library-switch standalone|server`: a switch recorded before the graph starts, as a logout or a
///   login left it in an earlier run (the logout marks the library inactive, the login ready).
/// `-test-switch-library-when-playing` (AppDelegate) requests the switch when playback first plays.
@MainActor enum LibrarySwitchJourneyFixture {
    nonisolated static let libraryID = "5a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e2f"

    static func prepare(root: URL, arguments: [String]) throws {
        guard root.lastPathComponent.hasPrefix("UITests-") else { return }
        let registry = LibraryRegistryFile(root: root)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        if let index = arguments.firstIndex(of: "-test-server-library"), index + 1 < arguments.count,
           try registry.read().library(libraryID) == nil {
            let location = LibraryLocation(root: root, reference: .server(libraryID))
            try location.prepare()
            try AppDelegate.seedAndroidDatabase(URL(fileURLWithPath: arguments[index + 1]), library: location.database)
            try registry.update {
                $0.libraries.append(.init(id: libraryID, serverURL: "https://sync.example.invalid", serverID: "journey-server",
                    accountID: "8d7c6b5a-4e3f-4a2b-9c1d-0e9f8a7b6c5d", username: "journey", state: .ready, createdAt: now))
            }
        }
        if let index = arguments.firstIndex(of: "-test-record-library-switch"), index + 1 < arguments.count {
            let server = arguments[index + 1] == "server"
            try registry.update { saved in
                guard let library = saved.libraries.firstIndex(where: { $0.id == libraryID }) else { return }
                saved.libraries[library].state = server ? .ready : .inactive
                try saved.recordSwitch(to: server ? .server(libraryID) : .standalone, reason: server ? .resume : .logout, at: now)
            }
        }
    }
}
#endif
