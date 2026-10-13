import Foundation
import Testing
@testable import NotTennaPodCore

struct ShownotesLinkMenuTests {
    @Test func emailCopyPreservesQueryAndDecodesSourcePayload() {
        #expect(ShownotesLinkMenu.emailClipboardText(for: "mailto:hello@example.invalid") == "hello@example.invalid")
        #expect(ShownotesLinkMenu.emailClipboardText(for: "mailto:hello%2Btag@example.invalid?subject=Test%20topic") == "hello+tag@example.invalid?subject=Test topic")
        #expect(ShownotesLinkMenu.emailClipboardText(for: "https://example.invalid") == nil)
    }
    @Test(arguments: [true,false]) func ordinaryLinksPreserveDestinationAndSourceOrder(canOpen: Bool) {
        let destination = "https://example.invalid/path?q=one%20two&x=3#part"
        let menu = ShownotesLinkMenu(destination:destination,canOpenInBrowser:canOpen)
        #expect(menu.actions == (canOpen ? [.openInBrowser,.copyURL,.shareURL] : [.copyURL,.shareURL]))
        #expect(menu.destination == destination && menu.title() == destination)
        #expect(menu.positionMilliseconds == nil)
    }
    @Test(arguments: ["antennapod://timecode/0","antennapod://timecode/00015000","antennapod://timecode/2147483647"])
    func timecodesOnlyOfferSeek(destination: String) throws {
        let menu = ShownotesLinkMenu(destination:destination,canOpenInBrowser:true)
        #expect(menu.actions == [.goToPosition])
        #expect(menu.destination == destination)
        let time = try #require(menu.positionMilliseconds)
        #expect(menu.title(locale:Locale(identifier:"en_US")) == EpisodeRowPresentation.time(time,locale:Locale(identifier:"en_US")))
        if time == 15000 { #expect(menu.title(locale:Locale(identifier:"en_US")) == "00:00:15") }
    }
    @Test(arguments: ["antennapod://timecode/2147483648","antennapod://timecode/-1","custom-unhandled://resource"])
    func unsupportedDestinationsRemainCopyableWithoutInventingASeek(destination: String) {
        let menu = ShownotesLinkMenu(destination:destination,canOpenInBrowser:false)
        #expect(menu.actions == [.copyURL,.shareURL])
        #expect(menu.positionMilliseconds == nil && menu.title() == destination)
    }
}
