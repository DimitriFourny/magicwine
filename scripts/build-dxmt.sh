#!/bin/bash
# Source-built DXMT remote consumer. No runtime Wine is installed or modified.
# 1. bash scripts/build-dxmt.sh --fetch       (cache public, SHA-256-pinned inputs)
# 2. bash scripts/build-dxmt.sh --lock-tools  (freeze local Apple SDK/compiler tools)
# 3. bash scripts/build-dxmt.sh              (offline build; requires frozen tools)
# WINE_BUILD selects the read-only MagicWine .4 development build.
# Outputs: runtime/source/provenance resources and independently compiled Swift pins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MAGICWINE_DXMT_ROOT="$ROOT"
exec python3 - "$@" <<'PY'
import argparse, gzip, hashlib, io, json, os, pathlib, shutil, subprocess, sys, tarfile, tempfile, urllib.request

ROOT = pathlib.Path(os.environ['MAGICWINE_DXMT_ROOT'])
CACHE = pathlib.Path(os.environ.get('DXMT_INPUTS', ROOT / 'inputs' if (ROOT / 'inputs').is_dir() else ROOT / '.local'))
RES = ROOT / 'Sources/MagicWineCore/Resources'
COMPONENT = 'dxmt-v0.80-remote.1'
EPOCH = 1776816000
COMMIT = '589adb780354b461645b29999cefaf533594ee99'
PATCH_SHA256 = 'af103ca38e19f6421675d3487a5ff81b9170692da1c5fc29e605079d21bac65e'
EXTRACTOR_SHA256 = '681a17040e62b8d5e8fb6f9f053ca6ff799455d0b98f90b209fb79ca44fca387'
INPUTS = {
    'dxmt-v0.80-source.tar.gz': ('https://codeload.github.com/3Shain/dxmt/tar.gz/refs/tags/v0.80', '79cd3a2b32749fc3890b6c2a9337f45de26fdb750014f3457bb7ebafa679492d'),
    'dxmt-v0.80-builtin.tar.gz': ('https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz', '8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d'),
    'llvm-project-15.0.7.tar.gz': ('https://codeload.github.com/llvm/llvm-project/tar.gz/refs/tags/llvmorg-15.0.7', '42a0088f148edcf6c770dfc780a7273014a9a89b66f357c761b4ca7c8dfa10ba'),
    'dxmt-directx-9df86f2.tar.gz': ('https://codeload.github.com/misyltoad/mingw-directx-headers/tar.gz/9df86f2341616ef1888ae59919feaa6d4fad693d', '9c1b8bbfd2d6c758fac4d93c2808a46bc1eee429fe656b4f21b29e02615aa8aa'),
    'llvm-mingw-20251216-ucrt-macos-universal.tar.xz': ('https://github.com/mstorsjo/llvm-mingw/releases/download/20251216/llvm-mingw-20251216-ucrt-macos-universal.tar.xz', '38bb5e48ec3e0ce95fb901f4efff0bd6ffa966d1b32539a6510af816a959d160'),
}
WINE_PINS = {
    'tools/winebuild/winebuild': 'c6ab0032f4d82edfc64f6724c6fdf3244122b2bf1b9f098e641136e2e38a801d',
    'dlls/ntdll/ntdll.so': 'ee3db713a091bcc6f34e4b9e9b8587c4c12528a78cf4c970a74780a7b526caee',
    'winemac.so': '407fdd69559745dc48fd9145c049b9dc291fd1d0037244e8d3e86c285e438316',
    'dlls/winecrt0/i386-windows/libwinecrt0.a': 'db074b01d2d2c2f121428ae8504ee1c9adb1d682d71f54c967087a759f12c33a',
    'dlls/winecrt0/x86_64-windows/libwinecrt0.a': '0d17ddfad158a932e4fe292377410f3a6e08ae553c83c143c5c9ce664555a7d4',
    'dlls/ntdll/i386-windows/libntdll.a': 'bf02af9d46758c85b9a4043413df66bd2ecc85f18a8372aea146374b69887005',
    'dlls/ntdll/x86_64-windows/libntdll.a': '28a24f67db12557d75f758a3edbc0e5379ca7020ee301ead133e7fb421051dfb',
}
WINE_SOURCE = 'winemac-wine11.0-metal.4-source.tar.gz'
WINE_SOURCE_SHA = '065432da2c0fc4bec24196d40ae7ad0b12ed7d6603e451c459aa3b9787c02fad'
STOCK = {
    'i386-windows/d3d10core.dll': 'c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f',
    'i386-windows/d3d11.dll': '9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d',
    'i386-windows/dxgi.dll': '7df8cdf66e12a108410002abc77b01f70aa59b8a36a70fa0bc6ae3b056841319',
    'i386-windows/winemetal.dll': '20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3',
    'x86_64-unix/winemetal.so': '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca',
    'x86_64-windows/d3d10core.dll': '833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26',
    'x86_64-windows/d3d11.dll': '7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47',
    'x86_64-windows/dxgi.dll': 'fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544',
    'x86_64-windows/nvapi64.dll': '7c37b66a88aa1fdb08c6035a7fe738af1c1b5eea53af78c4812498d22bef8bc3',
    'x86_64-windows/nvngx.dll': '18d5847ee524ba6eeb2eee656817ddc00a45c46759a753854335a765e997e5fe',
    'x86_64-windows/winemetal.dll': '514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0',
}

