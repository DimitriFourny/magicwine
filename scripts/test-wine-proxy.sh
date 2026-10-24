#!/bin/bash
# Copyright 2026 MagicWine contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise WinHTTP without changing host network settings.
set -euo pipefail

usage() {
    echo "Usage: $0 /absolute/path/to/wine/bin/wine [--expect-disabled]" >&2
    echo "       $0 --native /patched/wine/source /configured/wine/build" >&2
    exit 2
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=runner-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/runner-common.sh"

if [ "${1:-}" = --native ]; then
    [ "$#" -eq 3 ] || usage
    SOURCE="$2"
    BUILD="$3"
    if [ ! -f "$SOURCE/dlls/winhttp/unixlib.c" ] || [ ! -f "$BUILD/include/config.h" ]; then
        echo "Native tests require the patched Wine source and a configured build tree." >&2
        exit 2
    fi
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicwine-proxy-native.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    xcrun clang -arch x86_64 -O2 -Wall -Wextra -fshort-wchar \
        -D__WINESRC__ -DWINE_UNIX_LIB -D_WIN64 \
        -I"$BUILD/include" -I"$SOURCE/include" -I"$SOURCE/dlls/winhttp" \
        "$ROOT/Tests/WineProxyPolicyTests.c" -o "$WORK/proxy-policy" \
        -framework SystemConfiguration -framework CoreFoundation
    arch -x86_64 "$WORK/proxy-policy"
    exit
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then usage; fi
WINE="$1"
if [ "$#" -eq 2 ] && [ "$2" != --expect-disabled ]; then usage; fi
case "$WINE" in /*) ;; *) usage ;; esac
if [ ! -x "$WINE" ] || [ ! -x "$(dirname "$WINE")/wineserver" ]; then
    echo "Wine and its adjacent wineserver must be executable." >&2
    exit 2
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicwine-proxy.XXXXXX")"
unset WINEARCH WINEDLLPATH WINEDLLOVERRIDES WINELOADER WINESERVER
export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
cleanup() {
    wineserver_stop "$(dirname "$WINE")/wineserver"
    rm -rf "$WORK"
}
trap cleanup EXIT
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror "$ROOT/Tests/WineProxyTests.c" \
    -o "$WORK/proxy64.exe" -lwinhttp -lws2_32
i686-w64-mingw32-gcc -O2 -Wall -Wextra -Werror "$ROOT/Tests/WineProxyTests.c" \
    -o "$WORK/proxy32.exe" -lwinhttp -lws2_32
run_with_timeout "$STEP_TIMEOUT" "$WINE" wineboot -u
for bits in 64 32; do
    if [ "$#" -eq 2 ]; then
        run_with_timeout "$STEP_TIMEOUT" "$WINE" "$WORK/proxy$bits.exe" --expect-disabled
    else
        run_with_timeout "$STEP_TIMEOUT" "$WINE" "$WORK/proxy$bits.exe"
    fi
done
