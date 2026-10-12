#!/bin/bash
# Build the public macOS DXVK fork with MagicWine's query-capability fix.
# Run: bash scripts/build-dxvk.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.10.3-magicwine.1"
COMPONENT="dxvk-macos-$VERSION"
COMMIT="8f1e28deed3ad30802f7e1bdff428ec14e6e7817"
SOURCE_URL="https://codeload.github.com/Gcenx/DXVK-macOS/tar.gz/$COMMIT"
SOURCE_SHA256="b3fc4a0415b3e4cdfb40497bec191c10f183ec2eb498950aa1f638f176cb996b"
SOURCE_ARCHIVE="$ROOT/.local/dxvk-magicwine-source.tar.gz"
PATCH="$ROOT/patches/dxvk-pipeline-statistics.patch"
OUTPUT="$ROOT/Sources/MagicWineCore/Resources/$COMPONENT.tar.gz"
# Fixed release-day epoch for compiler macros and archive headers.
export SOURCE_DATE_EPOCH=1683417600
export LC_ALL=C
export TZ=UTC
export COPYFILE_DISABLE=1

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'This script requires macOS and native Homebrew cross-compilers.\n' >&2
  exit 1
fi
missing=()
for tool in curl tar patch python3 meson ninja glslangValidator; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
for triplet in i686-w64-mingw32 x86_64-w64-mingw32; do
  for suffix in gcc g++ ar strip windres ld; do
    command -v "$triplet-$suffix" >/dev/null 2>&1 || missing+=("$triplet-$suffix")
  done
