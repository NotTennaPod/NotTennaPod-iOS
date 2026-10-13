import Foundation

/// One settings group saved as a JSON file, like one of Android's SharedPreferences groups.
///
/// - A missing file (confirmed absent, never a file that cannot be examined) means the defaults.
/// - An unreadable file is reported and left untouched; the app decides what to do with it.
/// - A write that fails publishes nothing: `value` and observers keep the saved state.
@MainActor public class JSONPreferenceStore<Value: Codable & Equatable & Sendable> {
    public private(set) var value: Value
    let file: URL
    private var observers: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(file: URL, defaultValue: Value) throws {
        self.file = file
        value = try SavedState.contents(of: file).map { try JSONDecoder().decode(Value.self, from: $0) } ?? defaultValue
    }

    public func update(_ value: Value) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        self.value = value
        for observer in observers.values { observer.yield(value) }
    }

    /// The current value, then every saved change.
    public func events() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(value)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return stream
    }

    isolated deinit { for observer in observers.values { observer.finish() } }
}

/// App start: a settings file whose content is damaged is renamed aside (its bytes kept beside it, with an
/// `unreadable-<seconds>` extension) and its group reopens from the defaults, as Android starts from the
/// defaults when a SharedPreferences file cannot be parsed. One damaged file no longer stops the library opening.
/// A file that cannot be read now (before the first unlock, a permission or I/O error) is not damaged: it is left
/// in place and the error is thrown, so the start is tried again once the file can be read.
public enum UnreadableSettingsFile {
    /// Opens `file`; if its content is damaged and the file can be set aside, reports the error and opens again.
    @MainActor public static func open<Store>(_ file: URL, now: Date = Date(), _ open: (URL) throws -> Store,
                                              setAside: (any Error) -> Void) throws -> Store {
        do { return try open(file) } catch {
            guard SavedState.isCorrupt(error) else { throw error }
            let aside = file.appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970))")
            guard (try? FileManager.default.moveItem(at: file, to: aside)) != nil else { throw error }
            setAside(error)
            return try open(file)
        }
    }
}
