#!/usr/bin/env python3
"""Round-trip oracle: an Android 3.12.1 backup restored on iOS, edited there and exported again must
give Android back exactly the user state Android itself would hold after the same user actions.

usage: check_edit_roundtrip.py <android.db> <ios-export.db> [--scenario steps.json] [--json diff.json]

Independent of the Swift tree. The expected file is a copy of the Android backup with every
scenario step applied the way Android 3.12.1 writes it (each step cites AntennaPod 3.12.1's source,
commit f8c64188). Both files are then normalized with normalize.py (Android 3.12.1
read semantics) and compared with compare_roundtrip's default ignore set (download date,
file path and embedded-picture flag; re-assigned row ids; feed cache path).
Without --scenario this is the plain restore -> export round trip.

Self-check: every step must change the presented state. A step that changes nothing (a wrong id,
an action already in effect) is an error, so the scenario cannot silently test nothing.

Exit 0 = equal; 1 = differences; 2 = unreadable input or invalid scenario.
Runs on the macOS system Python 3.9 (no 3.10+ syntax).
"""
import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare_roundtrip as C  # noqa: E402
import normalize as N  # noqa: E402

# Android enum codes, by the names the user sees in the source (model/feed/*.java).
AUTO_DOWNLOAD = {"DISABLED": 0, "GLOBAL": 1, "ENABLED": 2}            # FeedPreferences.java:82-90
AUTO_DELETE = {"GLOBAL": 0, "ALWAYS": 1, "NEVER": 2}                   # FeedPreferences.java:20-28
NEW_EPISODES = {"GLOBAL": 0, "ADD_TO_INBOX": 1, "NOTHING": 2, "ADD_TO_QUEUE": 3}  # FeedPreferences.java:41-49
SKIP_SILENCE = {"OFF": 0, "GLOBAL": 1, "AGGRESSIVE": 2}                # FeedPreferences.java:63-68
VOLUME = {"OFF": 0, "LIGHT_REDUCTION": 1, "HEAVY_REDUCTION": 2,        # VolumeAdaptionSetting.java:8-14
          "LIGHT_BOOST": 3, "MEDIUM_BOOST": 4, "HEAVY_BOOST": 5}
SORT = {"DATE_OLD_NEW": 1, "DATE_NEW_OLD": 2, "EPISODE_TITLE_A_Z": 3,  # SortOrder.java:15-25
        "EPISODE_TITLE_Z_A": 4, "DURATION_SHORT_LONG": 5, "DURATION_LONG_SHORT": 6,
        "EPISODE_FILENAME_A_Z": 7, "EPISODE_FILENAME_Z_A": 8, "SIZE_SMALL_LARGE": 9,
        "SIZE_LARGE_SMALL": 10, "GLOBAL_DEFAULT": 11}
NEW, UNPLAYED, PLAYED = -1, 0, 1                                       # FeedItem.java:51-53
TAG_SEPARATOR = "\u001e"                                               # FeedPreferences.java:18


class ScenarioError(Exception):
    pass


def one(db, sql, args=()):
    row = db.execute(sql, args).fetchone()
    if row is None:
        raise ScenarioError(f"no row for {sql} {args}")
    return row


def media_of(db, item):
    """FeedItemCursor joins the lowest-id FeedMedia row."""
    return db.execute("SELECT id, position, played_duration, duration FROM FeedMedia WHERE feeditem=? "
                      "ORDER BY id LIMIT 1", (item,)).fetchone()


def queue(db):
    return [r[0] for r in db.execute("SELECT feeditem FROM Queue ORDER BY id")]


def set_queue(db, items):
    """PodDBAdapter.setQueue (:891-909): delete all rows, re-insert with id = position."""
    db.execute("DELETE FROM Queue")
    for position, item in enumerate(items):
        feed = one(db, "SELECT feed FROM FeedItems WHERE id=?", (item,))[0]
        db.execute("INSERT INTO Queue(id, feeditem, feed) VALUES (?, ?, ?)", (position, item, feed))


def add_queue_item_back(db, item):
    """DBWriter.addQueueItem (:378-424) with the default Enqueue location BACK (UserPreferences.java:
    356-357) and Keep sorted off: an item already queued or without media is skipped; a NEW item
    becomes UNPLAYED."""
    q = queue(db)
    if item in q or media_of(db, item) is None:
        return
    set_queue(db, q + [item])
    if one(db, "SELECT read FROM FeedItems WHERE id=?", (item,))[0] == NEW:
        mark_items_played(db, item, UNPLAYED, False)


