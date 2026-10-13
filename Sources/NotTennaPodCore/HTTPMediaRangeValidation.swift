import Foundation

/// Identity of bytes already used to prepare a playback source. A new loading
/// budget does not authorize combining a different representation with them.
struct HTTPMediaRepresentation: Equatable, Sendable {
    let length: Int64?
    let validation: HTTPMediaRangeValidation
}

/// Validators strengthen active-playback range requests; their absence does not disable seeking.
/// This source's temporary bytes are never reused for another playback load or HTTP response cache.
enum HTTPMediaRangeValidation: Equatable, Sendable {
    case strongETag(String)
    case unvalidated

    init(etag: String?) {
        guard let etag else { self = .unvalidated; return }
        let bytes = Array(etag.utf8)
        guard bytes.count >= 2, bytes.first == 34, bytes.last == 34,
              bytes.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) || $0 >= 128 }) else {
            self = .unvalidated; return
        }
        self = .strongETag(etag)
    }

    var ifRange: String? {
        if case .strongETag(let value) = self { value } else { nil }
    }

    func validate(etag: String?, isFullResponse: Bool) throws {
        guard case .strongETag(let original) = self else { return }
        // A 206 after If-Range can omit the repeated validator. A 200 might instead be the
        // result of a failed condition, so require explicit identity before using that body.
        guard etag == original || (!isFullResponse && etag == nil) else {
            throw URLError(.resourceUnavailable)
        }
    }
}
