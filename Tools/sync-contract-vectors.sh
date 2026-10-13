#!/bin/sh
# Copies the shared contract vectors the host tests use from a NotTennaPod-Server checkout into
# TestSupport/Contract/vectors, with the server commit and a SHA256SUMS manifest.
#
#   Tools/sync-contract-vectors.sh [--check] [server-checkout]
#
# The server checkout defaults to ../NotTennaPod-Server beside this repository. With --check nothing is
# copied: it fails if a copy differs from the server's file or from the manifest.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
if python3 "$root/Tools/validation-lock.py" --verify; then
    :
elif [ "${1:-}" = "--check" ] && python3 "$root/Tools/validation-lock.py" --verify-readonly; then
    # The host's existing --check helper uses Foundation Process, which can close extra descriptors.
    # Its authenticated live ancestor still holds the lock; mutation never takes this branch.
    :
else
    exec python3 "$root/Tools/validation-lock.py" --kind sync -- /bin/sh "$0" "$@"
fi

check=0
if [ "${1:-}" = "--check" ]; then
    check=1
    shift
fi
# The sibling of the outermost checkout (a worktree under <checkout>/.work/ uses its checkout's), as Tools/ntp-server.sh.
top=${root%%/.work/*}
server=${1:-"${NTP_SERVER_CHECKOUT:-$top/../NotTennaPod-Server}"}
server=$(cd "$server" && pwd)
source="$server/contract/vectors"
destination="$root/TestSupport/Contract/vectors"

# The contract suites the host tests use (PROTOCOL §15.1) and the feed parser vectors.
# mac and time_normalization are server-only and not copied. The rule vectors are below.
suites="canonical_json causal_order content_hash cursor digest_chain guid ids length_prefixed parts
queue_between queue_compare queue_parse queue_sort strip_userinfo url"

files=""
for suite in $suites; do files="$files $suite.json"; done
files="$files feed_values.json feed_date_symbols.json"
for path in "$source"/feeds/*; do files="$files feeds/$(basename "$path")"; done

# The rule vectors the record applier projects (episode.leave, PROTOCOL §8.4), in TestSupport/Contract/rules,
# taken from the server commit the host agreement tests run against (TestSupport/Server/server-version.txt), so the
# projection is checked against the fold of the server the tests use.
rules="rules_episode_leave"
pinned=$(grep -v '^#' "$root/TestSupport/Server/server-version.txt" | tr -d '[:space:]')
rules_destination="$root/TestSupport/Contract/rules"
rules_status=0
for suite in $rules; do
    if [ "$check" -eq 1 ]; then
        if ! (cd "$server" && git show "$pinned:contract/vectors/$suite.json") | cmp -s - "$rules_destination/$suite.json"; then
            echo "differs from the server at $pinned: rules/$suite.json"; rules_status=1
        fi
    else
        mkdir -p "$rules_destination"
        (cd "$server" && git show "$pinned:contract/vectors/$suite.json") > "$rules_destination/$suite.json"
    fi
done
if [ "$check" -eq 1 ]; then
    if ! (cd "$rules_destination" && shasum -a 256 -c --quiet SHA256SUMS); then
        echo "the rule vectors differ from TestSupport/Contract/rules/SHA256SUMS"; rules_status=1
    fi
else
    (cd "$rules_destination" && for suite in $rules; do shasum -a 256 "$suite.json"; done > SHA256SUMS)
    echo "$pinned" > "$rules_destination/server-commit.txt"
fi

if [ "$check" -eq 1 ]; then
    status=$rules_status
    for file in $files; do
        if [ ! -f "$destination/$file" ]; then
            echo "missing copy: $file"; status=1
        elif ! cmp -s "$source/$file" "$destination/$file"; then
            echo "differs from the server: $file"; status=1
        fi
    done
    for path in "$destination"/*.json "$destination"/feeds/*; do
        file=${path#"$destination/"}
        if [ ! -f "$source/$file" ]; then echo "not in the server: $file"; status=1; fi
    done
    if ! (cd "$destination" && shasum -a 256 -c --quiet ../SHA256SUMS); then
        echo "the copies differ from TestSupport/Contract/SHA256SUMS"; status=1
    fi
    if [ "$status" -eq 0 ]; then echo "contract vectors match $server"; fi
    exit "$status"
fi

# Copy only committed vectors, so the recorded commit describes them.
changed=$(cd "$server" && git status --porcelain -- $(for file in $files; do printf 'contract/vectors/%s ' "$file"; done))
if [ -n "$changed" ]; then
    echo "the server's vectors have uncommitted changes:"; echo "$changed"; exit 1
fi
rm -rf "$destination"
mkdir -p "$destination/feeds"
for file in $files; do cp "$source/$file" "$destination/$file"; done
(cd "$destination" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > ../SHA256SUMS)
(cd "$server" && git rev-parse HEAD) > "$root/TestSupport/Contract/server-commit.txt"
echo "copied $(echo "$files" | wc -w | tr -d ' ') files from $server at $(cat "$root/TestSupport/Contract/server-commit.txt")"
