#!/usr/bin/env python3
"""The drawer and bottom-navigation counters Android 3.12.1 shows for an Antennapod.db.

usage: navigation_counters.py <db> [--scenario steps.json] [--out counters.json]

Independent of the Swift tree. Each counter is the SQL text Android builds, executed with sqlite3:
  queue                PodDBAdapter.getQueueSize (:1300-1308): SELECT COUNT(id) FROM Queue
                       -> Queue row of the drawer (NavListAdapter.bindNavView :193-199)
  inbox                DBReader.getTotalEpisodeCount(new FeedItemFilter(NEW)) (DBReader.java:237-248)
                       -> PodDBAdapter.getEpisodeCountCursor (:1128-1134) with FeedItemFilterQuery
                       (:23-101): read = -1, and because the filter names no feed state, only
                       SUBSCRIBED feeds (state 0). Inbox row of the drawer (:200-205) and the
                       bottom-navigation Inbox badge (BottomNavigation.java:66-85).
  feed_counters        PodDBAdapter.getFeedCounters / conditionalFeedCounterRead (:1310-1366):
                       subscribed feeds only, LEFT JOIN FeedMedia, per counter setting.
  subscriptions_entry  NavDrawerFragment.getFeedCounterSum (:342-351): the sum of feed_counters
                       for the setting (NavListAdapter :206-211); SHOW_NONE has no counters.

With --scenario the counters are listed for the file and after each step, the steps applied the
way Android 3.12.1 writes them (check_edit_roundtrip.apply_step, cited there).
Runs on the macOS system Python 3.9.
"""
import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_edit_roundtrip as E  # noqa: E402

JOIN_FEED_ITEM_AND_MEDIA = " LEFT JOIN FeedMedia ON FeedItems.id=FeedMedia.feeditem "  # PodDBAdapter:349-350
SELECT_WHERE_FEED_IS_SUBSCRIBED = "FeedItems.feed IN (SELECT id FROM Feeds WHERE state=0)"  # :361-363
# FeedCounter (model/feed/FeedCounter.java) -> whereRead of getFeedCounters (:1311-1331)
WHERE_READ = {
    "SHOW_NEW": "read=-1",
    "SHOW_UNPLAYED": "(read=-1 OR read=0)",
    "SHOW_DOWNLOADED": "downloaded>0",
    "SHOW_DOWNLOADED_UNPLAYED": "(read=-1 OR read=0) AND downloaded>0",
}


def counters(path):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        queue = db.execute("SELECT COUNT(id) FROM Queue").fetchone()[0]
        # FeedItemFilterQuery.generateFrom(NEW): " (" + "FeedItems.read = -1 " + " AND " + state clause + ") "
        new_filter = (" (FeedItems.read = -1  AND FeedItems.feed IN (SELECT id FROM Feeds WHERE state IN (0))) ")
        inbox = db.execute("SELECT count(FeedItems.id) FROM FeedItems" + JOIN_FEED_ITEM_AND_MEDIA
                           + " WHERE " + new_filter).fetchone()[0]
        feed_counters = {}
        for setting, where_read in WHERE_READ.items():
            rows = db.execute("SELECT feed, COUNT(FeedItems.id) AS count  FROM FeedItems" + JOIN_FEED_ITEM_AND_MEDIA
                              + "WHERE " + SELECT_WHERE_FEED_IS_SUBSCRIBED + " AND  " + where_read
                              + " GROUP BY feed").fetchall()
            feed_counters[setting] = {str(feed): count for feed, count in rows}
        entry = {setting: sum(values.values()) for setting, values in feed_counters.items()}
        entry["SHOW_NONE"] = 0
        return {"queue": queue, "inbox": inbox, "feed_counters": feed_counters, "subscriptions_entry": entry}
    finally:
        db.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Android 3.12.1 drawer / bottom-navigation counters")
    ap.add_argument("db")
    ap.add_argument("--scenario", help="JSON object with a 'steps' list (check_edit_roundtrip actions)")
    ap.add_argument("--out", help="write the JSON here instead of stdout")
    a = ap.parse_args(argv)
    steps = []
    if a.scenario:
        with open(a.scenario, encoding="utf-8") as fh:
            steps = json.load(fh)["steps"]
    workdir = tempfile.mkdtemp(prefix="gap-data-counters-")
    try:
        path = os.path.join(workdir, "state.db")
        shutil.copyfile(a.db, path)
        states = [dict(counters(path), after=None)]
        for step in steps:
            db = sqlite3.connect(path)
            try:
                E.apply_step(db, step)
                db.commit()
            finally:
                db.close()
            states.append(dict(counters(path), after=step))
    except (E.ScenarioError, KeyError, sqlite3.Error) as err:
        print(f"ERROR: {type(err).__name__}: {err}", file=sys.stderr)
        return 2
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    text = json.dumps({"states": states}, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
