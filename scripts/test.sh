#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/toolchain.sh"
TESTING_PLUGINS="$TOOLCHAIN_USR/lib/swift/host/plugins/testing"
# Current Command Line Tools ship Testing macros separately from the default plugin path.
if [[ -d "$TESTING_PLUGINS" ]]; then
    swift test "${SWIFT_OPTIONS[@]}" --disable-xctest -Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS" "$@"
else
    swift test "${SWIFT_OPTIONS[@]}" --disable-xctest "$@"
fi
