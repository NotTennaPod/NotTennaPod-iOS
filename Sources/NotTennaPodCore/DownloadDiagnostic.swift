import Foundation

/// Source-owned diagnostic wording; underlying system errors retain their native
/// message. A missing diagnostic stays absent rather than repeating the status.
enum DownloadDiagnostic {
    static func wrongSize(expected: Int64, received: Int64) -> String {
        "Download completed but size: \(received) does not equal expected size \(expected)"
    }
    static func media(_ failure: MediaDownloadFailure) -> String? {
        switch failure {
        case .http(let code): String(code)
        case .wrongSize(let expected, let received): wrongSize(expected: expected, received: received)
        default: nil
        }
    }
}