def sha(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def verify(path, expected):
    if not path.is_file() or sha(path) != expected:
        raise SystemExit(f'Missing or mismatched pinned input: {path}')

def run(*args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)

def output(*args):
    return subprocess.check_output(args, text=True).strip()

def tool_lock():
    tools = {}
    for name in ('clang', 'clang++', 'strip', 'install_name_tool'):
        path = pathlib.Path(output('xcrun', '--find', name)).absolute()
        tools[name] = {'path': str(path), 'sha256': sha(path)}
    for name in ('meson', 'ninja', 'cmake', 'python3', 'patch', 'xxd'):
        path = pathlib.Path(shutil.which(name) or '/missing').resolve()
        tools[name] = {'path': str(path), 'sha256': sha(path)}
    tools['versions'] = {name: output(name, '--version') for name in ('meson', 'ninja', 'cmake', 'python3')}
    sdk = pathlib.Path(output('xcrun', '--show-sdk-path'))
    # Pin SDK headers, interfaces and framework stubs, not only the SDK version label.
    digest = hashlib.sha256()
    for path in sorted(sdk.rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(sdk)).encode() + b'\0' + bytes.fromhex(sha(path)))
    tools['sdk'] = {'path': str(sdk), 'version': output('xcrun', '--show-sdk-version'), 'sha256': digest.hexdigest()}
    return tools

def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter='data')

