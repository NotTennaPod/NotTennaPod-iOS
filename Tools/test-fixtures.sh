#!/bin/zsh
# Starts/stops every loopback fixture server the UI tests use, each on its own port.
# The NotTennaPod scheme's test pre-action runs `start` and its post-action `stop`, so an ordinary
# `xcodebuild test` has its fixtures; it can also be run by hand:  Tools/test-fixtures.sh start|stop|status|seed [device-udid]
# With a device it also seeds that Simulator's Files storage (seed_files).
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
# Receipts, logs, pids and the run registry live in this checkout's own .work (never another checkout's): runs on
# several Simulators from one checkout share its servers, once each listener is checked to be the process this
# checkout started for it; a listener of anything else (another checkout's fixtures) fails the start loudly.
STATE=${NTP_FIXTURE_STATE:-$ROOT/.work/test-fixtures}; mkdir -p $STATE
# Serialize starts/stops/seeding with host tests and resync. A verified inherited descriptor avoids
# nested acquisition when this script is called by the scheme's pre-action.
if ! python3 Tools/validation-lock.py --verify; then
  exec python3 Tools/validation-lock.py --kind fixture --fixture-state "$STATE" -- /bin/zsh "$0" "$@"
fi
DEVICE=${2:-${TARGET_DEVICE_IDENTIFIER:-}}
T=TestSupport/Servers; F=Tests/NotTennaPodCoreTests/Fixtures
# The hub's run folder; an acceptance run (Tools/acceptance.sh) names its own, and keeps it.
if [ -n "${NTP_HUB_RUN_DIR:-}" ]; then HUB_RUN=${NTP_HUB_RUN_DIR:a}; HUB_KEEP=--keep; else HUB_RUN=$STATE/hub; HUB_KEEP=""; fi
# name|port(s) checked|command
SERVERS=(
  "listening|18765|python3 -u $T/serve-listening-fixture.py"
  "paged-feed|18766|python3 -u $T/serve-paged-feed-fixture.py"
  "pull-refresh|18767|python3 -u $T/serve-pull-refresh-fixture.py"
  "feed-selection|18768|python3 -u $T/serve-feed-selection-fixture.py"
  "new-episodes|18769|python3 -u $T/serve-new-episodes-fixture.py"
  "authenticated|18770|python3 -u $T/serve-authenticated-feed-fixture.py"
  "downloads-controls|18771|python3 -u $T/serve-downloads-controls-fixture.py"
  "preview|18774|python3 -u $T/serve-preview-fixture.py"
  "auto-download|18775|python3 -u $T/serve-auto-download-fixture.py"
  "download-log|18776|python3 -u $T/serve-download-log-fixture.py"
  "list-inbox|18777|python3 -u $T/serve-list-inbox-fixture.py --host 127.0.0.1 --port 18777"
  "playback-end|18778|python3 -u $T/serve-playback-end-fixture.py"
  "proxy|18790|python3 -u $T/serve-proxy-protocol-fixture.py --report $STATE/proxy-report.json --media TestSupport/Media/listening/30sec.mp3 --live-media $F/playback-unknown-duration.mp3 --hls $F/StreamingHLS --hls-aes $F/StreamingHLSAES"
  "app-playback|18803|python3 -u $T/serve-app-playback-fixture.py"
  "player-chapters|18807|python3 -u $T/serve-player-chapters.py"
  "player-buffering|18808|python3 -u $T/serve-player-buffering.py"
  "chapter-dismissal|18809|python3 -u $T/serve-chapter-dismissal.py"
  "synchronization|18812|python3 -u $T/serve-synchronization-fixture.py"
  "nextcloud|18813|python3 -u $T/serve-nextcloud-fixture.py"
  "discovery|18820|python3 -u $T/serve-discovery-fixture.py"
  "ntp-server|18831|python3 -u $T/serve-ntp-server-fixture.py --port 18831 --server-port 18830 --publisher-port 18834 --run-dir $HUB_RUN $HUB_KEEP"
  "playback-audio|59431|python3 -u AppUITests/Fixtures/PlaybackAudio/serve_playback_audio.py --fixtures-root $F --port 59431 --receipt $STATE/playback-audio-receipt.json"
)
[ -n "$DEVICE" ] && SERVERS+=("playback-video|59421|python3 -u AppUITests/Fixtures/PlaybackVideo/serve.py --port 59421 --device $DEVICE")
# The script's own tests (TestSupport/Servers/hub/tests/test_fixtures.py) give their own state folder and servers.
[ -n "${NTP_FIXTURE_SERVERS:-}" ] && SERVERS=("${(@f)NTP_FIXTURE_SERVERS}")

