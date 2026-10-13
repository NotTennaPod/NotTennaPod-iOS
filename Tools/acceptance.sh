#!/bin/zsh
# The integration acceptance runs (PROTOCOL §16): builds the release candidate,
# then runs one phase's rows in order and writes .work/acceptance/<run>/summary.md with the triple (iOS, server and
# web commits), the candidate, the seed, the clock offsets the hub recorded, each row's command, duration, load
# averages and result, and the scenario rows still pending in this phase.
#
#   Tools/acceptance.sh A [--run <name>] [--only <row>[,<row>…]] [--seed <n>] [--keep-going] [--keep] [--list]
#   NTP_ACCEPTANCE_IPHONE=<simulator name> (default "iPhone 18 Pro") picks the Simulator of the UI journeys.
#
# Rows of phase A: the candidate; the hub's own tests; the server's `make check build cross-build
# media-acceptance` on the candidate's source; the web client's `npm run check` and its journeys, player and layout
# suites on the candidate (NTP_SERVER_BINARY); the iOS host suites of the attachment and the exchange against the
# candidate; the attach journeys and the hub smoke on the iPhone (UI: one Simulator, nothing else heavy); the server
# witness on the journeys' data. Each row's output is in <row>.log; the
# journeys' hub keeps its folder (server data, event log, witness copies) in hub/. A failed run keeps everything; a
# passing run drops the server's data copies. NTP_ACCEPTANCE=<seed> is exported to every row (the sweeps read it).
set -u
root=${0:A:h:h}
cd $root
phase=${1:-}
[[ $phase == A ]] || { print -u2 "usage: $0 A [--run <name>] [--only <rows>] [--seed <n>] [--keep-going] [--keep] [--list]"; exit 2 }
shift
run_name=$(date +%Y%m%d-%H%M%S)-$phase
only="" seed=$(( (RANDOM << 15) | RANDOM )) keep_going=0 keep=0 list=0
while (( $# )); do
  case $1 in
    --run) run_name=$2; shift;;
    --only) only=,$2,; shift;;
    --seed) seed=$2; shift;;
    --keep-going) keep_going=1;;
    --keep) keep=1;;
    --list) list=1;;
    *) print -u2 "unknown option $1"; exit 2;;
  esac
  shift
done
export NTP_ACCEPTANCE=$seed
# The Simulator the UI journeys run on, by name; NTP_ACCEPTANCE_IPHONE overrides the default.
iphone=${NTP_ACCEPTANCE_IPHONE:-iPhone 18 Pro}

# name|what|command (run in the repository root; $run, $binary, $web, $go and $iphone are set)
rows=(
  "candidate|The release candidate: the pinned server with the pinned web client|zsh Tools/ntp-server.sh --with-web && zsh Tools/ntp-server.sh --web-copy && \$binary --version"
  "hub|The hub's own tests (proxy modes, publisher, bridge, transplant, lifecycle with the candidate)|python3 -m unittest discover -s TestSupport/Servers/hub/tests -t TestSupport/Servers -v"
  "server|Server: make check build cross-build media-acceptance on the candidate's source|rm -rf \$run/server-src && cp -c -R \${binary:h}/src \$run/server-src && make -C \$run/server-src check build cross-build media-acceptance GO=\$go"
  "web-check|Web: npm run check in the pinned web copy|cd \$web && npm run check"
  "web-journeys|Web: journeys, player and layout suites on the candidate|cd \$web && NTP_SERVER_BINARY=\$binary npm run journeys && NTP_SERVER_BINARY=\$binary npm run player && NTP_SERVER_BINARY=\$binary npm run layout"
  "ios-parser-latency|iOS parser latency in a quiet host slot, with its existing cancellation and memory assertions|Tools/test-host.sh --build-path .work/acceptance-build --filter ParityLatencyTests"
  "ios-pcm-safety|iOS real-time PCM starvation in a quiet host slot, with its existing audio safety assertions|Tools/test-host.sh --build-path .work/acceptance-build --filter PCMRealTimeStarvationTests"
  "ios-host|iOS host: contract vectors, recording, accounts, exchange (scenarios 1-13, 20-23) and the hub smoke against the candidate|NTP_SERVER_BINARY=\$binary Tools/test-host.sh --build-path .work/acceptance-build --filter 'Contract|ServerRecording|ServerAgreement|ServerAccounts|ServerClient|ServerExchange|HubProxySmoke'"
  "ios-journeys|iOS UI journeys on the iPhone: attachment, logout, switching and the hub smoke|Tools/test-fixtures.sh start && xcodebuild test -project NotTennaPod.xcodeproj -scheme NotTennaPod -destination \"platform=iOS Simulator,name=\$iphone\" -derivedDataPath .work/acceptance-build/xcode -parallel-testing-enabled NO -resultBundlePath \$run/ios-journeys.xcresult -only-testing:NotTennaPodUITests/ServerSynchronizationJourneyTests -only-testing:NotTennaPodUITests/LibrarySwitchJourneyTests -only-testing:NotTennaPodUITests/ServerAcceptanceHubSmokeTests"
  "witness|The server witness on the journeys' data directory|curl -sf -m 3600 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18831/server/witness | python3 -c 'import json,sys; e=json.load(sys.stdin); print(e); sys.exit(0 if e.get(\"passed\") else 1)'"
)

