#!/usr/bin/env python3
"""Canonical JSON of the library state Android AntennaPod 3.12.1 presents for an Antennapod.db.

Independent of the Swift tree: expectations come from the pinned Android source and Android cursor
semantics, not from the iOS mapper.

Input: a 3110000-shaped file (user_version >= 3080000; 3080000 -> 3110000 has no schema step,
DBU:352-357). Older files must first be upgraded (Android's own import). Columns are read BY NAME
(getColumnIndexOrThrow); extra/obsolete columns are ignored; a missing column is an error, as it is
for Android (mapper/*Cursor.java).

Android read semantics applied [src unless noted]:
* Cursor getters [aosp CursorWindow]: getInt/getLong/getFloat of NULL -> 0; getInt truncates the
  64-bit value to Java int; getString of an INTEGER is its decimal text, of a REAL "%g"; TEXT read
  as a number uses strtoll/strtod prefix parsing.
* Feeds (FeedCursor.java:42-93, FeedPreferencesCursor.java:39-84):
  - payment_link -> FeedFunding.extractPaymentLinks (FeedFunding.java:49-78); null and [] are both
    "no funding" in the UI (FeedInfoFragment.java:215) and are output as [].
  - hide -> FeedItemFilter tokens (Feed.java:138-142, FeedItemFilter.java:50-58): NULL/'' -> [];
    else Java split(",") (trailing empties dropped), order kept.
  - sort_order -> SortOrder.fromCodeString (SortOrder.java:60-71) + Feed.setSortOrder (Feed.java:
    461-467): NULL/'' -> null; 1-11 -> code; anything else Android throws -> {"invalid": raw}.
  - tags: NULL/'' -> {"#root"}; else set(Java split(U+001E)); output sorted.
  - enums with Android's fallbacks: auto_download unknown->GLOBAL, auto_delete unknown->NEVER,
    skip_silence unknown->GLOBAL, new_episodes_action unknown->ADD_TO_INBOX; volume adaption
    outside 0-5 throws -> {"invalid": n}.
  - include/exclude NULL -> ""; feed_playback_speed as Java float.
* Items (FeedItemCursor.java:38-88, PDA:349-350 LEFT JOIN FeedMedia ON feeditem):
  - items whose `feed` row does not exist are dropped and listed under anomalies;
  - read: -1 NEW, 1 PLAYED, anything else UNPLAYED (FeedItem.java:51-53);
  - transcript kept only when the URL is non-null (FeedItem.java:104-107);
  - auto_download = getLong > 0; has_simple_chapters = getInt > 0;
  - chapters (SimpleChapters, rowid order, PDA:1035-1040) only when has_simple_chapters > 0
    (ChapterUtils.java:59-60), else null;
  - media = the FeedMedia row with the lowest id whose feeditem = item id;
    playback_completion_date > 0 else null (FeedMediaCursor.java:49-50);
    has_embedded_picture 1 -> true, 0/NULL -> false, other -> null (:52-63);
    downloaded (download date ms, or legacy boolean 1) and derived downloaded_flag = downloaded > 0.
* Queue: ORDER BY Queue.id INNER JOIN FeedItems (PDA:1059-1066); items dropped above are removed;
  a duplicated item keeps its first occurrence.
* Favorites: membership only (PDA:290-291), for kept items; orphans are anomalies.
* DownloadLog: all rows, ORDER BY completion_date DESC (PDA:1049-1052; the UI shows the first 200),
  reason via DownloadError.fromCode (unknown throws -> {"invalid": n}); type-2 rows are resolved to
  the owning item through FeedMedia.id -> FeedMedia.feeditem.

`--ignore` removes fields that iOS legitimately changes:
  D1                    = FeedMedia.downloaded + FeedMedia.file_url + FeedMedia.has_embedded_picture
  ids                   = FeedMedia.id + SimpleChapters.id + DownloadLog.id
  FeedMedia.downloaded  media download date and downloaded_flag
  FeedMedia.file_url    Android media path
  FeedMedia.has_embedded_picture
  FeedMedia.id          media row id (iOS re-export uses the item id; also hides raw
                        DownloadLog.feedfile of type-2 rows, the resolved item id stays)
  SimpleChapters.id     chapter row ids (re-assigned in chapter order)
  DownloadLog.id        log row ids (re-assigned ascending)
  Feeds.file_url        feed cache path, never read for behaviour
  Feeds.downloaded      lastRefreshAttempt ms (pre-3.4: boolean)
  Feeds.credentials     username/password
  DownloadLog           the whole log
  anomalies             the anomalies section (not presented state)

usage: normalize.py <db> [--ignore TOKEN ...] [--out file.json]
"""
import argparse
import json
import math
import re
import sqlite3
import struct
import sys