def pack(directory, destination):
    with open(destination, 'wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as tar:
            for path in [directory, *sorted(directory.rglob('*'))]:
                if path.is_symlink():
                    raise SystemExit(f'Unexpected output symlink: {path}')
                info = tar.gettarinfo(str(path), str(path.relative_to(directory.parent)))
                info.uid = info.gid = 0
                info.uname = info.gname = 'root'
                info.mtime = EPOCH
                info.pax_headers = {}
                info.mode = 0o755 if path.is_dir() or os.access(path, os.X_OK) else 0o644
                if path.is_file():
                    with path.open('rb') as data:
                        tar.addfile(info, data)
                else:
                    tar.addfile(info)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fetch', action='store_true')
parser.add_argument('--lock-tools', action='store_true')
args = parser.parse_args()
CACHE.mkdir(parents=True, exist_ok=True)
lockfile = CACHE / 'dxmt-remote-toolchain.json'
if args.fetch:
    for name, (url, digest) in INPUTS.items():
        path = CACHE / name
        if not path.exists():
            temporary = path.with_suffix(path.suffix + '.download')
            urllib.request.urlretrieve(url, temporary)
            verify(temporary, digest)
            temporary.replace(path)
        verify(path, digest)
    sys.exit(0)
if args.lock_tools:
    lockfile.write_text(json.dumps(tool_lock(), indent=2, sort_keys=True) + '\n')
    print(lockfile)
    sys.exit(0)
if sys.platform != 'darwin':
    raise SystemExit('Requires macOS, Rosetta, Apple CLT/SDK, Meson, Ninja and CMake.')
if not lockfile.is_file():
    raise SystemExit('Freeze installed build tools first with --lock-tools. Build performs no network access.')
tools = tool_lock()
if tools != json.loads(lockfile.read_text()):
    raise SystemExit('Toolchain differs from frozen input lock; use the recorded SDK and tools.')
for name, (_, digest) in INPUTS.items():
    verify(CACHE / name, digest)
wine_original = pathlib.Path(os.environ.get('WINE_BUILD', ROOT / 'wine-development-inputs'))
if not wine_original.is_dir():
    raise SystemExit('Set WINE_BUILD to the MagicWine .4 development build, or rebuild from the bundled source archive.')
for name, digest in WINE_PINS.items():
    verify(wine_original / name, digest)
wine_source = CACHE / WINE_SOURCE if (CACHE / WINE_SOURCE).is_file() else RES / WINE_SOURCE
license_file = ROOT / 'LICENSE-DXMT.txt' if (ROOT / 'LICENSE-DXMT.txt').is_file() else RES / 'LICENSE-DXMT.txt'
verify(wine_source, WINE_SOURCE_SHA)
verify(license_file, '0acf1ce81dc7bbc0165f2f95ea359f37dc6bbe6546ef9f5feefa33496a942624')
verify(ROOT / 'patches/dxmt-remote-metal.patch', PATCH_SHA256)
verify(ROOT / 'scripts/extract-dxmt-shaders.py', EXTRACTOR_SHA256)
(ROOT / '.local').mkdir(parents=True, exist_ok=True)
work = pathlib.Path(tempfile.mkdtemp(prefix='dxmt-remote-build.', dir=ROOT / '.local'))
print('Build retained at', work, flush=True)
source_dist = work / (COMPONENT + '-source')
source_dist.mkdir()
inputs = source_dist / 'inputs'
inputs.mkdir()
# Retain corresponding-source inputs, not the large LLVM/MinGW build prerequisites.
for name in ('dxmt-v0.80-source.tar.gz', 'dxmt-v0.80-builtin.tar.gz', 'dxmt-directx-9df86f2.tar.gz'):
    shutil.copy2(CACHE / name, inputs / name)
shutil.copy2(wine_source, inputs / WINE_SOURCE)
shutil.copy2(lockfile, inputs / lockfile.name)
wine = source_dist / 'wine-development-inputs'
for name in WINE_PINS:
    target = wine / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(wine_original / name, target)
(wine / 'dlls/winemac.drv').mkdir(parents=True)
shutil.copy2(wine / 'winemac.so', wine / 'dlls/winemac.drv/winemac.so')
for name in ('scripts/build-dxmt.sh', 'scripts/extract-dxmt-shaders.py', 'patches/dxmt-remote-metal.patch'):
    target = source_dist / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / name, target)
shutil.copy2(license_file, source_dist / 'LICENSE-DXMT.txt')
extract(inputs / 'dxmt-v0.80-source.tar.gz', work)
src = work / 'dxmt-0.80'
with (ROOT / 'patches/dxmt-remote-metal.patch').open('rb') as patch:
    run('patch', '--batch', '--forward', '-p1', '-d', src, stdin=patch)
extract(inputs / 'dxmt-directx-9df86f2.tar.gz', work / 'directx')
shutil.copytree(next((work / 'directx').iterdir()), src / 'include/native/directx', dirs_exist_ok=True)
extract(inputs / 'llvm-project-15.0.7.tar.gz', work)
llvm_src = work / 'llvm-project-llvmorg-15.0.7'
extract(inputs / 'llvm-mingw-20251216-ucrt-macos-universal.tar.xz', work)
mingw = work / 'llvm-mingw-20251216-ucrt-macos-universal'
extract(inputs / 'dxmt-v0.80-builtin.tar.gz', work / 'stock')
payload = work / COMPONENT
shutil.copytree(work / 'stock/v0.80', payload)
for name, digest in STOCK.items():
    verify(payload / name, digest)
