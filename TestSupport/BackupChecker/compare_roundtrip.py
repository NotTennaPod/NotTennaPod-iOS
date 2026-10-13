#!/usr/bin/env python3
"""Database backup round-trip oracle: Android DB -> iOS import -> iOS re-export must present the same
Android 3.12.1 state, modulo the documented ignore set.

usage: compare_roundtrip.py <android.db> <ios-reexport.db> [--ignore TOKEN ...]
                            [--no-default-ignore] [--json diff.json]

Both files are normalized with normalize.normalize() (Android 3.12.1 read semantics) and compared
per table/row/field. Exit 0 only when the presented states are equal; 1 on differences; 2 when a
file cannot be read as a 3110000-shaped database.

Default ignore set (each is a deliberate iOS change, not a tolerance):
  FeedMedia.downloaded, FeedMedia.file_url, FeedMedia.has_embedded_picture
      An Android backup's downloaded rows import as not downloaded (Android paths never exist on
      iOS; Android's own repaired state, PlayActionButton.java:45-52), and the iOS export writes
      downloaded=0, file_url=NULL, has_embedded_picture=0.
  FeedMedia.id
      The iOS export uses the episode id as FeedMedia.id; the import has no iOS
      counterpart for media ids. Type-2 DownloadLog rows are still compared by the item they
      resolve to (FeedMedia.id -> feeditem).
  SimpleChapters.id, DownloadLog.id
      Absent in iOS, re-assigned ascending in chapter / log order.
  Feeds.file_url
      Feed cache path, never read for behaviour; the iOS export writes NULL.
  anomalies
      Rows Android never presents (orphans, duplicate queue rows, extra media rows, invalid
      codes): iOS drops or defaults them, so they are reported for both files but not
      compared. Use --no-default-ignore to compare them too.

Compared by default although iOS stores them differently:
  Feeds.downloaded (lastRefreshAttempt ms) - the import maps 0 -> nil -> 0 and ms -> Date -> ms, so it
  round-trips; pass `--ignore Feeds.downloaded` if a deliberate change drops it.
  Feeds.credentials - the iOS export writes the Keychain credentials back in plaintext.
  DownloadLog - the import keeps the log verbatim and the iOS export writes it back; pass
  `--ignore DownloadLog` only if a deliberate change drops it.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize as N  # noqa: E402

DEFAULT_IGNORE = ["D1", "FeedMedia.id", "SimpleChapters.id", "DownloadLog.id", "Feeds.file_url",
                  "anomalies"]


def diff(a, b, path=""):
    """Yield (path, left, right) for every differing leaf."""
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            p = f"{path}/{k}"
            if k not in a:
                yield p, "<absent>", b[k]
            elif k not in b:
                yield p, a[k], "<absent>"
            else:
                yield from diff(a[k], b[k], p)
    elif isinstance(a, list) and isinstance(b, list) and not (
            path.endswith("/tags") or path.endswith("/hide") or path.endswith("/funding")):
        for i in range(max(len(a), len(b))):
            p = f"{path}[{i}]"
            if i >= len(a):
                yield p, "<absent>", b[i]
            elif i >= len(b):
                yield p, a[i], "<absent>"
            else:
                yield from diff(a[i], b[i], p)
    elif a != b or type(a) is not type(b) and not (isinstance(a, (int, float)) and isinstance(b, (int, float))):
        yield path, a, b


def compare(android_db, ios_db, ignore):
    left = N.normalize(android_db, ignore)
    right = N.normalize(ios_db, ignore)
    diffs = list(diff(left["state"], right["state"]))
    if "anomalies" not in N.expand_ignore(ignore):
        diffs += list(diff(left.get("anomalies"), right.get("anomalies"), "/anomalies"))
    return left, right, diffs


def main(argv=None):
    ap = argparse.ArgumentParser(description="Android database backup round-trip check")
    ap.add_argument("android_db")
    ap.add_argument("ios_db")
    ap.add_argument("--ignore", nargs="*", default=[], metavar="TOKEN",
                    help=f"extra ignore tokens; known: {sorted(N.IGNORE_TOKENS | set(N.IGNORE_GROUPS))}")
    ap.add_argument("--no-default-ignore", action="store_true")
    ap.add_argument("--json", help="write the full diff and both counts here")
    a = ap.parse_args(argv)
    ignore = ([] if a.no_default_ignore else DEFAULT_IGNORE) + a.ignore
    try:
        left, right, diffs = compare(a.android_db, a.ios_db, ignore)
    except (N.SchemaError, Exception) as err:  # unreadable input is not "equal"
        print(f"ERROR: {type(err).__name__}: {err}", file=sys.stderr)
        return 2
    print(f"ignore: {sorted(N.expand_ignore(ignore))}")
    print(f"android: user_version {left['meta']['user_version']} {left['meta']['counts']}")
    print(f"ios:     user_version {right['meta']['user_version']} {right['meta']['counts']}")
    for side, d in (("android", left), ("ios", right)):
        an = {k: len(v) for k, v in (d.get("anomalies") or {}).items() if v}
        if an:
            print(f"{side} anomalies (not presented by Android): {an}")
    for p, l, r in diffs:
        print(f"DIFF {p}: android={json.dumps(l, ensure_ascii=False)} "
              f"ios={json.dumps(r, ensure_ascii=False)}")
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump({"ignore": sorted(N.expand_ignore(ignore)), "android": left["meta"],
                       "ios": right["meta"], "diffs": [list(x) for x in diffs]}, fh, indent=1,
                      ensure_ascii=False)
    print("EQUAL" if not diffs else f"{len(diffs)} difference(s)")
    return 0 if not diffs else 1


if __name__ == "__main__":
    sys.exit(main())