PRESENTED_VERSION_MIN = 3080000

IGNORE_GROUPS = {
    "D1": {"FeedMedia.downloaded", "FeedMedia.file_url", "FeedMedia.has_embedded_picture"},
    "ids": {"FeedMedia.id", "SimpleChapters.id", "DownloadLog.id"},
}
IGNORE_TOKENS = {
    "FeedMedia.downloaded", "FeedMedia.file_url", "FeedMedia.has_embedded_picture", "FeedMedia.id",
    "SimpleChapters.id", "DownloadLog.id", "Feeds.file_url", "Feeds.downloaded",
    "Feeds.credentials", "DownloadLog", "anomalies",
}


def expand_ignore(tokens):
    out = set()
    for t in tokens or ():
        if t in IGNORE_GROUPS:
            out |= IGNORE_GROUPS[t]
        elif t in IGNORE_TOKENS:
            out.add(t)
        else:
            raise ValueError(f"unknown ignore token {t!r}; known: "
                             f"{sorted(IGNORE_TOKENS | set(IGNORE_GROUPS))}")
    return out


# --- Android CursorWindow getter semantics [aosp] -------------------------------------------------

INT64_MAX, INT64_MIN = (1 << 63) - 1, -(1 << 63)


class BlobValue(Exception):
    pass


def _strtoll(s):
    """C strtoll(s, NULL, 0): optional whitespace, sign, 0x/0 prefix; longest valid prefix."""
    m = re.match(r"\s*([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)", s)
    if not m:
        return 0
    sign, digits = m.groups()
    if digits[:2].lower() == "0x":
        v = int(digits, 16)
    elif digits.startswith("0") and len(digits) > 1:
        v = int(digits, 8)
    else:
        v = int(digits, 10)
    v = -v if sign == "-" else v
    return max(INT64_MIN, min(INT64_MAX, v))


def _strtod(s):
    m = re.match(r"\s*([+-]?(?:\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?|inf(?:inity)?|nan))",
                 s, re.I)
    return float(m.group(1)) if m else 0.0


def get_long(v):
    if v is None:
        return 0
    if isinstance(v, bytes):
        raise BlobValue("getLong on BLOB")
    if isinstance(v, float):
        if math.isnan(v):
            return 0
        return max(INT64_MIN, min(INT64_MAX, int(v)))
    if isinstance(v, str):
        return _strtoll(v) if v else 0
    return int(v)


def get_int(v):
    x = get_long(v) & 0xFFFFFFFF
    return x - (1 << 32) if x >= (1 << 31) else x


def get_double(v):
    if v is None:
        return 0.0
    if isinstance(v, bytes):
        raise BlobValue("getDouble on BLOB")
    if isinstance(v, str):
        return _strtod(v) if v else 0.0
    return float(v)


def get_float(v):
    d = get_double(v)
    try:
        return struct.unpack("<f", struct.pack("<f", d))[0]
    except OverflowError:
        return math.copysign(math.inf, d)


