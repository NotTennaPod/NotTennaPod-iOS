"""The two-installation transplant, 2I (PROTOCOL §16): copies the app's data container from one Simulator to
another, as a device backup restored on a second phone would bring it.

What it copies: `Library/Application Support` and `Documents` (or one DEBUG test library's folder, `library`), each
SQLite database with its WAL and shared memory as one set: the destination's old set is removed before the new one
is put in place, so a database never meets another copy's WAL. What it leaves out: `staging/` and everything else
marked as excluded from backup, and the Keychain (a backup restore never brings the `ThisDeviceOnly` items server
mode uses). The source app must not be running (2I copies after a SIGKILL), and the destination app not either.
The same Simulator, or containers that are the same or nested folders, are refused before anything is changed.

    python3 TestSupport/Servers/hub/transplant.py --from <simulator name or UDID> --to <name or UDID> [--library <id>]
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

BUNDLE = "org.nottennapod.app"
DEVICES = Path.home() / "Library" / "Developer" / "CoreSimulator" / "Devices"
EXCLUDE_XATTR = b"com.apple.metadata:com_apple_backup_excludeItem"
SQLITE_SUFFIXES = (".sqlite", ".db")
COMPANIONS = ("-wal", "-shm", "-journal")

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
_libc.getxattr.restype = ctypes.c_ssize_t


def excluded_from_backup(path: Path) -> bool:
    return _libc.getxattr(os.fsencode(path), EXCLUDE_XATTR, None, 0, 0, 0x0001) >= 0  # XATTR_NOFOLLOW


def simulator(name_or_udid: str) -> str:
    """A Simulator's UDID, by name or UDID."""
    if (DEVICES / name_or_udid).is_dir():
        return name_or_udid
    listed = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True, check=True)
    found = [device["udid"] for devices in json.loads(listed.stdout)["devices"].values() for device in devices
             if device["name"] == name_or_udid]
    if len(found) != 1:
        raise LookupError(f"{len(found)} Simulators are named {name_or_udid!r}")
    return found[0]


def container(udid: str, bundle: str = BUNDLE) -> Path:
    """The app's data container on a Simulator, found from the container manager's metadata (no boot needed)."""
    for metadata in (DEVICES / udid / "data" / "Containers" / "Data" / "Application").glob(
            "*/.com.apple.mobile_container_manager.metadata.plist"):
        with open(metadata, "rb") as file:
            if plistlib.load(file).get("MCMMetadataIdentifier") == bundle:
                return metadata.parent
    raise LookupError(f"{bundle} is not installed on {udid}")


def _is_database(path: Path) -> bool:
    return path.suffix in SQLITE_SUFFIXES


def _companion_of(path: Path) -> Path | None:
    for suffix in COMPANIONS:
        if path.name.endswith(suffix):
            base = path.with_name(path.name[: -len(suffix)])
            if _is_database(base):
                return base
    return None


def plan(source: Path) -> tuple[list[Path], list[list[Path]], list[Path]]:
    """What a copy of `source` takes: plain files, database sets (database first), and what it leaves out."""
    files: list[Path] = []
    sets: dict[Path, list[Path]] = {}
    left_out: list[Path] = []
    for directory, subdirectories, names in os.walk(source):
        here = Path(directory)
        kept = []
        for name in sorted(subdirectories):
            path = here / name
            if name == "staging" or excluded_from_backup(path):
                left_out.append(path)
            else:
                kept.append(name)
        subdirectories[:] = kept
        for name in sorted(names):
            path = here / name
            if excluded_from_backup(path):
                left_out.append(path)
            elif _is_database(path):
                sets.setdefault(path, []).insert(0, path)
            elif (base := _companion_of(path)) is not None:
                sets.setdefault(base, []).append(path)
            else:
                files.append(path)
    for base, members in sets.items():
        if members[0] != base:  # a WAL without its database is left out
            left_out.extend(members)
    return files, [members for base, members in sets.items() if members[0] == base], left_out


def _separate(source: Path, target: Path) -> None:
    """A copy never runs onto its own source: equal or nested trees (also through links) are refused."""
    a, b = source.resolve(), target.resolve()
    if a == b or a in b.parents or b in a.parents:
        raise ValueError(f"refusing to copy {source} onto {target}: they are the same or nested folders")


def copy_tree(source: Path, target: Path) -> dict:
    """Replaces `target` with the backed-up part of `source`."""
    _separate(source, target)
    files, sets, left_out = plan(source)
    if target.exists():
        # The destination's old databases go as whole sets first, so no old WAL is ever left beside a new database.
        for path in sorted(target.rglob("*")):
            if path.is_file() and (_is_database(path) or _companion_of(path) is not None):
                path.unlink()
        shutil.rmtree(target)
    target.mkdir(parents=True)
    for path in files:
        destination = target / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    for members in sets:
        base = target / members[0].relative_to(source)
        base.parent.mkdir(parents=True, exist_ok=True)
        staged = [(member, base.parent / f".transplant-{uuid.uuid4().hex}-{member.name}") for member in members]
        for member, temporary in staged:
            shutil.copy2(member, temporary)
        for member, temporary in staged:  # the set appears together, the database last
            if member != members[0]:
                os.replace(temporary, base.parent / member.name)
        os.replace(staged[0][1], base)
    return {"files": len(files), "databases": len(sets), "left_out": [str(path.relative_to(source)) for path in left_out]}


def transplant(source_device: str, target_device: str, library: str | None = None, bundle: str = BUNDLE) -> dict:
    source_udid, target_udid = simulator(source_device), simulator(target_device)
    if source_udid == target_udid:
        raise ValueError(f"{source_device} and {target_device} are the same Simulator ({source_udid})")
    source, target = container(source_udid, bundle), container(target_udid, bundle)
    _separate(source, target)  # before anything is changed
    report: dict = {"from": source_udid, "to": target_udid, "copied": {}}
    support = Path("Library") / "Application Support"
    if library:
        folder = library if library.startswith("UITests-") else "UITests-" + library
        parts = [support / folder]
    else:
        parts = [support, Path("Documents")]
    for part in parts:
        if not (source / part).exists():
            raise LookupError(f"{part} does not exist in the source container")
        report["copied"][str(part)] = copy_tree(source / part, target / part)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--from", dest="source", required=True)
    parser.add_argument("--to", dest="target", required=True)
    parser.add_argument("--library")
    parser.add_argument("--bundle", default=BUNDLE)
    arguments = parser.parse_args()
    try:
        print(json.dumps(transplant(arguments.source, arguments.target, arguments.library, arguments.bundle), indent=2))
    except (LookupError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"transplant: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
