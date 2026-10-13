#!/bin/zsh
# Prints the path of a NotTennaPod server binary, building it first if needed (PROTOCOL §16).
# Everything is built from archived copies (`git archive`), so no checkout is ever changed:
#
#   Tools/ntp-server.sh                       the server pinned in TestSupport/Server/server-version.txt, with the web
#                                             build its own commit carries, into .work/ntp-server/<commit>/ (host tests)
#   Tools/ntp-server.sh --with-web [commit]   the release candidate: the pinned server with the web client pinned in
#                                             TestSupport/Server/web-version.txt (or <commit>) built into
#                                             internal/webui/dist (what the web's install-into-server does), then
#                                             `make build`, into .work/ntp-server/<server>+web-<web>/. The archived
#                                             server source stays beside the binary in src/ (the witness runs there).
#   Tools/ntp-server.sh --web-copy [commit]   prints the archived web copy (built, with node_modules) the web actor
#                                             runs from: .work/ntp-web/<commit>/
#   --commit <sha>                            build an exact server revision instead of the pin
#
# The web copy uses the web checkout's node_modules only when its package-lock.json is the pinned commit's, and fails
# loudly otherwise. NTP_SERVER_CHECKOUT, NTP_WEB_CHECKOUT and NTP_GO override the checkouts and the Go toolchain; by
# default they are the siblings of the outermost checkout (a worktree under <checkout>/.work/ uses its checkout's).
set -euo pipefail
root=${0:A:h:h}
top=${root%%/.work/*}
pinned() { grep -v '^#' $1 | head -1 | tr -d '[:space:]' }
commit=$(pinned $root/TestSupport/Server/server-version.txt)
mode=server
web_commit=""
while (( $# )); do
  case $1 in
    --with-web|--web-copy)
      mode=${1#--}
      if (( $# > 1 )) && [[ $2 != --* ]]; then web_commit=$2; shift; fi;;
    --commit) (( $# > 1 )) || { print -u2 "ntp-server: --commit needs a commit"; exit 2 }; commit=$2; shift;;
    *) print -u2 "usage: $0 [--with-web [commit] | --web-copy [commit]] [--commit <sha>]"; exit 2;;
  esac
  shift
done
[[ -n $web_commit ]] || web_commit=$(pinned $root/TestSupport/Server/web-version.txt)
checkout=${NTP_SERVER_CHECKOUT:-${top:h}/NotTennaPod-Server}
web_checkout=${NTP_WEB_CHECKOUT:-${top:h}/NotTennaPod-Web}
go=${NTP_GO:-$checkout/.work/toolchains/go/bin/go}
mkdir -p $root/.work
tmp=""
trap '[[ -n $tmp ]] && rm -rf $tmp' EXIT

need_server() {
  [[ -e $checkout/.git ]] || { print -u2 "ntp-server: no server checkout at $checkout (set NTP_SERVER_CHECKOUT)"; exit 1 }
  [[ -x $go ]] || { print -u2 "ntp-server: no Go toolchain at $go (set NTP_GO)"; exit 1 }
  git -C $checkout cat-file -e "$commit^{commit}" 2>/dev/null || { print -u2 "ntp-server: $checkout has no commit $commit"; exit 1 }
}

# The archived web copy, built, with the checkout's node_modules when the lockfiles match.
web_copy() {
  local web=$root/.work/ntp-web/$web_commit
  if [[ -f $web/.ready ]]; then print -r -- $web; return; fi
  [[ -e $web_checkout/.git ]] || { print -u2 "ntp-server: no web checkout at $web_checkout (set NTP_WEB_CHECKOUT)"; exit 1 }
  git -C $web_checkout cat-file -e "$web_commit^{commit}" 2>/dev/null || { print -u2 "ntp-server: $web_checkout has no commit $web_commit"; exit 1 }
  mkdir -p $root/.work/ntp-web
  tmp=$(mktemp -d $root/.work/ntp-web/build.XXXXXX)
  git -C $web_checkout archive $web_commit | tar -x -C $tmp
  if ! cmp -s $tmp/package-lock.json $web_checkout/package-lock.json; then
    print -u2 "ntp-server: the web checkout's package-lock.json ($web_checkout) is not web commit $web_commit's;"
    print -u2 "ntp-server: its node_modules cannot be used. Check out a commit with that lockfile there and run npm ci."
    exit 1
  fi
  [[ -d $web_checkout/node_modules/@playwright/test && -d $web_checkout/node_modules/esbuild ]] || {
    print -u2 "ntp-server: $web_checkout/node_modules is incomplete; run npm ci there"; exit 1 }
  cp -c -R $web_checkout/node_modules $tmp/node_modules 2>/dev/null || cp -R $web_checkout/node_modules $tmp/node_modules
  (cd $tmp && node scripts/build.mjs) >&2
  rm -rf $web
  mv $tmp $web
  tmp=""
  touch $web/.ready
  print -r -- $web
}

case $mode in
  web-copy)
    web_copy;;
  with-web)
    out=$root/.work/ntp-server/$commit+web-$web_commit
    binary=$out/nottennapod-server
    if [[ -x $binary ]]; then print -r -- $binary; exit 0; fi
    need_server
    web=$(web_copy)
    mkdir -p $root/.work/ntp-server
    tmp=$(mktemp -d $root/.work/ntp-server/build.XXXXXX)
    mkdir $tmp/src
    git -C $checkout archive $commit | tar -x -C $tmp/src
    # What the web's install-into-server does, into the archived copy.
    NTP_SERVER=$tmp/src node $web/scripts/install-into-server.mjs >&2
    make -C $tmp/src build GO=$go VERSION=${commit[1,12]}+web-${web_commit[1,12]} >&2
    mv $tmp/src/.work/bin/nottennapod-server $tmp/nottennapod-server
    rm -rf $tmp/src/.work $out
    mv $tmp $out
    tmp=""
    print -r -- $binary;;
  server)
    out=$root/.work/ntp-server/$commit
    binary=$out/nottennapod-server
    if [[ -x $binary ]]; then print -r -- $binary; exit 0; fi
    need_server
    tmp=$(mktemp -d $root/.work/ntp-server-build.XXXXXX)
    git -C $checkout archive $commit | tar -x -C $tmp
    (cd $tmp && $go build -o $tmp/nottennapod-server ./cmd/nottennapod-server) >&2
    mkdir -p $out
    mv $tmp/nottennapod-server $binary
    print -r -- $binary;;
esac