# The PROTOCOL §16 scenarios in phase A: where each is evidenced now, or why it is pending. Never a stand-in pass.
matrix=(
  "1|pending|iOS journeys; a cross-client journey"
  "2|pending|a cross-client journey and the server-crash sweep"
  "3|pending|a cross-client journey"
  "4|pending|iOS journeys"
  "5|pending|iOS journeys"
  "6|pending|iOS journeys"
  "7|pending|iOS journeys"
  "8|run|ios-host (ServerExchangeScenarioTests)"
  "8a|pending|iOS journeys"
  "8b|pending|iOS journeys"
  "8c|partial|ios-host with stand-ins; the recorder's rerun needs the iOS journeys"
  "8d|pending|iOS journeys"
  "9|run|ios-host (ServerExchangeScenarioTests)"
  "10|pending|iOS journeys"
  "11|pending|iOS journeys"
  "12|run|ios-host (ServerExchangeScenarioTests)"
  "13|pending|a cross-client journey"
  "14|pending|iOS journeys"
  "15|pending|iOS journeys"
  "16|pending|iOS journeys"
  "17|pending|iOS journeys"
  "17a|pending|iOS journeys"
  "17b|pending|iOS journeys"
  "18|pending|iOS journeys"
  "19|pending|iOS journeys"
  "20|pending|iOS journeys"
  "21|pending|iOS journeys"
  "22|pending|iOS journeys"
  "23|partial|ios-host, ios-journeys (attach journeys); the extension (no media request reaches Pub) is pending"
  "24|pending|a cross-client journey"
  "25|pending|a cross-client journey (R is ready in the hub)"
  "26|pending|iOS journeys"
  "27|run|ios-host (accounts), web-journeys"
  "28|pending|iOS journeys"
  "29|pending|iOS journeys"
  "30|pending|iOS journeys"
  "31|pending|iOS journeys"
  "32|pending|iOS journeys"
  "33|pending|iOS journeys"
  "34|pending|iOS journeys"
  "35|pending|iOS journeys"
  "36|pending|iOS journeys"
  "37|pending|iOS journeys"
  "38|pending|iOS journeys"
  "39|pending|a cross-client journey"
  "40|run|web-journeys (web only)"
  "41|pending|iOS journeys"
  "42|partial|ios-host (the exchange's part); a cross-client journey pending"
  "43|pending|iOS journeys"
  "44|pending|iOS journeys"
  "45|pending|iOS journeys"
  "46|pending|iOS journeys (scenario 46's vectors)"
)

if (( list )); then
  for entry in $rows; do print -r -- "${entry%%|*}: $(cut -d'|' -f2 <<< $entry)"; done
  exit 0
fi