run(sys.executable, ROOT / 'scripts/extract-dxmt-shaders.py', work / 'stock/v0.80', src)
env = os.environ.copy()
for key in ('CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'AR', 'LD', 'STRIP', 'WINEARCH', 'WINEPREFIX'):
    env.pop(key, None)
env.update(PATH=str(mingw / 'bin') + os.pathsep + env['PATH'], SOURCE_DATE_EPOCH=str(EPOCH), LC_ALL='C', TZ='UTC', COPYFILE_DISABLE='1', MACOSX_DEPLOYMENT_TARGET='15.0')
env['SDKROOT'] = tools['sdk']['path']
os.environ.clear()
os.environ.update(env)
jobs = str(os.environ.get('JOBS', min(os.cpu_count() or 2, 8)))
llvm_build = work / 'llvm-build'
llvm_install = work / 'llvm-native'
native_file = work / 'apple-native.ini'
native_file.write_text("[binaries]\nc = " + repr(tools['clang']['path']) +
                       "\ncpp = " + repr(tools['clang++']['path']) + "\n")
run('cmake', '-G', 'Ninja', '-S', llvm_src / 'llvm', '-B', llvm_build,
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=x86_64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
    '-DCMAKE_C_COMPILER=' + tools['clang']['path'], '-DCMAKE_CXX_COMPILER=' + tools['clang++']['path'],
    '-DCMAKE_OSX_SYSROOT=' + tools['sdk']['path'],
    '-DLLVM_HOST_TRIPLE=x86_64-apple-darwin', '-DLLVM_ENABLE_ASSERTIONS=ON', '-DLLVM_ENABLE_ZSTD=OFF',
    '-DLLVM_TARGETS_TO_BUILD=', '-DLLVM_BUILD_TOOLS=OFF', '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_EXAMPLES=OFF',
    '-DBUG_REPORT_URL=https://github.com/3Shain/dxmt', '-DPACKAGE_VENDOR=DXMT', '-DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=OFF')
# Only libraries actually linked by airconv, plus their CMake dependencies.
import re
llvm_targets = re.findall(r"'-l(LLVM[^']+)'", (src / 'src/airconv/meson.build').read_text())
run('cmake', '--build', llvm_build, '--parallel', jobs, '--target', *llvm_targets)
shutil.copytree(llvm_src / 'llvm/include', llvm_install / 'include')
shutil.copytree(llvm_build / 'include', llvm_install / 'include', dirs_exist_ok=True)
shutil.copytree(llvm_build / 'lib', llvm_install / 'lib')
for bits, architecture, triplet in ((64, 'x86_64-windows', 'x86_64-w64-mingw32'), (32, 'i386-windows', 'i686-w64-mingw32')):
    build = work / f'build.{bits}'
    implib = work / f'dxgi.{bits}.a'
    run(mingw / 'bin' / (triplet + '-dlltool'), '-d', src / 'src/dxgi/dxgi.def', '-D', 'dxgi.dll', '-l', implib)
    run('meson', 'setup', build, src, '--cross-file', src / f'build-win{bits}.txt', '--native-file', native_file, '--buildtype=release',
        '-Dbuild_airconv_for_windows=false', '-Denable_tests=false', '-Denable_nvapi=false', '-Denable_nvngx=false',
        '-Dretained_shader_inputs=true',
        '-Dwine_builtin_dll=true', '-Dwine_build_path=' + str(wine), '-Dnative_llvm_path=' + str(llvm_install),
        '-Dstock_dxgi_import_library=' + str(implib), '-Dc_link_args=-Wl,--no-insert-timestamp', '-Dcpp_link_args=-Wl,--no-insert-timestamp')
    targets = ['src/d3d11/d3d11.dll', 'src/winemetal/winemetal.dll']
    if bits == 64:
        targets.append('src/winemetal/unix/winemetal.so')
    run('ninja', '-C', build, '-j', jobs, *targets)
    for module in ('d3d11', 'winemetal'):
        target = payload / architecture / (module + '.dll')
        shutil.copy2(build / 'src' / module / (module + '.dll'), target)
        run(mingw / 'bin' / (triplet + '-strip'), '--strip-unneeded', target)
        run(wine / 'tools/winebuild/winebuild', '--builtin', target)
    if bits == 64:
        native = payload / 'x86_64-unix/winemetal.so'
        shutil.copy2(build / 'src/winemetal/unix/winemetal.so', native)
        run(tools['install_name_tool']['path'], '-change', 'winemac.so', '@rpath/winemac.so', native)
        run('xcrun', 'strip', '-x', native)
changed = {f'{arch}/{name}.dll' for arch in ('i386-windows', 'x86_64-windows') for name in ('d3d11', 'winemetal')} | {'x86_64-unix/winemetal.so'}
for name in set(STOCK) - changed:
    verify(payload / name, STOCK[name])
# The source bundle contains both pristine inputs and complete altered DXMT source.
shutil.copytree(src, source_dist / 'dxmt-0.80')
RES.mkdir(parents=True, exist_ok=True)
pack(payload, RES / (COMPONENT + '.tar.gz'))
pack(source_dist, RES / (COMPONENT + '-source.tar.gz'))
metadata = {
    'schema': 1, 'component': COMPONENT, 'source_commit': COMMIT,
    'inputs': {name: {'url': url, 'sha256': digest} for name, (url, digest) in INPUTS.items()},
    'wine_development_inputs': WINE_PINS, 'wine_corresponding_source': {'file': WINE_SOURCE, 'sha256': WINE_SOURCE_SHA},
    'tools': tools, 'source_date_epoch': EPOCH,
    'recipe_sha256': sha(ROOT / 'scripts/build-dxmt.sh'), 'patch_sha256': sha(ROOT / 'patches/dxmt-remote-metal.patch'),
    'shader_extractor_sha256': sha(ROOT / 'scripts/extract-dxmt-shaders.py'),
    'shader_inputs': 'Unchanged generated arrays extracted by named PE/Mach-O symbols, bounded length globals and independent SHA-256 pins from the verified stock archive. Complete shader sources and upstream regeneration rules retained.',
    'shader_arrays': {
        'dxmt_command': {'size': 152339, 'sha256': '875e4990dcd818c6f4b5dfb697823afd0d2b851601f0b1e89ec0e5dd54bbf195'},
        'air_msad': {'size': 5152, 'sha256': 'fda73b9a7a91b11060737fd372678d18123f59142a22dd6f6ba2c5d36ffc3962'},
        'air_samplepos': {'size': 3488, 'sha256': '0abefdee437628a5bdd26be6ebf1b099ec7c546260b3c937e9ddc40bd4287e80'},
        'air_tessellation': {'size': 59536, 'sha256': '21eca32c2172d6434ece59c11a5375fd8195a6285779855ae9dac2a4d1f7c811'},
    },
    'shader_regeneration': 'Requires Apple Metal compiler (Xcode toolchain). Original rules: xcrun -sdk macosx metal -o NAME.air -c NAME.metal; xcrun -sdk macosx metallib -o dxmt_command.metallib dxmt_command.air; AIR helper compile adds -std=metal3.1 --target=air64-apple-macos14.0. xxd -n NAME -i INPUT NAME.h. Source files/rules remain in corresponding DXMT source. This package retains original generated arrays, not recompilations.',
    'rebuilt': sorted(changed), 'stock_payload_sha256': STOCK,
    'payload_sha256': {name: sha(payload / name) for name in sorted(STOCK)},
    'archive_sha256': sha(RES / (COMPONENT + '.tar.gz')),
    'source_archive_sha256': sha(RES / (COMPONENT + '-source.tar.gz')),
    'license': 'DXMT v0.80 MIT; dependency licenses retained in LICENSE-DXMT.txt and corresponding source archives.',
    'offline_rebuild': 'Extract the source bundle, run bash scripts/build-dxmt.sh --fetch once to cache the SHA-pinned LLVM/MinGW prerequisites, then run bash scripts/build-dxmt.sh using the recorded Apple toolchain. The build itself is offline. Bundled inputs/, wine-development-inputs/ and LICENSE-DXMT.txt are detected automatically; no checkout reconstruction is needed. DXMT_INPUTS and WINE_BUILD may override input locations; pins remain mandatory.',
}
provenance_path = RES / (COMPONENT + '-provenance.json')
provenance_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
# These pins are generated only from actual completed artifacts; no placeholders.
pins = '// Generated by scripts/build-dxmt.sh from real source-built artifacts.\nenum DXMTRemoteBuildPins {\n'
for key, value in [('archiveSHA256', metadata['archive_sha256']), ('sourceSHA256', metadata['source_archive_sha256']), ('provenanceSHA256', sha(provenance_path))]:
    pins += f'    static let {key} = "{value}"\n'
pins += '    static let payloadDigests: [String: String] = [\n'
for name, digest in metadata['payload_sha256'].items():
    pins += f'        "{name}": "{digest}",\n'
pins += '    ]\n}\n'
(ROOT / 'Sources/MagicWineCore/DXMTRemoteBuildPins.swift').write_text(pins)
print(json.dumps(metadata, indent=2, sort_keys=True))
print('Generated Resources:', COMPONENT + '.tar.gz,', COMPONENT + '-source.tar.gz,', COMPONENT + '-provenance.json')
print('Generated compile-time pins: Sources/MagicWineCore/DXMTRemoteBuildPins.swift')
PY
