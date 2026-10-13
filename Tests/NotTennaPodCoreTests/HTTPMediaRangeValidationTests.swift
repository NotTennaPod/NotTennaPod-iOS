import Foundation
import Testing
@testable import NotTennaPodCore

struct HTTPMediaRangeValidationTests {
    @Test func onlySyntacticallyStrongEntityTagsAreSentAsIfRange() {
        for value in ["\"\"", "\"v1\"", "\"!#$%&'()*+,-./:;<=>?@[\\]^_`{|}~\"", "\"é\""] {
            #expect(HTTPMediaRangeValidation(etag: value).ifRange == value)
        }
        for value: String? in [nil, "", "v1", "W/\"v1\"", "w/\"v1\"", "\"x\"y\"", "\"a b\"",
                              "\"a\tb\"", "\"a\nb\"", "\"a\rb\"", "\"\u{7f}\"", "\""] {
            #expect(HTTPMediaRangeValidation(etag: value) == .unvalidated)
            #expect(HTTPMediaRangeValidation(etag: value).ifRange == nil)
        }
    }

    @Test func validatedResponsesCannotSilentlyDowngradeOrChangeTheValidator() throws {
        let validation = HTTPMediaRangeValidation(etag: "\"v1\"")
        try validation.validate(etag: nil, isFullResponse: false)
        for full in [false, true] {
            try validation.validate(etag: "\"v1\"", isFullResponse: full)
            for etag in ["\"v2\"", "W/\"v1\"", "invalid"] {
                #expect(throws: URLError.self) { try validation.validate(etag: etag, isFullResponse: full) }
            }
        }
        #expect(throws: URLError.self) { try validation.validate(etag: nil, isFullResponse: true) }
    }

    @Test func unvalidatedRequestsDoNotPretendAnEntityTagIsRequiredOrProven() throws {
        for original: String? in [nil, "W/\"v1\"", "invalid"] {
            let validation = HTTPMediaRangeValidation(etag: original)
            for full in [false, true] {
                for response: String? in [nil, "W/\"v1\"", "\"new\""] {
                    try validation.validate(etag: response, isFullResponse: full)
                    #expect(validation.ifRange == nil)
                }
            }
        }
    }
}
