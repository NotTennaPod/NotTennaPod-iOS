import Foundation
import Testing
@testable import NotTennaPodCore

/// Plain episode derivation of fetched items and the server's rule for repeated items in one fetch: the first
/// item per derived episode ID is kept (PROTOCOL §9).
struct FetchEpisodeIdentityTests {
    private let namespace = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5"
    private let podcast = "p1:fc3b4ebdaa92f8db758a04d6d9cb53dc4a127a4911d389849df83553ca1c2ecd"

    private func feed(_ items: String, atom: Bool = false) throws -> ParsedFeed {
        let xml = atom
            ? "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Show</title>\(items)</feed>"
            : "<rss version=\"2.0\"><channel><title>Show</title>\(items)</channel></rss>"
        return try FeedParser().parse(Data(xml.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func firstPerEpisodeKeepsTheFirstOfEachIDAndEveryItemWithoutOne() {
        #expect(FetchEpisodeIdentity.firstPerEpisode(["a", "b", "a", nil, nil, "b", "c"]) == [0, 1, 3, 4, 6])
        #expect(FetchEpisodeIdentity.firstPerEpisode([]) == [])
        // IDs compare exactly, not by Unicode canonical equivalence.
        #expect(FetchEpisodeIdentity.firstPerEpisode(["\u{E9}", "e\u{301}"]) == [0, 1])
    }

    /// The server reference's case (selftest_rules.py, "repeated items in one fetch, the first kept").
    @Test func aRepeatedGUIDKeepsTheFirstItem() throws {
        let parsed = try feed("""
            <item><title>First</title><guid>dup</guid><enclosure url="https://cdn.example.com/dup.mp3?ad=1" type="audio/mpeg"/></item>
            <item><title>Second</title><guid>dup</guid><enclosure url="https://cdn.example.com/dup.mp3?ad=2" type="audio/mpeg"/></item>
            """)
        let kept = try FetchEpisodeIdentity.firstPerEpisode(parsed, namespace: namespace, podcastID: podcast)
        #expect(kept.map(\.title) == ["First"])
        let id = try FetchEpisodeIdentity.plainEpisodeID(namespace: namespace, podcastID: podcast, guid: "dup",
                                                         enclosureURL: nil, atom: false)
        #expect(id == (try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: "dup")))
    }

    @Test func guidsAreTrimmedAndAbsentGUIDsFallBackToTheEnclosure() throws {
        let parsed = try feed("""
            <item><title>One</title><guid>  g1 </guid></item>
            <item><title>Two</title><guid>g1</guid></item>
            <item><title>Three</title><guid>null</guid><enclosure url="HTTPS://Example.COM:443/a.mp3#t=1" type="audio/mpeg"/></item>
            <item><title>Four</title><enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
            <item><title>Five</title><enclosure url="https://user:secret@example.com/a.mp3" type="audio/mpeg"/></item>
            <item><title>Six</title><enclosure url="https://example.com/b.mp3" type="audio/mpeg"/></item>
            <item><title>Seven</title></item>
            <item><title>Eight</title></item>
            """)
        let kept = try FetchEpisodeIdentity.firstPerEpisode(parsed, namespace: namespace, podcastID: podcast)
        #expect(kept.map(\.title) == ["One", "Three", "Six", "Seven", "Eight"])
        let identity = try #require(FetchEpisodeIdentity.plainIdentity(guid: "null", enclosureURL: "HTTPS://Example.COM:443/a.mp3#t=1", atom: false))
        #expect(identity.kind == .enclosure && identity.value == "https://example.com/a.mp3")
    }

    @Test func guidsLoseTheirUserinfoBeforeTrimming() throws {
        let identity = try #require(FetchEpisodeIdentity.plainIdentity(guid: " https://u:p@example.com/e/1 ", enclosureURL: nil, atom: false))
        #expect(identity.kind == .rssGUID && identity.value == "https://example.com/e/1")
        // A control character the trim removes still ends text before a scheme-relative URL.
        let control = try #require(FetchEpisodeIdentity.plainIdentity(guid: "\u{01}//u@example.com/e/2", enclosureURL: nil, atom: false))
        #expect(control.value == "//example.com/e/2")
    }

    @Test func atomEntriesUseTheAtomIDKind() throws {
        let parsed = try feed("""
            <entry><title>A</title><id>urn:x:1</id></entry>
            <entry><title>B</title><id>urn:x:1</id></entry>
            <entry><title>C</title><id>urn:x:2</id></entry>
            """, atom: true)
        let kept = try FetchEpisodeIdentity.firstPerEpisode(parsed, namespace: namespace, podcastID: podcast)
        #expect(kept.map(\.title) == ["A", "C"])
        let atom = try FetchEpisodeIdentity.plainEpisodeID(namespace: namespace, podcastID: podcast, guid: "urn:x:1", enclosureURL: nil, atom: true)
        let rss = try FetchEpisodeIdentity.plainEpisodeID(namespace: namespace, podcastID: podcast, guid: "urn:x:1", enclosureURL: nil, atom: false)
        #expect(atom == (try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .atomID, value: "urn:x:1")))
        #expect(atom != rss)
    }
}
