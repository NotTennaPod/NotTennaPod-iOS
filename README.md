# NotTennaPod for iOS

NotTennaPod is a native iOS podcast app that recreates [AntennaPod](https://github.com/AntennaPod/AntennaPod) for Android: the same features, screens, wording, settings and behaviour, written in Swift and UIKit.

**NotTennaPod is not AntennaPod.** It is an independent project with no affiliation with, endorsement from or support by the AntennaPod project. Please don't report NotTennaPod problems to the AntennaPod team.

**AntennaPod version.** The target is AntennaPod's latest tagged release. The current code is built around AntennaPod 3.12.1 and is updated as new releases come out; version numbers in the code, tests and test data record what each part was built and checked against.

## Features

- Subscriptions, Inbox, Episodes, Queue, Downloads, Favorites, History and the Home screen, in Android AntennaPod's order and layout
- Playback of audio and video podcasts with variable speed, skip silence, volume adaptation, chapters, transcripts and a sleep timer
- Downloads, including automatic downloads and background transfers, with mobile-data and proxy rules
- Feed refresh in the background, new-episode notifications and per-podcast settings
- Google Cast
- Synchronization with gpodder.net and Nextcloud, or with an optional self-hosted NotTennaPod server
- Android interoperability: imports and exports Android AntennaPod database backups and OPML, and exports HTML (subscriptions and favorites), exactly as Android does
- Statistics, tags, swipe actions and settings search
- Home Screen widget, Control Center control, Siri and Shortcuts actions, quick actions and the share sheet
- iPhone, iPad and iPhone Duo layouts, with rotation, window resizing, right-to-left languages and VoiceOver

## Requirements

- A Mac with Apple silicon: the codec is built for arm64 only.
- **Xcode 27.1 or later**, which has the iPhone Duo Simulator. Download it from [Apple's developer site](https://developer.apple.com/download/applications/), signed in with an Apple developer account.
- The iOS 27 Simulator runtime (Xcode → Settings → Components). The app needs iOS 27.0 or later on the device or Simulator.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 (the committed project is its output), and for building the codec: Python 3.12+, Meson, Ninja and pkg-config (all available from Homebrew: `brew install xcodegen python meson ninja pkg-config`).

Use Xcode 27.1 or later for every command below: select it with `sudo xcode-select --switch <Xcode.app>`, or for one shell set `DEVELOPER_DIR` to its `Contents/Developer` folder:

```sh
export DEVELOPER_DIR=<Xcode.app>/Contents/Developer
```

## Setting up a fresh checkout

Two dependencies are built or downloaded locally and never committed:

1. **Audio/video codec** (FFmpeg 9.0.2 and dav1d 1.5.4) as `Vendor/CFFmpegCodec.xcframework`: follow [DEPENDENCIES](docs/DEPENDENCIES.md#codec-ffmpeg-and-dav1d). The build takes a while; the package refuses to build without it.
2. **Google Cast SDK** 4.8.6 as `Vendor/GoogleCastSDK`: follow [DEPENDENCIES](docs/DEPENDENCIES.md#google-cast-sdk).

Then generate the Xcode project (and again whenever targets or schemes in `project.yml` change):

```sh
xcodegen generate --spec project.yml
```

## Building and running

Open `NotTennaPod.xcodeproj`, choose the **NotTennaPod** scheme and an iOS 27 Simulator, and run.

To build for the Simulator from the command line:

```sh
xcodebuild build -project NotTennaPod.xcodeproj -scheme NotTennaPod -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .work/debug ARCHS=arm64
```

`ARCHS=arm64` is needed because the codec has only an arm64 Simulator slice: without it, the generic Simulator destination also builds x86_64 and fails to link.

To check that the Release build compiles without signing:

```sh
xcodebuild build -project NotTennaPod.xcodeproj -scheme NotTennaPod -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .work/release CODE_SIGNING_ALLOWED=NO
```

## Installing on an iPhone

1. On the iPhone, turn on **Developer Mode** (Settings → Privacy & Security), then connect it to the Mac.
2. In Xcode → Settings → Accounts, sign in with an Apple developer account. The account's team ID is shown there.
3. Find the phone's device ID with `xcrun devicectl list devices`.
4. Build and install:

```sh
xcodebuild build -project NotTennaPod.xcodeproj -scheme NotTennaPod -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .work/device \
  DEVELOPMENT_TEAM=<team-id> CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates
xcrun devicectl device install app --device <device-id> \
  .work/device/Build/Products/Release-iphoneos/NotTennaPod.app
```

The app, share extension and widget use the IDs `org.nottennapod.app`, `org.nottennapod.app.share` and `org.nottennapod.app.widget`, and the app and widget share the App Group `group.org.nottennapod.app`. These belong to one developer team, so another team must change them all: the three `PRODUCT_BUNDLE_IDENTIFIER` settings in `project.yml` (the `NotTennaPod`, `NotTennaPodShare` and `NotTennaPodWidget` targets; they are explicit, so changing `bundleIdPrefix` alone does not change them), both `application-groups` entries there, the two `.entitlements` files and `PlayerWidget.appGroup` (`Sources/NotTennaPodCore/PlayerWidgetModel.swift`). Then regenerate the project.

If signing reports the App Group as missing, enable `com.apple.ApplicationGroups.iOS` under `SystemCapabilities` in the app's and widget's `TargetAttributes` of the generated project for one signing pass, then regenerate the project.

## Testing

Tests find all their inputs in the repository; the server-backed host tests and every UI journey run also need the sibling server and web checkouts and their toolchains ([Test prerequisites](#test-prerequisites)). The UI tests' local fixture servers start and stop automatically through the scheme's test pre- and post-actions (`Tools/test-fixtures.sh`); the view tests' scheme makes the show-notes tests' loopback TLS certificates in its pre-action (`Tools/shownotes-tls-fixture.sh`).

| Tests | Command | What they cover |
| --- | --- | --- |
| Host | `Tools/test-host.sh` | Logic and data on the Mac: feeds, playback processing, storage, Android backup, OPML and HTML interchange |
| View | `xcodebuild test -project NotTennaPod.xcodeproj -scheme NotTennaPodViewTests -destination 'platform=iOS Simulator,name=<simulator>' -parallel-testing-enabled NO` | Screens, menus and layout, including iPad, Duo and right-to-left |
| UI journeys | the same command with `-scheme NotTennaPod` | Flows across screens and relaunches on the iPhone |

`Tools/test-host.sh` forwards Swift test arguments, enforces `--no-parallel`, uses the Xcode that `DEVELOPER_DIR` or `xcode-select` selects and restores the exact original `Package.resolved` once every process that could write it has exited, failed and cancelled runs included; when it cannot confirm that, it keeps the original aside and fails instead (see [restoration pending](docs/TESTING.md#the-hub-lifecycle-and-evidence)). It shares a blocking file lock with fixture start/stop/seeding and `Tools/sync-contract-vectors.sh`; active fixture test registrations must finish before a quiet host run or resync. Idle processes without a test registration are recorded and left alone. Run UI journeys on one Simulator at a time; Simulators share the Mac's clipboard.

Some host suites are opt-in: `NTP_SCALE=1` adds the power-user scale cases (libraries of up to 100,000 episodes; run them on a release build, `-c release`), `NTP_CHANGE_ORACLE=1` checks every transaction of the sync scenarios against the change-set oracle, and `NTP_SYNC_STARVATION` runs `SyncLoadStarvationTests` (minutes long; run it on a quiet machine; its value is the large podcast's episode count, 20,000 by default). [TESTING](docs/TESTING.md#opt-in-runs-and-overrides) lists every such variable and override.

`Tools/acceptance.sh A` keeps its rows serial and gives `ParityLatencyTests` and `PCMRealTimeStarvationTests` separate quiet host rows, preserving their assertions and budgets; an audio change also needs a listening check on a real iPhone ([Audio changes](docs/TESTING.md#audio-changes)). `--keep` preserves successful acceptance data. The hub retains finalized logs before deleting disposable data; raw logs stay private and shareable evidence contains filtered event fields. See [the hub's lifecycle and evidence](docs/TESTING.md#the-hub-lifecycle-and-evidence).

### Test prerequisites

Besides the setup above, the server-backed tests run the NotTennaPod server and web client pinned in `TestSupport/Server/server-version.txt` and `web-version.txt`. `Tools/ntp-server.sh` builds them from archived copies of their checkouts (no checkout is changed), so these apply to the ordinary host and UI tests as well as to the acceptance runs:

- **Sibling checkouts** of [NotTennaPod-Server](https://github.com/NotTennaPod/NotTennaPod-Server) and [NotTennaPod-Web](https://github.com/NotTennaPod/NotTennaPod-Web) beside this one (`../NotTennaPod-Server`, `../NotTennaPod-Web`), each holding its pinned commit (fetch there if it doesn't). `NTP_SERVER_CHECKOUT` and `NTP_WEB_CHECKOUT` name other locations.
- **Go 1.26 or later** (the server's `go.mod`). The scripts run `NTP_GO`, by default `<server checkout>/.work/toolchains/go/bin/go`; with Go installed elsewhere (`brew install go`), set `NTP_GO=$(command -v go)`. Go on `PATH` alone is not used.
- **Node 24 or later** (`brew install node`), and `npm ci` in the web checkout at the pinned commit: the build uses that checkout's `node_modules` only when its `package-lock.json` is the pinned commit's.
- **Playwright browsers** for the hub's own tests and the acceptance runs: `npx playwright install chromium` in the web checkout for the web actor, or `npx playwright install` for the web client's suites (Chromium, Firefox and WebKit).
- **The Simulator's Files app opened once**, so its "On My iPhone" storage exists; the UI tests' pre-action seeds it and stops with "open the Files app once" otherwise.
- **For the acceptance runs only:** `ffmpeg` and `ffprobe` 6 or later on `PATH`, with the `aac` and `libopus` encoders (`brew install ffmpeg`), for the server's media acceptance and the web client's player suite, and an `openssl` whose `req` takes `-addext` (1.1.1 or later) for the player suite's HTTPS publisher. The server's [Development](https://github.com/NotTennaPod/NotTennaPod-Server#development) section and the web client's [Testing](https://github.com/NotTennaPod/NotTennaPod-Web#testing) section give the details. The ordinary host and UI tests don't need them.

| Tests | Need |
| --- | --- |
| Host suites that run the pinned server (`Server*`, agreement, recovery, exchange) | The server checkout and Go: plain `Tools/ntp-server.sh` builds the server alone into `.work/ntp-server/<server commit>/` |
| `HubProxySmokeTests` and every UI journey run (the scheme's pre-action starts the hub) | Both checkouts, Go, Node and `npm ci`: `Tools/ntp-server.sh --with-web` builds the candidate into `.work/ntp-server/<server>+web-<web>/`, and the built web copy goes to `.work/ntp-web/<web commit>/` (`--web-copy` prints it) |
| The hub's own tests | Both checkouts, Go, Node, `npm ci` and the Playwright browsers |
| `Tools/acceptance.sh A` | Everything above, and the acceptance-only `ffmpeg`, `ffprobe` and `openssl` (its `server` and `web-journeys` rows) |

A build is cached under those paths and reused while the pins stay the same.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/NotTennaPodCore/` | Shared logic: feeds, storage, downloads, playback engine, Android interchange |
| `Sources/NativePCMTransport/` | The small Objective-C++ audio render bridge ([constraints](docs/ARCHITECTURE.md#the-native-render-bridge)) |
| `Sources/SQLiteBudget/` | The small C SQLite VFS that keeps bulk synchronization writes within a byte budget |
| `App/` | The UIKit app |
| `Widget/`, `WidgetShared/`, `ShareExtension/` | Home Screen widget and Control Center control, share extension |
| `Tests/` | Host tests and their fixtures |
| `AppTests/`, `AppUITests/`, `UITestFixtures/`, `ProbeTests/` | View tests, UI journeys and their in-app fixtures, network probes |
| `TestSupport/` | Fixture servers, Android-format test libraries and media used by the tests |
| `Tools/` | Codec and Cast setup scripts, the fixture-server launcher, the host-test, server-build and acceptance runners |
| `Vendor/` | The codec and Cast SDK, created by the setup in [DEPENDENCIES](docs/DEPENDENCIES.md); not committed |

[ARCHITECTURE.md](docs/ARCHITECTURE.md) describes the main components and data contracts, and [TESTING.md](docs/TESTING.md) the probe tests, the hub and where the test data comes from. [AGENTS.md](AGENTS.md) holds the project guidelines for contributors and coding tools.

## Licence

NotTennaPod is free software under the [GNU General Public License v3.0](LICENSE). It adapts code and behaviour from AntennaPod (GPL-3.0); [NOTICE.md](NOTICE.md) lists the adapted sources and their versions, and third-party licences are in [Licenses/](Licenses/). FFmpeg is used under the LGPL 2.1 and dav1d under the BSD 2-clause licence. The Google Cast SDK is Google's proprietary SDK, used under its own terms and not included in this repository.
