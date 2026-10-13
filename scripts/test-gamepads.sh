#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise the real native XInput APIs in both Windows ABIs without physical hardware.
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /absolute/path/to/wine/bin/wine" >&2
    exit 2
fi
WINE="$1"
SERVER="$(dirname "$WINE")/wineserver"
if [[ ! -x "$WINE" || ! -x "$SERVER" ]]; then
    echo "Wine and its adjacent wineserver must be executable." >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicwine-gamepad.XXXXXX")"
unset WINEARCH WINEDLLPATH WINEDLLOVERRIDES WINELOADER WINESERVER
export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
cleanup() {
    "$SERVER" -k || true
    rm -rf "$WORK"
}
trap cleanup EXIT
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror "$ROOT/Tests/WineGamepadTests.c" -o "$WORK/gamepad64.exe"
i686-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror "$ROOT/Tests/WineGamepadTests.c" -o "$WORK/gamepad32.exe"
"$WINE" wineboot -u
for name in xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0; do
    cp "$ROOT/Sources/MagicWineCore/Resources/magicwine-xinput-v1-x86_64.dll" "$WINEPREFIX/drive_c/windows/system32/$name.dll"
    cp "$ROOT/Sources/MagicWineCore/Resources/magicwine-xinput-v1-i686.dll" "$WINEPREFIX/drive_c/windows/syswow64/$name.dll"
done
export WINEDLLOVERRIDES='xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=n'
"$WINE" "$WORK/gamepad64.exe"
"$WINE" "$WORK/gamepad32.exe"