def get_string(v):
    if v is None or isinstance(v, str):
        return v
    if isinstance(v, bytes):
        raise BlobValue("getString on BLOB")
    if isinstance(v, float):
        return "%g" % v
    return str(v)


def java_split(s, sep):
    """Java String.split for a literal single-char separator: no match -> [s] (even for "");
    otherwise trailing empty strings are removed (so "," -> [])."""
    if sep not in s:
        return [s]
    parts = s.split(sep)
    while parts and parts[-1] == "":
        parts.pop()
    return parts


def _java_is_whitespace(c):
    """Character.isWhitespace: Unicode space/line/paragraph separators except the no-break
    spaces U+00A0/U+2007/U+202F, plus U+0009-U+000D and U+001C-U+001F."""
    import unicodedata
    if c in "\t\n\x0b\x0c\r\x1c\x1d\x1e\x1f":
        return True
    return unicodedata.category(c) in ("Zs", "Zl", "Zp") and c not in "\u00a0\u2007\u202f"


def java_is_blank(s):
    """StringUtils.isBlank (commons-lang3)."""
    return s is None or all(_java_is_whitespace(c) for c in s)


# --- Android value mappers --------------------------------------------------------------------

def funding(payment_link):
    """FeedFunding.extractPaymentLinks (FeedFunding.java:49-78). None -> []."""
    if java_is_blank(payment_link):
        return []
    if "\x1e" not in payment_link and "\x1f" not in payment_link:
        return [[payment_link, ""]]
    out = []
    for entry in java_split(payment_link, "\x1e"):
        link_content = java_split(entry, "\x1f")
        if not link_content:  # e.g. entry "\x1f": split -> [] and linkContent[0] throws in Java
            raise ValueError("ArrayIndexOutOfBoundsException in extractPaymentLinks")
        if java_is_blank(link_content[0]):
            continue
        title = link_content[1] if len(link_content) > 1 and not java_is_blank(link_content[1]) else ""
        out.append([link_content[0], title])
    return out


def hide_tokens(hide):
    if hide is None or hide == "":
        return []
    return java_split(hide, ",")


def sort_order(code_str):
    if code_str is None or code_str == "":
        return None
    try:
        if not re.fullmatch(r"[+-]?\d+", code_str):
            raise ValueError
        code = int(code_str)
        if not -(1 << 31) <= code < (1 << 31):
            raise ValueError
    except ValueError:
        return {"invalid": code_str}
    if 1 <= code <= 11:  # INTRA_FEED codes (SortOrder.java:15-25)
        return code
    return {"invalid": code_str}  # unknown or INTER_FEED -> Android throws


def tags(tag_string):
    if tag_string is None or tag_string == "":
        tag_string = "#root"
    return sorted(set(java_split(tag_string, "\x1e")))


AUTO_DOWNLOAD = {0: "DISABLED", 1: "GLOBAL", 2: "ENABLED"}          # FeedPreferences.java:82-100
AUTO_DELETE = {0: "GLOBAL", 1: "ALWAYS", 2: "NEVER"}                 # :20-39
NEW_EPISODES = {0: "GLOBAL", 1: "ADD_TO_INBOX", 2: "NOTHING", 3: "ADD_TO_QUEUE"}  # :41-61
SKIP_SILENCE = {0: "OFF", 1: "GLOBAL", 2: "AGGRESSIVE"}             # :63-80
VOLUME = {0: "OFF", 1: "LIGHT_REDUCTION", 2: "HEAVY_REDUCTION", 3: "LIGHT_BOOST",
          4: "MEDIUM_BOOST", 5: "HEAVY_BOOST"}                      # VolumeAdaptionSetting.java:8-31
STATES = {0: "SUBSCRIBED", 1: "NOT_SUBSCRIBED", 2: "ARCHIVED"}      # Feed.java:21-23
DOWNLOAD_ERROR = set(range(0, 23))                                  # DownloadError.java:4-43
TRANSCRIPT_TYPES = {"application/json": "JSON", "text/vtt": "VTT", "application/srt": "SRT",
                    "application/srr": "SRT", "application/x-subrip": "SRT"}  # TranscriptType:17-27


