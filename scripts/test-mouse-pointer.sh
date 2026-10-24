#!/bin/bash
# Exercise actual Win32 pointer input in a disposable prefix, in both Windows ABIs.
set -euo pipefail
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /absolute/path/to/wine/bin/wine" >&2
    exit 2
fi
WINE="$1"
if [ ! -x "$WINE" ] || [ ! -x "$(dirname "$WINE")/wineserver" ]; then
    echo "Wine and its adjacent wineserver must be executable." >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=runner-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/runner-common.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicwine-pointer.XXXXXX")"
unset WINEARCH WINEDLLPATH WINEDLLOVERRIDES WINELOADER WINESERVER
export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
cleanup() {
    wineserver_stop "$(dirname "$WINE")/wineserver"
    rm -rf "$WORK"
}
trap cleanup EXIT
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror "$ROOT/Tests/WineMousePointerTests.c" -o "$WORK/pointer64.exe" -luser32
i686-w64-mingw32-gcc -O2 -Wall -Wextra -Werror "$ROOT/Tests/WineMousePointerTests.c" -o "$WORK/pointer32.exe" -luser32
run_with_timeout "$STEP_TIMEOUT" "$WINE" wineboot -u
for bits in 64 32; do
    for enabled in 0 1; do
        run_with_timeout "$STEP_TIMEOUT" "$WINE" "$WORK/pointer$bits.exe" "$enabled"
    done
done