def mark_items_played(db, item, played, reset_position):
    """DBWriter.markItemsPlayed (:652-666) -> PodDBAdapter.setFeedItemsRead (:760-782)."""
    db.execute("UPDATE FeedItems SET read=? WHERE id=?", (played, item))
    media = media_of(db, item)
    if reset_position and media is not None:
        db.execute("UPDATE FeedMedia SET position=0 WHERE id=?", (media[0],))


def save_current_position(db, item, position, duration, timestamp):
    """PlayableUtils.saveCurrentPosition (:21-37) with FeedMedia.onPlaybackStart (:410-414) taken
    from the stored state, written by PodDBAdapter.setFeedMediaPlaybackInformation (:585-598)."""
    media = media_of(db, item)
    if media is None:
        raise ScenarioError(f"episode {item} has no media to play")
    mid, start, played, stored_duration = media
    start = max(start or 0, 0)
    if (stored_duration or 0) != duration:
        raise ScenarioError(f"episode {item}: scenario duration {duration} != stored {stored_duration}")
    played = played or 0
    if position > start:
        played = played + position - start
    if one(db, "SELECT read FROM FeedItems WHERE id=?", (item,))[0] == NEW:
        mark_items_played(db, item, UNPLAYED, False)
    db.execute("UPDATE FeedMedia SET position=?, played_duration=?, last_played_time=?, "
               "playback_completion_date=? WHERE id=?", (position, played, timestamp, timestamp, mid))


