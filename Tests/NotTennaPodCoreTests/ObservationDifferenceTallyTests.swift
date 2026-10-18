import Foundation
import Testing
@testable import NotTennaPodCore

/// The first-refresh diagnosis tally: which fields of an observed record differ from its canonical record,
/// by name only.
@Suite struct ObservationDifferenceTallyTests {
    static func record(url: String? = "https://media.example.test/1.mp3?token=a", duration: Int64 = 0, title: String = "One") -> ContractJSON {
        ["title": .string(title), "description": .null, "link": .null, "pub_date": 1_000, "image_url": .null, "payment_link": .null,
         "media": url.map { ["url": .string($0), "size": "1000", "mime_type": "audio/mpeg", "duration": .integer(duration)] } ?? .null,
         "chapters": .null, "chapter_url": .null, "transcript_url": .null, "transcript_type": .null, "social_interact_url": .null]
    }

    @Test func equalRecordsAreCountedWithoutAField() {
        var tally = ObservationDifferenceTally()
        tally.note(Self.record(), canonical: Self.record())
        #expect(tally.line == "items=1 differ=0 fields=none")
    }

    @Test func eachDifferenceIsNamedOnce() {
        var tally = ObservationDifferenceTally()
        tally.note(Self.record(duration: 0), canonical: Self.record(duration: 61_000))
        tally.note(Self.record(url: "https://media.example.test/1.mp3?token=b"), canonical: Self.record())
        tally.note(Self.record(url: "https://other.example.test/1.mp3"), canonical: Self.record())
        tally.note(Self.record(url: nil), canonical: Self.record())
        tally.note(Self.record(duration: 5, title: "Two"), canonical: Self.record())
        tally.note(Self.record(), canonical: nil)
        #expect(tally.line == "items=6 differ=6 fields=media:1,media.duration:2,media.url:1,media.url.query:1,missing:1,title:1")
    }

    /// The line names fields only: no title, address or value of a record ever appears in it.
    @Test func theLineHoldsNoValues() {
        var tally = ObservationDifferenceTally()
        var unknown = Self.record(title: "A private title")
        if case .object(var object) = unknown { object["future_field"] = "value"; unknown = .object(object) }
        tally.note(unknown, canonical: Self.record(url: "https://secret.example.test/x.mp3?k=1"))
        let line = tally.line
        for value in ["private", "secret", "example", "value", "x.mp3"] { #expect(!line.contains(value), "\(line)") }
        #expect(line == "items=1 differ=1 fields=media.url:1,other:1,title:1")
    }
}
