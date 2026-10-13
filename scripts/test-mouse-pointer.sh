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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicwine-pointer.XXXXXX")"
unset WINEARCH WINEDLLPATH WINEDLLOVERRIDES WINELOADER WINESERVER
export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
cleanup() {
    "$(dirname "$WINE")/wineserver" -k || true
    rm -rf "$WORK"
}
trap cleanup EXIT
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra "$ROOT/Tests/WineMousePointerTests.c" -o "$WORK/pointer64.exe" -luser32
i686-w64-mingw32-gcc -O2 -Wall -Wextra "$ROOT/Tests/WineMousePointerTests.c" -o "$WORK/pointer32.exe" -luser32
"$WINE" wineboot -u
for bits in 64 32; do
    for enabled in 0 1; do
        "$WINE" "$WORK/pointer$bits.exe" "$enabled"
    done
done