run=$root/.work/acceptance/$run_name
mkdir -p $run
summary=$run/summary.md
load() { sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1" "$2" "$3}' }
binary=$(zsh Tools/ntp-server.sh --with-web 2>$run/candidate-build.log) || { print -u2 "acceptance: the candidate did not build; see $run/candidate-build.log"; exit 1 }
web=$(zsh Tools/ntp-server.sh --web-copy 2>>$run/candidate-build.log) || { print -u2 "acceptance: the web copy failed; see $run/candidate-build.log"; exit 1 }
top=${root%%/.work/*}
go=${NTP_GO:-${NTP_SERVER_CHECKOUT:-${top:h}/NotTennaPod-Server}/.work/toolchains/go/bin/go}
export NTP_HUB_RUN_DIR=$run/hub
ios=$(git rev-parse HEAD)
dirty=$([[ -n $(git status --porcelain --untracked-files=no) ]] && print " (with uncommitted changes)")
grep_pin() { grep -v '^#' TestSupport/Server/$1 | head -1 | tr -d '[:space:]' }

{
  print "# Acceptance run $run_name (phase $phase)"
  print
  print -r -- "- Started: $(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname -s), load average $(load)"
  print -r -- "- iOS: \`$ios\` ($(git rev-parse --abbrev-ref HEAD))$dirty"
  print -r -- "- Server: \`$(grep_pin server-version.txt)\`; web: \`$(grep_pin web-version.txt)\`"
  print -r -- "- Candidate: \`$binary\` ($($binary --version 2>/dev/null))"
  print -r -- "- Seed: NTP_ACCEPTANCE=$seed (rerun with \`Tools/acceptance.sh $phase --seed $seed\`)"
  print
  print "| Row | What | Started | Duration | Load (1, 5, 15 min) | Result |"
  print "| --- | --- | --- | --- | --- | --- |"
} > $summary

failed=0
for entry in $rows; do
  name=${entry%%|*} rest=${entry#*|}
  what=${rest%%|*} command=${rest#*|}
  if [[ -n $only && $only != *,$name,* ]]; then
    print "| $name | $what | | | | not selected (--only) |" >> $summary
    continue
  fi
  if (( failed && !keep_going )); then
    print "| $name | $what | | | | not run (an earlier row failed) |" >> $summary
    continue
  fi
  [[ $name == ios-journeys ]] && print "acceptance: $name runs UI journeys on $iphone (one Simulator; nothing else heavy)"
  print "acceptance: $name ..."
  started=$(date +%H:%M:%S) before=$(load) begin=$SECONDS
  print -r -- "\$ $command" > $run/$name.log
  ( eval $command ) >> $run/$name.log 2>&1
  code=$?
  seconds=$(( SECONDS - begin ))
  result=$([[ $code == 0 ]] && print pass || print "**fail** (exit $code, see $name.log)")
  (( code == 0 )) || failed=1
  print "| $name | $what | $started | $(( seconds / 60 ))m $(( seconds % 60 ))s | $before | $result |" >> $summary
  print "acceptance: $name $result"
done

# The journeys' hub stops with the fixtures (their run registry is this checkout's).
if [[ -z $only || $only == *,ios-journeys,* || $only == *,witness,* ]]; then
  Tools/test-fixtures.sh stop > $run/fixtures-stop.log 2>&1 || failed=1
fi

{
  print
  print "## Clock offsets"
  print
  offsets=""
  [[ -f $run/hub/events.jsonl ]] && offsets=$(python3 TestSupport/Servers/hub/summary.py clock-offsets $run/hub/events.jsonl)
  print -r -- "${offsets:-- none recorded by the journeys' hub, the server's or an app launch's (the hub and ios-host rows start their own servers)}"
  print
  print "## PROTOCOL §16 scenarios in this phase"
  print
  print "| Row | Status | Evidence or what it waits for |"
  print "| --- | --- | --- |"
  for entry in $matrix; do
    print "| ${entry%%|*} | $(cut -d'|' -f2 <<< $entry) | $(cut -d'|' -f3- <<< $entry) |"
  done
  print
  print "Finished $(date '+%Y-%m-%d %H:%M:%S %Z'), load average $(load). Result: $([[ $failed == 0 ]] && print 'every row run passed' || print 'FAILED')."
} >> $summary

if (( failed == 0 && !keep )); then
  rm -rf $run/server-src $run/hub/server/data $run/hub/witness/*/data(N)
fi
print "acceptance: summary in $summary"
exit $failed
