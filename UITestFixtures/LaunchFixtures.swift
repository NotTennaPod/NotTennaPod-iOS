#if DEBUG
import UIKit
import OSLog
import Synchronization
import NotTennaPodCore

/// Fixtures that seed their library once and then mark it ready. Before such a library opens, one without its
/// fixture's ready marker is emptied, whatever an earlier run left in it (another fixture version's files included), so
/// the fixture seeds it again instead of taking it as ready or refusing it.
enum SeededLibraryFixtures {
    static func prepare(root: URL, arguments: [String]) throws {
        guard root.lastPathComponent.hasPrefix("UITests-") else { return }
        let seeded = [("-test-statistics-journey", StatisticsPeriodJourneyFixture.readyMarker),
                      ("-test-opml-export-journey", OPMLExportJourneyFixture.readyMarker)]
        for (argument, marker) in seeded
        where arguments.contains(argument) && !FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path) {
            for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: item)
            }
        }
    }
}

/// UI-test launch fixtures, chosen by launch arguments and run only for a UUID-isolated test library.
extension AppDelegate {
    /// Fixtures that prepare their library once the graph is running (first launch only, not after an import).
    func startLaunchFixtures(arguments: [String], directory: URL, store: FeedLibraryStore, downloads preferences: DownloadPreferenceStore,
                             startRemovedEpisodePeriodicRefresh: (() -> Void)?) {
        if arguments.contains("-test-queue-gestures"), directory.lastPathComponent.hasPrefix("UITests-") {
            Task {
                do { try await QueueGestureFixture.prepare(directory: directory, store: store, navigation: self.navigationPreferences) }
                catch { Logger(subsystem: "org.nottennapod.app", category: "QueueFixture").error("Queue fixture failed: \(String(describing: error), privacy: .public)") }
            }
        }
        if arguments.contains("-test-statistics-journey"), directory.lastPathComponent.hasPrefix("UITests-") {
            Task {
                do { try await StatisticsPeriodJourneyFixture.prepare(directory: directory, store: store) }
                catch { Logger(subsystem: "org.nottennapod.app", category: "StatisticsFixture").error("Statistics fixture failed: \(String(describing: error), privacy: .public)") }
            }
        }
        if arguments.contains("-test-opml-export-journey"), directory.lastPathComponent.hasPrefix("UITests-") {
            Task {
                do { try await OPMLExportJourneyFixture.prepare(directory: directory, store: store) }
                catch { Logger(subsystem: "org.nottennapod.app", category: "OPMLExportFixture").error("OPML export fixture failed: \(String(describing: error), privacy: .public)") }
            }
        }
        if arguments.contains("-test-inbox-swipe-journey"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil, let allEpisodesFilterPreferences {
            Task {
                do {
                    try await InboxSwipeJourneyFixture.prepare(root: directory.appendingPathComponent("inbox-swipe-journey"),
                        store: store, downloads: preferences, filter: allEpisodesFilterPreferences)
                    for controller in Self.libraryControllers { await controller.reloadLibrary()?.value }
                } catch {
                    Logger(subsystem: "org.nottennapod.app", category: "TestFixture")
                        .error("Inbox-swipe fixture failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if arguments.contains("-test-list-inbox-cleanup"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil {
            let fixtureRoot = directory.appendingPathComponent("list-inbox-fixture", isDirectory: true)
            Task {
                do {
                    _ = try await ListInboxActionFixture.prepare(root: fixtureRoot, store: store, preferences: preferences)
                    for controller in Self.libraryControllers { await controller.reloadLibrary()?.value }
                } catch {
                    Logger(subsystem: "org.nottennapod.app", category: "TestFixture")
                        .error("List-inbox fixture failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if arguments.contains("-test-removed-episode-refresh"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil, let playback {
            let fixtureRoot = directory.appendingPathComponent("removed-episode-fixture", isDirectory: true)
            removedEpisodeRefreshFixtureTask = Task {
                do {
                    let fixture = try await RemovedEpisodeRefreshFixture.prepare(root: fixtureRoot, store: store)
                    startRemovedEpisodePeriodicRefresh?()
                    for controller in Self.libraryControllers { await controller.reloadLibrary()?.value }
                    try await fixture.moveAfterTargetPlaysThenPauses(playback: playback)
                } catch {
                    Logger(subsystem: "org.nottennapod.app", category: "TestFixture")
                        .error("Removed-episode fixture failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Installs an Android database as the UUID test library before it opens, through the database import.
    static func seedAndroidDatabase(_ source: URL, library: URL) throws {
        guard !FileManager.default.fileExists(atPath: library.path) else { return }
        let staging = library.deletingLastPathComponent().appendingPathComponent("seed-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let restored = try AndroidDatabaseRestore.read(source, staging: staging)
        let done = DispatchSemaphore(value: 0)
        let failure = Mutex<(any Error)?>(nil)
        Task.detached {
            do {
                let store = try FeedLibraryStore(url: library)
                try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
                try await store.close()
            } catch { failure.withLock { $0 = error } }
            done.signal()
        }
        done.wait()
        if let error = failure.withLock({ $0 }) { throw error }
    }
}
#endif
