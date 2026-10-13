# NotTennaPod for iOS

NotTennaPod is a native Swift/UIKit iOS app that clones the user experience of Android **AntennaPod**. It is not affiliated with AntennaPod. [README](README.md) covers setup, building and testing; [ARCHITECTURE](docs/ARCHITECTURE.md) covers the code layout and data contracts; [TESTING](docs/TESTING.md) covers the hub, the probe tests and where the test data comes from.

It is one of four NotTennaPod repositories, checked out side by side: NotTennaPod-Server, the optional self-hosted sync server, whose `docs/PROTOCOL.md` and contract vectors define sync (the tests here pin its commit and copy its vectors); NotTennaPod-Web, the browser client the server serves; and NotTennaPod-Android, upstream AntennaPod plus test-only exporters that produce the Android reference results. Without a server the app behaves as AntennaPod does; server sync is opt-in.

The target is AntennaPod's latest tagged release. The app is currently built around AntennaPod 3.12.1; when a new release comes out, compare it with what the app was built around and update the app, its tests and its test data.

## The goal

**The app must work for a normal person and behave like Android AntennaPod:** the same features, screens, buttons, wording, settings, behaviour and data. Judge everything by what a person would notice.

What matters:
- Features and controls exist, are reachable and do the right thing.
- Audio plays, pauses, seeks and completes with nothing lost or skipped. Seeks land where asked. Speed is accurate (1.5× plays 1.5× within a few percent). Skip-silence and volume take effect.
- Downloads, the queue, played/new state and settings persist.
- Lists show the right items in Android's order, with the right counters.
- Data is never lost or changed. Android database backups, OPML and HTML export stay exactly interoperable with Android AntennaPod.
- Errors are shown sensibly; there are no crashes or hangs.
- Layout works on iPhone, iPad and Duo, through rotation and resizing and in right-to-left languages: nothing hidden, clipped, overlapping or misplaced.
- VoiceOver labels and actions work.

What doesn't matter: differences nobody can perceive (timing in microseconds, sub-point geometry, exact pixel colours), internal call or timer order, and matching Android's implementation when the visible result is the same.

**It must look like AntennaPod.** Keep Android's icons, wording, composition (order, grouping, placement) and capabilities; check by eye with side-by-side screenshots against Android. Adapting measurements to screen size is fine; relocation, missing features or an iOS redesign are not. When an Apple platform difference prevents literal Android behaviour, use the smallest adaptation that keeps the capability, meaning, wording and icons. Don't copy Android crashes or data-loss bugs.

## Building and testing

- Before building a feature, write a short checklist (screens, wording, rules) from the [Android AntennaPod source](https://github.com/AntennaPod/AntennaPod) (the latest release tag) and the Android app. Look at how Pocket Casts and other open-source podcast apps solve iOS-specific problems; they inform, they don't decide behaviour.
- For every check and failure, ask: if this were broken, would a person notice? If yes, it must work: fix the app, or make the check reliable. If no, relax or remove that one check.
- Test at the right level: logic and data with host tests; screens, menus and layout (including iPad, Duo and right-to-left) with view tests; flows across screens and relaunches with a small set of UI journeys on the iPhone. Effort in proportion to risk: deep for playback, downloads and data interchange; light for a settings row.
- **Done** means: it works and looks like Android on the iPhone, its tests and the tests of what it touches pass on the iPhone, its layout is checked on iPad and Duo, and the Release build compiles. Run the full suite on all three devices before a release.
- **Audio changes need real-time proof.** Any change to output, transports, refill, queue depth, producers or speed processing must pass `PCMRealTimeStarvationTests` and a listening check on a real iPhone (1.75× and 3×, seeking, screen in use and locked). Never trade audio safety margin for CPU savings.
- Tests are self-sufficient: fixture servers start from the scheme's pre-action, and inputs live in the repository. Wait for conditions, never sleep. On iOS 27.1, tap only after an element has settled (`tapWhenSettled`) and type with `typeTextSettled`.
- Never change device, Simulator, macOS or system settings to make a test pass. A test that changes a setting restores it.
- Don't rename saved-data identifiers (database `application_id`, settings keys, Keychain services, widget kinds, background task IDs, the `antennapod_local:`/`antennapod_generative_cover:` prefixes, the `antennapod-subscribe` scheme, the `AntennaPodPage` App Intents type). Users' libraries, widgets and Shortcuts depend on them.

## Environment

- Xcode 27.1 or later (needed for the Duo Simulator), selected with `xcode-select` or `DEVELOPER_DIR` for every Xcode command. Minimum iOS 27.0.
- UI journeys run on one Simulator at a time.
- Put builds, results and other disposable files in the ignored `.work/` folder.
- `swift test` rewrites `Package.resolved`; restore it afterwards.

## Before every push

Work happens on branches. Before pushing, make sure everything wanted is merged into `main`. Push only `main`: never another branch, `--all`, `--mirror` or tags.

Always run the privacy scan first, before every push without exception, however small. Scan everything that will be pushed (the tracked files, and the metadata of every commit being pushed) for personally identifiable information or anything else that shouldn't go to GitHub:

- personal names, usernames and email addresses; the commit author and committer must be the project identity;
- home directories and absolute local paths, machine and host names, IP addresses, device and Simulator identifiers, and Apple team IDs;
- keys, tokens, passwords, certificates and signing profiles; documented public keys, such as AntennaPod's Podcast Index pair, are the exception;
- time zones and locale: commit dates must be in UTC, and no local time-zone names, offsets or locale may appear in files, fixtures or logs;
- personal data: real podcast libraries, OPML, databases, listening history and screenshots;
- metadata hidden in binary files, such as EXIF or GPS in images and tags in audio;
- internal notes, mentions of AI tools or review process, logs, build outputs, caches and other artifacts.

Fix anything found before pushing.
