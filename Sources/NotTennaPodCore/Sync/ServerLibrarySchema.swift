/// Schema 19 (PROTOCOL §15.2): the `ntp_*` tables every library has. They stay empty in a standalone
/// library, where nothing reads or writes them; a library is a server library once its `ntp_library` row exists.
/// The Android `.db`, OPML and HTML exports are written from the store's own rows and never include them.
///
/// Every statement is idempotent (`IF NOT EXISTS`), so a reopened partial schema (tests lowering
/// `user_version`) upgrades again.
enum ServerLibrarySchema {
    /// Facts a write that must not fail could not record (a play load's queue add), replayed by the next
    /// successful write and at launch; one per intent and subject. Sessions' owed exports are `ntp_library.export_owed`.
    static let owedTable = """
        CREATE TABLE IF NOT EXISTS ntp_owed (
            intent TEXT NOT NULL, subject TEXT NOT NULL, record BLOB, created_at INTEGER NOT NULL,
            PRIMARY KEY(intent, subject))
        """

    static let statements: [String] = [
        // The library's server identity, transport counters, cursor and the state later stages keep. `protocol_version`
        // is the newest protocol version a server reported when it refused a whole request (`version_unsupported`).
        """
        CREATE TABLE IF NOT EXISTS ntp_library (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            library_id TEXT NOT NULL, server_url TEXT, server_id TEXT,
            account_id TEXT NOT NULL, namespace TEXT NOT NULL, username TEXT,
            install_id TEXT NOT NULL, device_marker TEXT, main_author TEXT NOT NULL,
            protocol_version INTEGER, bounds BLOB,
            cursor TEXT, log_id TEXT, epoch INTEGER, seq INTEGER, digest TEXT,
            next_install_seq INTEGER NOT NULL DEFAULT 1, acked_install_seq INTEGER NOT NULL DEFAULT 0,
            pause_reason TEXT, transition BLOB, recovery BLOB, pending_transition BLOB,
            knowledge_clock INTEGER NOT NULL DEFAULT 0, export_owed INTEGER NOT NULL DEFAULT 0,
            durability_counter INTEGER NOT NULL DEFAULT 0,
            queue_revision INTEGER NOT NULL DEFAULT 0, overlay_revision INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL, updated_at INTEGER)
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_authors (
            author_id TEXT PRIMARY KEY, role TEXT NOT NULL CHECK(role IN ('main', 'registration')),
            next_seq INTEGER NOT NULL DEFAULT 1, last_op_id TEXT, registration_op TEXT, forked_from TEXT,
            created_at INTEGER NOT NULL)
        """,
        // Facts in transport-slot order. `fact` is the canonical JSON (JCS) the content hash covers.
        """
        CREATE TABLE IF NOT EXISTS ntp_outbox (
            install_seq INTEGER PRIMARY KEY, op_id TEXT NOT NULL UNIQUE, author_id TEXT NOT NULL,
            author_seq INTEGER NOT NULL, type TEXT NOT NULL, fact BLOB NOT NULL, content_hash TEXT NOT NULL,
            secret_ids TEXT, framing BLOB, receipt BLOB, receipt_lineage BLOB, waiting BLOB,
            created_at INTEGER NOT NULL, UNIQUE(author_id, author_seq))
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_retained (
            op_id TEXT PRIMARY KEY, transport TEXT NOT NULL, slot INTEGER NOT NULL, fact BLOB NOT NULL,
            receipt BLOB, lineage BLOB, secret_ids TEXT)
        """,
        // What each unretired local fact shows over the base, keyed by its op ID (PROTOCOL §6.8). `clock` is the
        // fact's knowledge clock: overlays apply in local creation order.
        """
        CREATE TABLE IF NOT EXISTS ntp_overlays (
            op_id TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL, property TEXT NOT NULL,
            kind TEXT NOT NULL, value BLOB, clock INTEGER NOT NULL,
            PRIMARY KEY(op_id, entity, id, property))
        """,
        "CREATE INDEX IF NOT EXISTS ntp_overlays_by_target ON ntp_overlays(entity, id)",
        // Facts and deferred cuts waiting for a podcast registration (PROTOCOL §15.2): a template with local IDs.
        """
        CREATE TABLE IF NOT EXISTS ntp_drafts (
            op_id TEXT PRIMARY KEY, author_id TEXT NOT NULL, author_seq INTEGER NOT NULL, previous_op_id TEXT,
            client_time INTEGER NOT NULL, registration_op TEXT NOT NULL, kind TEXT NOT NULL,
            template BLOB NOT NULL, dependencies TEXT, created_at INTEGER NOT NULL,
            UNIQUE(author_id, author_seq))
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_records (
            entity TEXT NOT NULL, id TEXT NOT NULL, field_group TEXT NOT NULL, value BLOB, provenance TEXT,
            PRIMARY KEY(entity, id, field_group))
        """,
        // Every known fact and decision. `frontier` marks the known nodes nothing known depends on;
        // `kind` is `local`, `draft` or `pulled` (drafts are never in the main author's frontier).
        """
        CREATE TABLE IF NOT EXISTS ntp_nodes (
            node_id TEXT PRIMARY KEY, knowledge_clock INTEGER NOT NULL, publication_seq INTEGER,
            frontier INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'local')
        """,
        "CREATE INDEX IF NOT EXISTS ntp_nodes_frontier ON ntp_nodes(frontier) WHERE frontier = 1",
        """
        CREATE TABLE IF NOT EXISTS ntp_podcasts (
            podcast_id TEXT PRIMARY KEY, feed_id INTEGER UNIQUE,
            live_generation TEXT, registration_op TEXT, identity_rules BLOB,
            pinned_removal INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_episodes (
            episode_id TEXT PRIMARY KEY, local_id INTEGER UNIQUE,
            podcast_id TEXT NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, occurrence BLOB, merged_into TEXT)
        """,
        // `feed_id` and `local_id` above have no foreign keys: local IDs are never reused (`library_ids`), and a
        // podcast or episode keeps its mapping after its local row is gone (an unsubscribe's fact is recorded after
        // the feed's deletion, in the same transaction).
        // A key for every queue entry of a server library (PROTOCOL §7.6); local queue order equals key order.
        """
        CREATE TABLE IF NOT EXISTS ntp_queue_keys (
            episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
            key TEXT NOT NULL, position_id TEXT NOT NULL, device_only INTEGER NOT NULL DEFAULT 0,
            next_anchor INTEGER, previous_anchor INTEGER)
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_sessions (
            session_id TEXT PRIMARY KEY, local_session TEXT, episode_id INTEGER, author_id TEXT,
            incarnation TEXT, state TEXT, record BLOB)
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_ledger (
            generation_id TEXT NOT NULL, occurrence TEXT NOT NULL, entry_id TEXT, state TEXT NOT NULL,
            notified INTEGER NOT NULL DEFAULT 0, record BLOB, PRIMARY KEY(generation_id, occurrence))
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_observed (
            entity TEXT NOT NULL, id TEXT NOT NULL, parse_hash TEXT, observation_op TEXT, catalog_node TEXT,
            PRIMARY KEY(entity, id))
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_secrets (
            secret_id TEXT PRIMARY KEY, credential_id TEXT NOT NULL UNIQUE, approved_origins TEXT,
            origin TEXT NOT NULL CHECK(origin IN ('local', 'fetched')), created_at INTEGER NOT NULL)
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_statistics_units (
            episode_id TEXT NOT NULL, unit_id TEXT NOT NULL, record BLOB, PRIMARY KEY(episode_id, unit_id))
        """,
        """
        CREATE TABLE IF NOT EXISTS ntp_attention (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, record BLOB, created_at INTEGER NOT NULL)
        """,
        // A podcast registration (`podcast.subscribe` or `podcast.register_preview`) and the registration author
        // that holds its drafts, from the action until its resolution is applied (PROTOCOL §15.2).
        """
        CREATE TABLE IF NOT EXISTS ntp_registrations (
            op_id TEXT PRIMARY KEY, feed_id INTEGER,
            kind TEXT NOT NULL CHECK(kind IN ('subscribe', 'register_preview')), author_id TEXT NOT NULL,
            feed_url TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending', 'resolved')),
            podcast_id TEXT, generation_id TEXT, mode TEXT, decision_id TEXT, created_at INTEGER NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS ntp_registrations_by_feed ON ntp_registrations(feed_id)",
        owedTable,
        // Revisions a shadow publication checks (PROTOCOL §6.8): `feed_changes` covers feeds and episodes only. In a
        // standalone library `ntp_library` has no row, so these update nothing.
        "CREATE TRIGGER IF NOT EXISTS ntp_queue_insert AFTER INSERT ON queue BEGIN UPDATE ntp_library SET queue_revision = queue_revision + 1; END",
        "CREATE TRIGGER IF NOT EXISTS ntp_queue_update AFTER UPDATE ON queue BEGIN UPDATE ntp_library SET queue_revision = queue_revision + 1; END",
        "CREATE TRIGGER IF NOT EXISTS ntp_queue_delete AFTER DELETE ON queue BEGIN UPDATE ntp_library SET queue_revision = queue_revision + 1; END",
        "CREATE TRIGGER IF NOT EXISTS ntp_overlays_insert AFTER INSERT ON ntp_overlays BEGIN UPDATE ntp_library SET overlay_revision = overlay_revision + 1; END",
        "CREATE TRIGGER IF NOT EXISTS ntp_overlays_update AFTER UPDATE ON ntp_overlays BEGIN UPDATE ntp_library SET overlay_revision = overlay_revision + 1; END",
        "CREATE TRIGGER IF NOT EXISTS ntp_overlays_delete AFTER DELETE ON ntp_overlays BEGIN UPDATE ntp_library SET overlay_revision = overlay_revision + 1; END",
        // A server library keeps every feed credential it sent or fetched as a secret until the library is
        // removed (PROTOCOL §15.4: recovery may upload a superseded secret). With no secrets (standalone) this is the
        // schema-11 trigger unchanged.
        "DROP TRIGGER IF EXISTS retire_feed_credential",
        "CREATE TRIGGER retire_feed_credential AFTER DELETE ON feed_credentials WHEN NOT EXISTS (SELECT 1 FROM ntp_secrets WHERE credential_id = OLD.credential_id) BEGIN INSERT OR IGNORE INTO feed_credential_cleanup VALUES (OLD.credential_id); END",
    ]
}
