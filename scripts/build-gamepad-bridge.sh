#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the original MagicWine XInput bridge, not proprietary controller DLLs.
# Run: bash scripts/build-gamepad-bridge.sh
# Prerequisites on macOS: brew install mingw-w64 python
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPONENT=magicwine-xinput-v1
OUTPUT="$ROOT/Sources/MagicWineCore/Resources"
export SOURCE_DATE_EPOCH=1768262400
export LC_ALL=C TZ=UTC COPYFILE_DISABLE=1
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS AR LD STRIP
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH

missing=()
for tool in python3 x86_64-w64-mingw32-gcc x86_64-w64-mingw32-strip i686-w64-mingw32-gcc i686-w64-mingw32-strip; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -ne 0 ]]; then
    printf 'Missing prerequisites: %s\nInstall with: brew install mingw-w64 python\n' "${missing[*]}" >&2
    exit 1
fi
mkdir -p "$ROOT/.local" "$OUTPUT"
WORK="$(mktemp -d "$ROOT/.local/gamepad-bridge-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/Sources/GamepadBridge/"* "$WORK/"
for arch in i686 x86_64; do
    compiler="$arch-w64-mingw32-gcc"
    "$compiler" --version
    (
        cd "$WORK"
        "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -shared -static-libgcc \
            -fno-ident -ffile-prefix-map="$ROOT"=. -ffile-prefix-map="$WORK"=. \
            -Wl,--no-insert-timestamp,--dynamicbase,--nxcompat,--kill-at,--enable-stdcall-fixup,--exclude-all-symbols \
            xinput.c xinput.def -o "$COMPONENT-$arch.dll"
        "$arch-w64-mingw32-strip" --strip-unneeded "$COMPONENT-$arch.dll"
    )
done

# An offline, deterministic corresponding-source distribution includes the
# original sources, this exact build recipe and the repository GPL license.
python3 - "$ROOT" "$WORK" "$COMPONENT" <<'PY'
import gzip
import hashlib
import io
import os
from pathlib import Path
import struct
import sys
import tarfile

root, work = map(Path, sys.argv[1:3])
component = sys.argv[3]
epoch = int(os.environ['SOURCE_DATE_EPOCH'])
for arch, machine in [('i686', 0x014c), ('x86_64', 0x8664)]:
    path = work / f'{component}-{arch}.dll'
    data = path.read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[:2] != b'MZ' or data[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', data, pe+4)[0] != machine:
        raise SystemExit(f'Unexpected PE architecture: {path}')
files = sorted([*root.joinpath('Sources/GamepadBridge').glob('*'),
                root / 'scripts/build-gamepad-bridge.sh', root / 'LICENSE'])
archive = work / f'{component}-source.tar.gz'
with archive.open('wb') as raw:
    with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=epoch) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as tar:
            for path in files:
                if not path.is_file() or path.is_symlink():
                    raise SystemExit(f'Unexpected source input: {path}')
                data = path.read_bytes()
                info = tarfile.TarInfo(f'{component}-source/{path.relative_to(root)}')
                info.size = len(data)
                info.mode = 0o755 if path.suffix == '.sh' else 0o644
                info.mtime = epoch
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                tar.addfile(info, io.BytesIO(data))
license_path = work / 'LICENSE-MAGICWINE-GAMEPAD.txt'
license_path.write_bytes((root / 'LICENSE').read_bytes())
for path in [work / f'{component}-i686.dll', work / f'{component}-x86_64.dll', archive, license_path]:
    print(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}')
PY
for name in "$COMPONENT-i686.dll" "$COMPONENT-x86_64.dll" "$COMPONENT-source.tar.gz" LICENSE-MAGICWINE-GAMEPAD.txt; do
    mv "$WORK/$name" "$OUTPUT/$name"
done
printf '\nPayloads written to %s\nIndependently pin their SHA-256 values in GamepadBridge.swift before shipping.\n' "$OUTPUT"