def play_state(read):
    return {-1: "NEW", 1: "PLAYED"}.get(read, "UNPLAYED")


# --- reading ------------------------------------------------------------------------------------

REQUIRED = {
    "Feeds": ["id", "title", "custom_title", "file_url", "download_url", "downloaded", "link",
              "description", "payment_link", "last_update", "language", "author", "image_url",
              "type", "feed_identifier", "auto_download", "username", "password",
              "include_filter", "exclude_filter", "minimal_duration_filter", "keep_updated",
              "is_paged", "next_page_link", "hide", "sort_order", "last_update_failed",
              "auto_delete_action", "feed_playback_speed", "feed_skip_silence",
              "feed_volume_adaption", "tags", "feed_skip_intro", "feed_skip_ending",
              "episode_notification", "state", "new_episodes_action"],
    "FeedItems": ["id", "title", "pubDate", "read", "link", "description", "payment_link", "feed",
                  "has_simple_chapters", "item_identifier", "image_url", "auto_download",
                  "podcastindex_chapter_url", "podcastindex_transcript_type",
                  "podcastindex_transcript_url", "social_interact_url"],
    "FeedMedia": ["id", "duration", "file_url", "download_url", "downloaded", "position",
                  "filesize", "mime_type", "playback_completion_date", "feeditem",
                  "played_duration", "has_embedded_picture", "last_played_time"],
    "DownloadLog": ["id", "feedfile", "feedfile_type", "reason", "successful", "completion_date",
                    "reason_detailed", "title"],
    "Queue": ["id", "feeditem", "feed"],
    "SimpleChapters": ["id", "title", "start", "feeditem", "link", "image_url"],
    "Favorites": ["id", "feeditem", "feed"],
}


class SchemaError(Exception):
    pass


def open_readonly(path):
    return sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)


def _rows(db, table):
    cols = [r[1] for r in db.execute(f'PRAGMA table_info("{table}")')]
    if not cols:
        raise SchemaError(f"missing table {table}")
    missing = [c for c in REQUIRED[table] if c not in cols]
    if missing:
        raise SchemaError(f"table {table} is missing columns {missing}")
    sel = ", ".join(f'"{c}"' for c in REQUIRED[table])
    return [dict(zip(REQUIRED[table], r)) for r in db.execute(f'SELECT {sel} FROM "{table}" ORDER BY rowid')]


def normalize(path, ignore=frozenset(), allow_old=False):
    ignore = expand_ignore(ignore)
    db = open_readonly(path)
    try:
        return _normalize(db, ignore, allow_old)
    finally:
        db.close()


