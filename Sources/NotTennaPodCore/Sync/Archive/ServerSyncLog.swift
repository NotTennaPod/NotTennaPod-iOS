import Foundation

/// One line of a server library's synchronization log (PROTOCOL §15 "Diagnostics").
public struct ServerSyncLogEntry: Equatable, Sendable {
    /// Milliseconds since 1970.
    public var time: Int64
    /// What happened: `push`, `outcome`, `pull`, `apply`, `paused`, `resumed`, `retry`, `waiting`, `error`, `requested`,
    /// `full`, `queue_safeguard`, `owed`, `unmapped`, `export`, … (the app names them).
    public var kind: String
    public var detail: String

    public init(time: Int64, kind: String, detail: String) { self.time = time; self.kind = kind; self.detail = detail }

    public var date: Date { Date(timeIntervalSince1970: Double(time) / 1_000) }
}

/// What the log may say about a server's answer or a failure (PROTOCOL §15.5: never payloads, passwords, tokens or secrets). A
/// server's words are logged only when they are the protocol's own (PROTOCOL §10, §3 and 4): error codes, push
/// result statuses, receipt outcomes and reasons, each from a fixed vocabulary; anything else, which may echo a password
/// or the request it refuses, is logged as a fixed description. A failure is logged by its kind, never its description.
enum ServerLogValue {
    static let errors: Set<String> = [
        "unauthorized", "forbidden", "lineage_unknown", "lineage_mismatch", "cursor_expired", "version_unsupported", "rate_limited",
        "server_busy", "dependency_missing", "payload_too_large", "invalid_request", "view_expired", "installation_conflict",
        "installation_superseded", "not_found", "method_not_allowed", "misdirected_request", "unsupported_media_type",
        "insufficient_space", "backup_running", "account_changed",
    ]
    static let statuses: Set<String> = [
        "accepted", "duplicate", "part_stored", "dependency_missing", "version_unsupported", "gap", "installation_conflict",
        "op_id_conflict", "invalid_part",
    ]
    static let outcomes: Set<String> = ["applied", "superseded", "not_applied", "rejected", "duplicate", "op_id_conflict"]
    static let reasons: Set<String> = [
        // Envelope violations (PROTOCOL §6.4).
        "invalid_author_id", "invalid_author_seq", "invalid_client_time", "invalid_dependencies", "invalid_previous_op_id",
        "invalid_targets", "invalid_type", "invalid_type_version", "missing_field", "unknown_field", "unsorted_dependencies",
        "unsorted_targets", "invalid_payload", "invalid", "invalid_receipt", "conflict",
        // The rules' reasons (PROTOCOL §7, checkpoints 5-8).
        "stale_subscribe", "alias_conflict", "already_admitted", "already_restored", "capability_not_declared",
        "episode_podcast_mismatch", "explicit_state", "foreign_session", "generation_closed", "generation_merged", "ineligible",
        "no_guid_no_enclosure", "not_playable", "not_subscribed", "refused", "session_finalized", "session_ordinal_conflict",
        "session_sealed", "unknown_generation", "unknown_podcast", "suspended", "cleared",
    ]

    static func error(_ code: String?) -> String { code.flatMap { errors.contains($0) ? $0 : nil } ?? "an unrecognized error" }
    static func status(_ status: String?) -> String { status.flatMap { statuses.contains($0) ? $0 : nil } ?? "an unrecognized result" }
    static func outcome(_ outcome: String?) -> String { outcome.flatMap { outcomes.contains($0) ? $0 : nil } ?? "an unrecognized outcome" }
    /// A receipt's reason, with its leading space; nothing without one.
    static func reason(_ reason: String?) -> String {
        guard let reason else { return "" }
        return " " + (reasons.contains(reason) ? reason : "an unrecognized reason")
    }

    /// Why a recovery could not restore an entry (PROTOCOL §6.11): one of the problems its progress records.
    static func recoveryProblem(_ status: String) -> String {
        ServerArchive.RecoveryProgress.problems.contains(status) ? status : "an unrecognized result"
    }

    /// The operation types this app records (PROTOCOL §7, §8 and §9).
    static let types: Set<String> = [
        "podcast.subscribe", "podcast.register_preview", "podcast.archive", "podcast.restore", "podcast.unsubscribe",
        "podcast.set_policy", "podcast.set_credentials", "podcast.change_url", "episode.mark_played", "episode.mark_unplayed",
        "episode.reset_position", "episode.restore_state", "episode.leave", "inbox.dismiss", "inbox.dismiss_all", "favorite.set",
        "account.set_discovery_policy", "account.set_queue_policy", "session.start", "session.checkpoint", "session.end",
        "session.finalize", "history.remove", "history.restore", "history.clear", "statistics.reset", "queue.add", "queue.restore",
        "queue.remove", "queue.move", "queue.reorder", "queue.clear", "installation.fork", "catalog.observe", "discovery.propose",
    ]

    /// A fact's operation type (`podcast.subscribe`) when it is one this app records; anything else, whatever its form,
    /// is "?" (a lowercase word could be a passphrase).
    static func type(_ type: String?) -> String { type.flatMap { types.contains($0) ? $0 : nil } ?? "?" }