def apply_step(db, step):
    a = step["action"]
    if a == "removeFromInbox":
        # FeedItemMenuHandler.removeNewFlagWithUndo (:301-303) -> markReadWithUndo(UNPLAYED) (:243-252)
        mark_items_played(db, step["episode"], UNPLAYED, False)
    elif a == "markPlayed":
        # EpisodeMultiSelectActionHandler.markedCheckedPlayed (:103-123): PLAYED, reset position
        mark_items_played(db, step["episode"], PLAYED, True)
    elif a == "markUnplayed":
        # EpisodeMultiSelectActionHandler.markedCheckedUnplayed (:125-138): UNPLAYED, keep position
        mark_items_played(db, step["episode"], UNPLAYED, False)
    elif a == "addFavorite":
        # DBWriter.addFavoriteItems (:536-546) -> PodDBAdapter.addFavoriteItems (:872-881)
        db.execute("INSERT INTO Favorites(feeditem, feed) SELECT id, feed FROM FeedItems WHERE id=? "
                   "AND id NOT IN (SELECT feeditem FROM Favorites)", (step["episode"],))
    elif a == "removeFavorite":
        # DBWriter.removeFavoriteItems (:548-558) -> PodDBAdapter.removeFavoriteItems (:883-889)
        db.execute("DELETE FROM Favorites WHERE feeditem=?", (step["episode"],))
    elif a == "moveInQueue":
        # DBWriter.moveQueueItem (:569-586): remove at the old index, insert at the new one
        q = queue(db)
        q.remove(step["episode"])
        q.insert(step["index"], step["episode"])
        set_queue(db, q)
    elif a == "removeFromQueue":
        # FeedItemMenuHandler (:201-202) -> DBWriter.removeQueueItemSynchronous (:482-528)
        set_queue(db, [i for i in queue(db) if i != step["episode"]])
    elif a == "addToQueue":
        # FeedItemMenuHandler (:199-200) -> DBWriter.addQueueItem
        add_queue_item_back(db, step["episode"])
    elif a == "playAndPause":
        # PlaybackService.startPlaying adds the episode to the queue (:806-811, :1874-1878); the pause
        # saves the position (saveCurrentPosition)
        add_queue_item_back(db, step["episode"])
        save_current_position(db, step["episode"], step["position"], step["duration"], step["at"])
    elif a == "playToEnd":
        # Last saved position, then PlaybackService.onPostPlayback(ended) (:1179-1236): markItemsPlayed
        # (PLAYED, reset position), removeQueueItem, no deletion (global auto-delete off by default,
        # UserPreferences.isAutoDelete), addItemToPlaybackHistory(now) (DBWriter.java:305-317 ->
        # PodDBAdapter.setFeedMediaLastPlayedTimeHistory :600-611)
        item = step["episode"]
        add_queue_item_back(db, item)
        save_current_position(db, item, step["position"], step["duration"], step["sampleAt"])
        mark_items_played(db, item, PLAYED, True)
        set_queue(db, [i for i in queue(db) if i != item])
        db.execute("UPDATE FeedMedia SET playback_completion_date=? WHERE id=?",
                   (step["endAt"], media_of(db, item)[0]))
    elif a == "download":
        # DownloadServiceInterfaceImpl.getRequest (:49-59): "Enqueue downloaded" (default on,
        # UserPreferences.java:347-349) adds it at the back; MediaDownloadedHandler.run (:46-110):
        # setDownloaded (FeedMedia.java:459-464, NEW -> UNPLAYED), size = file length,
        # disableAutoDownload, setFeedItem; the success row is DownloadResult(title, media id,
        # type 2, SUCCESS, no detail) as in the real 3.12.1 rows of emulator-parity-library.db.
        # No chapters are cached from a file without them (ChapterUtils.java:85-122 returns null).
        # downloaded / file_url / has_embedded_picture are the `D1` ignore group and are not compared.
        item = step["episode"]
        add_queue_item_back(db, item)
        media = media_of(db, item)
        if media is None:
            raise ScenarioError(f"episode {item} has no media to download")
        if one(db, "SELECT read FROM FeedItems WHERE id=?", (item,))[0] == NEW:
            db.execute("UPDATE FeedItems SET read=? WHERE id=?", (UNPLAYED, item))
        db.execute("UPDATE FeedMedia SET downloaded=?, filesize=? WHERE id=?", (step["at"], step["bytes"], media[0]))
        db.execute("UPDATE FeedItems SET auto_download=0 WHERE id=?", (item,))
        title = one(db, "SELECT title FROM FeedItems WHERE id=?", (item,))[0]
        db.execute("INSERT INTO DownloadLog(feedfile, feedfile_type, reason, successful, completion_date, "
                   "reason_detailed, title) VALUES (?, 2, 0, 1, ?, NULL, ?)", (media[0], step["at"], title))
    elif a == "feedPreferences":
        # FeedSettingsFragment -> DBWriter.setFeedPreferences -> PodDBAdapter.setFeedPreferences
        # (:493-515); the rename is setFeedCustomTitle (:816-820)
        f = step["feed"]
        db.execute("UPDATE Feeds SET custom_title=?, auto_download=?, keep_updated=?, auto_delete_action=?, "
                   "new_episodes_action=?, feed_volume_adaption=?, feed_skip_intro=?, feed_skip_ending=?, "
                   "episode_notification=?, include_filter=?, exclude_filter=?, minimal_duration_filter=? "
                   "WHERE id=?",
                   (step["customTitle"], AUTO_DOWNLOAD[step["autoDownload"]], int(step["keepUpdated"]),
                    AUTO_DELETE[step["autoDelete"]], NEW_EPISODES[step["newEpisodesAction"]],
                    VOLUME[step["volumeAdaptation"]], step["skipIntro"], step["skipEnding"],
                    int(step["episodeNotification"]), step["includeFilter"], step["excludeFilter"],
                    step["minimalDuration"], f))
    elif a == "episodeFilter":
        # FeedItemFilter tokens joined with "," (PodDBAdapter.setFeedItemFilter :517-523)
        db.execute("UPDATE Feeds SET hide=? WHERE id=?", (",".join(step["values"]), step["feed"]))
    elif a == "sortOrder":
        # SortOrder.toCodeString (:74-77) via PodDBAdapter.setFeedItemSortOrder (:526-530)
        db.execute("UPDATE Feeds SET sort_order=? WHERE id=?", (str(SORT[step["order"]]), step["feed"]))
    elif a == "playbackSpeed":
        # FeedPreferences feed_playback_speed (Java float) and feed_skip_silence (PodDBAdapter.setFeedPreferences :493-515)
        db.execute("UPDATE Feeds SET feed_playback_speed=?, feed_skip_silence=? WHERE id=?",
                   (step["speed"], SKIP_SILENCE[step["skipSilence"]], step["feed"]))
    elif a == "credentials":
        # Plaintext username/password (setFeedPreferences)
        db.execute("UPDATE Feeds SET username=?, password=? WHERE id=?",
                   (step["username"], step["password"], step["feed"]))
    elif a == "tags":
        # TagSettingsDialog.updatePreferencesTags (:151-160): the set, "#root" only when the root
        # folder box is checked, joined with U+001E (FeedPreferences.getTagsAsString :309-311)
        db.execute("UPDATE Feeds SET tags=? WHERE id=?", (TAG_SEPARATOR.join(step["tags"]), step["feed"]))
    elif a == "archive":
        # RemoveFeedDialog Archive (:81-82) -> DBWriter.setFeedState(ARCHIVED) (:862-885) -> PodDBAdapter.setFeedState (:822)
        db.execute("UPDATE Feeds SET state=2 WHERE id=?", (step["feed"],))
    elif a == "restoreArchived":
        # Archived feed header Restore / RemoveFeedDialog Restore (:83-84) -> DBWriter.setFeedState
        # (ARCHIVED -> SUBSCRIBED changes the state only, :862-885)
        if one(db, "SELECT state FROM Feeds WHERE id=?", (step["feed"],))[0] != 2:
            raise ScenarioError(f"feed {step['feed']} is not archived")
        db.execute("UPDATE Feeds SET state=0 WHERE id=?", (step["feed"],))
    elif a == "removeAllFromInbox":
        # Inbox menu Remove all from inbox -> DBWriter.removeAllNewFlags (:686-695) ->
        # PodDBAdapter.setFeedItems(NEW, UNPLAYED) (:1103-1117): every feed, whatever its state
        db.execute("UPDATE FeedItems SET read=? WHERE read=?", (UNPLAYED, NEW))
    elif a == "subscribePreview":
        # DBWriter.setFeedState NOT_SUBSCRIBED -> SUBSCRIBED also turns Keep updated on (:869-871)
        if one(db, "SELECT state FROM Feeds WHERE id=?", (step["feed"],))[0] != 1:
            raise ScenarioError(f"feed {step['feed']} is not a preview")
        db.execute("UPDATE Feeds SET state=0, keep_updated=1 WHERE id=?", (step["feed"],))
    else:
        raise ScenarioError(f"unknown action {a!r}")