def _normalize(db, ignore, allow_old):
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version < PRESENTED_VERSION_MIN and not allow_old:
        raise SchemaError(f"user_version {version} < {PRESENTED_VERSION_MIN}: upgrade it first")
    anomalies = {k: [] for k in ("items_missing_feed", "extra_media_rows", "orphan_media",
                                 "queue_dropped", "queue_duplicates", "orphan_favorites",
                                 "orphan_chapters", "invalid_values", "blob_values")}

    def safe(fn, v, where):
        try:
            return fn(v)
        except BlobValue:
            anomalies["blob_values"].append(where)
            return None

    feeds = {}
    for r in _rows(db, "Feeds"):
        fid = get_long(r["id"])
        w = f"Feeds[{fid}]"
        S = lambda c: safe(get_string, r[c], f"{w}.{c}")
        I = lambda c: safe(get_int, r[c], f"{w}.{c}")
        sort = sort_order(S("sort_order"))
        if isinstance(sort, dict):
            anomalies["invalid_values"].append(f"{w}.sort_order={r['sort_order']!r} (Android throws)")
        vol = I("feed_volume_adaption")
        if vol not in VOLUME:
            anomalies["invalid_values"].append(f"{w}.feed_volume_adaption={vol} (Android throws)")
        state = I("state")
        if state not in STATES:
            anomalies["invalid_values"].append(f"{w}.state={state} (none of the three states)")
        speed = safe(get_float, r["feed_playback_speed"], f"{w}.feed_playback_speed")
        if speed is not None and not (speed == -1.0 or (speed > 0 and math.isfinite(speed))):
            anomalies["invalid_values"].append(f"{w}.feed_playback_speed={r['feed_playback_speed']!r}")
        def feed_funding(raw):
            try:
                return funding(raw)
            except ValueError as err:
                anomalies["invalid_values"].append(f"{w}.payment_link={raw!r} ({err})")
                return {"invalid": raw}

        f = {
            "title": S("title"),
            "custom_title": S("custom_title"),
            "file_url": S("file_url"),
            "download_url": S("download_url"),
            "last_refresh_attempt": safe(get_long, r["downloaded"], f"{w}.downloaded"),
            "link": S("link"),
            "description": S("description"),
            "funding": feed_funding(S("payment_link")),
            "last_update": S("last_update"),
            "language": S("language"),
            "author": S("author"),
            "image_url": S("image_url"),
            "type": S("type"),
            "feed_identifier": S("feed_identifier"),
            "is_paged": I("is_paged") > 0,
            "next_page_link": S("next_page_link"),
            "hide": hide_tokens(S("hide")),
            "sort_order": sort,
            "last_update_failed": I("last_update_failed") > 0,
            "state": STATES.get(state, {"invalid": state}),
            "preferences": {
                "auto_download": AUTO_DOWNLOAD.get(I("auto_download"), "GLOBAL"),
                "keep_updated": I("keep_updated") > 0,
                "auto_delete_action": AUTO_DELETE.get(I("auto_delete_action"), "NEVER"),
                "volume_adaption": VOLUME.get(vol, {"invalid": vol}),
                "username": S("username"),
                "password": S("password"),
                "include_filter": S("include_filter") or "",
                "exclude_filter": S("exclude_filter") or "",
                "minimal_duration_filter": I("minimal_duration_filter"),
                "feed_playback_speed": speed if speed is None or math.isfinite(speed) else repr(speed),
                "skip_intro": I("feed_skip_intro"),
                "skip_ending": I("feed_skip_ending"),
                "skip_silence": SKIP_SILENCE.get(I("feed_skip_silence"), "GLOBAL"),
                "episode_notification": I("episode_notification") > 0,
                "new_episodes_action": NEW_EPISODES.get(I("new_episodes_action"), "ADD_TO_INBOX"),
                "tags": tags(S("tags")),
            },
        }
        if "Feeds.file_url" in ignore:
            del f["file_url"]
        if "Feeds.downloaded" in ignore:
            del f["last_refresh_attempt"]
        if "Feeds.credentials" in ignore:
            del f["preferences"]["username"], f["preferences"]["password"]
        feeds[str(fid)] = f

    media_by_item, media_item_of = {}, {}
    for r in _rows(db, "FeedMedia"):
        mid = get_long(r["id"])
        if r["feeditem"] is None:
            anomalies["orphan_media"].append(mid)
            continue
        owner = get_long(r["feeditem"])
        media_item_of[mid] = owner
        media_by_item.setdefault(owner, []).append((mid, r))

    chapters_by_item = {}
    for r in _rows(db, "SimpleChapters"):
        if r["feeditem"] is None:
            anomalies["orphan_chapters"].append(get_long(r["id"]))
            continue
        chapters_by_item.setdefault(get_long(r["feeditem"]), []).append(r)

    favorite_ids = {get_long(r["feeditem"]) for r in _rows(db, "Favorites") if r["feeditem"] is not None}
    favorites_null = [get_long(r["id"]) for r in _rows(db, "Favorites") if r["feeditem"] is None]

    items = {}
    item_ids_all = set()
    for r in _rows(db, "FeedItems"):
        raw_id = get_long(r["id"])
        item_ids_all.add(raw_id)
        iid = get_int(r["id"])  # FeedItemCursor.java:73 getInt
        w = f"FeedItems[{raw_id}]"
        S = lambda c: safe(get_string, r[c], f"{w}.{c}")
        feed_id = get_long(r["feed"])
        if str(feed_id) not in feeds:
            anomalies["items_missing_feed"].append({"item": raw_id, "feed": r["feed"]})
            continue
        read = get_int(r["read"])
        if read not in (-1, 0, 1):
            anomalies["invalid_values"].append(f"{w}.read={r['read']!r} (behaves as unplayed)")
        has_chapters = get_int(r["has_simple_chapters"]) > 0
        t_url = S("podcastindex_transcript_url")
        transcript = None
        if t_url is not None:
            t_type = S("podcastindex_transcript_type")
            transcript = {"url": t_url, "type": t_type}
            if t_type not in TRANSCRIPT_TYPES:
                anomalies["invalid_values"].append(f"{w}.podcastindex_transcript_type={t_type!r} "
                                                   "(TranscriptType NONE)")
        media = None
        rows = sorted(media_by_item.get(raw_id, []), key=lambda x: x[0])
        if rows:
            mid, m = rows[0]
            for extra_mid, _ in rows[1:]:
                anomalies["extra_media_rows"].append({"item": raw_id, "media": extra_mid})
            mw = f"FeedMedia[{mid}]"
            hist = get_long(m["playback_completion_date"])
            hep = get_int(m["has_embedded_picture"])
            dl = safe(get_long, m["downloaded"], f"{mw}.downloaded")
            media = {
                "id": mid,
                "duration": get_int(m["duration"]),
                "file_url": safe(get_string, m["file_url"], f"{mw}.file_url"),
                "download_url": safe(get_string, m["download_url"], f"{mw}.download_url"),
                "downloaded": dl,
                "downloaded_flag": (dl or 0) > 0,
                "position": get_int(m["position"]),
                "size": get_long(m["filesize"]),
                "mime_type": safe(get_string, m["mime_type"], f"{mw}.mime_type"),
                "last_played_time_history": hist if hist > 0 else None,
                "played_duration": get_int(m["played_duration"]),
                "has_embedded_picture": {1: True, 0: False}.get(hep),
                "last_played_time": get_long(m["last_played_time"]),
            }
            if "FeedMedia.id" in ignore:
                del media["id"]
            if "FeedMedia.downloaded" in ignore:
                del media["downloaded"], media["downloaded_flag"]
            if "FeedMedia.file_url" in ignore:
                del media["file_url"]
            if "FeedMedia.has_embedded_picture" in ignore:
                del media["has_embedded_picture"]
        chapters = None
        if has_chapters:
            chapters = []
            for c in sorted(chapters_by_item.get(raw_id, []), key=lambda c: get_long(c["id"])):
                ch = {"id": get_long(c["id"]), "start": get_long(c["start"]),
                      "title": get_string(c["title"]), "link": get_string(c["link"]),
                      "image_url": get_string(c["image_url"])}
                if "SimpleChapters.id" in ignore:
                    del ch["id"]
                chapters.append(ch)
        items[str(iid)] = {
            "feed": feed_id,
            "title": S("title"),
            "link": S("link"),
            "pub_date": get_long(r["pubDate"]),
            "payment_link": S("payment_link"),
            "description": S("description"),
            "has_chapters": has_chapters,
            "image_url": S("image_url"),
            "play_state": play_state(read),
            "item_identifier": S("item_identifier"),
            "auto_download": get_long(r["auto_download"]) > 0,
            "podcastindex_chapter_url": S("podcastindex_chapter_url"),
            "transcript": transcript,
            "social_interact_url": S("social_interact_url"),
            "is_favorite": raw_id in favorite_ids,
            "media": media,
            "chapters": chapters,
        }
    kept = {int(k) for k in items}

    for fav in sorted(favorite_ids):
        if fav not in item_ids_all:
            anomalies["orphan_favorites"].append(fav)
    anomalies["orphan_favorites"] += [{"favorite_row_with_null_item": x} for x in favorites_null]
    for owner in sorted(media_by_item):
        if owner not in item_ids_all:
            anomalies["orphan_media"] += [mid for mid, _ in media_by_item[owner]]
    for owner in sorted(chapters_by_item):
        if owner not in item_ids_all:
            anomalies["orphan_chapters"] += [get_long(c["id"]) for c in chapters_by_item[owner]]

    queue, seen = [], set()
    for r in sorted(_rows(db, "Queue"), key=lambda q: get_long(q["id"])):
        if r["feeditem"] is None or get_long(r["feeditem"]) not in item_ids_all:
            anomalies["queue_dropped"].append({"queue_id": r["id"], "item": r["feeditem"],
                                               "reason": "no FeedItems row (INNER JOIN)"})
            continue
        it = get_long(r["feeditem"])
        if get_int(it) not in kept:
            anomalies["queue_dropped"].append({"queue_id": r["id"], "item": it,
                                               "reason": "item dropped (feed missing)"})
            continue
        if it in seen:
            anomalies["queue_duplicates"].append({"queue_id": r["id"], "item": it})
            continue
        seen.add(it)
        queue.append(get_int(it))

    log = []
    for r in _rows(db, "DownloadLog"):
        reason = get_int(r["reason"])
        ftype = get_int(r["feedfile_type"])
        feedfile = get_long(r["feedfile"])
        e = {"id": get_long(r["id"]), "feedfile_type": ftype, "feedfile": feedfile,
             "reason": reason if reason in DOWNLOAD_ERROR else {"invalid": reason},
             "successful": get_int(r["successful"]) > 0,
             "completion_date": get_long(r["completion_date"]),
             "reason_detailed": get_string(r["reason_detailed"]), "title": get_string(r["title"])}
        if reason not in DOWNLOAD_ERROR:
            anomalies["invalid_values"].append(f"DownloadLog[{e['id']}].reason={reason} (Android throws)")
        if ftype == 0:
            e["target"] = {"feed": feedfile if str(feedfile) in feeds else None}
        elif ftype == 2:
            owner = media_item_of.get(feedfile)
            e["target"] = {"item": owner if owner is not None and str(get_int(owner)) in items else None}
            if "FeedMedia.id" in ignore:
                del e["feedfile"]
        else:
            e["target"] = None  # e.g. legacy type 1 (FeedImage): no label, no retry
        if "DownloadLog.id" in ignore:
            del e["id"]
        log.append(e)
    log.sort(key=lambda e: (-e["completion_date"], e.get("id", 0),
                            json.dumps(e, sort_keys=True, ensure_ascii=False)))

    state = {"feeds": feeds, "items": items, "queue": queue}
    if "DownloadLog" not in ignore:
        state["download_log"] = log
    out = {"meta": {"user_version": version,
                    "counts": {"feeds": len(feeds), "items": len(items), "queue": len(queue),
                               "favorites": sum(1 for i in items.values() if i["is_favorite"]),
                               "download_log": len(log)},
                    "ignored": sorted(ignore)},
           "state": state}
    if "anomalies" not in ignore:
        out["anomalies"] = anomalies
    return out


def dumps(obj):
    return json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("db")
    ap.add_argument("--ignore", nargs="*", default=[], metavar="TOKEN")
    ap.add_argument("--allow-old", action="store_true",
                    help="read a pre-3080000 file anyway (only if it already has every column)")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    text = dumps(normalize(a.db, a.ignore, a.allow_old))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)


if __name__ == "__main__":
    main()
