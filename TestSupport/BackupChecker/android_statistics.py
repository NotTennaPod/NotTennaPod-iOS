#!/usr/bin/env python3
"""The statistics stock AntennaPod 3.12.1 shows for an Antennapod.db, as JSON.

usage: android_statistics.py <db> [--from MS] [--to MS] [--now MS]

Independent of the Swift tree. Each value is the SQL text Android builds, executed with sqlite3:
  feeds    PodDBAdapter.getFeedStatisticsCursor (:1239-1282), once with includeMarkedAsPlayed false and once true,
           with the period [from, to) and sixMonthsAgo = now - 15,780,096,000 ms (DBReader.getStatistics): per feed
           num_episodes, oldest_date, episodes_started, played_time, total_time, num_downloaded, download_size,
           num_recent_unplayed.
  months   PodDBAdapter.getMonthlyStatisticsCursor (:1228-1237): total_duration per UTC month.
  episodes the rows a feed's episode list shows (FeedItems joined with FeedMedia), to compare states.
Runs on the macOS system Python 3.9.
"""
import argparse
import json
import sqlite3
import sys

LONG_MAX = 9223372036854775807
PLAYED = 1


def feed_statistics(db, include_marked, time_from, time_to, six_months_ago):
    last = "FeedMedia.last_played_time"
    was_started = "FeedMedia.playback_completion_date > 0 AND FeedMedia.played_duration > 0"
    if include_marked:
        was_started = "(" + was_started + ") OR FeedItems.read=" + str(PLAYED) + " OR FeedMedia.position> 0"
    time_filter = last + ">=" + str(time_from) + " AND " + last + "<" + str(time_to)
    played_time = "FeedMedia.played_duration"
    if include_marked:
        played_time = ("(CASE WHEN " + played_time + " != 0 THEN " + played_time + " ELSE (CASE WHEN FeedItems.read="
                       + str(PLAYED) + " THEN FeedMedia.duration ELSE 0 END) END)")
    query = ("SELECT Feeds.id, COUNT(*) AS num_episodes, "
             "MIN(CASE WHEN " + last + " > 0 THEN " + last + " ELSE " + str(LONG_MAX) + " END) AS oldest_date, "
             "SUM(CASE WHEN (" + was_started + ") THEN 1 ELSE 0 END) AS episodes_started, "
             "IFNULL(SUM(CASE WHEN (" + time_filter + ") THEN (" + played_time + ") ELSE 0 END), 0) AS played_time, "
             "IFNULL(SUM(FeedMedia.duration), 0) AS total_time, "
             "SUM(CASE WHEN FeedMedia.downloaded > 0 THEN 1 ELSE 0 END) AS num_downloaded, "
             "SUM(CASE WHEN FeedMedia.downloaded > 0 THEN FeedMedia.filesize ELSE 0 END) AS download_size, "
             "SUM(CASE WHEN FeedItems.read != " + str(PLAYED) + " AND FeedItems.pubDate >= " + str(six_months_ago)
             + " THEN 1 ELSE 0 END) AS num_recent_unplayed "
             " FROM FeedItems LEFT JOIN FeedMedia ON FeedItems.id=FeedMedia.feeditem "
             " INNER JOIN Feeds ON FeedItems.feed=Feeds.id WHERE Feeds.state!=1 GROUP BY Feeds.id")
    columns = ["feed", "num_episodes", "oldest_date", "episodes_started", "played_time", "total_time",
               "num_downloaded", "download_size", "num_recent_unplayed"]
    return [dict(zip(columns, row)) for row in db.execute(query)]


def monthly(db):
    query = ("SELECT SUM(played_duration) AS total_duration, "
             "strftime('%m', datetime(last_played_time/1000, 'unixepoch')) AS month, "
             "strftime('%Y', datetime(last_played_time/1000, 'unixepoch')) AS year "
             "FROM FeedMedia WHERE last_played_time > 0 AND played_duration > 0 GROUP BY year, month ORDER BY year, month")
    return [{"year": int(row[2]), "month": int(row[1]), "played": row[0]} for row in db.execute(query)]


def episodes(db):
    query = ("SELECT FeedItems.id, FeedItems.feed, FeedItems.title, FeedItems.read, FeedItems.item_identifier, "
             "FeedMedia.id, FeedMedia.position, FeedMedia.played_duration, FeedMedia.last_played_time, "
             "FeedMedia.playback_completion_date, FeedMedia.duration FROM FeedItems LEFT JOIN FeedMedia "
             "ON FeedItems.id=FeedMedia.feeditem ORDER BY FeedItems.id")
    columns = ["item", "feed", "title", "read", "guid", "media", "position", "played", "last_played", "history", "duration"]
    return [dict(zip(columns, row)) for row in db.execute(query)]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("db")
    parser.add_argument("--from", dest="time_from", type=int, default=0)
    parser.add_argument("--to", dest="time_to", type=int, default=LONG_MAX)
    parser.add_argument("--now", type=int, required=True)
    args = parser.parse_args(argv)
    db = sqlite3.connect("file:" + args.db + "?mode=ro", uri=True)
    six = args.now - 15780096000
    result = {
        "feeds": feed_statistics(db, False, args.time_from, args.time_to, six),
        "feeds_marked": feed_statistics(db, True, args.time_from, args.time_to, six),
        "months": monthly(db),
        "episodes": episodes(db),
        "references": {
            "queue": [row[0] for row in db.execute("SELECT feeditem FROM Queue ORDER BY id")],
            "favorites": [row[0] for row in db.execute("SELECT feeditem FROM Favorites ORDER BY feeditem")],
            "chapters": [row[0] for row in db.execute("SELECT DISTINCT feeditem FROM SimpleChapters ORDER BY feeditem")],
            "dangling": db.execute("SELECT count(*) FROM Queue WHERE feeditem NOT IN (SELECT id FROM FeedItems)").fetchone()[0]
            + db.execute("SELECT count(*) FROM Favorites WHERE feeditem NOT IN (SELECT id FROM FeedItems)").fetchone()[0]
            + db.execute("SELECT count(*) FROM SimpleChapters WHERE feeditem NOT IN (SELECT id FROM FeedItems)").fetchone()[0]
            + db.execute("SELECT count(*) FROM FeedMedia WHERE feeditem NOT IN (SELECT id FROM FeedItems)").fetchone()[0],
        },
        "tables": sorted(row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")),
    }
    json.dump(result, sys.stdout, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
