# Source provenance

NotTennaPod is an independent iOS app, a fresh clone of AntennaPod. It is not AntennaPod and is not affiliated with, endorsed by or supported by the AntennaPod project.

The playback timing, queue placement, navigation configuration, feed parsing/fetching, refresh merging, duplicate matching, address handling, and their behavior tests are adaptations of AntennaPod release 3.12.1, commit `f8c641887e4677237b01b6e942ff8fe20fc8beec`, copyright the AntennaPod contributors, under GNU GPL version 3. The unchanged license is included in `LICENSE`.

The adapted sources are in [AntennaPod 3.12.1](https://github.com/AntennaPod/AntennaPod/tree/3.12.1) (commit `f8c641887e4677237b01b6e942ff8fe20fc8beec`):

- `playback/base/.../RewindAfterPauseUtils.java` and its tests
- `playback/service/.../internal/SkipUtils.java` and active Media3 callers
- `storage/database/.../ItemEnqueuePositionCalculator.java` and its tests
- `storage/database/.../DBWriter.java` queue add/indexed insert/remove/move/clear and Inbox-state rules, plus `FeedDatabaseWriter.updateFeed` batch queue submission
- `app/.../episodeslist/EpisodeItemViewHolder.java`, `actionbutton/ItemActionButton.java`, `screen/queue/QueueRecyclerAdapter.java`, `app/src/main/res/layout/feeditemlist_item.xml`, `ui/common/.../Converter.java` and `DateFormatter.java` for row state, geometry and display rules
- `ui/glide/.../GenerativePlaceholderImageModelLoader.java` for deterministic generated artwork; its original Java drawing loop also supplies independent test fixtures through recording-only graphics stubs
- `storage/database/.../FeedDatabaseWriter.java`, `FeedItemDuplicateGuesser.java`, `FeedItemDuplicateGuesserPool.java`, `FeedItemPubdateComparator.java`, their tests, and `DBWriter`/`PodDBAdapter` creation callers
- `storage/preferences/.../UserPreferences.java`
- `storage/preferences/src/main/res/values/arrays.xml` and `app/.../ui/screen/drawer/BottomNavigation.java`
- `parser/feed/.../SyndHandler.java`, namespace handlers, value parsers, and original test resources and expectations
- `model/.../feed/FeedItem.java`, `TranscriptType.java`, and associated feed models
- `net/common/.../UrlChecker.java`, `UriUtil.java`, `RedirectChecker.java`, `BasicAuthorizationInterceptor.java`, `HttpCredentialEncoder.java`, `AntennapodHttpClient.java`, and tests
- `net/download/service/.../feed/remote/HttpDownloader.java`, `FeedParserTask.java`, and feed update/request construction callers
- `net/download/service/.../feed/remote/HttpDownloader.java` media request/range/text/size rules and `net/common/.../BasicAuthorizationInterceptor.java` for the foreground `MediaDownloadTransfer` implementation and source-derived tests
- `net/download/service/.../feed/DownloadServiceInterfaceImpl.java`, `episode/EpisodeDownloadWorker.java`, `episode/MediaDownloadedHandler.java`, `app/.../actionbutton/CancelDownloadActionButton.java`, `model/.../FeedMedia.java` and `storage/database/.../DBWriter.java` for download job, worker retry/failure, completion and cancellation contracts and tests
- `app/.../actionbutton/DownloadActionButton.java`, `net/common/.../NetworkUtils.java`, `storage/preferences/.../UserPreferences.java` and `DownloadServiceInterfaceImpl.java` for warning/bypass and persisted network-constraint rules and tests
- `net/download/service/.../feed/FeedUpdateWorker.java`, `storage/database/.../DBWriter.java`, `PodDBAdapter.java`, and `mapper/FeedItemSortQuery.java` for refresh persistence and failure/recovery behavior

SwiftSoup 2.13.9, revision `18b80329749eca5ea29fc50211dca5c7eff5bfec`, supplies HTML tree parsing and entity decoding under the MIT license. Its unchanged copyright and license text is in `Licenses/SwiftSoup.txt`.

The Google Cast iOS SDK 4.8.6 (static XCFramework, [bootstrap](docs/DEPENDENCIES.md#google-cast-sdk)) supplies Cast device discovery, sessions and media control. It is Google's proprietary SDK, used under the [Google Cast SDK Additional Developer Terms of Service](https://developers.google.com/cast/docs/terms) (last updated 2024-09-18), which incorporate the Google APIs Terms of Service. The SDK bundles third-party components under their own licenses (Abseil, gRPC, Protocol Buffers, Eigen, Kiss FFT, TCMalloc, Material Components for iOS, SimplePing, the tz database and others). Their texts are extracted unchanged from the SDK's `OpenSourceLicenses/oss_licenses.bin` into `Licenses/GoogleCastSDK-OpenSourceLicenses.txt`. The SDK collects its own diagnostic, device-ID and product-interaction data, declared in its bundled privacy manifest and `NutritionLabel/NutritionLabel.txt`; the App Store privacy answers must include it.

GTMSessionFetcher 5.3.1, revision `724a52eea6329b7e12d3ad8300d76ca9f3895fcc` (Google, `project.yml`), is linked only because the Cast SDK requires it. It is under Apache License 2.0; its unchanged license is identical to `Licenses/Apache-2.0.txt`.

The plain-text block-boundary and whitespace conversion in `FeedValueParsing.htmlText` adapts the rules in Android's `core/java/android/text/Html.java`, copyright (C) 2007 The Android Open Source Project, under Apache License 2.0. It is a new Swift implementation over SwiftSoup; it does not include Android styling/span classes. The source inspected was [AOSP Html.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/text/Html.java), blob `a42eece57eec99c164876a4080962e38ccdda952`. The license is in `Licenses/Apache-2.0.txt`. Android runtime equivalence remains to be verified.

HTTP redirect/retry rules in `FeedFetcher` also adapt [OkHttp 4.12.0 RetryAndFollowUpInterceptor](https://github.com/square/okhttp/blob/parent-4.12.0/okhttp/src/main/kotlin/okhttp3/internal/http/RetryAndFollowUpInterceptor.kt), copyright (C) 2016 Square, Inc., under Apache License 2.0, preserved in `Licenses/Apache-2.0.txt`. This is a new Swift implementation; the original dependency version is pinned by the AntennaPod release's root `build.gradle`.

The positive file-size display calculation adapts AOSP `Formatter.java`, copyright (C) 2006 The Android Open Source Project, under Apache License 2.0, preserved in `Licenses/Apache-2.0.txt`. The inspected [official source](https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/text/format/Formatter.java) has blob `7653bdb7b2d818dc8be2e2a921d9d761c3f9323d`. The app supplies SI symbols and locale-formatted numbers, without Android's localized ICU units and bidirectional formatting.

Playback selection, sampling and completion contracts adapt `playback/service/.../Media3PlaybackService.java`, `internal/PlayableUtils.java`, `model/.../FeedMedia.java`, `storage/database/.../{DBWriter,PodDBAdapter}.java`, `storage/preferences/.../UserPreferences.java` and `net/sync/service/.../SynchronizationQueueImpl.java` from the pinned GPL-3.0 release.

Download row controls and progress adapt `app/src/main/res/layout/secondary_action.xml`, `app/.../actionbutton/{DownloadActionButton,CancelDownloadActionButton,PlayActionButton}.java` and `ui/common/.../CircularProgressBar.java` from the same GPL-3.0 release. Download warning strings and the `ic_cancel`/`ic_play_24dp` paths use the corresponding upstream resources and asset catalogue provenance.

The UIKit welcome and navigation views and the English strings adapt `app/src/main/res/layout/home_fragment.xml`, `main.xml`, `app/.../drawer/BottomNavigation.java`, `ui/common/src/main/res/values/{styles,colors}.xml` and `ui/i18n/src/main/res/values/strings.xml` from the same GPL-3.0 release. Their vector paths are converted to template PDF assets. The app icon, the logo layers (`Logo-{main,debug}-{background,foreground}`, app and widget) and the About banner (`about-teaser`) are NotTennaPod's own artwork, a teal broken-wave mark, not AntennaPod's launcher artwork. Apple's safe areas remain system-owned.

`App/Resources/Roboto-Regular.ttf` is the unchanged variable Roboto 3.011 font from Android Studio's `plugins/design-tools/resources/layoutlib/data/fonts/`. Embedded copyright: Copyright 2011 The Roboto Project Authors (https://github.com/googlefonts/roboto-classic). SHA-256: `9e157d5ff70ae52cc8c527b36e89d9b3c69c6c814da79fa6237a0bf0895abc7c`. Its embedded license is SIL Open Font License 1.1, preserved in `Licenses/Roboto-OFL.txt` from the project's [official license](https://github.com/googlefonts/roboto-3-classic/blob/main/OFL.txt). It remains OFL-licensed separately from application code.

The shared playback coordinator adapts the active Media3 forwarding-player, listener, sampling and queue-continuation contracts and `MediaLibrarySessionCallback.onSetMediaItems` from the same pinned GPL-3.0 release.

The native playback resolver follows the pinned `playback/base/.../MediaItemAdapter.java` and `model/.../FeedMedia.java` source-selection behavior. The bundled test fixture `Tests/NotTennaPodCoreTests/Fixtures/playback-30sec.mp3` is copied unchanged from the pinned release's `app/src/androidTest/assets/30sec.mp3` under GPL-3.0; its SHA-256 is `93209db68e1db6c3fed062b8ae530e1d00eb50d42b8d46e3da72b725ae211271`.

The player layout, mini-player progress, fade thresholds and control placement adapt `app/src/main/res/layout/{external_player_fragment,audioplayer_fragment,cover_fragment}.xml`, `app/.../activity/MainActivity.java` and `app/.../screen/playback/audio/{ExternalPlayerFragment,AudioPlayerFragment}.java` from the pinned GPL-3.0 release. The player icons retain upstream vector paths.

Sleep-timer state, preferences, warning/reset/extension rules, playback completion and volume composition adapt `playback/service/.../internal/{SleepTimer,ClockSleepTimer,EpisodeSleepTimer}.java`, active `Media3PlaybackService`, `storage/preferences/.../{SleepTimerPreferences,SleepTimerType}.java` and their event/value classes from that GPL-3.0 release.

Player seek-track drawing and playback-ring geometry adapt the pinned GPL-3.0 `ChapterSeekBar.java` and `CircularProgressBar.java`. Seek thumb PNGs are unchanged AndroidX AppCompat 1.7.1 resources, copyright (C) 2015 The Android Open Source Project, Apache License 2.0. The source selector `abc_seekbar_thumb_material.xml` supplies normal, pressed and disabled states; `Base.Widget.AppCompat.SeekBar` supplies 16-dp horizontal padding.

The toolbar back arrow `abc_ic_ab_back_material` (`App/Resources/Assets.xcassets`) is AndroidX AppCompat's drawable of that name, rendered as a PDF, copyright The Android Open Source Project, Apache License 2.0 (`Licenses/Apache-2.0.txt`).

`gpodder_icon.png` and `nextcloud_logo.png` (`App/Resources/Assets.xcassets`) are unchanged copies of AntennaPod 3.12.1's `ui/preferences/src/main/res/drawable-nodpi/` images, used, as in AntennaPod, to identify the gpodder.net and Nextcloud synchronization services. The gPodder and Nextcloud names and logos belong to their respective owners.

`Sources/NotTennaPodCore/FeedArtworkBlur.swift` follows the blur in AntennaPod's `ui/glide/.../FastBlurTransformation.java` (GPL-3.0): the Stack Blur algorithm by Mario Klingemann, ported to Android by Yahel Bouaziz, which AntennaPod lists as StackBlur (Enrique López Mañas, Apache License 2.0, `Licenses/Apache-2.0.txt`). `App/ArtworkImageCache.swift` keeps each cover's source as AntennaPod's `ResizingOkHttpStreamFetcher` does (GPL-3.0): a picture of at most 1 MiB unchanged, a larger one reduced to at most 1,500 px.

The seek rounding and five-percent accessibility increment follow [AOSP AbsSeekBar.java](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/master/core/java/android/widget/AbsSeekBar.java), copyright (C) 2007 The Android Open Source Project, Apache License 2.0. UIKit handles native tracking/accessibility; equivalence of every Android touch-slop and accessibility path remains unverified. Player sheet release direction adapts [Material Components 1.12.0 BottomSheetBehavior.java](https://github.com/material-components/material-components-android/blob/1.12.0/lib/java/com/google/android/material/bottomsheet/BottomSheetBehavior.java), copyright the Android Open Source Project, Apache License 2.0. The unchanged license for these sources is in `Licenses/Apache-2.0.txt`.

Playback speed resolution, time display and queue aggregation adapt `ui/episodes/.../{PlaybackSpeedUtils,TimeSpeedConverter}.java`, `app/.../ui/screen/playback/{VariableSpeedDialog,PlaybackSpeedSeekBar}.java`, `AudioPlayerFragment`, `QueueFragment`, and the active Media3 speed/preference paths from the same GPL-3.0 release.

`SilenceSkippingProcessor.swift` adapts the default algorithm from AndroidX Media3 1.10.0 `SilenceSkippingAudioProcessor.java`, copyright 2018 The Android Open Source Project, under Apache License 2.0 (`Licenses/Apache-2.0.txt`). The Swift adaptation uses interleaved Int16 samples and a value-owned circular buffer. Original APK processor output supplies the independent test oracle.

`PCMSpeedProcessor.swift` adapts the PCM16, unity-pitch/same-sample-rate speed path from AndroidX Media3 1.10.0 `Sonic.java`, copyright (C) 2017 The Android Open Source Project and (C) 2010 Bill Cox, Sonic Library, under Apache License 2.0 (`Licenses/Apache-2.0.txt`). It is bounded Swift processing before Apple output, not an Android runtime dependency. The original release dependency bytecode supplies the independent host test oracle.

`PCMPlaybackClock.swift` adapts the sink checkpoint/skipping and timestamp-scaling rules from AndroidX Media3 1.10.0 `DefaultAudioSink.java` and `Util.java` (copyright (C) 2016 The Android Open Source Project), plus `SonicAudioProcessor.java` (copyright (C) 2017 The Android Open Source Project), under Apache License 2.0 (`Licenses/Apache-2.0.txt`). Its comparison generator extracts those Java methods unchanged into a harness with controlled state/native-output bindings.

The live parameter drain and request-coalescing behavior in `LocalPCMPlaybackStream.swift` adapts AndroidX Media3 1.10.0 `ExoPlayerImpl.java` and `DefaultAudioSink.java`, copyright (C) 2016 The Android Open Source Project, under Apache License 2.0 (`Licenses/Apache-2.0.txt`).

`PlaybackFocusPolicy.swift` adapts AndroidX Media3 1.10.0 `AudioFocusManager.java` (copyright (C) 2018 The Android Open Source Project), `ExoPlayerImplInternal.java` and `Util.java` (copyright (C) 2016 The Android Open Source Project), under Apache License 2.0 (`Licenses/Apache-2.0.txt`). The suppression-clear rewind behavior adapts the active AntennaPod 3.12.1 `Media3PlaybackService` listener from the pinned GPL-3.0 release.

The drawer and navigation-settings implementation adapts AntennaPod 3.12.1 `MainActivity`, `NavDrawerFragment`, `NavListAdapter`, preference XML and drawer resources under GPL-3.0. Original theme preview PNGs are retained unchanged. Drawer width/release/settling logic adapts AndroidX DrawerLayout 1.2.0 and customview 1.1.0 (`DrawerLayout`, `ViewDragHelper`), copyright The Android Open Source Project, under Apache License 2.0 (`Licenses/Apache-2.0.txt`).

Navigation customization adapts AntennaPod 3.12.1 `DrawerPreferencesDialog`, `ReorderDialog`, its adapter/touch callback, `UserInterfacePreferencesFragment` and `MainActivity` under GPL-3.0. The drag-handle vector retains original path data.

Default-page selection, root navigation identity and the Back policy adapt AntennaPod 3.12.1 `MaterialListPreference`, `MainActivity`, navigation arrays and subscriptions/drawer callers under GPL-3.0. The recorded Material 1.12.0 single-choice resource is copyright 2019 The Android Open Source Project under Apache License 2.0 (`Licenses/Apache-2.0.txt`).

FFmpeg 9.0.2 supplies the internal demuxer/decoder libraries under LGPL 2.1 or later. Source archive SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`. The unchanged license and license-details files are `Licenses/FFmpeg-LGPL-2.1.txt` and `Licenses/FFmpeg-LICENSE.md`. dav1d 1.5.4 supplies AV1 decoding under the BSD-2-Clause license, preserved unchanged in `Licenses/dav1d-COPYING`. [Bootstrap and provenance](docs/DEPENDENCIES.md#codec-ffmpeg-and-dav1d) define the exact build and generated artifact. Application behavior and reader ownership are Swift.

The FFmpeg reader seek-admission rule adapts Media3 1.10.0 `MediaCodecRenderer.java` and `MediaCodecAudioRenderer.java`, copyright the Android Open Source Project, under Apache License 2.0 (`Licenses/Apache-2.0.txt`).

`PCMInputTimeline.swift` adapts the Media3 1.10.0 `DefaultAudioSink.handleBuffer` timestamp synchronization rule, copyright (C) 2016 The Android Open Source Project, under Apache License 2.0 (`Licenses/Apache-2.0.txt`).

The Opus playback adapter follows AOSP `C2SoftOpusDec.cpp` (copyright 2018 The Android Open Source Project) and Media3 1.10.0 `OpusUtil.java` (copyright 2020 The Android Open Source Project), under Apache License 2.0 (`Licenses/Apache-2.0.txt`).

`StatisticsByteResources.swift` imports87 locale pairs for `byteShort` and `fileSizeSuffix` from Android API36 SDK framework resources, copyright The Android Open Source Project, under Apache License2.0 (`Licenses/Apache-2.0.txt`). `StatisticsTextFormatter` adapts Android16 `android.text.format.Formatter` unit/precision rules (same license) and AntennaPod's `Converter.shortLocalizedDuration`/`DateFormatter.formatAbbrev` behavior (GPL-3.0).

`FeedInformationLinkPattern.swift` imports the Android API36 runtime `Patterns.AUTOLINK_WEB_URL` pattern; `FeedInformationLinks.swift` adapts the corresponding `Linkify.WEB_URLS` match filter and URL-prefix handling. Copyright The Android Open Source Project, Apache License2.0 (`Licenses/Apache-2.0.txt`).

`FeedShareText.swift` and the explicit feed-URL update operation adapt AntennaPod3.12.1 `ShareUtils.shareFeedLink`, `DBWriter.updateFeedDownloadURL` and `PodDBAdapter.setFeedDownloadUrl` under GPL-3.0.

`FeedURLEditFlow.swift` and `FeedURLConfirmationCountdown.swift` adapt the pinned GPL-3.0 EditUrlSettingsDialog flow, warning text and timer-display arithmetic. The input outline/padding follows Material Components1.12.0 styles (Copyright The Android Open Source Project, Apache License2.0, `Licenses/Apache-2.0.txt`). Native editing, keyboard layout and monotonic scheduling use Apple APIs.

`FeedRefreshRequest.swift`, `FeedRefreshWorker.swift`, `ManualFeedRefreshCoordinator.swift` and the admission probe adapt the pinned AntennaPod3.12.1 `FeedUpdateManagerImpl`/`FeedUpdateWorker` behavior under GPL-3.0. Swift task ownership, native network monitoring and an SQLite journal implement those source contracts.

`NewEpisodeNotification.swift` and the corresponding preference/counter APIs adapt GPL-3.0 AntennaPod3.12.1 `FeedPreferences`, `PodDBAdapter.getFeedCounters` and `NewEpisodesNotification`.

`PodcastLoudnessCompressor` adapts the AOSP adaptive loudness compressor under Apache-2.0. Source, copyright and changes are recorded in `Licenses/Android-Loudness.txt`; the unchanged license is in `Licenses/Apache-2.0.txt`.

`MP3XingMetadata.swift`, `MP3SourceTimeline.swift` and `MP3RequiredID3Metadata.swift` adapt AndroidX Media3 1.10.0 MPEG Layer III, Xing/Info/VBRI and required ID3/MLLT metadata interpretation under Apache-2.0. Exact source paths, copyright and modifications are in `Licenses/Android-MP3-Metadata.txt`; Apple AudioFileStream remains the audio packet parser.

`NativeAudioSourceTimeline.swift`, `NativeMP4SourceTimeline.swift`, `NativeMP4Input.swift`, `NativeFLACSeekIndex.swift`, `NativeFLACPacketTiming.swift` and `NativeAudioPacketProducer.swift` adapt the AndroidX Media3 1.10.0 MP4, ADTS, WAV and FLAC duration, seeking and synchronization rules under Apache-2.0; the source classes, archive hash and changes are in `Licenses/Android-Native-Audio-Metadata.txt`. The exact range-EOF rule of `HTTPMediaRangeEnd` and `HTTPCodecByteInput` follows Media3 1.10.0 `DefaultHttpDataSource`/`HttpUtil` under Apache-2.0 (`Licenses/Android-HTTP-Range-EOF.txt`).

The usage-suggestion balloon's arrow is the Balloon 1.5.3 arrow drawable (skydoves, Apache-2.0), converted to a template PDF; see `Licenses/Balloon-arrow.txt`.

Sleep-timer dialog, hour dial, original toolbar icons and feedback semantics adapt `app/.../ui/screen/playback/{SleepTimerDialog,TimeRangeDialog}.java`, `app/src/main/res/layout/time_dialog.xml`, original `ic_sleep`/`ic_sleep_off`, and `playback/service/.../internal/ShakeListener.java` from the same GPL-3.0 release.

The transcript grouping, speaker/copy rules and overflow visibility in `EpisodeTranscript.swift`, `TranscriptParser.swift` and `PlayerOverflow.swift` are derived from AntennaPod3.12.1's model, transcript parser and player/menu implementation at the pinned reference commit. They retain this project's GPL-3.0 licensing; the disposable oracle's org.json dependency is not linked into the Swift app.

The classic Cast chooser adapts AndroidX MediaRouter1.8.1 `MediaRouteChooserDialog`, `MediaRouteDialogHelper`, chooser layouts and original bitmap icons, copyright The Android Open Source Project, under Apache License2.0 (`Licenses/Apache-2.0.txt`).

The connected Cast controls and toolbar indicator also adapt AndroidX MediaRouter1.8.1 `MediaRouteControllerDialog`, `MediaRouteButton`, and the connecting/connected animation frame PNGs (pixels unchanged; the 2023 timestamp chunks of `cast_connected-dark@1x.png` and `cast_connected_30-dark@1x.png` are removed) and timing, under the same Apache License2.0.

Cast group controls also adapt the original MediaRouter member layout, expand/collapse frame PNGs and timing under Apache License2.0.

Cast ripple wave/sparkle equations in `App/CastRippleFeedback.swift` adapt Android16 `RippleShader.java` and `RippleAnimationSession.java`, copyright (C) 2021 The Android Open Source Project, licensed under Apache License2.0.

Chapter merge/loading, cover previous/next policies, embedded tag parsing and image byte-range models adapt `ui/chapters/ChapterUtils.java`, `ChapterMerger.java`, `app/.../playback/audio/CoverFragment.java`, `parser/feed/PodcastIndexChapterParser.java`, `parser/media/{id3,vorbis,m4a}` chapter readers, and `model/.../feed/{Chapter,EmbeddedChapterImage}.java` from the pinned GPL-3.0 release. Seven unchanged original encoder fixtures in `Tests/NotTennaPodCoreTests/Fixtures/EmbeddedChapters/` retain their source paths/hashes in `manifest.json`; the remaining 43 fixtures were generated for these tests.

The chapter UIKit presentation and segmented seekbar adapt the pinned release’s CoverFragment, AudioPlayerFragment, ChaptersFragment, ChaptersListAdapter, ChapterSeekBar and related XML layouts under GPL-3.0. The English chapter strings are imported from `ui/i18n`.

`PlayerLoadingIndicator.swift` adapts AOSP Material progress vector geometry, trim interpolators, independent animation clocks and the static reduced-motion drawable, copyright (C) 2014/2016 The Android Open Source Project, Apache License2.0 (`Licenses/Apache-2.0.txt`). Native rendering uses Core Animation/Core Graphics and local view bounds.

## Server-mode parity parse

`Sources/NotTennaPodCore/Sync/Parity/` is a Swift port of the NotTennaPod server's feed parse (`internal/feed` of NotTennaPod-Server, GPL-3.0), which server libraries use so that the phone and the server parse a feed alike. Besides that parse and the AntennaPod 3.12.1 parser rules it carries (`ParityHandlers.swift`, `ParityValues.swift`, `ParityDateParser.swift` and its components; GPL-3.0, `LICENSE`), it ports or generates tables from the following works. The generated files name their exact sources in their headers.

- **Go 1.27.1** (BSD 3-Clause, `Licenses/Go-BSD-3-Clause.txt`). Copyright 2009 The Go Authors; the individual source files carry Copyright 2009, 2010, 2025 and 2026 The Go Authors.
  - `ParityGoFloat.swift` ports `strconv.ParseFloat` line by line from `src/internal/strconv/atof.go`, `decimal.go`, `uscale.go`, `pow10tab.go` and `atoi.go`'s `underscoreOK`.
  - `ParityFloatTables.swift` holds `pow10tab.go`'s powers of ten, generated by `Tools/parity-float-table.py`.
  - `ParityXMLDecoder.swift` ports `encoding/xml`'s `Decoder.RawToken` (`src/encoding/xml/xml.go`). `ParitySAX.swift` reads its tokens.
  - `ParityUnicode.swift` ports the `unicode` and `unicode/utf8` functions the server's parse uses.
  - `ParityTables.swift` (generated by `Tools/parity-tables.sh`) holds Go's `unicode` range and case tables (Unicode 17.0.0), `encoding/xml`'s name tables and `HTMLEntity` map, and the `html` package's entity table (`src/html/entity.go`).
- **golang.org/x/text v0.42.0** (BSD 3-Clause, `Licenses/golang-x-text-BSD-3-Clause.txt`). Copyright 2013 The Go Authors; `encoding/ianaindex` and `encoding/htmlindex` carry Copyright 2015 The Go Authors.
  - `ParityCJK.swift` ports the CJK decoders of `encoding/japanese`, `encoding/korean`, `encoding/simplifiedchinese` and `encoding/traditionalchinese`.
  - `ParityCJKTables.swift` (generated) holds their decoding tables, the WHATWG Encoding Standard indexes as x/text ships them.
  - `ParityDecode.swift` ports `encoding/unicode`'s UTF-16 decoder and resolves charset names as `encoding/ianaindex` and `encoding/htmlindex` do. Their aliases and the `encoding/charmap` single-byte tables are `ParityCharsetTables` in `ParityTables.swift`.
- **The Android Open Source Project, Android 16** (Apache License 2.0, `Licenses/Apache-2.0.txt`). `ParityHTMLText.swift` follows `android.text.Html`'s `HtmlToSpannedConverter` text. `ParityValues.swift` uses Android's `MimeTypeMap` extensions, captured from API 36 in `AndroidMIMEMap.swift`. Copyright (C) The Android Open Source Project.
- **TagSoup**, as in AOSP `platform/external/tagsoup` (Apache License 2.0, `Licenses/Apache-2.0.txt`). `ParityHTMLText.swift` ports its scanner and parser, and `ParityTagSoupTables` in `ParityTables.swift` holds its schema tables. Copyright 2002-2008 by John Cowan.
- **ICU**, as in AOSP `platform/external/icu`, and the Unicode Character Database (Unicode License v3, `Licenses/Unicode-3.0.txt`). `ParityDateTables` in `ParityTables.swift` holds ICU's English time zone names and metazones; Go's `unicode` tables above derive from the Unicode Character Database. Copyright © 1991-2026 Unicode, Inc.
- **The IANA time zone database 2025a** (public domain), as packaged in AOSP `platform/system/timezone`: the zone rules in `ParityDateTables`.
- **jsoup 1.15.1** (MIT License, `Licenses/jsoup-MIT.txt`). Its behaviour for website titles and feed links is ported in `ParityWebsite.swift`, and for the head of a page in `HTMLHead.swift` and `FeedDocumentClassifier.swift`. Copyright (c) 2009-2022 Jonathan Hedley.
- **Apache Commons IO 2.5** (Apache License 2.0, `Licenses/Apache-2.0.txt`). `XmlStreamReader`'s encoding detection is ported in `ParityDecode.swift` and `FeedDocumentDecoding.swift`, and `FilenameUtils.getExtension` in `ParityValues.swift`. Its NOTICE:

      Apache Commons IO
      Copyright 2002-2016 The Apache Software Foundation

      This product includes software developed at
      The Apache Software Foundation (http://www.apache.org/).
