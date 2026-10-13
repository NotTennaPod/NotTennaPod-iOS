import Foundation
import NotTennaPodCore

extension HTTPUserAgent {
    /// `NotTennaPod/<CFBundleShortVersionString>`, as every app-side network request sends it.
    static var current: String {
        application(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
    }
}
