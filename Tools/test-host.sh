#!/bin/zsh
# Quiet host validation, synchronized with contract resync and fixture launch.
# Forward swift-test arguments while enforcing --no-parallel and exact Package.resolved restoration.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
build_arguments=(--build-path .work/host-build)
for argument in "$@"; do
  [[ $argument != --parallel ]] || { print -u2 'test-host: --parallel conflicts with the required quiet host run'; exit 2; }
  [[ $argument != --build-path && $argument != --build-path=* ]] || build_arguments=()
done
exec python3 Tools/validation-lock.py --kind host --restore-package-resolved -- \
  xcrun swift test --package-path . "${build_arguments[@]}" --no-parallel "$@"
