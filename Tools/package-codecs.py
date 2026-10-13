#!/usr/bin/env python3
"""Package verified local FFmpeg builds for SwiftPM; never replace an existing vendor artifact."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_HASH = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("macos", type=Path)
    parser.add_argument("simulator", type=Path)
    parser.add_argument("ios", type=Path)
    parser.add_argument("--destination", type=Path, help="Fresh staged XCFramework path inside .work; default is the absent Vendor artifact")
    args = parser.parse_args()
    destination = (args.destination or ROOT / "Vendor/CFFmpegCodec.xcframework").resolve()
    if args.destination and (not destination.is_relative_to(ROOT / ".work") or destination.suffix != ".xcframework"):
        raise SystemExit("Explicit destination must be an XCFramework path inside workspace .work")
    if destination.exists():
        raise SystemExit("Destination already exists; verify it instead of overwriting")
    metadata = {}
    for platform in ["macos", "simulator", "ios"]:
        source = getattr(args, platform).resolve()
        record = json.loads((source / "build.json").read_text())
        if (record["state"], record["version"], record["archiveSHA256"], record["platform"]) != (
                "complete", "9.0.2", ARCHIVE_HASH, platform):
            raise SystemExit(f"Unverified or wrong build: {source}")
        expected = {"libavformat.a", "libavcodec.a", "libswresample.a", "libavutil.a"}
        if (record.get("profile") or {}).get("swscale", False):
            expected.add("libswscale.a")
        if (record.get("dependency") or {}).get("name") == "dav1d":
            expected.add("libdav1d.a")
        if set(record["libraries"]) != expected:
            raise SystemExit("Unexpected codec library set")
        for name, info in record["libraries"].items():
            if hashlib.sha256((source / "install/lib" / name).read_bytes()).hexdigest() != info["sha256"]:
                raise SystemExit(f"Changed library: {source / name}")
        for name, digest in record.get("headers", {}).items():
            if hashlib.sha256((source / "install/include" / name).read_bytes()).hexdigest() != digest:
                raise SystemExit(f"Changed header: {source / name}")
        for name, digest in record.get("configurationFiles", {}).items():
            if hashlib.sha256((source / "build" / name).read_bytes()).hexdigest() != digest:
                raise SystemExit(f"Changed build configuration: {source / name}")
        metadata[platform] = record
    if len({record.get("profileSHA256") for record in metadata.values()}) != 1:
        raise SystemExit("Slices have different decoder profiles")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="codec-package-", dir=destination.parent if args.destination else ROOT / ".work"))
    command = ["xcodebuild", "-create-xcframework"]
    for platform, record in metadata.items():
        source = getattr(args, platform).resolve()
        target = staging / platform
        target.mkdir()
        headers = target / "Headers"
        shutil.copytree(source / "install/include", headers)
        (headers / "FFmpegCodec.h").write_text(
            "#include <libavformat/avformat.h>\n#include <libavcodec/avcodec.h>\n"
            "#include <libavutil/error.h>\n#include <libavutil/display.h>\n#include <libswresample/swresample.h>\n"
            + ("#include <libswscale/swscale.h>\n" if "libswscale.a" in record["libraries"] else "") +
            "static inline int apCodecAgain(void) { return AVERROR(EAGAIN); }\n"
            "static inline int apCodecEOF(void) { return AVERROR_EOF; }\n")
        (headers / "module.modulemap").write_text(
            'module CFFmpegCodec {\n    header "FFmpegCodec.h"\n    link "z"\n    export *\n}\n')
        library = target / "libCFFmpegCodec.a"
        subprocess.run(["xcrun", "libtool", "-static", "-o", str(library)] +
                       [str(source / "install/lib" / name) for name in sorted(record["libraries"])], check=True)
        command += ["-library", str(library), "-headers", str(headers)]
    product = staging / "CFFmpegCodec.xcframework"
    subprocess.run(command + ["-output", str(product)], check=True)
    notices = product / "Notices"
    notices.mkdir()
    first_source = args.macos.resolve()
    for name in ["COPYING.LGPLv2.1", "LICENSE.md"]:
        shutil.copy2(first_source / "ffmpeg-9.0.2" / name, notices / ("FFmpeg-" + name))
    if (metadata["macos"].get("dependency") or {}).get("name") == "dav1d":
        shutil.copy2(first_source / "dav1d-1.5.4/COPYING", notices / "dav1d-COPYING")
    provenance = {"sourceURL": "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz",
                  "archiveSHA256": ARCHIVE_HASH, "builds": metadata,
                  "packagingScriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  "files": {str(p.relative_to(product)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in sorted(product.rglob("*")) if p.is_file()}}
    (product / "BuildProvenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    destination.parent.mkdir(exist_ok=True)
    product.rename(destination)
    print(f"Packaged {destination}; source/build provenance and per-file hashes included")


if __name__ == "__main__":
    main()
