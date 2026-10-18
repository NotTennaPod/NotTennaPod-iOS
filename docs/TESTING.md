# Testing

The [README](../README.md#testing) lists the test suites and how to run them. This page covers the framework probes, acceptance runs, the hub that runs the release candidate for the integration tests, and where the test data comes from.

## Prerequisites

The host suites that run the pinned server, every UI journey run (the NotTennaPod scheme's pre-action starts the hub), `HubProxySmokeTests`, the probes (their fixture servers include the hub), the hub's own tests and the acceptance runs need the sibling NotTennaPod-Server and NotTennaPod-Web checkouts, Go and Node; the hub's own tests and the acceptance runs also need the Playwright browsers; the acceptance runs alone also need `ffmpeg`, `ffprobe` and `openssl` (for the server's media acceptance and the web player suite); and the UI journeys need the Simulator's Files app opened once. [README: Test prerequisites](../README.md#test-prerequisites) lists them, which suite needs what, and the build caches. The other host suites and the view tests need only the README's setup.

## Probe tests

Run only with the `NotTennaPodProbeTests` scheme. These experiments are excluded from the app, view-test and UI-journey schemes and are not among the suites that must pass. They test assumptions about Apple frameworks that an implementation choice depends on; a failed probe informs that choice and never justifies changing platform settings or dropping a requirement. The probe scheme has no fixture pre-action: start what a probe needs with `Tools/test-fixtures.sh start` first.

`ProxyProtocolProbeTests` and `ProxyStreamingProtocolProbeTests` perform real TLS HEAD and relay requests through the authenticated HTTP (18790) and SOCKS (18791) proxy fixture `TestSupport/Servers/serve-proxy-protocol-fixture.py`; the first also reaches a public HTTPS endpoint.

`BackgroundProxyProbeTests` downloads through the same proxy fixture with a background `URLSession` configured by `PodcastProxy.apply`: HTTP forward proxy, HTTPS through an authenticated CONNECT proxy and SOCKSv5; it also records that an HTTP proxy's 407 challenge is not offered to a background session's delegate.

## Acceptance runs

`Tools/acceptance.sh A` builds the release candidate and runs acceptance A's rows in order (`--list` prints them). Its UI journeys run on the Simulator named by `NTP_ACCEPTANCE_IPHONE`, by default `iPhone 18 Pro`; set it to the name of any iOS 27 iPhone Simulator you have, for example `NTP_ACCEPTANCE_IPHONE="iPhone 18 Pro Max" Tools/acceptance.sh A`. The script never creates or renames a Simulator. `NTP_SERVER_CHECKOUT`, `NTP_WEB_CHECKOUT` (by default the sibling `NotTennaPod-Server` and `NotTennaPod-Web` checkouts) and `NTP_GO` (by default the server checkout's `.work/toolchains/go/bin/go`) select the checkouts and the Go toolchain, as for `Tools/ntp-server.sh`.

## Audio changes