    /// The system's error domains a failure may name (with its code); any other domain could be made of anything.
    static let domains: Set<String> = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain]

    /// A failure by its kind: the server's answer as a protocol error, a database error by its code, a system error by a
    /// known domain and its code, otherwise this app's error type and case. Never a description, a dynamic domain or
    /// anything a value carries: they may hold what was being handled.
    static func failure(_ error: any Error) -> String {
        switch error {
        case let error as ServerExchangeError:
            if case .server(let status, let code, _) = error { return "HTTP \(status) \(self.error(code))" }
            return error.description
        case FeedLibraryError.sqlite(let code, _):
            return "a library database error (SQLite \(code))"
        case is CancellationError:
            return "cancelled"
        case let error as URLError:
            return "a network error (\(error.code.rawValue))"
        default:
            if Swift.type(of: error) is NSError.Type {
                let error = error as NSError
                return domains.contains(error.domain) ? "a failure (\(error.domain) \(error.code))" : "an unrecognized failure"
            }
            // A Swift error: its type, and the case an enum's value is (names written in code, never its values).
            let type = String(describing: Swift.type(of: error))
            let mirror = Mirror(reflecting: error)
            guard mirror.displayStyle == .enum else { return "a failure (\(type))" }
            if let label = mirror.children.first?.label { return "a failure (\(type).\(label))" }
            return "a failure (\(type) \((error as NSError).code))"
        }
    }
}

/// The synchronization log of a server library, `sync.sqlite`'s `sync_log` (PROTOCOL §15.5): operations sent
/// with their outcomes (type, outcome and reason, never payloads), refusals, recoveries, lineage events, pauses and
/// resumptions, unmapped-change reports, changes recorded late and queue safeguards.
///
/// - Bounded at every write: entries older than 30 days go, and at most the newest 5,000 stay (`ServerArchive`).
/// - Passwords, tokens, secrets and URL userinfo never enter it: every line passes `redacted(_:)` at the one place
///   the log is written (`ServerArchive.log`).
public enum ServerSyncLog {
    /// The log's entries, newest first. A library whose sync database does not exist yet has none; reading never
    /// creates the file.
    public static func entries(syncDatabase url: URL) throws -> [ServerSyncLogEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let database = try SyncSQLite(url: url)
        defer { try? database.close() }
        guard try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'sync_log'") > 0 else { return [] }
        return try database.rows("SELECT time, kind, detail FROM sync_log ORDER BY id DESC").map {
            ServerSyncLogEntry(time: $0[0].integer ?? 0, kind: $0[1].text ?? "", detail: $0[2].text ?? "")
        }
    }

    private static let redactions: [(NSRegularExpression, String)] = [
        // URL userinfo (`scheme://user:password@host`), up to the last `@` before the path.
        (#"(?i)\b([a-z][a-z0-9+.\-]*://)[^\s/?#]*@"#, "$1"),
        // NotTennaPod credentials (device tokens and web sessions: `ntp1_` and 43 base64url characters).
        (#"ntp1_[A-Za-z0-9_\-]+"#, "ntp1_…"),
        // HTTP authorization values.
        (#"(?i)\b(bearer|basic)\s+[^\s"',;]+"#, "$1 …"),
        // JSON members and form or query parameters that carry a secret.
        (#"(?i)("(?:password|passwd|token|access_token|refresh_token|secret|setup_code|authorization)"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"…\""),
        (#"(?i)\b(password|passwd|token|access_token|refresh_token|secret|setup_code)=[^&\s"']*"#, "$1=…"),
        // A plain "password: value" (the log's own lines never say so; an echo could).
        (#"(?i)\b(password|passwd|secret)(\s*:\s*)[^\s"',;}\]]+"#, "$1$2…"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// The line with every password, token, secret and URL userinfo it could carry taken out.
    public static func redacted(_ text: String) -> String {
        var result = text
        for (expression, template) in redactions {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// The shared log's header, from what this app owns only: the title and app version it is given, the server address
    /// the person typed at sign-in, and the library's local ID. Nothing a server answered: the account's name comes from
    /// the sign-in answer and could carry anything, so it is left out rather than redacted.
    public static func shareHeader(title: String, app: String, library: LibraryRegistry.ServerLibrary,
                                   serverLine: String, libraryLine: String) -> [String] {
        let server = ServerAddress(stored: library.serverURL)?.string ?? "?"
        return [title, app, String(format: serverLine, server), String(format: libraryLine, library.id)]
    }

    /// The text the Share button exports: the header lines, an empty line, then one line per entry, newest first:
    /// the time with its offset (unambiguous wherever it is read), what happened and the detail.
    public static func shareText(_ entries: [ServerSyncLogEntry], header: [String], label: (String) -> String,
                                 timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        let lines = entries.map { entry in
            redacted("\(formatter.string(from: entry.date))  \(label(entry.kind))  \(entry.detail)")
        }
        return (header.map(redacted) + [""] + lines).joined(separator: "\n") + "\n"
    }
}
