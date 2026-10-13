#!/bin/bash
# Copyright 2026 MagicWine contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercise each backend's Windows ABIs through real graphics installation/launch.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 /absolute/path/to/magicwine /absolute/path/to/wine dxmt|d3dmetal [--visual]" >&2
    exit 2
fi
CLI="$1"
WINE="$2"
BACKEND="$3"
if [[ ! -x "$CLI" || ! -x "$WINE" || "$CLI" != /* || "$WINE" != /* ||
      ( "$BACKEND" != dxmt && "$BACKEND" != d3dmetal ) ||
      ( $# -eq 4 && "$4" != --visual ) ]]; then
    echo "Executable paths must be absolute; select dxmt or d3dmetal." >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicwine-remote-presentation.XXXXXX")"
BOTTLE=""
cleanup() {
    status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$WORK"/library/Logs/*.log; do
            [[ -f "$log" ]] || continue
            printf '\nFailure log: %s\n' "$log"
            cat "$log"
        done
    fi
    if [[ -n "$BOTTLE" ]]; then "$CLI" --root "$WORK/library" stop "$BOTTLE" || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
x86_64-w64-mingw32-g++ -O2 -Wall -Wextra -Werror -static "$ROOT/Tests/WineRemotePresentationTests.cpp" \
    -o "$WORK/remote64.exe" -ld3d11 -ldxgi -ldxguid
# D3DMetal supplies only x86_64 modules; its i386 path is WineD3D, not Metal.
BITS=(64)
if [[ "$BACKEND" == dxmt ]]; then
    i686-w64-mingw32-g++ -O2 -Wall -Wextra -Werror -static "$ROOT/Tests/WineRemotePresentationTests.cpp" \
        -o "$WORK/remote32.exe" -ld3d11 -ldxgi -ldxguid
    BITS+=(32)
fi
CREATED="$("$CLI" --root "$WORK/library" create "Remote presentation regression" "$WINE")"
printf '%s\n' "$CREATED"
if [[ "$CREATED" =~ Bottle:\ ([0-9A-Fa-f-]+) ]]; then
    BOTTLE="${BASH_REMATCH[1]}"
else
    echo "No bottle identifier returned." >&2
    exit 1
fi
"$CLI" --root "$WORK/library" graphics "$BOTTLE" "$BACKEND" --accept-experimental
for bits in "${BITS[@]}"; do
    if [[ $# -eq 4 ]]; then
        "$CLI" --root "$WORK/library" exec "$BOTTLE" "$WORK/remote$bits.exe" --visual
    else
        "$CLI" --root "$WORK/library" exec "$BOTTLE" "$WORK/remote$bits.exe"
    fi
done
