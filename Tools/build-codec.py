#!/usr/bin/env python3
"""Build the app's pinned FFmpeg and dav1d codec slice for one platform with Xcode's compiler.

Tools/package-codecs.py then packages the slices into Vendor/. Outputs must be fresh
directories in .work. The source archives must match the SHA-256 pins below.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

VERSION = "9.0.2"
SHA256 = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
ROOT = Path(__file__).resolve().parents[1]
DAV1D_VERSION = "1.5.4"
DAV1D_SHA256 = "686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["macos", "simulator", "ios"])
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--profile", type=Path, help="Explicit bounded decoder configuration; omitted preserves the original audio experiment")
    parser.add_argument("--dav1d-archive", type=Path, help="Verified dav1d source for an explicit libdav1d profile")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    profile = None
    if args.profile:
        profile = json.loads(args.profile.read_text())
        if set(profile) != {"name", "demuxers", "decoders", "parsers", "swscale", "rationale", "bitstreamFilters"}:
            parser.error("Unexpected profile fields")
        for key in ["demuxers", "decoders", "parsers", "bitstreamFilters"]:
            if not isinstance(profile[key], list) or not profile[key] or any(
                not isinstance(name, str) or not name.replace("_", "").isalnum() for name in profile[key]
            ):
                parser.error(f"Invalid {key}")
        if not isinstance(profile["swscale"], bool):
            parser.error("swscale must be a Boolean")
    needs_dav1d = profile is not None and "libdav1d" in profile["decoders"]
    if needs_dav1d != (args.dav1d_archive is not None):
        parser.error("A libdav1d profile requires exactly one --dav1d-archive")
    if args.dav1d_archive and hashlib.sha256(args.dav1d_archive.read_bytes()).hexdigest() != DAV1D_SHA256:
        parser.error("dav1d source archive does not match the verified pin")
    archive = args.archive.resolve()
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("Source archive does not match the verified pin")
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / ".work"):
        raise SystemExit("Experimental output must be inside the workspace .work directory")
    sdk, target = {
        "macos": ("macosx", "arm64-apple-macos27.0"),
        "simulator": ("iphonesimulator", "arm64-apple-ios27.0-simulator"),
        "ios": ("iphoneos", "arm64-apple-ios27.0"),
    }[args.platform]

    def capture(*command):
        return subprocess.check_output(command, text=True).strip()

    compiler = capture("xcrun", "--sdk", sdk, "--find", "clang")
    sysroot = capture("xcrun", "--sdk", sdk, "--show-sdk-path")
    output.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as source:
        source.extractall(output, filter="data")
    build = output / "build"
    build.mkdir()
    install = output / "install"
    flags = f"-target {target} -isysroot {sysroot}"
    dependency = None
    if needs_dav1d:
        with tarfile.open(args.dav1d_archive) as source:
            source.extractall(output, filter="data")
        cross = output / "dav1d-cross.ini"
        cross.write_text("[binaries]\nc = " + repr(compiler) + "\nar = 'ar'\nstrip = 'strip'\n"
            "[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n"
            "[properties]\nneeds_exe_wrapper = true\n[built-in options]\n"
            "c_args = " + repr(["-target", target, "-isysroot", sysroot]) + "\n"
            "c_link_args = " + repr(["-target", target, "-isysroot", sysroot]) + "\n")
        commands = [
            ["meson", "setup", str(output / "dav1d-build"), str(output / f"dav1d-{DAV1D_VERSION}"),
             "--cross-file", str(cross), "--prefix", str(install), "--libdir", "lib", "--buildtype", "release",
             "--default-library", "static", "-Db_staticpic=true", "-Denable_tools=false", "-Denable_tests=false",
             "-Denable_examples=false", "-Denable_docs=false", "-Dbitdepths=8"],
            ["ninja", "-C", str(output / "dav1d-build"), f"-j{args.jobs}"],
            ["meson", "install", "-C", str(output / "dav1d-build")]]
        dependency = {"name": "dav1d", "version": DAV1D_VERSION, "archiveSHA256": DAV1D_SHA256,
            "sourceURL": f"https://downloads.videolan.org/pub/videolan/dav1d/{DAV1D_VERSION}/dav1d-{DAV1D_VERSION}.tar.xz",
            "license": "BSD-2-Clause", "commands": commands, "bitdepths": [8],
            "mesonVersion": capture("meson", "--version"), "ninjaVersion": capture("ninja", "--version")}
    configure = [str(output / f"ffmpeg-{VERSION}" / "configure"),
                 f"--prefix={install}", "--arch=arm64", "--target-os=darwin",
                 "--enable-cross-compile", f"--cc={compiler}", f"--sysroot={sysroot}",
                 f"--extra-cflags={flags}", f"--extra-ldflags={flags}",
                 "--disable-autodetect", "--disable-everything", "--disable-programs",
                 "--disable-doc", "--disable-debug", "--disable-shared", "--enable-static",
                 "--enable-pic", "--disable-network", "--disable-avdevice",
                 "--disable-avfilter", "--disable-gpl", "--disable-nonfree", "--disable-version3",
                 "--enable-swscale" if profile and profile["swscale"] else "--disable-swscale", "--enable-swresample",
                 "--enable-avformat", "--enable-avcodec", "--enable-avutil",
                 "--enable-demuxer=" + ",".join(profile["demuxers"] if profile else ["ogg", "matroska"]),
                 "--enable-decoder=" + ",".join(profile["decoders"] if profile else ["vorbis", "opus"]),
                 "--enable-parser=" + ",".join(profile["parsers"] if profile else ["vorbis", "opus"]),
                 "--enable-protocol=file", "--enable-zlib"]
    if profile:
        configure += ["--enable-bsf=" + ",".join(profile["bitstreamFilters"])]
    if needs_dav1d:
        configure += ["--enable-libdav1d", "--pkg-config-flags=--static"]
    metadata = {"version": VERSION, "archiveSHA256": SHA256, "platform": args.platform,
                "target": target, "sdk": sysroot, "xcode": capture("xcodebuild", "-version"),
                "compiler": capture(compiler, "--version"), "configure": configure,
                "state": "pending", "jobs": args.jobs, "dependency": dependency,
                "profile": profile,
                "profileSHA256": hashlib.sha256(args.profile.read_bytes()).hexdigest() if args.profile else None,
                "buildScriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}

    def save():
        (output / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")

    save()
    try:
        environment = os.environ.copy()
        if needs_dav1d:
            with (output / "dav1d-build.log").open("w") as log:
                for command in dependency["commands"]:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            environment["PKG_CONFIG_LIBDIR"] = str(install / "lib/pkgconfig")
            environment["PKG_CONFIG_PATH"] = ""
        with (output / "build.log").open("w") as log:
            for command in [configure, ["make", f"-j{args.jobs}"], ["make", "install"]]:
                subprocess.run(command, cwd=build, stdout=log, stderr=subprocess.STDOUT, check=True, env=environment)
        metadata["state"] = "complete"
        metadata["libraries"] = {
            p.name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted((install / "lib").glob("*.a"))}
        metadata["headers"] = {
            str(p.relative_to(install / "include")): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((install / "include").rglob("*")) if p.is_file()}
        metadata["configurationFiles"] = {
            name: hashlib.sha256((build / name).read_bytes()).hexdigest()
            for name in ["config.h", "config_components.h", "ffbuild/config.mak"]}
    except BaseException:
        metadata["state"] = "failed"
        raise
    finally:
        save()
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
