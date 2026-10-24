#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the original MagicWine XInput bridge, not proprietary controller DLLs.
# Run: bash scripts/build-gamepad-bridge.sh
# Prerequisites on macOS: brew install mingw-w64 python
#
# Current sources are MIT. The checked-in magicwine-xinput-v1 payload is the
# historical GPL-3.0-or-later build whose bytes are pinned in GamepadBridge.swift
# and validated in existing bottles, so this recipe never writes to those names.
# Output goes to a gitignored staging directory under a NEW component identity
# (default magicwine-xinput-v2); adopting it is a separate, explicit step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPONENT="${COMPONENT:-magicwine-xinput-v2}"
OUTPUT="$ROOT/.local/gamepad-bridge-output/$COMPONENT"
LICENSE_NAME="LICENSE-$COMPONENT.txt"
export SOURCE_DATE_EPOCH=1768262400
export LC_ALL=C TZ=UTC COPYFILE_DISABLE=1
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS AR LD STRIP
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH

if [[ "$COMPONENT" == magicwine-xinput-v1 ]]; then
    printf 'Refusing COMPONENT=magicwine-xinput-v1: that identity is the pinned historical GPL payload under Sources/MagicWineCore/Resources.\nUse a new identity such as magicwine-xinput-v2.\n' >&2
    exit 1
fi
if [[ ! "$COMPONENT" =~ ^magicwine-xinput-v[0-9]+$ ]]; then
    printf 'COMPONENT must look like magicwine-xinput-v<N> (got "%s").\n' "$COMPONENT" >&2
    exit 1
fi
if [[ -e "$OUTPUT" ]]; then
    printf 'Refusing to overwrite existing output: %s\nMove or delete it first, or choose a new COMPONENT.\n' "$OUTPUT" >&2
    exit 1
fi

missing=()
for tool in python3 x86_64-w64-mingw32-gcc x86_64-w64-mingw32-strip i686-w64-mingw32-gcc i686-w64-mingw32-strip; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -ne 0 ]]; then
    printf 'Missing prerequisites: %s\nInstall with: brew install mingw-w64 python\n' "${missing[*]}" >&2
    exit 1
fi
mkdir -p "$ROOT/.local"
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
# original sources, this exact build recipe and the repository MIT license.
python3 - "$ROOT" "$WORK" "$COMPONENT" "$LICENSE_NAME" <<'PY'
import gzip
import hashlib
import io
import os
from pathlib import Path
import struct
import sys
import tarfile

root, work = map(Path, sys.argv[1:3])
component, license_name = sys.argv[3:5]
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
license_path = work / license_name
license_path.write_bytes((root / 'LICENSE').read_bytes())
for path in [work / f'{component}-i686.dll', work / f'{component}-x86_64.dll', archive, license_path]:
    print(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}')
PY
mkdir -p "$ROOT/.local/gamepad-bridge-output"
mkdir "$OUTPUT"
for name in "$COMPONENT-i686.dll" "$COMPONENT-x86_64.dll" "$COMPONENT-source.tar.gz" "$LICENSE_NAME"; do
    mv -n "$WORK/$name" "$OUTPUT/$name"
done
cat <<EOF

Staged $COMPONENT payloads (not installed) in:
  $OUTPUT

Nothing under Sources/MagicWineCore/Resources was touched; the pinned
magicwine-xinput-v1 files and LICENSE-MAGICWINE-GAMEPAD.txt are unchanged.

To adopt this build as a new component, as one deliberate change:
  1. Compare the hashes above with an independent rebuild.
  2. Copy the four files into Sources/MagicWineCore/Resources and list them
     in the Package.swift resources.
  3. Add $COMPONENT with new SHA-256 pins, backup directory name and license
     file to GamepadBridge.swift; keep magicwine-xinput-v1 pins and migration
     paths for existing bottles.
  4. Update THIRD_PARTY_NOTICES.md, docs/controllers.md and tests, then run
     ./scripts/test.sh.
EOF
