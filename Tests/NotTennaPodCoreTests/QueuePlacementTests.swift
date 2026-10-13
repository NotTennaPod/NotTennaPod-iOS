import Foundation
import Testing
@testable import NotTennaPodCore

struct QueuePlacementTests {
    private func entry(_ id: Int64, media: Bool = true) -> QueueEntry {
        QueueEntry(episodeID: id, media: media ? QueueMedia(downloadURL: "episode-\(id)") : nil)
    }

    @Test func repeatedDownloadsKeepTheUsersTapOrderAtFront() {
        var queue = [entry(10), entry(11)]
        var downloading: Set<String> = []
        for id in [Int64(1), 2, 3] {
            let index = QueuePlacement.insertionIndex(
                location: .front, queue: queue, playing: nil,
                isDownloading: { $0.map(downloading.contains) ?? false }
            )
            queue.insert(entry(id), at: index)
            downloading.insert("episode-\(id)")
        }
        #expect(queue.map(\.episodeID) == [1, 2, 3, 10, 11])
    }

    @Test func downloadCompletionChangesNextInsertionPoint() {
        let queue = [entry(1), entry(2), entry(3)]
        #expect(QueuePlacement.insertionIndex(
            location: .front, queue: queue, playing: nil,
            isDownloading: { $0 == "episode-2" }
        ) == 0)
        #expect(QueuePlacement.insertionIndex(
            location: .afterCurrentlyPlaying, queue: queue, playing: .episode(1),
            isDownloading: { $0 == "episode-2" }
        ) == 2)
    }

    @Test func localMediaAndMissingMediaRemainDistinct() {
        let queue = [QueueEntry(episodeID: 1, media: QueueMedia(downloadURL: nil)), entry(2, media: false)]
        var calls = 0
        #expect(QueuePlacement.insertionIndex(
            location: .front, queue: queue, playing: nil,
            isDownloading: { url in calls += 1; return url == nil }
        ) == 1)
        #expect(calls == 1)
    }

    @Test func duplicateCurrentIdentityUsesFirstMatch() {
        let queue = [entry(1), entry(2), entry(1)]
        #expect(QueuePlacement.insertionIndex(
            location: .afterCurrentlyPlaying, queue: queue, playing: .episode(1), isDownloading: { _ in false }
        ) == 1)
    }

    @Test(arguments: 0...20)
    func randomPlacementAllowsEverySlotIncludingTheEnd(count: Int) {
        let queue = (0..<count).map { entry(Int64($0)) }
        for slot in 0...count {
            let index = QueuePlacement.insertionIndex(
                location: .random, queue: queue, playing: nil,
                isDownloading: { _ in Issue.record("Random placement must not inspect downloads"); return false },
                randomIndex: { range in #expect(range == 0...count); return slot }
            )
            #expect(index == slot)
        }
    }

    @Test func unknownStoredPreferenceFallsBackToBack() {
        for value in [nil, "", "front", "unsupported"] as [String?] {
            #expect(EnqueueLocation(storedValue: value) == .back)
        }
        for location in EnqueueLocation.allCases {
            #expect(EnqueueLocation(storedValue: location.rawValue) == location)
        }
    }

    @Test func matchesOriginalJavaCalculatorForEnumeratedQueueStates() throws {
        struct Case: Decodable {
            let mediaStates: [Int]
            let current: Int
            let location: EnqueueLocation
            let expected: Int
        }
        let url = try #require(Bundle.module.url(forResource: "queue-java", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count == 8_199)
        for fixture in cases {
            let queue = fixture.mediaStates.enumerated().map { entry(Int64($0.offset), media: $0.element != 0) }
            let playing: PlayingItem? = fixture.current == -2 ? .external : (fixture.current == -1 ? nil : .episode(Int64(fixture.current)))
            let downloading = Set(fixture.mediaStates.enumerated().filter { $0.element == 2 }.map { "episode-\($0.offset)" })
            let index = QueuePlacement.insertionIndex(
                location: fixture.location, queue: queue, playing: playing,
                isDownloading: { $0.map(downloading.contains) ?? false }
            )
            #expect(index == fixture.expected, "states=\(fixture.mediaStates), current=\(fixture.current), location=\(fixture.location)")
        }
    }
}
