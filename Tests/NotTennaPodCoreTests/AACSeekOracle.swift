import Foundation
import Testing
@testable import NotTennaPodCore

/// Fixture lookup for AACDeterministicTests. The sample-exact Apple converter oracle
/// that used to live here had no remaining caller and was removed.
enum AACSeekOracle {
    static func fixture(_ name: String, directory: String = "StreamingFormats") throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + directory))
#else
        // The app test target copies some fixture folders as folder references (subdirectory kept)
        // and StreamingFormats/LongNativeFormats file by file (flat), as NativeSourceFixtures reads them.
        let bundle = Bundle(for: AACOracleBundle.self)
        return try #require(bundle.url(forResource: name, withExtension: nil, subdirectory: directory)
            ?? bundle.url(forResource: name, withExtension: nil))
#endif
    }
}
private final class AACOracleBundle: NSObject {}
