# Dependencies

The app needs two generated dependencies that are not committed: the codec XCFramework
(FFmpeg and dav1d) and the Google Cast SDK. Set both up on a fresh checkout before any
SwiftPM or Xcode command. SwiftSoup is pinned by `Package.resolved`. Licences are in
`Licenses/` and attributions in [NOTICE.md](../NOTICE.md).

## Codec (FFmpeg and dav1d)

`CFFmpegCodec.xcframework` is generated and ignored. Build it before SwiftPM or
Xcode commands on a fresh checkout. The package deliberately fails if the
dependency is missing; it does not silently omit codec support.

Source: FFmpeg 9.0.2, official tarball
`https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz`, SHA-256
`8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
Preserve the pin; upgrades require validation.

The playback profile also builds **dav1d 1.5.4**, official archive
`https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz`, SHA-256
`686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5`.
The build script enforces the hash. Its official checksum was verified; the retained detached signature was not
cryptographically verified. This dependency supplies software AV1 Main8 decoding.

From the repository root, with Python 3.12+, Meson, Ninja, pkg-config and Xcode 27.1 or later selected
with `xcode-select` or `DEVELOPER_DIR` (these scripts install nothing globally):

```sh
mkdir -p .work/ffmpeg-source-download
curl --fail --location --output .work/ffmpeg-source-download/ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
curl --fail --location --output .work/ffmpeg-source-download/dav1d-1.5.4.tar.xz https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz
python3 Tools/build-codec.py macos .work/ffmpeg-source-download/ffmpeg-9.0.2.tar.xz .work/ffmpeg-codec-macos --profile Tools/playback-codec-profile.json --dav1d-archive .work/ffmpeg-source-download/dav1d-1.5.4.tar.xz --jobs 2
python3 Tools/build-codec.py simulator .work/ffmpeg-source-download/ffmpeg-9.0.2.tar.xz .work/ffmpeg-codec-simulator --profile Tools/playback-codec-profile.json --dav1d-archive .work/ffmpeg-source-download/dav1d-1.5.4.tar.xz --jobs 2
python3 Tools/build-codec.py ios .work/ffmpeg-source-download/ffmpeg-9.0.2.tar.xz .work/ffmpeg-codec-ios --profile Tools/playback-codec-profile.json --dav1d-archive .work/ffmpeg-source-download/dav1d-1.5.4.tar.xz --jobs 2
python3 Tools/package-codecs.py .work/ffmpeg-codec-macos .work/ffmpeg-codec-simulator .work/ffmpeg-codec-ios
```

Build directories and the XCFramework must not already exist. Reuse verified
completed builds rather than rebuilding them. The packaging tool verifies the
build metadata and static-library hashes, assembles slices using Xcode, and
stores exact configuration, source URL/hash and every packaged file's hash in
`BuildProvenance.json`. Inspect and verify that manifest before reusing an artifact.
Failed builds stay available for diagnosis; choose fresh paths for a corrected
build and pass those to the packaging command.

The current slices are arm64 macOS 27 (host tests), arm64 iOS 27 Simulator and
arm64 iOS 27 device. The explicit profile supplies the demonstrated audio and video/container families,
including AMR, FLAC, selected WAV encodings, AAC/MP3/Vorbis/Opus and
H264/MPEG4/VP8/VP9/HEVC/AV1 Main8, with PCM conversion and owned video pixels.
`Tools/playback-codec-profile.json` lists the exact enabled components; a decoder
name does not establish every profile or route.
HTTP transport stays outside the codec libraries. Network, avfilter, encoders,
GPL, nonfree and version3 configurations remain disabled. Six static libraries
are merged: avformat, avcodec, avutil, swresample, swscale and dav1d. No external
codec binary is downloaded. Omitting the profile retains the historical narrow
Vorbis/Opus build for reproduction, but does not reproduce the current app artifact.

The dependency's generated headers retain upstream notices. The unchanged LGPL
text is in `Licenses/FFmpeg-LGPL-2.1.txt`; source license details are in
`Licenses/FFmpeg-LICENSE.md`. Before distribution retain/release the exact
corresponding source, build configuration and applicable notices, including any
modifications. dav1d's unchanged BSD-2-Clause notice is in
`Licenses/dav1d-COPYING`; all three applicable notices are also packaged under
`CFFmpegCodec.xcframework/Notices` and hashed. No source changes are made by these
build scripts.

`FFmpegAudioReader` is an internal actor that exposes bounded chunks and raw
timestamps. The app's `ApplicationPlaybackEngine` selects the processed
`PCMPlaybackEngine` whenever its decoder factories (FFmpeg or native) support a
source, and AVPlayer otherwise.
HTTP byte input uses custom AVIO outside these libraries.

## Google Cast SDK

The app links Google's static Cast 4.8.6 XCFramework. The binary and its resources
are generated/ignored at `Vendor/GoogleCastSDK`. Google distributes device
arm64 and Simulator arm64/x86_64 slices. The deployment minimum remains iOS 27.0.

From the repository root, before or after the codec:

```sh
mkdir -p .work/cast-sdk-download
curl --fail --location --output .work/cast-sdk-download/GoogleCastSDK-ios-4.8.6_static.zip https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.6_static.zip
python3 Tools/bootstrap-cast.py .work/cast-sdk-download/GoogleCastSDK-ios-4.8.6_static.zip
python3 Tools/bootstrap-cast.py --verify
xcodegen generate --spec project.yml
```

The bootstrap pins archive SHA256
`e1fe7fd6f2bf4b58e830d378fafc435d159bd755f7ee20fd3033aa1ce313cd6e`.
This checksum was recorded from the official HTTPS download, not an independent
publisher signature. It preserves the unmodified SDK and license files, records
all 1811 packaged files, and refuses to overwrite an existing install. Use
`--verify` before reuse. Codec bootstrap is still independently required.

The [published 4.8.6 manifest](https://cdn.cocoapods.org/Specs/8/1/2/google-cast-sdk/4.8.6/google-cast-sdk.podspec.json)
declares GTMSessionFetcher and Apple frameworks beyond the short manual guide.
`project.yml` pins Google's Swift package to 5.3.1, revision
`724a52eea6329b7e12d3ad8300d76ca9f3895fcc`, with its bundled privacy resources.
CoreData, AVKit and AVRouting are linked explicitly; other required frameworks
are supplied by existing app imports or the Cast module map. Keep `-ObjC -lc++`.
Do not use `-Ofast`.

`copy-cast-resources.py` copies the SDK's matching platform bundles after compile.
The device and Simulator core-data model metadata differ, so preserve each
platform's resources. The SDK privacy manifest is in `GoogleCastPrivacy.bundle`.
Upstream notices and nutrition metadata remain in the ignored SDK directory;
distribution must retain the applicable notices and Google SDK terms. This
bootstrap does not initialize discovery, accept user terms, connect a receiver or
establish device playback.
