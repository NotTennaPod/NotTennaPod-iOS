import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedAddressTests {
    @Test func upstreamURLPreparationExpectations() throws {
        for (input, expected) in [
            ("http://example.com", "http://example.com"), ("https://example.com", "https://example.com"),
            ("example.com", "http://example.com"), ("feed://example.com", "http://example.com"),
            ("pcast://example.com", "http://example.com"), ("itpc://example.com", "http://example.com"),
            ("itpc://https://example.com", "https://example.com"), ("\n http://example.com \t", "http://example.com"),
            ("\n example.com \t", "http://example.com"), ("antennapod-subscribe://example.com", "http://example.com"),
            ("pcast://https://example.com", "https://example.com"),
            ("antennapod-subscribe://https://example.com", "https://example.com"),
            ("PCAST:FEED://HTTPS://example.com", "HTTPS://example.com"),
            ("https://subscribeonandroid.com/example.com/feed", "https://example.com/feed")
        ] {
            #expect(try FeedAddress.prepare(input) == expected, "\(input)")
        }
        for base in ["https://examplebase.com", "antennapod-subscribe://https://examplebase.com"] {
            #expect(try FeedAddress.prepare("//example.com", base: base) == "https://example.com")
        }
        #expect(try FeedAddress.prepare("https://example.com", base: "http://examplebase.com") == "https://example.com")
        #expect(try FeedAddress.prepare("example.com", base: nil) == "http://example.com")
    }

    @Test func upstreamSubscribeDeeplinkExpectations() throws {
        for prefix in ["https://antennapod.org", "http://antennapod.org", "http://www.antennapod.org",
                       "https://www.antennapod.org"] {
            for slash in ["", "/"] {
                for value in ["http://example.org/podcast.rss", "http%3A%2F%2Fexample.org%2Fpodcast.rss", "example.org/podcast.rss"] {
                    for title in ["", "&title=a"] {
                        #expect(try FeedAddress.prepare("\(prefix)/deeplink/subscribe\(slash)?url=\(value)\(title)")
                                == "http://example.org/podcast.rss")
                    }
                }
            }
        }
        #expect(throws: FeedAddressError.missingDeeplinkURL) {
            try FeedAddress.prepare("https://antennapod.org/deeplink/subscribe?title=a")
        }
    }

    @Test func upstreamURLIdentityExpectations() {
        for (first, second) in [
            ("https://www.example.com/test", "https://www.example.com/test"),
            ("https://www.example.com/test", "https://www.example.com/test/"),
            ("https://www.example.com/test", "https://www.example.com//test"),
            ("https://www.example.com", "https://www.example.com/"),
            ("https://www.example.com", "http://www.example.com"),
            ("http://www.example.com/", "https://www.example.com/"),
            ("https://www.example.com/?id=42", "https://www.example.com/?id=42"),
            ("https://example.com/podcast%20test", "https://example.com/podcast test"),
            ("https://example.com/?a=podcast%20test", "https://example.com/?a=podcast test"),
            ("https://example.com/?", "https://example.com/"), ("https://example.com/?", "https://example.com"),
            ("https://Example.com", "https://example.com"), ("https://example.com/test", "https://example.com/Test"),
            ("antennapod_local:abc", "antennapod_local:abc"),
            ("http://user:pass@example.com:8080/Path#old", "https://example.com/path#new")
        ] { #expect(FeedAddress.equivalent(first, second), "\(first) / \(second)") }
        for (first, second) in [
            ("https://www.example.com/test", "https://www.example2.com/test"),
            ("https://www.example.com/test", "https://www.example.de/test"),
            ("https://example.com/", "https://otherpodcast.example.com/"),
            ("https://www.example.com/?id=42&a=b", "https://www.example.com/?id=43&a=b"),
            ("https://example.com/podcast%25test", "https://example.com/podcast test"),
            ("antennapod_local:abc", "https://example.com/"),
            ("https://example.com/a%2Fb", "https://example.com/a/b")
        ] { #expect(!FeedAddress.equivalent(first, second), "\(first) / \(second)") }
    }

    @Test func upstreamRequestEncodingExpectations() throws {
        #expect(try FeedAddress.requestURL("http://example.com/this%20is%20encoded").absoluteString
                == "http://example.com/this%20is%20encoded")
        #expect(try FeedAddress.requestURL("http://example.com/this is not encoded").absoluteString
                == "http://example.com/this%20is%20not%20encoded")
        for input in ["", "file:///tmp/feed", "https://", "relative"] {
            #expect(throws: FeedAddressError.malformedURL) { try FeedAddress.requestURL(input) }
        }
    }
}
