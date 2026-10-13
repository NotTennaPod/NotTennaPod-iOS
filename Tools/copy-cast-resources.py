#!/usr/bin/env python3
"""Copy resources from the selected Cast SDK platform into the application."""
import os
from pathlib import Path
import shutil

sdk = Path(__file__).resolve().parents[1] / "Vendor/GoogleCastSDK"
platform = os.environ["PLATFORM_NAME"]
if platform not in {"iphoneos", "iphonesimulator"}:
    raise SystemExit(f"Unsupported Cast SDK platform: {platform}")
destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
destination.mkdir(parents=True, exist_ok=True)
for bundle in (sdk / "Resources" / platform).glob("*.bundle"):
    shutil.copytree(bundle, destination / bundle.name, dirs_exist_ok=True)
