#!/usr/bin/env python3
"""Install or verify the pinned, unmodified official Google Cast SDK archive."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import zipfile

VERSION = "4.8.6"
URL = f"https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-{VERSION}_static.zip"
SHA256 = "e1fe7fd6f2bf4b58e830d378fafc435d159bd755f7ee20fd3033aa1ce313cd6e"
DESTINATION = Path(__file__).resolve().parents[1] / "Vendor/GoogleCastSDK"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root):
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob("*"))
            if p.is_file() and p.name != "BuildProvenance.json"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", nargs="?", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        manifest = json.loads((DESTINATION / "BuildProvenance.json").read_text())
        if (manifest["archiveSHA256"] != SHA256 or manifest["sourceURL"] != URL
                or manifest["files"] != files(DESTINATION)):
            raise SystemExit("Cast SDK provenance mismatch; preserved installed files.")
        print(f"Google Cast {VERSION}: verified {len(manifest['files'])} files")
        return
    if args.archive is None or digest(args.archive) != SHA256:
        raise SystemExit("Supply the pinned official archive; checksum mismatch or archive missing.")
    if DESTINATION.exists():
        raise SystemExit("Destination exists. Use --verify; do not overwrite an existing SDK.")
    # Vendor/ may not exist yet when Cast is set up before the codec.
    DESTINATION.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cast-bootstrap-", dir=DESTINATION.parent) as staging:
        root = Path(staging)
        with zipfile.ZipFile(args.archive) as archive:
            for entry in archive.infolist():
                if not (root / entry.filename).resolve().is_relative_to(root.resolve()):
                    raise SystemExit("Unsafe archive path")
            archive.extractall(root)
        sdk = root / f"GoogleCastSDK-ios-{VERSION}_static_xcframework"
        # Each platform keeps its own supplied resources (the model differs).
        for platform, slice_name in [("iphoneos", "ios-arm64"),
                                      ("iphonesimulator", "ios-arm64_x86_64-simulator")]:
            framework = sdk / "GoogleCast.xcframework" / slice_name / "GoogleCast.framework"
            resources = sdk / "Resources" / platform
            resources.mkdir(parents=True)
            for bundle in framework.glob("*.bundle"):
                shutil.copytree(bundle, resources / bundle.name)
            privacy = resources / "GoogleCastPrivacy.bundle"
            privacy.mkdir()
            shutil.copy2(framework / "PrivacyInfo.xcprivacy", privacy / "PrivacyInfo.xcprivacy")
        manifest = {"version": VERSION, "sourceURL": URL, "archiveSHA256": SHA256,
                    "verification": "Official HTTPS download; checksum pinned on first retrieval, not an independent signature.",
                    "files": files(sdk)}
        (sdk / "BuildProvenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
        sdk.rename(DESTINATION)
    print(f"Installed Google Cast {VERSION}; {len(manifest['files'])} files")


if __name__ == "__main__":
    main()