done
if [[ ${#missing[@]} -ne 0 ]]; then
  printf 'Missing prerequisites: %s\n' "${missing[*]}" >&2
  printf 'Install with: brew install mingw-w64 meson ninja glslang python\n' >&2
  exit 1
fi

# Do not silently inherit another toolchain or Wine build configuration.
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS AR LD STRIP
unset WINEARCH WINEPREFIX
mkdir -p "$ROOT/.local" "$(dirname "$OUTPUT")"
WORK="$(mktemp -d "$ROOT/.local/dxvk-magicwine-build.XXXXXX")"
DOWNLOAD=""
trap 'if [[ -n "$DOWNLOAD" ]]; then rm -f "$DOWNLOAD"; fi' EXIT

verify_source() {
  python3 - "$1" "$SOURCE_SHA256" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
actual = hashlib.sha256(path.read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit(f"Source SHA-256 mismatch: {path}\nExpected: {sys.argv[2]}\nActual:   {actual}")
PY
}

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  DOWNLOAD="$(mktemp "$ROOT/.local/dxvk-magicwine-source.XXXXXX")"
  curl --fail --location --proto '=https' --tlsv1.2 "$SOURCE_URL" -o "$DOWNLOAD"
  verify_source "$DOWNLOAD"
  mv "$DOWNLOAD" "$SOURCE_ARCHIVE"
  DOWNLOAD=""
fi
verify_source "$SOURCE_ARCHIVE"
tar -xzf "$SOURCE_ARCHIVE" -C "$WORK"
SRC="$WORK/DXVK-macOS-$COMMIT"
patch --batch --forward -p1 -d "$SRC" < "$PATCH"
PAYLOAD="$WORK/$COMPONENT"
mkdir -p "$PAYLOAD/x32" "$PAYLOAD/x64"
cp "$SRC/dxvk.conf" "$PAYLOAD/dxvk.conf"

# Keep provenance outside the tightly allowlisted runtime archive.
python3 - "$WORK/provenance.json" "$SOURCE_URL" "$COMMIT" "$SOURCE_SHA256" \
  "$PATCH" "$ROOT/scripts/build-dxvk.sh" "$SRC" "$VERSION" <<'PY'
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess
import sys

def version(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
    return result.stdout.strip()

tools = {}
for name in ('meson', 'ninja', 'glslangValidator', 'python3'):
    tools[name] = {'path': shutil.which(name), 'version': version([name, '--version'])}
for triplet in ('i686-w64-mingw32', 'x86_64-w64-mingw32'):
    for suffix in ('gcc', 'g++', 'ar', 'strip', 'windres', 'ld'):
        name = f'{triplet}-{suffix}'
        tools[name] = {'path': shutil.which(name), 'version': version([name, '-v' if suffix in ('gcc', 'g++') else '--version'])}
source = pathlib.Path(sys.argv[7])
metadata = {
    'version': sys.argv[8],
    'source': {'repository': 'https://github.com/Gcenx/DXVK-macOS', 'url': sys.argv[2], 'commit': sys.argv[3], 'sha256': sys.argv[4]},
    'patch': {'path': sys.argv[5], 'sha256': hashlib.sha256(pathlib.Path(sys.argv[5]).read_bytes()).hexdigest()},
    'script': {'path': sys.argv[6], 'sha256': hashlib.sha256(pathlib.Path(sys.argv[6]).read_bytes()).hexdigest()},
    'host': platform.platform(),
    'tools': tools,
    'source_date_epoch': 1683417600,
    'meson_options': ['--buildtype=release', '--strip', '-Dbuild_id=false', '-Denable_dxgi=false', '-Denable_d3d9=false', '-Denable_d3d10=true', '-Denable_d3d11=true', '-Dc_link_args=-Wl,--no-insert-timestamp', '-Dcpp_link_args=-Wl,--no-insert-timestamp'],
    'crossfiles': {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in ('build-win32.txt', 'build-win64.txt')},
    'targets': ['src/d3d10/d3d10core.dll', 'src/d3d11/d3d11.dll'],
    'build_directory': str(source.parent),
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(metadata, indent=2) + '\n')
PY

# Use upstream MinGW crossfiles and release options, but leave DXGI builtin.
# Explicit targets avoid unrelated DLLs and any Wine executable runner.
for bits in 64 32; do
  if [[ "$bits" == 64 ]]; then
    triplet=x86_64-w64-mingw32
  else
    triplet=i686-w64-mingw32
  fi
  BUILD="$WORK/build.$bits"
  meson setup "$BUILD" "$SRC" \
    --cross-file "$SRC/build-win$bits.txt" \
    --buildtype release --strip --prefix "$PAYLOAD" \
    --bindir "x$bits" --libdir "x$bits" \
    -Dbuild_id=false -Denable_dxgi=false -Denable_d3d9=false \
    -Denable_d3d10=true -Denable_d3d11=true \
    -Dc_link_args=-Wl,--no-insert-timestamp \
    -Dcpp_link_args=-Wl,--no-insert-timestamp 2>&1 | tee "$WORK/setup.$bits.log"
  ninja -C "$BUILD" src/d3d10/d3d10core.dll src/d3d11/d3d11.dll \
    2>&1 | tee "$WORK/build.$bits.log"
  for dll in d3d10core d3d11; do
    if [[ "$dll" == d3d10core ]]; then
      built="$BUILD/src/d3d10/$dll.dll"
    else
      built="$BUILD/src/d3d11/$dll.dll"
    fi
    cp "$built" "$PAYLOAD/x$bits/$dll.dll"
    "$triplet-strip" --strip-unneeded "$PAYLOAD/x$bits/$dll.dll"
  done
done

# Write only the contract members, with fixed ownership, modes and timestamps.
# Python's native tar/gzip avoids requiring GNU tar on macOS; gzip has no filename.
python3 - "$PAYLOAD" "$OUTPUT" "$WORK/provenance.json" <<'PY'
import gzip
import hashlib
import json
import os
import pathlib
import tarfile
import tempfile
import sys

payload = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
provenance = pathlib.Path(sys.argv[3])
files = ('dxvk.conf', 'x32/d3d10core.dll', 'x32/d3d11.dll', 'x64/d3d10core.dll', 'x64/d3d11.dll')
hashes = {name: hashlib.sha256((payload / name).read_bytes()).hexdigest() for name in files}
fd, temporary = tempfile.mkstemp(prefix=output.name + '.', dir=output.parent)
try:
    with os.fdopen(fd, 'wb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name in ('', 'x32', 'x64', *files):
                    member = tarfile.TarInfo(payload.name + ('/' + name if name else ''))
                    member.uid = member.gid = 0
                    member.uname = member.gname = 'root'
                    member.mtime = 1683417600
                    if name in files:
                        member.type = tarfile.REGTYPE
                        member.mode = 0o644
                        member.size = (payload / name).stat().st_size
                        with (payload / name).open('rb') as data:
                            archive.addfile(member, data)
                    else:
                        member.type = tarfile.DIRTYPE
                        member.mode = 0o755
                        archive.addfile(member)
    os.chmod(temporary, 0o644)
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
archive_hash = hashlib.sha256(output.read_bytes()).hexdigest()
metadata = json.loads(provenance.read_text())
metadata['archive'] = {'path': str(output), 'sha256': archive_hash}
metadata['payload_sha256'] = hashes
provenance.write_text(json.dumps(metadata, indent=2) + '\n')
print(f'Archive: {output}\nArchive SHA256: {archive_hash}')
for name, digest in hashes.items():
    print(f'Payload SHA256: {digest}  {name}')
print(f'Provenance: {provenance}')
print(f'Build logs and source retained: {payload.parent}')
PY
