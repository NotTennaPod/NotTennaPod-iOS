#!/bin/zsh
# Regenerates the parity parse's tables (Sources/NotTennaPodCore/Sync/Parity/ParityTables.swift and
# ParityCJKTables.swift) from the NotTennaPod server pinned in TestSupport/Server/server-version.txt: an archived copy
# of the server (`git archive`, the checkout is never changed) runs Tools/parity-tables/swift_tables_test.go inside
# its internal/feed package with the server's Go toolchain, so the tables are the server's own: Go's Unicode
# properties and case mappings, encoding/xml's name tables, golang.org/x/text's charsets, datezones.go and TagSoup's
# schema. It also writes the charset cases of ParityDecodeTests (Tests/NotTennaPodCoreTests/Fixtures/ParityCharsets.txt):
# the server's own answers. NTP_SERVER_CHECKOUT and NTP_GO override the checkout and the toolchain, as in
# Tools/ntp-server.sh.
set -euo pipefail
root=${0:A:h:h}
top=${root%%/.work/*}
commit=$(grep -v '^#' $root/TestSupport/Server/server-version.txt | head -1 | tr -d '[:space:]')
checkout=${NTP_SERVER_CHECKOUT:-${top:h}/NotTennaPod-Server}
go=${NTP_GO:-$checkout/.work/toolchains/go/bin/go}
[[ -x $go ]] || { print -u2 "parity-tables: no Go toolchain at $go (set NTP_GO)"; exit 1 }
mkdir -p $root/.work
tmp=$(mktemp -d $root/.work/parity-tables.XXXXXX)
trap 'rm -rf $tmp' EXIT
git -C $checkout archive $commit | tar -x -C $tmp
cp $root/Tools/parity-tables/swift_tables_test.go $tmp/internal/feed/zz_swift_tables_test.go
cd $tmp
xtext=$(GOFLAGS=-mod=mod $go list -m -f '{{.Dir}}' golang.org/x/text)
out=$root/Sources/NotTennaPodCore/Sync/Parity
mkdir -p $out
fixtures=$root/Tests/NotTennaPodCoreTests/Fixtures/ParityCharsets.txt
NTP_SWIFT_TABLES_OUT=$out NTP_SWIFT_FIXTURES_OUT=$fixtures NTP_XTEXT_DIR=$xtext NTP_SERVER_COMMIT=$commit GOFLAGS=-mod=mod \
    $go test -count=1 -run '^(TestEmitSwiftTables|TestEmitSwiftCharsetFixtures)$' ./internal/feed/
print "parity-tables: wrote $out/ParityTables.swift and ParityCJKTables.swift, and $fixtures, from server $commit"