def expected_file(android_db, steps, workdir):
    """Copy of the Android backup with the steps applied; each step must change the presented state."""
    path = os.path.join(workdir, "expected.db")
    shutil.copyfile(android_db, path)
    previous = N.normalize(path, C.DEFAULT_IGNORE)["state"]
    for index, step in enumerate(steps):
        db = sqlite3.connect(path)
        try:
            apply_step(db, step)
            db.commit()
        finally:
            db.close()
        current = N.normalize(path, C.DEFAULT_IGNORE)["state"]
        if current == previous:
            raise ScenarioError(f"step {index} {json.dumps(step)} changes nothing Android presents")
        previous = current
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description="Android backup restore/edit/export round-trip check")
    ap.add_argument("android_db")
    ap.add_argument("ios_db")
    ap.add_argument("--scenario", help="JSON object with a 'steps' list")
    ap.add_argument("--json", help="write the diff here")
    a = ap.parse_args(argv)
    steps = []
    if a.scenario:
        with open(a.scenario, encoding="utf-8") as fh:
            steps = json.load(fh)["steps"]
    workdir = tempfile.mkdtemp(prefix="gap-data-")
    try:
        try:
            expected = expected_file(a.android_db, steps, workdir)
        except (ScenarioError, KeyError, sqlite3.Error) as err:
            print(f"ERROR: invalid scenario: {type(err).__name__}: {err}", file=sys.stderr)
            return 2
        try:
            left, right, diffs = C.compare(expected, a.ios_db, C.DEFAULT_IGNORE)
        except Exception as err:  # unreadable input is not "equal"
            print(f"ERROR: {type(err).__name__}: {err}", file=sys.stderr)
            return 2
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    print(f"steps: {len(steps)}; ignore: {sorted(N.expand_ignore(C.DEFAULT_IGNORE))}")
    print(f"expected: {left['meta']['counts']}")
    print(f"ios:      {right['meta']['counts']}")
    for p, l, r in diffs:
        print(f"DIFF {p}: android={json.dumps(l, ensure_ascii=False)} ios={json.dumps(r, ensure_ascii=False)}")
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump({"steps": len(steps), "diffs": [list(x) for x in diffs]}, fh, indent=1, ensure_ascii=False)
    print("EQUAL" if not diffs else f"{len(diffs)} difference(s)")
    return 0 if not diffs else 1


if __name__ == "__main__":
    sys.exit(main())