listening() { lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1; }
listener_pids() { lsof -nP -t -iTCP:$1 -sTCP:LISTEN 2>/dev/null; }
# A port is this checkout's when the process listening on it is the live one this checkout started for it.
owned() {
  local pid
  [ -f $STATE/$1.pid ] || return 1
  pid=$(cat $STATE/$1.pid)
  python3 Tools/fixture-process.py owned --state "$STATE" --name "$1" && listener_pids $2 | grep -qx "$pid"
}
any_owned() {
  local entry
  for entry in $SERVERS; do local name=${entry%%|*} rest=${entry#*|}; owned $name ${rest%%|*} && return 0; done
  return 1
}
# Every listening port must be one of this checkout's own; another's listener is reported, never shared.
no_foreign() {
  local entry found=0
  for entry in $SERVERS; do
    local name=${entry%%|*} rest=${entry#*|}; local port=${rest%%|*}
    listening $port || continue
    owned $name $port && continue
    local pid=$(listener_pids $port | head -1)
    echo "test-fixtures: port $port ($name) is held by process ${pid:-?} ($(ps -o command= -p ${pid:-0} 2>/dev/null | cut -c1-100)), not by this checkout's fixtures ($STATE); stop it, or wait for the run that started it" >&2
    found=1
  done
  return $found
}
pin() { grep -v '^#' $ROOT/TestSupport/Server/$1 | head -1 | tr -d '[:space:]'; }
# A shared hub must be configured with this checkout's candidate, run its pinned server now,
# and, when NTP_HUB_RUN_DIR is given, use that folder.
hub_matches() {
  local entry
  for entry in $SERVERS; do
    [ "${entry%%|*}" = ntp-server ] || continue
    local rest=${entry#*|}; local port=${rest%%|*}
    listening $port || continue
    curl -s -m 10 http://127.0.0.1:$port/status | python3 -c '
import json, sys
expected_run, named, server, web, port = sys.argv[1:]
try:
    status = json.load(sys.stdin)
except ValueError:
    sys.exit(f"test-fixtures: the hub on port {port} gave no status; it is not shared")
candidate = status.get("candidate") or {}
active = (status.get("server") or {}).get("commit")
if (candidate.get("server_commit"), candidate.get("web_commit")) != (server, web):
    sys.exit(f"test-fixtures: the hub on port {port} runs candidate server {candidate.get("server_commit")} web "
             f"{candidate.get("web_commit")}, not this checkout'"'"'s server {server} web {web}; it is not shared")
# Check the running identity as well as the configured candidate.
if active != server and not (active is None and not status.get("ready")):
    sys.exit(f"test-fixtures: the hub on port {port} runs server {active}, not this checkout'"'"'s pinned server "
             f"{server}; it is not shared")
if named and status.get("run", "").rstrip("/") != expected_run.rstrip("/"):
    sys.exit(f"test-fixtures: the hub on port {port} keeps its run folder in {status.get("run")}, not NTP_HUB_RUN_DIR "
             f"{expected_run}; stop the fixtures first")
' "$HUB_RUN" "${NTP_HUB_RUN_DIR:-}" "$(pin server-version.txt)" "$(pin web-version.txt)" $port || return 1
  done
  return 0
}
# Runs on different Simulators share the servers: `start` counts a user, `stop` stops them after the last one.
USERS=$STATE/users
lock() { return 0; } # validation-lock.py owns the checkout-local file lock for this whole command
unlock() { return 0; }
all_up() { local entry; for entry in $SERVERS; do local rest=${entry#*|}; listening ${rest%%|*} || return 1; done; }
kill_servers() {
  python3 Tools/fixture-process.py stop --state "$STATE"
}
launch() { python3 Tools/fixture-process.py launch --state "$STATE" --name "$1" --port "$2" -- ${=3}; }
wait_port() { python3 Tools/fixture-process.py wait-port --state "$STATE" --port "$1"; }
# Each run registers under its device, so a run can only release its own registration: a post-action whose
# pre-action failed, or a stray stop, can no longer stop the servers under another run.
REGISTRY=$STATE/users.d
register() { mkdir -p $REGISTRY; touch $REGISTRY/${DEVICE:-manual}; }
# Older script copies (e.g. in git worktrees) still count runs in $USERS; those runs count too.
registered() { echo $(( $(ls $REGISTRY 2>/dev/null | wc -l) + $(cat $USERS 2>/dev/null || echo 0) )); }
stop() {
  lock || return 1
  rm -f $REGISTRY/${DEVICE:-manual}
  local users=$(registered)
  if [ $users -le 0 ]; then
    kill_servers || { unlock; return 1; }
    rm -rf $USERS $REGISTRY; echo "test-fixtures: stopped"
  else echo "test-fixtures: $users run(s) still using the servers"; fi
  unlock
}
start() {
  lock || exit 1
  # Registrations cover the test's lifetime, including a fixture crash. Only that run's explicit
  # post-action/stop releases its registration; PID disappearance is not a stale-lease rule.
  # Another run of this checkout uses the servers: share them once every listener is checked to be this
  # checkout's (and the hub this run's), and start only the missing ones instead of restarting the set under it.
  if [ $(registered) -gt 0 ]; then
    if ! no_foreign || ! hub_matches; then unlock; exit 1; fi
    local shared_failed=0 started=0
    for entry in $SERVERS; do
      local name=${entry%%|*} rest=${entry#*|}; local port=${rest%%|*} cmd=${rest#*|}
      listening $port && continue
      started=1
      launch "$name" "$port" "$cmd" || { shared_failed=1; continue; }
      wait_port $port || { echo "test-fixtures: $name did not listen on $port; see $STATE/$name.log" >&2; shared_failed=1; }
    done
    if [ $shared_failed = 0 ] && seed_files; then
      register; unlock
      [ $started = 0 ] && echo "test-fixtures: servers already listening; shared" || echo "test-fixtures: shared servers completed"
      return
    fi
    unlock; exit 1
  fi
  kill_servers || { unlock; exit 1; }
  local failed=0
  for entry in $SERVERS; do
    local name=${entry%%|*} rest=${entry#*|}; local port=${rest%%|*} cmd=${rest#*|}
    if listening $port; then
      local pid=$(listener_pids $port | head -1)
      echo "test-fixtures: port $port ($name) is held by process ${pid:-?} ($(ps -o command= -p ${pid:-0} 2>/dev/null | cut -c1-100)), not by this checkout's fixtures ($STATE)" >&2
      failed=1; continue
    fi
    launch "$name" "$port" "$cmd" || failed=1
  done
  for entry in $SERVERS; do
    local name=${entry%%|*} rest=${entry#*|}; local port=${rest%%|*}
    wait_port $port || { echo "test-fixtures: $name did not listen on $port; see $STATE/$name.log" >&2; failed=1; }
  done
  seed_files || failed=1
  if [ $failed = 0 ]; then rm -rf $REGISTRY $USERS; register; unlock; echo "test-fixtures: ${#SERVERS} servers listening"
  else kill_servers; rm -rf $USERS $REGISTRY; unlock; exit 1; fi
}
# Places the Files-picker documents (TestSupport/Media/files-provider) into the Simulator's local Files storage.
seed_files() {
  [ -n "$DEVICE" ] && [ -z "${NTP_FIXTURE_NO_SEED:-}" ] || return 0
  local group="" meta
  for meta in ~/Library/Developer/CoreSimulator/Devices/$DEVICE/data/Containers/Shared/AppGroup/*/.com.apple.mobile_container_manager.metadata.plist(N); do
    [ "$(plutil -extract MCMMetadataIdentifier raw "$meta" 2>/dev/null)" = group.com.apple.FileProvider.LocalStorage ] && group=${meta:h}
  done
  [ -n "$group" ] || { echo "test-fixtures: no local Files storage on $DEVICE; open the Files app once" >&2; return 1; }
  local store="$group/File Provider Storage" P=TestSupport/Media/files-provider
  mkdir -p "$store"
  # Earlier test exports would trigger the Save picker's replace prompt.
  rm -f "$store"/AntennaPodBackup-*.db(N) "$store"/NotTennaPodBackup-*.db(N) "$store"/antennapod-feeds-*.(opml|html)(N) "$store"/nottennapod-feeds-*.(opml|html)(N) "$store"/antennapod-favorites-*.html(N) "$store"/nottennapod-favorites-*.html(N)
  cp TestSupport/Data/database-restore/android-3.12.1/emulator-parity-library.db $P/M16/*.db "$store/"
  rm -rf "$store/M18"; mkdir "$store/M18"
  # The OPML journeys use these fixed library IDs (their Files folders are named after them), so each run also
  # starts their app libraries empty; an earlier run's imported subscriptions would otherwise still be there.
  local id app=$(xcrun simctl get_app_container $DEVICE org.nottennapod.app data 2>/dev/null)
  for id in 9A490CDF-7E51-457F-9576-188511EB247C F0483971-C6CE-430B-ACAA-EB6A521272AC C49DFF3B-C214-4EE7-A820-1FFAE7CB4EFF \
            5C4734B7-61CA-487F-B3AC-5ED0BFAE3208 39724F84-202F-4455-9037-1ED941C991C9; do
    rm -rf "$store/M11-$id"; mkdir "$store/M11-$id"; cp $P/M11/*.opml "$store/M11-$id/"
    [ -n "$app" ] && rm -rf "$app/Library/Application Support/UITests-$id"
  done
  echo "test-fixtures: Files storage seeded"
}
status() { for entry in $SERVERS; do local name=${entry%%|*} rest=${entry#*|}; local port=${rest%%|*}; listening $port && echo "up   $port $name" || echo "DOWN $port $name"; done; }
case ${1:-} in start) start;; seed) seed_files;; stop) stop;; status) status;; *) echo "usage: $0 start|stop|status|seed [device-udid]" >&2; exit 2;; esac
