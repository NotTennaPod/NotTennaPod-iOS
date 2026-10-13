import Foundation
import Security
import SQLite3

/// Saved state that cannot be reached now: before the first unlock after a restart iOS keeps protected files and
/// Keychain items locked, and a folder or file may be temporarily unreadable for other reasons. Such state is never
/// replaced by defaults, set aside, given up for another library, or counted as a failed download: the work is
/// retried once it can read the state again.
public struct SavedStateUnavailable: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ underlying: (any Error)? = nil) {
        description = underlying.map { "Saved state unavailable: \(String(describing: $0))" } ?? "Saved state unavailable"
    }
}

/// Saved content whose bytes were read but are not a valid value (a decoding or format error). The only reason a
/// settings file is ever set aside.
public protocol CorruptSavedContent: Error {}

public enum SavedState {
    /// The bytes of `url`, or nil only when the file system confirms nothing is there (`ENOENT`, or `ENOTDIR`: a part
    /// of the path is a file). Any other failure, including a folder that cannot be examined, is thrown.
    public static func contents(of url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch where isAbsent(url) { return nil }
    }

    /// Whether something exists at `url`: false only when the file system confirms nothing is there; a path that
    /// cannot be examined throws.
    public static func isPresent(_ url: URL) throws -> Bool {
        var info = stat()
        if stat(url.path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Whether nothing exists at `url`: true only when the file system says so (`ENOENT` or `ENOTDIR`).
    public static func isAbsent(_ url: URL) -> Bool { (try? isPresent(url)) == false }

    /// Whether `error` means saved state could not be reached now (permission, data protection, I/O, a locked
    /// Keychain), as opposed to absent or damaged content.
    public static func isUnavailable(_ error: any Error) -> Bool {
        if error is SavedStateUnavailable { return true }
        if let error = error as? SynchronizationCredentialError, case .keychain(let status) = error { return keychainLocked(status) }
        if let error = error as? ServerSecretStoreError, case .keychain(let status) = error { return keychainLocked(status) }
        if let error = error as? FeedLibraryError, case .sqlite(let code, _) = error {
            // Includes a database another connection holds locked (busy, locked): it can be read once released.
            return [SQLITE_CANTOPEN, SQLITE_IOERR, SQLITE_PERM, SQLITE_AUTH, SQLITE_BUSY, SQLITE_LOCKED].contains(code & 0xFF)
        }
        if error is DecodingError || error is CorruptSavedContent { return false }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return posixUnavailable(Int32(underlying.code))
        }
        switch ns.domain {
        case NSPOSIXErrorDomain: return posixUnavailable(Int32(ns.code))
        case NSOSStatusErrorDomain: return keychainLocked(OSStatus(ns.code))
        case NSCocoaErrorDomain:
            return [CocoaError.fileLocking, .fileReadUnknown, .fileReadNoPermission, .fileWriteUnknown,
                    .fileWriteNoPermission].map(\.rawValue).contains(ns.code)
        default: return false
        }
    }

    /// Whether `error` is confirmed damage of content that was read: a decoding or format error, or a file SQLite read
    /// and found not to be a valid database.
    public static func isCorrupt(_ error: any Error) -> Bool {
        if error is DecodingError || error is CorruptSavedContent { return true }
        if let error = error as? FeedLibraryError, case .sqlite(let code, _) = error {
            return [SQLITE_NOTADB, SQLITE_CORRUPT].contains(code & 0xFF)
        }
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain
            && [CocoaError.fileReadCorruptFile, .propertyListReadCorrupt].map(\.rawValue).contains(ns.code)
    }

    private static func posixUnavailable(_ code: Int32) -> Bool {
        [EPERM, EACCES, EIO, EAGAIN, EBUSY, ETIMEDOUT].contains(code)
    }

    private static func keychainLocked(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }
}

/// Values a settings or registry file holds that fail their own validation once decoded.
extension PlaybackSpeedError: CorruptSavedContent {}
extension InboxSwipePreferenceError: CorruptSavedContent {}
extension LibraryRegistryError: CorruptSavedContent {}
