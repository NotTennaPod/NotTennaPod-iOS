import Foundation
import Testing
@testable import NotTennaPodCore

struct ProxySettingsDraftTests {
    @Test func hostValidationMatchesOriginalRuntimeIncludingUnicodeAndUnderscores() throws {
        struct Oracle: Decodable { struct Host: Decodable { let host: String; let valid: Bool }; let hosts: [Host] }
        let url = try #require(Bundle.module.url(forResource: "proxy-validation", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.hosts.count == 22)
        for row in oracle.hosts { #expect(ProxySettingsDraft.validHost(row.host) == row.valid, "Host: \(row.host)") }
    }
    @Test func portBoundsPreventConfirmedOriginalOverflowWhileDirectRetainsInactiveFields() {
        for text in ["-1", "65536", "9999999999999999999", "not-a-port"] {
            var draft = ProxySettingsDraft(.init(kind: .http, host: "localhost")); draft.port = text
            #expect(draft.errors[.port] == "proxy_port_invalid_error")
            draft.kind = .direct
            // DIRECT can be saved safely without parsing/trapping dormant text.
            #expect(draft.configuration.port == 0 && draft.configuration.host == "localhost")
        }
        for text in ["", "0", "1", "65535", "+80", "00080"] {
            var draft = ProxySettingsDraft(.init(kind: .http, host: "localhost")); draft.port = text
            #expect(draft.errors.isEmpty)
        }
    }
    @Test func resetRetainsTypeAndRemovesEveryField() {
        var draft = ProxySettingsDraft(.init(kind: .socks, host: "example.com", port: 8081, username: "fixture-user", password: "fixture-secret"))
        draft.clearFields()
        #expect(draft.configuration == PodcastProxy(kind: .socks))
        #expect(draft.errors == [.host: "proxy_host_empty_error"])
    }
}