A change to the audio output, transports, refill, queue depth, producers or speed processing needs two kinds of evidence ([AGENTS.md](../AGENTS.md)): `PCMRealTimeStarvationTests` must pass (acceptance A's quiet `ios-pcm-safety` row, or `Tools/test-host.sh --filter PCMRealTimeStarvationTests` on a quiet Mac), and a person must listen on a real iPhone at 1.75× and 3×, seeking, with the screen in use and locked. The test plays the long MP3 (`LongMP3/`) through the processed path into a muted transport at 1×, 1.75× and 3×, with the main thread blocked 400 ms of every second and every core loaded, and asserts that the renderer never runs out of audio and that the position advances at the selected speed. It is evidence about the pipeline's timing on the Mac, not about what is heard on a phone.

## Opt-in runs and overrides

These variables switch on runs that are off by default, or point a test at other inputs or outputs. Host suites read them from the environment. A UI journey or view test reads them from the test runner's environment: set them with a `TEST_RUNNER_` prefix on the `xcodebuild test` command (`TEST_RUNNER_HOME_SECTIONS_EXPECTED=<file> xcodebuild test …`), which `xcodebuild` passes to the runner without the prefix.

| Variable | Read by | Unset | Set |
| --- | --- | --- | --- |
| `NTP_SCALE=1` | The scale cases of `DerivedScaleTests`, `DerivedSequenceTests`, `KeyedReadsTests`, `LibraryMemoryBudgetTests`, `LibraryScreenBudgetTests`, `LibraryScreenModelEquivalenceTests`, `LibraryScreenOtherScreensTests`, `ProjectedTextChangeTests`, `ServerChangeSetBudgetTests` and `ServerChangeSetScaleTests` | Ordinary sizes | Power-user libraries of 10,000 to 100,000 episodes; run on a release build (`-c release`) |
| `NTP_CHANGE_ORACLE=1` | The sync suites' stores (`ChangeSetOracle.swift`) | No oracle | Every transaction of the sync scenarios is checked against the change-set oracle |
| `NTP_SYNC_STARVATION[=<episodes>]` | `SyncLoadStarvationTests` | Not run | Runs it (minutes long, on a quiet Mac); the value is the large podcast's episode count, 20,000 by default |
| `NTP_EXCHANGE_MEASURE[=<episodes>]` | `ServerExchangeMeasurementTests`, `ServerRecoveryMeasurementTests` | Not run | Measures large commits, the store's holds and playback-save latency (minutes long); the value is the large podcast's episode count, by default 20,000 for the exchange and 10,000 for recovery |
| `DATABASE_RESTORE_ORACLE_INPUT`, `DATABASE_RESTORE_ORACLE_OUTPUT` | `AndroidDatabaseRestoreTests.oracleHarnessExportsEveryInput` | Not run | Imports every `.db` in the input folder and writes, into the output folder, its re-export under the same name and `<name>.result.txt` (imported or rejected), for the `TestSupport/BackupChecker` round-trip checks |
| `DATABASE_BACKUP_KEEP=<file>` | `AndroidDatabaseBackupTests` | Nothing kept | Copies the written backup to that file, for an import on Android 3.12.1 |
| `HTML_EXPORT_KEEP_DIR=<folder>` | `HTMLExportWriterTests` | Nothing kept | Writes each export that differs from its expected document into that existing folder (`<library>-feeds.html`, `<library>-favorites.html`) |
| `SUBSCRIPTION_TAGS_EXPORT_DIR=<folder>` | `SubscriptionTagsTests` | Nothing kept | Keeps each bulk edit's `BEFORE.db` and `AFTER.db` in a subfolder per case |
| `HOME_SECTIONS_EXPECTED=<file>`, `HOME_SECTIONS_DATABASE=<file>` | `HomeSectionsJourneyTests` | `TestSupport/Data/home-sections/expected/journey-rich.json` and `databases/rich.db` | Runs the journey on another Android database and its oracle output |
| `SUBSCRIPTIONS_EXPECTED=<file>`, `SUBSCRIPTIONS_DATABASE=<file>` | `SubscriptionsJourneyTests` | The expectations recorded in the test and `TestSupport/Data/subscriptions-screen/databases/mixed.db` | Runs the journey on another Android database and its oracle output |
| `QUEUE_SCENE_RESIZE_IN_MOUNTED_TESTS=1` | `QueueGestureTests.test09RTLLeadingHalfAndRotation` | Rotates the device | Stops before the device rotation, for the Duo, whose orientation request does not resize its scene; the view test `QueueInteractionViewTests.queueRTLRetainsOrderAndReachabilityAcrossDeliveredSceneResize` then supplies the real scene resize, so run it with the journey |
| `KEEP_LOCAL_EXPORTS=1` | Journeys that save into the Files storage | Their exports are removed when they end | Keeps them for an independent check (below) |

## The hub: lifecycle and evidence

The hub (`TestSupport/Servers/hub/`, described in [ARCHITECTURE](ARCHITECTURE.md#integration-acceptance-protocol-16)) runs the release candidate for the integration tests. Its ordinary lifecycle checks create one isolated run per test method. Cleanup is registered before construction, builds or readiness can fail. Restart, backup and witness checks seed their own account, populated library, queue, listening/history facts and sealed feed credentials.

Shutdown first refuses control arrivals, cancels waits, builds and administrative commands, and terminates owned Server output before joining startup/restart and in-flight control handlers. Publisher/proxy listener creation and stop share lifecycle locks. Web writes use cancellable nonblocking pipes. Actor groups and Playwright's separately detached browser groups have independent ownership receipts; an iOS-owned Node preload records detached browser launches and synchronizes the public ESM child-process exports. Every owned group must exit, including a wait after forced kill, before successful finalization. Child logs and events are finalized before a log-only snapshot is retained. A failed shutdown or snapshot preserves originals, records the primary failure separately and reports missing or possibly truncated evidence.

Evidence is unique per candidate and method/invocation:

- `.work/hub-evidence/<server>-<web>/<test>-<timestamp>-<unique>/private/`: complete allowlisted raw logs and the private receipt; directories are mode 0700 and files mode 0600.
- The sibling `shareable/`: filtered event fields and a receipt without free-form errors, request URLs, raw child output, credentials or personal paths.
- `.work/fixture-evidence/`: equivalent launcher snapshots after owned fixture groups exit. PID receipts include process birth identity; unknown/reused PIDs are refused and never signalled.

Snapshots never recursively copy server data, backup archives, setup codes, key bundles or passphrase inputs. An explicit witness command copies only a stopped synthetic data directory for its check. `--keep` keeps the original private run; otherwise successful finalization and retention precede disposable data removal. Retention is bounded to evidence file types, with no silent pruning of prior failure receipts. Delete ignored evidence explicitly once it is no longer needed.

`Tools/test-host.sh` and `Tools/sync-contract-vectors.sh` share a checkout-local file lock with `Tools/test-fixtures.sh`. The host wrapper restores exact `Package.resolved` bytes/mode or original absence after its child group has exited, including failure/cancellation. Host-launched Hubs also register detached child groups and pending terminal receipts outside the Swift command group. The wrapper checks their independent exits and terminal retention; a failed retention receipt with all writers exited still restores the original, preserves evidence and leaves a separate unfinished lease. If finalization cannot confirm exit, it preserves the original privately in `.work/validation/restore-pending-*` and fails without restoring while an unconfirmed writer may remain. Its group finalizer uses only the standard library, so isolated Tools copies remain self-contained. Fixture registrations represent active test/UI leases; unleased idle or unclassified PIDs are recorded in `.work/validation/lease-observation.json` and are not stopped or treated as heavy work. Guard nesting uses a verified inherited descriptor. A nested mutating command that lost its descriptor fails explicitly instead of deadlocking. The existing Foundation-launched `--check` host helper may verify its authenticated ancestor's still-held lock for a read-only check; mutation cannot use that branch.

The Hub runs only the current pinned Server/Web candidate. Public `/web/stop` stops the actor reversibly; the next Web command starts a new owned actor. Terminal Hub shutdown forbids resurrection. Detached build, Server, administrative and actor groups have private durable ownership receipts. Launcher stop succeeds only after every recorded group exits and the Hub hands off a successful terminal retention receipt; incomplete shutdown preserves logs and ownership receipts and fails explicitly.

A test registration remains active when its fixtures exit or crash. Its run must explicitly release it with `Tools/test-fixtures.sh stop <device-or-run-name>`; starting another run never silently removes registrations. The isolated vector-script test drops the outer checkout lock environment only for its disposable copy, whose distinct root acquires its own lock.

## Test data

Tests find all their inputs in the repository. Every input is synthetic, generated by the project, copied unchanged from AntennaPod (GPL-3.0, like this project) or produced by AntennaPod's own code; the sections below say which.

The generators run `ffmpeg`, `ffprobe`, `java` and `javac` from `PATH`; for the scripts that read them, `FFMPEG` and `FFPROBE` name other builds. The MP3 seek-marker and format-change generators take ffmpeg as an argument instead (`generate.py <ffmpeg> <empty output directory>`). Recorded commands in manifests and provenance files name the executables only; the recorded versions say which builds made the files.

### Map

Three kinds of evidence are kept apart: **runtime Android output** (made by AntennaPod or Media3 running on Android), **source-based oracles** (independent programs written from the pinned Android source, sharing no code with the app) and **synthetic inputs** (made by the project). Most of the programs that made these files are not in the repository and cannot be rerun from here. What a file records about its origin varies: some expected files name their oracle, some only the reference commit, some nothing; the consuming test's description says what its expectations come from.

| Folder | What it is | Kind | Used by |
| --- | --- | --- | --- |
| `TestSupport/Data/database-restore/` | Android backups ([below](#android-backups-testsupportdatadatabase-restore)) | Runtime Android output and synthetic | Restore, backup, export and recovery tests |
| `TestSupport/Data/android-first-journey/Antennapod.db` | A database pulled from AntennaPod 3.12.1, the schema the backup writer must produce | Runtime Android output | `AndroidDatabaseBackupTests` |
| `TestSupport/BackupChecker/` | `normalize.py` (the state Android 3.12.1 presents for a database, by its cursor semantics), `compare_roundtrip.py` (Android → iOS import → re-export), `check_edit_roundtrip.py` (edited on iOS, as Android would hold it), `android_statistics.py` and `navigation_counters.py` (Android's own SQL) | Source-based oracle, committed and runnable | `AndroidBackupRoundTripOracleTests`, `LibraryExportTests`, the restore oracle harness ([overrides](#opt-in-runs-and-overrides)) |
| `TestSupport/Data/episode-list-menus/`, `episode-pager/`, `home-sections/`, `queue-sort-clear/`, `statistics-tabs/`, `subscription-tags-bulk/`, `subscriptions-screen/`, `swipe-settings/` | Android-schema databases of synthetic libraries (and their inputs as JSON), with the expected lists, pages, sections, queues, statistics, tags, subscriptions and swipe settings | Synthetic inputs; expected files from source-based oracles, not committed. The episode-list, pager, Home, tags and subscriptions files name their oracle and reference commit; the queue and statistics files only the reference commit, the swipe-settings file its source pin | `EpisodeListsTests`, `EpisodePagerTests`, `HomeSectionsTests`, `QueueSortTests`, `StatisticsTabsTests`, `SubscriptionTagsTests`, `SubscriptionDisplayTests`, `SwipeSettingsTests`, their view tests and journeys |
| `TestSupport/Data/html-export/` | Android-schema databases and the expected HTML: `expected-escaped/` is the oracle's escaped output of Android 3.12.1's documents. `HTMLExportWriterTests` itself applies the NotTennaPod branding and two NULL adjustments (a NULL feed address written as `href=""`, a NULL-state feed kept in favorites) to the `missing` and `states` documents before comparing | Synthetic inputs; source-based oracle (not committed; described in the test) | `HTMLExportWriterTests` |
| `TestSupport/Data/background-work/` | Download-log retention, attempt-budget and transfer-assembly cases (with their reference commit) and the expected results | Source-based oracle (not committed; described in the test) | `BackgroundWorkTests` |
| `TestSupport/Data/interface-settings/`, `notifications-settings/`, `project-about/`, `settings-search/` | Expected settings screens, rows and search results. The notifications file records its reference commit, the settings-root and settings-search files their source files' hashes; the interface-settings file holds results only. The tests' descriptions add that settings search was cross-checked against lib.preferencesearch 2.7.3 and the 3.12.1 APK, and the settings root against an emulator capture | Source-based oracles (not committed) | `InterfaceSettingsTests`, `NotificationsTests`, `SettingsRootCompositionTests`, `SettingsSearchTests` and their view tests and journeys |
| `TestSupport/Data/add-podcast-discovery/` | Discovery inputs, pages and expectations ([below](#add-podcast-discovery-testsupportdataadd-podcast-discovery)) | Synthetic inputs; source-based oracle | `AddPodcastDiscoveryTests`, `AddPodcastJourneyTests` |
| `Tests/NotTennaPodCoreTests/Fixtures/LongMP3/` | 1,800 s of synthetic changing harmonics, 44.1 kHz mono MP3 (the FFmpeg command is in its manifest) | Synthetic | `PCMRealTimeStarvationTests`, `SyncLoadStarvationTests`, `NativeMP3LongSourceTests` |
| `Fixtures/MP4Gapless/`, `MP4EditedStartup/`, `AACEdits/`, `AACEmptyEdits/` | MP4 files rewritten from the `AACGapless/` encodes with gapless metadata and edit lists (forward, gaps, repeats, reverses, empty edits, clipped starts), and `android-report.json`: what Media3 1.10.0 played from each on an Android 16 emulator | Synthetic inputs (the rewriting script is not committed; manifests record sources and hashes); runtime Android output | `MP4GaplessMetadataTests`, `MP4ExactIntervalTests`, `MP4StartupSourceTests`, `MP4EditedStartupTests`, `AACEditSequenceTests`, `AACEmptyEditTests`, `AACLocalSourceSelectionTests` |
| `Fixtures/NativeMP4Timeline/`, `NativeFormatReference/` | MP4 timeline variants (edits, timescales, empty and priority tracks) and MP4 extents, with Android 16 emulator reports of their durations and seekability | Synthetic inputs, committed (the programs that made them are not); runtime Android output | `NativeMP4SourceTimelineTests`, `NativeAudioSourceTimelineTests`, `NativeAudioPacketProducerTests`, `NativeMP4InputTests` |
| `Fixtures/BufferedCodecReference/` | Android's decodes of the Ogg and WebM tones (16-bit PCM) and their buffer timeline | Runtime Android output | `FFmpegBufferedSeekReferenceTests` |
| `Fixtures/external-entry-oracle.json` | 95 address, subscription-link and shared-text cases with Android's outcome; for shared text also the iOS outcome (it opens the first link) | Source-based oracle (an independent Python probe of the pinned source, not committed) | `ExternalEntryTests` |

The sections below describe the other host fixtures and the UI journeys' fixtures.

### Feed parser vectors

`TestSupport/Contract/` holds byte-checked copies of NotTennaPod Server's shared contract vectors (`Tools/sync-contract-vectors.sh`, with `SHA256SUMS` and the server commit). The feed parser corpus and the expected outputs of Android AntennaPod 3.12.1's own parser are in `TestSupport/Contract/vectors/feeds/`; its `PROVENANCE.md` is generated with the corpus, copied with it and covered by `SHA256SUMS`, so it stays beside the files it describes.

### Host test fixtures

`Tests/NotTennaPodCoreTests/Fixtures/` holds the host tests' inputs. These fixtures come from the pinned Android source, Android runtime captures or independent generators, never from the Swift implementation. Oracles record original outputs at full precision; tests compare them at the precision a person would notice, exactly only for visible order, counters, text and data ([AGENTS.md](../AGENTS.md#the-goal)).

`release-schedule-oracle.json` contains 2100 predictions from the complete unchanged original ReleaseScheduleGuesser and DateUtils, including original real-world histories and synthetic five-zone/DST cases. It was generated by a Python probe script.

`feed-statistics-oracle.json` contains 1317 feed inputs and 7008 aggregate results from eight configurations of the original Java-constructed SQLite statistics query. It covers media/state/date boundaries and aggregate truncation and was generated by a Python probe script.

`feed-information-oracle.json` records 101 original description outputs and 118 funding lists from unchanged `HtmlToPlainText` and the original `FeedInfoFragment` funding block, with actual pinned Jsoup 1.15.1/Commons Lang 3.18.0. It was generated by a Python probe script.

`recycler-scroll-runtime.json` is an unchanged capture of 96 isolated Android RecyclerView 1.4.0 refresh layouts with source-aligned core/annotation versions and 20 settling frames. It records adapter positions, offsets, rows and attached-child geometry; it is not a whole feed-screen capture.

`queue-java.json` was generated by a shell script executing the original release 3.12.1 queue-placement calculator. It is not generated from the Swift implementation.

The matrix enumerates queue lengths 0 through 5, each entry without media / with idle media / with downloading media, every possible current item plus absent/missing/external playback, and the three deterministic placement modes. Random placement is tested separately for its inclusive range contract.

`HostileFeeds/` holds hand-written synthetic feed documents: malformed, truncated, wrongly encoded and hostile ones (external entities and DTDs, huge numbers, NUL bytes, other root elements). `expected/android.jsonl` (the named documents) and `expected/mutations.jsonl` (a seeded corpus `HostileFeedCorpusTests` derives from them) are the outcomes of Android 3.12.1's own TypeGetter and FeedHandler SAX pass, run unchanged by an independent oracle and mapped as FeedParserTask does. The same documents are in the feed parser corpus as `hostile-*.xml`.

`ParityDatesGolden.json` is an unchanged copy of NotTennaPod Server's `internal/feed/testdata/dates_golden.json`, the server's date parser results that the phone's parity parse must match.

`OPMLFixtures/` holds OPML documents and `oracle.json`, the results of AntennaPod's unchanged reader with Android's own KXmlParser; NotTennaPod Server keeps an unchanged copy of the oracle and the supported cases' documents in `internal/importer/testdata/opml/`.

`Feeds/` contains all nine XML resources copied byte-for-byte from release 3.12.1 `parser/feed/src/test/resources/`. `FeedParserTests` adapts the assertions in the upstream `RssParserTest` and `AtomParserTest`, then adds source-derived scenarios. These expected values were not generated by the Swift parser. Copy equality was checked with `cmp` for every original file.

`duration-java.json` contains 1,463 cases generated by a shell script from the unchanged Java `DurationParser.java`. Inputs include the upstream examples, seconds −2 through 65 with seven fractional variants in seconds/minutes/hours forms, trailing colons, invalid values, signed/Unicode numbers, exponent/hex float forms, and overflow. The original algorithm runs directly on the Android Studio JDK; there are no Android stubs in this oracle.

`cover-oracle.json` contains 42 patterns generated by a Python tool. The tool extracts the palette, grey-shade method and drawing loop unchanged from the pinned `ui/glide/.../GenerativePlaceholderImageModelLoader.java`, retaining Java `String.hashCode` and `java.util.Random`. Minimal Canvas/Paint/filter stubs record drawing calls; they do not rasterize pixels or emulate Glide, gradients or JPEG encoding. Seven model strings (including the listening fixture URL, emoji, Japanese and composed/decomposed Unicode) run at six sizes, including a nonsquare size. Float coordinates/stroke widths are stored as signed IEEE bit patterns and colors/tints as unsigned ARGB integers. Source path/hash are inside the fixture. SHA-256: `16aa5afa1b87d60b29c5b0d38f80ed19421f36ed7832dc30439ed35777d7cd3b`. It covers the declared draw operations, not rasterized output.

`AACGapless/` holds three synthetic AAC-LC, HE-AAC and HE-AACv2 `.m4a` files from Apple's AAC encoder and Android's report on them (`android-report.json`). `manifest.json` also records the raw ADTS encodes made with them; those bytes are kept once, as `AACProfiles/lc-stereo.aac`, `he-stereo.aac` and `hev2-stereo.aac`.

`StreamingFormats/` contains eight synthetic tone encodings (WAV, M4A with and without a tail, ADTS, FLAC, Ogg Vorbis, Ogg Opus and WebM Opus) made with FFmpeg 8.1.2; its manifest records every command, the codec/container metadata and the hashes (the generating script is not committed). Apple's own parser and AVPlayer open all but the WebM (`StreamingFormatMatrixTests`); the app identifies WebM as Matroska first and plays it through the bundled decoder, which the ordinary playback tests cover (`BufferedPCMPlaybackEngineTests`, `PCMRemoteRoutingTests`). Native format detection and playback fixtures, not an Android runtime oracle.

`StreamingHLS/` is an AAC packet-preserving HLS remux of `StreamingFormats/tone.m4a`, generated with FFmpeg 8.1.2. Its manifest records the source hash, exact remux options and every playlist/segment hash. It tests native playlist playback and source routing for conventional and misleading URL extensions, including seek/rate/play intent kept across routing; it is not an Android runtime oracle.

`stream-loading-oracle.json` was generated by a Python probe from original Media3 1.10.0 method bodies and active AntennaPod 3.12.1 player configuration. It contains 2880 loading/start, 168 retry and 16 recovery cases, including nested causes, time/size boundaries, prior loading state and unknown-length/duration variants. These are policy comparisons with recording stubs, not Android network/cache/runtime evidence.

`vorbis-descriptions-oracle.json` contains 316 cases from complete unchanged original Vorbis reader classes, with separate retained crash/empty-page defect results. `VorbisDescriptions/` contains three unchanged original test media files. These binary fixtures also support the separate native metadata capability experiment; that experiment is not complete provider/UI parity.

`local-metadata-dates-oracle.json` records 222 original Java conversions from the unchanged LocalFeedUpdater date block and complete DateUtils with pinned Commons Lang 3.18.0. Swift comparisons retain source behavior except the encoded-instant corruption, whose corrected expectations come from original dashed equivalents. `local-metadata-native-oracle.json` joins ten actual Android callback observations to independently extracted image hashes; the builder verifies media hashes and excludes inconclusive descriptor rows.

`episode-artwork-oracle.json` retains 216 unchanged original image-priority cases and two stale-presence merge reproductions. It was generated reproducibly by a Python probe. The iOS test target bundles an unchanged `auphonic.ogg` to verify actual codec artwork after import/reopen.

`lazy-artwork-oracle.json` retains 108 cases from unchanged original lazy/check/availability/downloaded methods with a counted native adapter. It records cached flags and lookup decisions rather than actual native file reads. It was generated reproducibly by a Python probe; actual media, persistence and iOS discovery are verified separately.

`feed-header-capture.json` contains seven header rectangles extracted from the hash-verified original Android first-journey 07-subscribed capture. It supplies Android's measured text heights and bounds as layout reference, not a pixel target for UIKit.

`feed-filter-oracle.json` retains 753 unchanged original per-feed SQL queries, 1008 episode states and 759,024 bit-packed decisions. It was generated by a Python probe that executes unchanged Java classes in a disposable directory and their resulting queries in SQLite, not the separate in-memory matcher.

`statistics-format-runtime.json` contains 825 original APK/Android formatter results (345 durations, 345 file sizes, 135 dates). The shared host/iOS formatter tests compare 820 unchanged results and separately verify prevention of the five signed-overflow observations.

`dialog-allocation-runtime.json` contains 240 extracted Material 1.12.0/AppCompat 1.7.1 dependency measurements. 192 non-overflow rows supply intrinsic-size inputs and panel/body/action outputs; 48 source overflow rows are recorded but not reproduced. Generated by a Python extraction script. This isolates allocation and does not establish typography, original app journeys or gesture parity.

`feed-tag-order.json` is the 260-case API 36 ART corpus generated by a Java probe: initial, saved, same-screen and fresh-load tag ordering, including root/default, UTF16, capacity and collision-tree cases.

`StreamingHLSAES/` encrypts the five existing `StreamingHLS` AAC transport-stream segments with AES-128-CBC/PKCS7, per-segment explicit IVs and two deterministic fixture keys, then concatenates them for byte-range delivery. The multivariant master and imported URI variable test nested routing; rotation tests both key recipients. `manifest.json` records the OpenSSL version, all input/output hashes, offsets and the decrypted-byte check. This is a native transport fixture, not Android runtime acceptance.

`playback-unknown-duration.mp3` is the packet-preserving no-Xing remux used by the original selected-player deferred-retry probe. All 1150 audio packet payloads match `playback-30sec.mp3`.

`playback-vbr-stereo.mp3` is a deterministic 0.7 s 48 kHz stereo chirp encoded with libmp3lame VBR; the two channels differ. It extends incremental MP3 decoding/padding checks beyond the mono CBR fixture. `playback-vbr-low-rate.mp3` is the 22.05 kHz mono counterpart: Apple omits its declared padding, which a bounded source-based Xing fallback corrects.

`playback-indexed-vbr-stereo.mp3` and `playback-indexed-vbr-low-rate.mp3` are deterministic 30-second chirps for range-source seeking. Their longer encoded streams separate the initial withheld prefix from the 20-second target. Generation uses the same FFmpeg/libmp3lame and metadata flags as the short VBR fixtures, with duration 30 and chirp coefficients 7/9. They check that audio after a seek is complete, with native preroll, approximate time origins and final padding.

`playback-indexed-mllt-stereo-v3.mp3` and `playback-indexed-mllt-stereo-v4.mp3` add valid per-packet MLLT references to the 30-second VBR stereo fixture. The generator reads packet sizes independently with ffprobe, preserves the audio bytes and exercises actual FF/00 escapes at the tag/frame level. Both contain 1252 references with a 30024 ms source duration.

`playback-indexed-vbri-9.mp3` and `playback-indexed-vbri-3.mp3` replace that stereo fixture's non-audio metadata frame with valid VBRI tables over unchanged MPEG audio. These are constructed fixtures, not Fraunhofer encoder output. Their 9-entry and 3-entry tables include a 69,672-byte segment, exercising seeking across a bounded preview window.

`MP3SeekMarkers/` contains five six-second synthetic MP3s covering MPEG-1, 2 and 2.5 layer III: 8 kHz and 16 kHz mono CBR, 22.05 kHz and 44.1 kHz stereo VBR (nearly every frame borrows from the bit reservoir) and 48 kHz mono CBR, each with a Xing/Info header and LAME encoder delay/padding. `generate.py` made them with FFmpeg 9.0.2/libmp3lame and refuses to replace files; `manifest.json` records the commands, hashes, frame sizes, encoder delay/padding and reservoir use. The signal is a chirp plus seeded low-passed noise, different on each stereo channel, so any 50 ms of decoded audio occurs once. `MP3SeekAdmissionTests` uses them to check that a seek starts at the first whole MPEG frame at or after the target (Media3 drops whole codec buffers before the target), and where that audio really is. Synthetic signals, not an Android runtime oracle.

`MP3FormatChanges/` contains MP3s that change format mid-file, like a show with a spliced ad. `dai_mono.mp3` (stereo show, mono ad), `dai_48k.mp3` (44.1 kHz show, 48 kHz ad) and `dai_monoshow_stereoad.mp3` (mono show, stereo ad) are 10 s of synthetic speech, a 5 s tone ad and 10 s more speech, without Xing frames (made by `SyntheticSpeech/make-speech-fixtures.sh`, see below). `stereo-mono-stereo.mp3`, `mono-stereo-mono.mp3`, `low-high-low.mp3` (22.05 kHz MPEG-2 show, 48 kHz ad) and `high-low-high.mp3` (48 kHz stereo show, 16 kHz mono ad) join three independently encoded segments whose every channel carries its own tone, shaped by a slow envelope and seeded noise. `converted-chain.mp3` joins six segments in five formats (44.1 kHz stereo, then 48 kHz stereo, 48 kHz mono, 22.05 kHz mono and 16 kHz mono converted in a row, then 44.1 kHz stereo); each is quiet seeded noise with 2 kHz marker bursts 60 ms after its start and 40 ms before its end, so every segment's position, including its last moments, can be measured. `generate.py` made them with FFmpeg 9.0.2/libmp3lame and copies the three speech files; it refuses to replace files, and `manifest.json` records commands, hashes and each segment's byte range, MPEG frames, rate, channels and tones. `MP3FormatChangeTests` decodes each segment on its own with the test's own converter as the reference. Synthetic signals, not an Android runtime oracle.

`LongNativeFormats/` contains 368-second 48 kHz mono synthetic ADTS, fast/tail-M4A and FLAC fixtures generated by a Python script. Its manifest records commands, encoder version, metadata and hashes; generation refuses to replace existing fixtures. They exercise native index acquisition and seeking into the six-minute tail.

`HeardRate/` contains synthetic signals that name their own content time, generated by a Python script with FFmpeg 8.1.2 (manifest: commands, hashes, marker definitions; the generator refuses to replace them). `ticks.mp3` (44.1 kHz mono), `ticks.aac` (ADTS, 48 kHz mono) and `ticks.m4a` (44.1 kHz stereo) are 30 s of 60 ms tone bursts every 0.2 s, burst i at 300 Hz + 25 Hz × i; `gaps.mp3` is 12.7 s of a rising tone (200 Hz + 100 Hz/s × t) in five "speech" windows with 61 % digital silence between them. `HeardPlaybackRateTests` reads them back from the PCM handed to the renderer to measure the speed heard and what skip-silence removes. Synthetic test signals, not an Android runtime oracle; the expectations come from Android's player settings.

`FLACVariants/` contains two lossless variable-block versions of the existing eight-second FLAC tone, with 1024/2048/4096-sample blocks and a 3072-sample final block, with and without a seek table. The generator refuses an existing destination, preserves encoded subframes, rewrites RFC 9639 headers/CRCs, and checks every packet position/duration and the decoded audio against the source with FFmpeg/ffprobe. Its manifest records hashes and all 188 packet positions. The original Media3 extractor was also run on these files in a seek probe. They exercise the native zero-frame-count/capacity adapter and seeking with and without an index.

`PlaybackDecoder/dai_adts_mono.aac` and `PlaybackDecoder/dai_adts_48k.aac` (`SyntheticSpeech/make-speech-fixtures.sh`, FFmpeg's AAC encoder) are 10 s of 44.1 kHz stereo synthetic speech, a 5 s inserted "ad" (a 440 Hz mono tone at 44.1 kHz, or a 660 Hz stereo tone at 48 kHz), then 10 s more speech, concatenated as raw ADTS. With `changing.aac` they exercise ADTS whose decoder configuration changes mid-stream. `derive-fixtures.py` makes `changing.aac` and `changing-video.ts` by joining two one-second encodes each; its `manifest.json` lists those intermediate `part-*` files, which are not kept. `PlaybackDecoder/stereo-markers-mono-ad.aac` (`make-stereo-markers.sh`, FFmpeg 9.0.2) is 2 s of 44.1 kHz stereo with a 440 Hz left and a 660 Hz right marker, a 1 s mono 1000 Hz ad and the same 2 s again. SHA-256 `6909d1adc7bef420007ecd8b1b3db9cc96abd0f21a56f857e20c9b5c3aafbcfd` (mono) and `585440f5d7ded3023a85af795b470cb2a0dbcbc63ec665d73820e818bd83213d` (48k).

`Surround/` holds multichannel fixtures for stereo playback of surround audio. `labelled-5.1.m4a` (AAC-LC), `labelled-5.1.aac` (the same AAC as ADTS), `labelled-5.1.flac`, `labelled-5.1.opus` and `labelled-7.1.opus` give every channel its own one-second sine (FC 300, FL 500, FR 700, LFE 60, BL 1100, BR 1300 Hz; 7.1 adds SL 1700, SR 1900 Hz), made by `make-surround.sh` with FFmpeg 9.0.2. The same script makes `layout-change-6ch.aac`: raw ADTS with six channels throughout whose layout changes after one second, from 5.1 (a 500 Hz tone on back-left only) to hexagonal (FL FR FC BL BR BC, written with a PCE; a 700 Hz tone on back-centre only). `surround.m4a` and `surround.opus` (`SyntheticSpeech/make-speech-fixtures.sh`) are 20 s of synthetic speech on the centre channel only, with a quiet 220 Hz tone on front left and right.

`SyntheticSpeech/` makes the seven fixtures with speech in them: the three spliced MP3 shows, the two spliced ADTS shows and the two centre-dialogue surround files. `generate_speech.py` writes 53.7 s of speech-like sound that is entirely synthetic, from a fixed seed and the Python standard library: formant-synthesized syllables (a glottal pulse train at about 100–190 Hz, falling across each phrase and rising on stressed syllables, through five formant resonators gliding between seven vowel targets, with plosive bursts, fricative noise and short releases), word gaps and phrase pauses of 0.6–8.3 s, over a seeded room-noise floor of about −66 dBFS; RMS −20 dBFS, peaks at −2 dBFS. It is no recording and no voice, and it says nothing. `make-speech-fixtures.sh` cuts and encodes it with FFmpeg 9.0.2: the first and second 10 s around 5 s ads (−6 dB sines: 440 Hz mono and 660 Hz stereo at 48 kHz for the stereo shows, 440 Hz stereo for the mono show), and the first 20 s on the centre of a 5.1 mix. The script prints the files' SHA-256; `MP3FormatChanges/manifest.json` records the MP3s and the ADTS hashes are above. SHA-256 of the speech `22dc75b9ca5dfa4780eb7eb3cd4f3da477aa261356dc586e5fc22c90b26f38c4`, `surround.m4a` `6880b078a737f452ccf818a6abc2bf1e415f208ff201e4fe5f1ed9925771fe16` and `surround.opus` `ab2d40e3b27b952362cba7b61c528bdc68ae158ddd46e19ce050bd5ae60bb8db`; two runs give the same bytes.

`NativeBuffering/` contains an 1800-second 48 kHz mono FLAC generated by a Python script that refuses replacement. The 23,638,580-byte file exceeds the default encoded-audio budget; its manifest records all 18750 packet positions and the decoded-audio SHA-256. It exercises default-budget suspension/refill, the five-minute back buffer, seeks within buffered audio and HTTP recovery.

`OPMLExportFixtures/` was generated by a JVM probe from AntennaPod 3.12.1's unchanged OpmlWriter and cached upstream KXml2 2.3.0; `provenance.json` there records the commands and adapters. Raw OPML is the independent writer output; `cases.json` retains the exact inputs and externally parsed attributes. The date is the actual isolated JVM source write time in Asia/Kathmandu. No Android runtime or provider verification is implied.

#### Sleep timer

`sleep-timer-oracle.json` was generated by a Python probe from eight unchanged AntennaPod 3.12.1 timer/preference/event/value classes. It records 1024 timer steps and all 576 automatic hour ranges. Android services, vibration and shake detection are recording stubs; a package-local Java `System` supplies a controlled wall clock. This is original-code behavior evidence, not Android device execution.

`transcript-oracle.json` contains 87 deterministic JSON/VTT/SRT inputs executed against unchanged AntennaPod 3.12.1 parser/model classes by a Python probe. It records parsed segments/speakers, empty results and thrown exceptions. Four explicitly marked cases test prevention of three parser exceptions and SRT body truncation after a second colon; ordinary expectations remain the original output.

`transcript-scroll-ordinary.json` and `transcript-scroll-tall.json` retain ten Android API 36 RecyclerView 1.4.0 trajectories from the unchanged release transcript scroll method. They are framework/runtime evidence, not original-app motion recordings.

#### Player chapters

`player-chapter-policy-oracle.json` retains Android API 36 results for 512 merge cases, 44 current-chapter selections, 105 previous/next controls and 30 parser documents from the pinned 3.12.1 app. Cover methods are mechanically extracted unchanged into a collaborator harness; merge, selection and JSON parsing invoke app classes.

`EmbeddedChapters/` contains 43 generated ID3v2.3/v2.4, Ogg Vorbis/Opus and Nero fixtures plus 7 unchanged original encoder files. Its manifest records each byte count/hash/source; the generator refuses to replace changed fixture bytes. Android readers/ChapterUtils produce the 50-case oracle, including image-range hashes. The two distinct-ID collision cases keep the original nil/error result and have separate native defect-prevention assertions; the other 48 require the original output.

`now-playing-oracle.json` is the output of a Python oracle script run on the pinned Android source: "Set notification buttons" ids, default, dialog order and labels, the exactly-two rule and error text, Media3 button order, and the iOS subset and command table.

### Android backups (`TestSupport/Data/database-restore/`)

Synthetic test libraries; their feeds point at local fixture servers or `example.invalid`. NotTennaPod Server keeps unchanged copies of the first four groups below in `internal/importer/androiddb/testdata/`; `gap-data/` is this app's counter-test data.

- `android-3.12.1/`: libraries made by AntennaPod 3.12.1 on the Android emulator.
- `older-versions/`: backups generated from the table definitions of older AntennaPod releases (`PodDBAdapter` at the release named in each file name, 0.8 to 3.8.0), and `v3110000-edges.db`, edge values in the 3.12.1 schema.
- `android-3.12.1-upgraded/`: the same older files after AntennaPod 3.12.1 itself upgraded them (the oracle for the ported upgrader).
- `invalid/`: files the import must refuse; `invalid.json` records what Android does with each.
- `gap-data/`: `counter-states.db`, an Android 3.12.1 library with NEW episodes in subscribed, archived and preview feeds, and `counter-expected.json`, Android's own counter SQL run on it (`NavigationCountersViewTests`).

### Synchronization fixture servers

`TestSupport/Servers/serve-synchronization-fixture.py` (a gpodder.net-compatible account) and `serve-nextcloud-fixture.py` (Nextcloud Login Flow v2 and the gpoddersync provider) serve synthetic accounts on loopback, with the fixed password `fixture-password`; nothing in them comes from a real account.

### View test fixtures

The show-notes view tests (`ShownotesSubresourceTests`) load the notes and their subresources from an HTTPS server on 127.0.0.1 (`AppTests/ShownotesFixtureServer.swift`), as a publisher's are. Its certificates are not in the repository: the `NotTennaPodViewTests` scheme's test pre-action runs `Tools/shownotes-tls-fixture.sh`, which makes two fresh self-signed certificates for 127.0.0.1 into the ignored `.work/test-fixtures/shownotes-tls/` (it can also be run by hand). Nothing is added to a trust store: a Debug-only hook in the notes trusts exactly the `trusted` certificate's SHA-256 fingerprint, and `other` is the control a test expects to be rejected.

### UI journey fixtures

The UI journeys' fixture servers (`TestSupport/Servers/`) start from the NotTennaPod scheme's test pre-action (`Tools/test-fixtures.sh`) and serve the media in `TestSupport/Media/` and `AppUITests/Fixtures/`.

#### Controlled listening (`TestSupport/Media/listening/`)

`feed.xml` is synthetic project-owned test data with two episodes, stable identifiers, fixed publication dates, HTML shownotes, no artwork and 30-second enclosure durations. The two enclosure URLs share the same audio bytes but keep different URL identities.

`navigation.xml` adds forty stable synthetic episodes for feed scrolling and Back navigation, using the same media bytes with distinct enclosure URLs.

`30sec.mp3` is copied unchanged from release 3.12.1 `app/src/androidTest/assets/30sec.mp3`, commit `f8c641887e4677237b01b6e942ff8fe20fc8beec`, SHA-256 `93209db68e1db6c3fed062b8ae530e1d00eb50d42b8d46e3da72b725ae211271`. Upstream's GPL-3.0 license applies (see [LICENSE](../LICENSE)). Android reports about 30.04 s for it (30,040 ms after playback, 30,041 ms from `MediaMetadataRetriever`), although the feed declares 30,000 ms; AVFoundation's asset duration reports 30,000 ms.

`TestSupport/Servers/serve-listening-fixture.py` serves this directory on 127.0.0.1:18765, together with the refresh route (`/feed.xml?edited=1`) and the online-search routes (`/directory/*`, `/online-feed.xml`). `Tools/test-fixtures.sh` starts it from the NotTennaPod scheme's test pre-action. By hand, from the workspace root:

```sh
python3 -u TestSupport/Servers/serve-listening-fixture.py
```

For an Android emulator, map the same port with `adb reverse tcp:18765 tcp:18765` and add `http://127.0.0.1:18765/feed.xml` through the RSS dialog. The iOS Simulator reaches the host's loopback address directly.

This server supports full-file downloads only, not ranges, resume, throttling, errors or authentication; those have dedicated fixture servers.

`transcript-feed.xml` and `transcript.json` are synthetic fixtures for player overflow/transcripts: the same 30-second MP3, a website and social URL under reserved `example.invalid`, and six five-second JSON transcript entries with two speakers. The enclosure length is 120017 bytes. Android imports this URL with an `application/rss+xml` VIEW intent; wait for its media session's `state=PLAYING(3)` before pausing with media key 127 to obtain an idle capture.

`transcript-long-feed.xml` / `transcript-long.json` use six five-second synthetic text segments over the same MP3. Each paragraph repeats deterministic words 16 times to force list scrolling on iPhone, iPad and Duo. The text is a layout/gesture fixture, not a transcription.

`transcript-lines-feed.xml` / `transcript-lines.json` contain 101 numbered lines in the first segment and one following segment at 5 s. They check that Line 100 is the final visible line while the full text and following-segment navigation are kept.

`shownotes-actions.xml` contains one 30-second episode with an encoded HTTP URL, a 15-second internal timecode and an email link, for the long-press journey (action order, clipboard paste, share/browser handoff, paused seeking on episode and player surfaces).

`shownotes-hit-types.xml` supplies a CRC-verified embedded PNG in linked and plain forms, mixed image-anchor text, a selectable word, an ordinary text link and a publisher-script sentinel, for image-hold, selection-copy and browser-return journeys on both shownotes surfaces.

`shownotes-race.xml` provides two distinct long documents over the same MP3 for the A→B→A media-replacement journey; component tests control delayed readiness separately.

`sync-60sec.mp3` is project-generated 440 Hz mono audio (60 s, 22050 Hz, 32 kbps MP3) used by `serve-synchronization-fixture.py`. Generate with `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=22050:duration=60 -ac 1 -c:a libmp3lame -b:a 32k sync-60sec.mp3`; ffprobe reports 60.000000 s and 240449 bytes. Its 60-second duration keeps the remote 12-second position outside the default final-30-second smart-mark-played window, which the 30-second fixture cannot do.

#### Gated HLS playback (`TestSupport/Media/listening/buffering-hls/`)

Generated from the deterministic 30-second MP3 fixture with the command, version and hashes in `manifest.json`: AAC transport-stream segments with a normal VOD playlist. `TestSupport/Servers/serve-player-buffering.py` serves this directory on loopback port 18808 (started by `Tools/test-fixtures.sh` from the scheme's test pre-action) with per-test UUID gates: first no segments, then parts 00–06, then all parts. Chapters 0/10/25 use integer seconds because the pinned PodcastIndex parser uses `optInt` before multiplying by 1000. The 25 s chapter lies beyond the partial data and leaves time to verify resumed playback before natural completion. No production media or networking path is replaced.

#### Episode end (`TestSupport/Media/playback-end/`)

Project-generated sine tones for the episode-end and kill-while-playing journeys (`AppUITests/PlaybackEndJourneyTests.swift`). They are served by `TestSupport/Servers/serve-playback-end-fixture.py` on 127.0.0.1:18778, which `Tools/test-fixtures.sh` starts from the NotTennaPod scheme's test pre-action. The tones carry no meaning; only their lengths matter, so that an episode reaches its natural end within seconds.

| File | Content | Duration (ffprobe) | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `tone-8sec.mp3` | 440 Hz mono, 22050 Hz, 32 kbps | 8.000000 s | 32489 | `860b68de2a44bfc33ffda0e26afb5bc655113734d0b9c0af0b2a45a4a755ae56` |
| `tone-20sec.mp3` | 660 Hz mono, 22050 Hz, 32 kbps | 20.000000 s | 80450 | `175285170553a37bba0438f21c0df477598db977dc93a60d23c314b7b3a19aca` |

Generated with FFmpeg 8.1.2:

```sh
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=22050:duration=8 -ac 1 -c:a libmp3lame -b:a 32k -bitexact tone-8sec.mp3
ffmpeg -f lavfi -i sine=frequency=660:sample_rate=22050:duration=20 -ac 1 -c:a libmp3lame -b:a 32k -bitexact tone-20sec.mp3
```

The 60-second "Earlier episode" reuses `TestSupport/Media/listening/sync-60sec.mp3` (see [Controlled listening](#controlled-listening-testsupportmedialistening)).

`/feed.xml?run=<id>` lists only "Earlier episode" (1 January 2001, 60 s) until the test calls `/advance?run=<id>&stage=1`. From then on it also lists Episode A (4 January, 8 s), Episode B (3 January, 20 s) and Episode C (2 January, 8 s). Because they are newer than the episode already stored, a refresh puts them in the Inbox (Android `FeedDatabaseWriter.updateFeed`, "new episodes" action ADD_TO_INBOX by default). Each run id has its own stage, so tests never share feed state.

#### List Remove from inbox (`TestSupport/Media/list-inbox/`)

`episode.wav` is project-generated 120-second mono PCM silence: 8,000 samples/second, signed 16-bit little-endian, one channel, uncompressed RIFF/WAVE. It contains 960,000 frames and 1,920,000 data bytes; the 44-byte header makes the file 1,920,044 bytes. Its SHA-256 is `1caa48318d0e447618c834d28d814ab469928d72c8ea57d5d10650338803aee5`.

The file is deterministic synthetic data written with Python's `wave` module from zero-valued samples. It is not copied from the Android reference or any third-party source. It provides a valid, seekable 120-second enclosure with accurate duration/length metadata for list-action journeys.

`Tools/test-fixtures.sh` starts the server on port 18777 from the NotTennaPod scheme's test pre-action. To run it by hand from the workspace root:

```sh
python3 -u TestSupport/Servers/serve-list-inbox-fixture.py --host 127.0.0.1 --port 18777
```

The default stage for a new UUID namespace is `/feed.xml?session=<UUID>` with only `inbox-0`. `GET /advance?session=<UUID>&stage=1` exposes `inbox-2`, `inbox-1`, then `inbox-0`; `stage=0` resets that namespace. Episode numbers increase with UTC publication time, so the Inbox's default newest-first order displays stage 1 as 2, 1, 0. The same WAV is served for each enclosure as `/media.wav?episode=N`, with GET, HEAD and single byte-range support.

RSS uses `audio/wav`, enclosure length 1,920,044 and `itunes:duration` 120. RSS does not encode AntennaPod's NEW state; the app's refresh classification of the two newly delivered items supplies it.

#### Add-podcast discovery (`TestSupport/Data/add-podcast-discovery/`)

Served by `TestSupport/Servers/serve-discovery-fixture.py` on `127.0.0.1:18820`, which `Tools/test-fixtures.sh` starts for every UI run (scheme pre-action).

All data is synthetic and has one source: `TestSupport/Data/add-podcast-discovery/` (written by the discovery oracle's fixture builder; NotTennaPod Server keeps unchanged copies of its pages in `internal/feed/testdata/discovery/`). The server reads `discovery-inputs.json` and `pages/*` from there and does not keep copies, so the app tests, host tests and the Android oracle use the same bytes. Expectations come from `TestSupport/Data/add-podcast-discovery/expected/discovery.json` (oracle, cross-checked against the unchanged Java classes, 73/73).

What the server changes, and why:

- `{BASE}` in pages becomes `http://127.0.0.1:18820`, the oracle's default base, so the chooser order in `expected/discovery.json` applies unchanged.
- Image URLs (`img.example.org`) and fyyd feed URLs (`fyyd.example.de`) are moved to this server, so no test reaches the internet.
- Combined-search feed URLs keep their `example.org`/`example.net` hosts: the displayed order hashes those URLs, and the journeys only read the rows.
- Apple lookups (`/apple/lookup?id=N`) return `/feeds/top-N.xml` on this server; `/feeds/*.xml` are small valid RSS feeds (with an author, so a subscribed suggestion is excluded).
- The top list for `DE` has German titles (country selection is visible), and `AQ` answers HTTP 400.

In DEBUG, a UI-test launch (`-test-library-id`) always sends the Apple top list here; `-test-discovery` also sends Apple, Podcast Index and fyyd searches and lookups here (`/apple`, `/podcastindex`, `/fyyd` path prefixes). The Podcast Index route answers 401 without the auth headers.

#### Files provider (`TestSupport/Media/files-provider/`)

Documents the UI journeys pick through the real system Files picker. `Tools/test-fixtures.sh start <udid>` (the NotTennaPod scheme's test pre-action) copies them into the Simulator's "On My iPhone/iPad" storage (`group.com.apple.FileProvider.LocalStorage`) before every UI run, and removes earlier test exports and every other folder there. **That storage is the test Simulator's whole "On My iPhone/iPad": every folder at its root is deleted at each UI run, so keep nothing of your own there.** Within a run the storage stays as seeded: every journey that saves into it (OPML, database and HTML export, automatic backup) removes what it saved when it ends, pass or fail (`keepLocalFilesSeeded` in `AppUITests/NavigationQueries.swift`). To keep a journey's exports for independent checking, run that journey alone with `TEST_RUNNER_KEEP_LOCAL_EXPORTS=1`.

- `OPML/*.opml`: OPML import journeys, one copy per test library in folder `OPML-<library-id>`. `malformed.opml` is a truncated document; `refresh.opml` re-imports the retained feeds that the `refresh-lifecycle` fixture seeds.
- `DatabaseImport/*.db`: the database-import error cases (a newer schema version and a non-database file). The valid backup is `TestSupport/Data/database-restore/android-3.12.1/emulator-parity-library.db`.
- `DatabaseExport`: an empty folder is created for the automatic-export journey.

#### Playback video (`AppUITests/Fixtures/PlaybackVideo/`)

Original synthetic 96 s H264/AAC MP4, 320×180 at 25 fps, with two mono 48 kHz AAC tracks (eng 440 Hz, deu 880 Hz). Each track alternates two seconds of tone and two seconds of silence. The burned-in four-digit number is the zero-based frame index (divide by 25 for source seconds); the background cycles red/blue/green/yellow every 2 s. `generate.py` creates the bytes and validates all tracks with the installed FFmpeg/ffprobe; `manifest.json` records the hash, counts, profiles and tool version. No external or copyrighted input.

`serve.py --port 59421 --device <simulator-udid>` serves the RSS feed and progressive/range media. `Tools/test-fixtures.sh` starts it from the NotTennaPod scheme's test pre-action with the Simulator running the tests (`TARGET_DEVICE_IDENTIFIER`; any UUID is accepted), and the scheme sets `PLAYBACK_VIDEO_FIXTURE_URL=http://127.0.0.1:59421`. Its `/checkpoint?library=<test-UUID>` endpoint reads that Simulator's UUID-named test library read-only (SQLite `mode=ro`) so tests can check saved favorite/position/speed/silence state after pause and relaunch. It never writes application data.

`PlaybackVideoJourneyTests` covers download and progressive entry, seek, audio-track selection, speed plus skip-silence, pause/resize, audio-only/reattach and downloaded-state relaunch through the real app engine. The numbered frame on screen shows which source time is rendered; UI labels alone do not prove video/audio sync. Picture-in-Picture restoration and Duo display transitions need a runtime that supports them.
